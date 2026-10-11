// VS-01 WP01-E E1 corrective, LIVE targeted stress (real Nakama 3.25.0 +
// PostgreSQL): throttled claims racing trades (each trade changes the Trade v1
// object that guards the intent write) and each other still leave exactly one
// durable MC-1 intent; the result is later settled exactly once.
import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { authEmail, rpc, begin, order, newKey, sleep } from "./live_client.mjs";

const COMPOSE_DIR = fileURLToPath(new URL("../..", import.meta.url));
const DOCKER = process.env.DOCKER ?? "docker";
const G1 = "prototype_monster_01", G2 = "prototype_monster_02";

function rows(userId, collection) {
  if (!/^[0-9a-f-]{36}$/.test(userId) || !/^[a-z0-9_]+$/.test(collection)) throw new Error("bad id");
  const out = execFileSync(DOCKER, ["compose", "exec", "-T", "postgres", "psql", "-U", "postgres", "-d", "nakama", "-tAc",
    `SELECT value::text FROM storage WHERE collection = '${collection}' AND user_id = '${userId}'`], { cwd: COMPOSE_DIR }).toString();
  return out.split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l));
}

function body(a, ticketId, key) {
  return { gameplay_session_id: a.gsid, idempotency_key: key, ticket_id: ticketId, outcome: "victory", kills: 10, hero_alive: true };
}

const reason = (r) => (r.status === 200 ? "ok" : (JSON.stringify(r.body).match(/"message":"([a-z_]+)"/) || [])[1] || String(r.status));

// Spends the account's 12 claim requests of the current 60 s window with
// too_early claims on an open ticket, then frees the slot by abandoning it.
async function exhaustClaimQuota(a) {
  const t = (await rpc(a, "vs01e_encounter_begin", { gameplay_session_id: a.gsid, group_ids: [G2] })).body.ticket;
  const key = newKey();
  for (let i = 0; i < 12; i++) assert.equal(reason(await rpc(a, "vs01e_encounter_claim", body(a, t.ticket_id, key))), "too_early");
  assert.equal(reason(await rpc(a, "vs01e_encounter_claim", body(a, t.ticket_id, key))), "rate_limited");
  const ab = await rpc(a, "vs01e_encounter_abandon", { gameplay_session_id: a.gsid, idempotency_key: newKey(), ticket_id: t.ticket_id, confirm: true });
  assert.equal(ab.status, 200, JSON.stringify(ab.body));
}

test("throttled same-key claims racing trades: intent durable once, settled once later", async (t) => {
  const a = await authEmail("e1c-same");
  await begin(a);
  await exhaustClaimQuota(a);
  const tk = (await rpc(a, "vs01e_encounter_begin", { gameplay_session_id: a.gsid, group_ids: [G1] })).body.ticket;
  const key = newKey();
  const results = await Promise.all([
    ...Array.from({ length: 20 }, () => rpc(a, "vs01e_encounter_claim", body(a, tk.ticket_id, key))),
    ...Array.from({ length: 10 }, () => rpc(a, "vs01_trade", order(a.gsid, { quantity: 1 }))),
  ]);
  const claims = results.slice(0, 20).map(reason);
  const trades = results.slice(20).map(reason);
  t.diagnostic(`claims: ${claims.join(",")}`);
  t.diagnostic(`trades: ${trades.join(",")}`);
  for (const c of claims) assert.ok(["rate_limited", "conflict_retry_exhausted"].includes(c), c);
  for (const tr of trades) assert.equal(tr, "ok");
  const intents = rows(a.userId, "vs01_wp01e_claim_intents").filter((v) => v.ticket_id === tk.ticket_id);
  assert.equal(intents.length, 1);
  assert.equal(intents[0].idempotency_key, key);
  assert.equal(intents[0].state, "RECORDED");
  assert.ok(intents[0].first_seen_at_ms < tk.expires_at_ms);
  // Once the claim window rolls (and the ticket is 10 s old), the same key settles once.
  await sleep(61000);
  const done = await rpc(a, "vs01e_encounter_claim", body(a, tk.ticket_id, key));
  assert.equal(done.status, 200, JSON.stringify(done.body));
  assert.equal(done.body.replayed, false);
  assert.equal(done.body.receipt.intent_first_seen_at_ms, intents[0].first_seen_at_ms);
  const again = await Promise.all(Array.from({ length: 5 }, () => rpc(a, "vs01e_encounter_claim", body(a, tk.ticket_id, key))));
  for (const r of again) assert.equal(r.body.replayed, true);
  const hero = rows(a.userId, "vs01_wp01e_hero_progression");
  assert.equal(hero.length, 1);
  assert.equal(hero[0].level, 2);
  assert.equal(hero[0].revision, 1, "EXP awarded exactly once");
  const trade = rows(a.userId, "vs01_wp01_progress");
  assert.equal(trade[0].backpack.test_good_01, 10, "every trade applied once");
});

test("throttled DIFFERENT-key claims racing: exactly one intent, the others claim_locked (final)", async (t) => {
  const a = await authEmail("e1c-diff");
  await begin(a);
  await exhaustClaimQuota(a);
  const tk = (await rpc(a, "vs01e_encounter_begin", { gameplay_session_id: a.gsid, group_ids: [G1] })).body.ticket;
  const results = await Promise.all(Array.from({ length: 15 }, () => rpc(a, "vs01e_encounter_claim", body(a, tk.ticket_id, newKey()))));
  const out = results.map(reason);
  t.diagnostic(`claims: ${out.join(",")}`);
  const intents = rows(a.userId, "vs01_wp01e_claim_intents").filter((v) => v.ticket_id === tk.ticket_id);
  assert.equal(intents.length, 1);
  for (const r of out) assert.ok(["rate_limited", "claim_locked", "conflict_retry_exhausted"].includes(r), r);
  assert.ok(out.includes("claim_locked"), "losers see the recorded intent");
  assert.equal(rows(a.userId, "vs01_wp01e_hero_progression").length, 0, "no EXP while throttled");
});
