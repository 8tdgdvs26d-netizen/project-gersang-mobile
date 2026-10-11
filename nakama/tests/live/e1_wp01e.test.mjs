// VS-01 WP01-E (E1) live checks against the LOCAL Nakama 3.25.0 + PostgreSQL:
// the encounter flow end to end, ACK-1 (the Trade v1 object rewritten with an
// identical value keeps its value and version; trade unaffected), policy A,
// concurrent claims and cross-node settlement. Disposable accounts only.
import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { authEmail, rpc, begin, order, newKey, sleep } from "./live_client.mjs";

const COMPOSE_DIR = fileURLToPath(new URL("../..", import.meta.url));
const DOCKER = process.env.DOCKER ?? "docker";
const NODE2 = process.env.MYRIAL_NAKAMA_URL_2;
const G1 = "prototype_monster_01", G2 = "prototype_monster_02", G3 = "prototype_monster_03";
const MIN_AGE_WAIT_MS = 10300;

// Server-only objects are read straight from the LOCAL test database.
function row(userId, collection, key) {
  if (!/^[0-9a-f-]{36}$/.test(userId) || !/^[a-z0-9_]+$/.test(collection) || !/^[A-Za-z0-9_-]+$/.test(key)) throw new Error("bad id");
  const out = execFileSync(DOCKER, ["compose", "exec", "-T", "postgres", "psql", "-U", "postgres", "-d", "nakama", "-tA", "-F", "\x1f", "-c",
    `SELECT value::text, version, (extract(epoch from update_time) * 1000000)::bigint FROM storage WHERE collection = '${collection}' AND key = '${key}' AND user_id = '${userId}'`],
    { cwd: COMPOSE_DIR }).toString().trim();
  if (out === "") return null;
  const [value, version, updateMicros] = out.split("\x1f");
  return { value: JSON.parse(value), version, updateMicros: Number(updateMicros) };
}

async function encounter(account, groups = [G1], base) {
  const r = await rpc(account, "vs01e_encounter_begin", { gameplay_session_id: account.gsid, group_ids: groups }, { base });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body.ticket;
}

function claimBody(account, ticketId, o = {}) {
  return {
    gameplay_session_id: o.gsid ?? account.gsid, idempotency_key: o.key ?? newKey(), ticket_id: ticketId,
    outcome: o.outcome ?? "victory", kills: o.kills ?? 10, hero_alive: o.hero_alive ?? true,
  };
}

test("E1 flow: begin -> too_early -> claim after 10 s -> Level 2 -> replay -> progression", async () => {
  const a = await authEmail("e1-flow");
  await begin(a);
  const t = await encounter(a, [G1]);
  assert.equal(t.enemy_count, 10);
  const key = newKey();
  const early = await rpc(a, "vs01e_encounter_claim", claimBody(a, t.ticket_id, { key }));
  assert.equal(early.status, 400, JSON.stringify(early.body)); // FAILED_PRECONDITION
  assert.match(JSON.stringify(early.body), /too_early/);
  assert.equal(row(a.userId, "vs01_wp01e_claim_intents", t.ticket_id).value.state, "RECORDED");
  await sleep(MIN_AGE_WAIT_MS);
  const r = await rpc(a, "vs01e_encounter_claim", claimBody(a, t.ticket_id, { key }));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.replayed, false);
  assert.equal(r.body.receipt.exp_awarded, 100);
  assert.deepEqual(r.body.progression, { level: 2, exp: 0, exp_to_next: 150, revision: 1 });
  const again = await rpc(a, "vs01e_encounter_claim", claimBody(a, t.ticket_id, { key }));
  assert.equal(again.body.replayed, true);
  assert.deepEqual(again.body.receipt, r.body.receipt);
  const p = await rpc(a, "vs01e_progression_get", { gameplay_session_id: a.gsid });
  assert.equal(p.status, 200);
  assert.equal(p.body.progression.level, 2);
  assert.equal(p.body.unresolved_ticket, null);
  const hero = row(a.userId, "vs01_wp01e_hero_progression", "hero");
  assert.equal(hero.value.level, 2);
  assert.ok(row(a.userId, "vs01_wp01e_ticket_claims", t.ticket_id));
});

test("ACK-1 (real PostgreSQL): identical-value rewrite keeps the Trade v1 value AND version; update_time changes; trade unaffected", async (t) => {
  const a = await authEmail("e1-ack1");
  await begin(a);
  // Give the trade object varied numbers first: money, stock, a recovery anchor (ms epoch).
  for (const o of [order(a.gsid, { quantity: 10 }), order(a.gsid, { action: "sell", quantity: 1 }), order(a.gsid, { city_id: "B", good_id: "test_good_06", quantity: 1 })]) {
    const tr = await rpc(a, "vs01_trade", o);
    assert.equal(tr.status, 200, JSON.stringify(tr.body));
  }
  const before = row(a.userId, "vs01_wp01_progress", "trade");
  assert.ok(before.value.market_recovery_anchor_ms > 1e12, "a large integer is present");
  const tk = await encounter(a, [G2]);
  const afterBegin = row(a.userId, "vs01_wp01_progress", "trade");
  await sleep(MIN_AGE_WAIT_MS);
  const c = await rpc(a, "vs01e_encounter_claim", claimBody(a, tk.ticket_id));
  assert.equal(c.status, 200, JSON.stringify(c.body));
  const afterClaim = row(a.userId, "vs01_wp01_progress", "trade");
  for (const [label, r] of [["begin", afterBegin], ["claim", afterClaim]]) {
    assert.deepEqual(r.value, before.value, `${label}: Trade v1 value unchanged (JSONB compare)`);
    assert.equal(r.version, before.version, `${label}: Trade v1 version (md5) unchanged`);
  }
  t.diagnostic(`ACK-1 evidence: version ${before.version} -> ${afterBegin.version} -> ${afterClaim.version}; update_time micros ${before.updateMicros} -> ${afterBegin.updateMicros} -> ${afterClaim.updateMicros}`);
  assert.ok(afterClaim.updateMicros > before.updateMicros, "update_time is touched (known, accepted: no WP01 code reads it)");
  // The trade receipt history and money are unchanged, and trading continues.
  const tr = await rpc(a, "vs01_trade", order(a.gsid, { quantity: 1 }));
  assert.equal(tr.status, 200, JSON.stringify(tr.body));
  assert.equal(tr.body.receipt.money_before, before.value.money);
});

test("policy A (live): superseded claim refused, reclaim resends the same key exactly once", async () => {
  const a = await authEmail("e1-takeover");
  const first = await begin(a);
  const tk = await encounter(a, [G1]);
  await sleep(MIN_AGE_WAIT_MS);
  const key = newKey();
  await begin(a); // another device takes over
  const stale = await rpc(a, "vs01e_encounter_claim", claimBody(a, tk.ticket_id, { key, gsid: first }));
  assert.equal(stale.status, 409, JSON.stringify(stale.body)); // ABORTED
  assert.match(JSON.stringify(stale.body), /gameplay_session_superseded/);
  assert.equal(row(a.userId, "vs01_wp01e_hero_progression", "hero"), null);
  await begin(a); // the original device reclaims
  const r = await rpc(a, "vs01e_encounter_claim", claimBody(a, tk.ticket_id, { key }));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const r2 = await rpc(a, "vs01e_encounter_claim", claimBody(a, tk.ticket_id, { key }));
  assert.equal(r2.body.replayed, true);
  assert.equal(row(a.userId, "vs01_wp01e_hero_progression", "hero").value.revision, 1);
});

test("concurrency (live): 10 parallel same-key and 10 parallel different-key claims settle exactly once", async (t) => {
  const a = await authEmail("e1-same");
  await begin(a);
  const ta = await encounter(a, [G1]);
  const b = await authEmail("e1-diff");
  await begin(b);
  const tb = await encounter(b, [G3]);
  await sleep(MIN_AGE_WAIT_MS);
  const key = newKey();
  const same = await Promise.all(Array.from({ length: 10 }, () => rpc(a, "vs01e_encounter_claim", claimBody(a, ta.ticket_id, { key }))));
  const applied = same.filter((r) => r.status === 200 && r.body.replayed === false);
  const replayed = same.filter((r) => r.status === 200 && r.body.replayed === true);
  t.diagnostic(`same key: ${same.map((r) => r.status).join(",")}`);
  assert.equal(applied.length, 1);
  assert.equal(replayed.length, 9);
  for (const r of replayed) assert.deepEqual(r.body.receipt, applied[0].body.receipt);
  assert.equal(row(a.userId, "vs01_wp01e_hero_progression", "hero").value.revision, 1);

  const diff = await Promise.all(Array.from({ length: 10 }, () => rpc(b, "vs01e_encounter_claim", claimBody(b, tb.ticket_id))));
  t.diagnostic(`different keys: ${diff.map((r) => `${r.status}:${r.status === 200 ? "ok" : JSON.stringify(r.body).match(/[a-z_]+(?=")/g)?.pop()}`).join(",")}`);
  assert.equal(diff.filter((r) => r.status === 200).length, 1);
  for (const r of diff.filter((x) => x.status !== 200)) assert.match(JSON.stringify(r.body), /ticket_already_claimed|claim_locked/);
  assert.equal(row(b.userId, "vs01_wp01e_hero_progression", "hero").value.revision, 1);
});

test("cross-node (live): begin on node 1, claim on node 2, replay on node 1", { skip: !NODE2 && "MYRIAL_NAKAMA_URL_2 not set" }, async () => {
  const a = await authEmail("e1-nodes");
  await begin(a);
  const tk = await encounter(a, [G2]);
  await sleep(MIN_AGE_WAIT_MS);
  const key = newKey();
  const r = await rpc(a, "vs01e_encounter_claim", claimBody(a, tk.ticket_id, { key }), { base: NODE2 });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const r2 = await rpc(a, "vs01e_encounter_claim", claimBody(a, tk.ticket_id, { key }));
  assert.equal(r2.body.replayed, true);
  assert.deepEqual(r2.body.receipt, r.body.receipt);
});
