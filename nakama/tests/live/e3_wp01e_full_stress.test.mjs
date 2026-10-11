// VS-01 WP01-E E3 FULL STRESS (LIVE, local Nakama 3.25.0 + PostgreSQL 16,
// two nodes when MYRIAL_NAKAMA_URL_2 is set). Disposable accounts only.
// Invariants checked against the database itself (server-only objects):
// one settlement per ticket, one receipt per key, Hero EXP = sum of applied
// receipts, Trade v1 consistent with its receipts, no write by a superseded
// session, approved quotas never exceeded.
import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { authEmail, rpc, begin, order, newKey, sleep, BASE } from "./live_client.mjs";

const COMPOSE_DIR = fileURLToPath(new URL("../..", import.meta.url));
const DOCKER = process.env.DOCKER ?? "docker";
const NODE2 = process.env.MYRIAL_NAKAMA_URL_2 ?? BASE;
const G1 = "prototype_monster_01", G2 = "prototype_monster_02";
const MIN_AGE_WAIT_MS = 10300;
const node = (i) => (i % 2 === 0 ? BASE : NODE2); // alternate the two nodes

function sql(query) {
  return execFileSync(DOCKER, ["compose", "exec", "-T", "postgres", "psql", "-U", "postgres", "-d", "nakama", "-tAc", query],
    { cwd: COMPOSE_DIR, maxBuffer: 64 * 1024 * 1024 }).toString();
}
function rows(userId, collection) {
  if (!/^[0-9a-f-]{36}$/.test(userId) || !/^[a-z0-9_]+$/.test(collection)) throw new Error("bad id");
  return sql(`SELECT value::text FROM storage WHERE collection = '${collection}' AND user_id = '${userId}'`)
    .split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l));
}
function hero(userId) {
  const h = rows(userId, "vs01_wp01e_hero_progression");
  return h.length === 0 ? null : h[0];
}
const reason = (r) => (r.status === 200 ? (r.body.replayed ? "replayed" : "applied")
  : ((typeof r.body === "object" && r.body !== null && r.body.message) || JSON.stringify(r.body).match(/[a-z_]{6,}/)?.[0] || String(r.status)));
const tally = (list) => list.reduce((acc, x) => { acc[x] = (acc[x] ?? 0) + 1; return acc; }, {});

async function account(label) {
  const a = await authEmail(label);
  await begin(a);
  return a;
}
async function ticket(a, groups = [G1], base = BASE) {
  const r = await rpc(a, "vs01e_encounter_begin", { gameplay_session_id: a.gsid, group_ids: groups }, { base });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body.ticket;
}
function claimBody(a, ticketId, key = newKey(), o = {}) {
  return { gameplay_session_id: o.gsid ?? a.gsid, idempotency_key: key, ticket_id: ticketId,
    outcome: o.outcome ?? "victory", kills: o.kills ?? 10, hero_alive: o.hero_alive ?? true };
}
// Sum of exp_awarded of every applied claim receipt of the account.
function receiptExp(userId) {
  return rows(userId, "vs01_wp01e_receipts").filter((r) => r.kind === "claim").reduce((s, r) => s + r.exp_awarded, 0);
}

test("FS-1: 50 concurrent same-key claims (two nodes) settle exactly once; throttled ones replay later", async (t) => {
  const a = await account("fs1");
  const tk = await ticket(a);
  await sleep(MIN_AGE_WAIT_MS);
  const key = newKey();
  const first = await Promise.all(Array.from({ length: 50 }, (_, i) => rpc(a, "vs01e_encounter_claim", claimBody(a, tk.ticket_id, key), { base: node(i) })));
  const out = first.map(reason);
  t.diagnostic(`FS-1 first wave: ${JSON.stringify(tally(out))}`);
  assert.equal(out.filter((x) => x === "applied").length, 1);
  for (const x of out) assert.ok(["applied", "replayed", "rate_limited"].includes(x), x);
  const applied = first.find((r) => reason(r) === "applied");
  for (const r of first.filter((x) => reason(x) === "replayed")) assert.deepEqual(r.body.receipt, applied.body.receipt);
  await sleep(61000); // throttled requests are transient: resend them after the window
  const throttled = out.filter((x) => x === "rate_limited").length;
  const second = [];
  for (let i = 0; i < throttled; i++) second.push(await rpc(a, "vs01e_encounter_claim", claimBody(a, tk.ticket_id, key), { base: node(i) }));
  t.diagnostic(`FS-1 resend of ${throttled} throttled: ${JSON.stringify(tally(second.map(reason)))}`);
  for (const r of second) assert.equal(reason(r), "replayed");
  assert.equal(hero(a.userId).revision, 1);
  assert.equal(rows(a.userId, "vs01_wp01e_receipts").length, 1);
  assert.equal(rows(a.userId, "vs01_wp01e_ticket_claims").length, 1);
});

test("FS-2: 50 different keys racing for one ticket: one settlement, the rest locked / already claimed / throttled", async (t) => {
  const a = await account("fs2");
  const tk = await ticket(a);
  await sleep(MIN_AGE_WAIT_MS);
  const res = await Promise.all(Array.from({ length: 50 }, (_, i) => rpc(a, "vs01e_encounter_claim", claimBody(a, tk.ticket_id), { base: node(i) })));
  const out = res.map(reason);
  t.diagnostic(`FS-2: ${JSON.stringify(tally(out))}`);
  assert.equal(out.filter((x) => x === "applied").length, 1);
  for (const x of out) assert.ok(["applied", "ticket_already_claimed", "claim_locked", "rate_limited"].includes(x), x);
  assert.equal(hero(a.userId).revision, 1);
  assert.equal(rows(a.userId, "vs01_wp01e_ticket_claims").length, 1);
  assert.equal(rows(a.userId, "vs01_wp01e_claim_intents").length, 1);
  assert.equal(receiptExp(a.userId), 100);
});

test("FS-3: 50 concurrent begins create at most one unresolved ticket", async (t) => {
  const a = await account("fs3");
  const res = await Promise.all(Array.from({ length: 50 }, (_, i) => rpc(a, "vs01e_encounter_begin", { gameplay_session_id: a.gsid, group_ids: [G1] }, { base: node(i) })));
  const out = res.map((r) => (r.status === 200 ? "issued" : reason(r)));
  t.diagnostic(`FS-3: ${JSON.stringify(tally(out))}`);
  assert.equal(out.filter((x) => x === "issued").length, 1);
  for (const x of out) assert.ok(["issued", "ticket_unsettled", "rate_limited"].includes(x), x);
  assert.ok(out.filter((x) => x !== "rate_limited").length <= 6, "begin quota 6 / 60 s");
  assert.equal(rows(a.userId, "vs01_wp01e_tickets").length, 1);
});

test("FS-4: 50 claim / abandon races (50 accounts): exactly one terminal outcome per ticket", async (t) => {
  const accounts = await Promise.all(Array.from({ length: 50 }, (_, i) => account(`fs4-${i}`)));
  const tickets = await Promise.all(accounts.map((a, i) => ticket(a, [G1], node(i))));
  await sleep(MIN_AGE_WAIT_MS);
  const results = await Promise.all(accounts.map((a, i) => Promise.all([
    rpc(a, "vs01e_encounter_claim", claimBody(a, tickets[i].ticket_id), { base: node(i) }),
    rpc(a, "vs01e_encounter_abandon", { gameplay_session_id: a.gsid, idempotency_key: newKey(), ticket_id: tickets[i].ticket_id, confirm: true }, { base: node(i + 1) }),
  ])));
  const outcomes = { claimed: 0, abandoned: 0 };
  results.forEach(([c, ab], i) => {
    const a = accounts[i];
    const status = rows(a.userId, "vs01_wp01e_tickets")[0].status;
    if (status === "CLAIMED") {
      outcomes.claimed += 1;
      assert.equal(reason(c), "applied");
      assert.match(reason(ab), /ticket_already_claimed/);
      assert.equal(hero(a.userId).revision, 1);
    } else {
      outcomes.abandoned += 1;
      assert.equal(status, "ABANDONED");
      assert.equal(reason(ab), "applied");
      assert.match(reason(c), /ticket_abandoned/);
      assert.equal(hero(a.userId), null, "an abandoned ticket pays nothing");
    }
  });
  t.diagnostic(`FS-4 outcomes: ${JSON.stringify(outcomes)}`);
  assert.equal(outcomes.claimed + outcomes.abandoned, 50);
});

test("FS-5: 5-minute abandon / begin bot: at most 6 accepted per rolling 60 s, zero EXP", async (t) => {
  const a = await account("fs5");
  const accepted = [];
  const tally5 = {};
  const end = Date.now() + 300000;
  let i = 0;
  while (Date.now() < end) {
    // Every request the limiter accepts counts (also refusals decided after
    // the limiter, e.g. ticket_unsettled); only rate_limited is not counted.
    const b = await rpc(a, "vs01e_encounter_begin", { gameplay_session_id: a.gsid, group_ids: [G1] }, { base: node(i++) });
    const bk = `begin:${b.status === 200 ? "ok" : reason(b)}`;
    tally5[bk] = (tally5[bk] ?? 0) + 1;
    if (reason(b) !== "rate_limited") accepted.push(Date.now());
    const st = rows(a.userId, "vs01_wp01e_encounter_state");
    const open = st.length ? st[0].open_ticket_id : "";
    if (open) {
      const ab = await rpc(a, "vs01e_encounter_abandon", { gameplay_session_id: a.gsid, idempotency_key: newKey(), ticket_id: open, confirm: true }, { base: node(i++) });
      const ak = `abandon:${ab.status === 200 ? "ok" : reason(ab)}`;
      tally5[ak] = (tally5[ak] ?? 0) + 1;
      if (reason(ab) !== "rate_limited") accepted.push(Date.now());
    }
    await sleep(200);
  }
  let maxWindow = 0;
  for (let s = 0; s < accepted.length; s++) {
    const n = accepted.filter((x) => x >= accepted[s] && x < accepted[s] + 58000).length;
    maxWindow = Math.max(maxWindow, n);
  }
  t.diagnostic(`FS-5: ${JSON.stringify(tally5)}; accepted ${accepted.length} in 300 s; max in any 58 s window ${maxWindow}`);
  assert.ok(maxWindow <= 6, `begin + abandon accepted ${maxWindow} > 6 in a window`);
  assert.ok(accepted.length <= 6 * 6, "at most the quota for the run");
  assert.equal(hero(a.userId), null, "rerolls never award EXP");
});

test("FS-6: trades and Online EXP written concurrently on 10 accounts (two nodes): both exact, Trade v1 intact", async (t) => {
  const accounts = await Promise.all(Array.from({ length: 10 }, (_, i) => account(`fs6-${i}`)));
  const tickets = await Promise.all(accounts.map((a, i) => ticket(a, [G2], node(i))));
  await sleep(MIN_AGE_WAIT_MS);
  const per = await Promise.all(accounts.map((a, i) => Promise.all([
    rpc(a, "vs01e_encounter_claim", claimBody(a, tickets[i].ticket_id), { base: node(i) }),
    ...Array.from({ length: 10 }, (_, k) => rpc(a, "vs01_trade", order(a.gsid, { quantity: 1 }), { base: node(i + k) })),
  ])));
  let trades = 0;
  per.forEach(([c, ...tr], i) => {
    const a = accounts[i];
    assert.equal(reason(c), "applied");
    for (const r of tr) { assert.equal(r.status, 200, JSON.stringify(r.body)); trades += 1; }
    const p = rows(a.userId, "vs01_wp01_progress")[0];
    const receipts = rows(a.userId, "vs01_wp01_receipts");
    assert.equal(receipts.length, 10);
    assert.equal(p.backpack.test_good_01, 10, "every trade applied once");
    assert.equal(p.money, 10000 - receipts.reduce((s, r) => s + r.total, 0), "money = start - sum of trade receipts");
    assert.equal(hero(a.userId).revision, 1);
    assert.equal(receiptExp(a.userId), 100);
  });
  t.diagnostic(`FS-6: 10 claims applied, ${trades} trades applied`);
});

test("FS-7: server restart during in-flight claims: each settles exactly once after the restart", async (t) => {
  const accounts = await Promise.all(Array.from({ length: 6 }, (_, i) => account(`fs7-${i}`)));
  const tickets = await Promise.all(accounts.map((a) => ticket(a)));
  await sleep(MIN_AGE_WAIT_MS);
  const keys = accounts.map(() => newKey());
  const inFlight = accounts.map((a, i) => rpc(a, "vs01e_encounter_claim", claimBody(a, tickets[i].ticket_id, keys[i])).catch(() => null));
  execFileSync(DOCKER, ["compose", "restart", "nakama"], { cwd: COMPOSE_DIR, stdio: "ignore" });
  const before = (await Promise.all(inFlight)).map((r) => (r ? reason(r) : "no answer"));
  for (let i = 0; i < 60; i++) { try { if ((await fetch(`${BASE}/healthcheck`)).ok) break; } catch { /* restarting */ } await sleep(1000); }
  const after = await Promise.all(accounts.map((a, i) => rpc(a, "vs01e_encounter_claim", claimBody(a, tickets[i].ticket_id, keys[i]))));
  t.diagnostic(`FS-7 during restart: ${JSON.stringify(tally(before))}; after: ${JSON.stringify(tally(after.map(reason)))}`);
  after.forEach((r, i) => {
    assert.ok(["applied", "replayed"].includes(reason(r)), reason(r));
    assert.equal(hero(accounts[i].userId).revision, 1, "exactly one award");
    assert.equal(rows(accounts[i].userId, "vs01_wp01e_receipts").length, 1);
  });
});

test("FS-8: lost replies (client aborts after send): the same key resolves to one outcome", async (t) => {
  const accounts = await Promise.all(Array.from({ length: 10 }, (_, i) => account(`fs8-${i}`)));
  const tickets = await Promise.all(accounts.map((a) => ticket(a)));
  await sleep(MIN_AGE_WAIT_MS);
  const keys = accounts.map(() => newKey());
  await Promise.all(accounts.map(async (a, i) => {
    const ctrl = new AbortController();
    const p = rpc(a, "vs01e_encounter_claim", claimBody(a, tickets[i].ticket_id, keys[i]), { signal: ctrl.signal }).catch(() => null);
    await sleep(5 + (i % 5) * 3);
    ctrl.abort();
    await p;
  }));
  const retry = await Promise.all(accounts.map((a, i) => rpc(a, "vs01e_encounter_claim", claimBody(a, tickets[i].ticket_id, keys[i]))));
  t.diagnostic(`FS-8 retry: ${JSON.stringify(tally(retry.map(reason)))}`);
  retry.forEach((r, i) => {
    assert.ok(["applied", "replayed"].includes(reason(r)));
    assert.equal(hero(accounts[i].userId).revision, 1);
  });
});

test("FS-9: session takeover racing claims (20 accounts): no superseded write; reclaim + same key settles once", async (t) => {
  const accounts = await Promise.all(Array.from({ length: 20 }, (_, i) => account(`fs9-${i}`)));
  const tickets = await Promise.all(accounts.map((a) => ticket(a)));
  await sleep(MIN_AGE_WAIT_MS);
  const keys = accounts.map(() => newKey());
  const race = await Promise.all(accounts.map((a, i) => {
    const old = a.gsid;
    return Promise.all([
      rpc(a, "vs01e_encounter_claim", claimBody(a, tickets[i].ticket_id, keys[i], { gsid: old }), { base: node(i) }),
      rpc(a, "vs01_session_begin", {}, { base: node(i + 1) }),
    ]);
  }));
  const first = race.map(([c]) => reason(c));
  t.diagnostic(`FS-9 claim during takeover: ${JSON.stringify(tally(first))}`);
  for (const x of first) assert.ok(["applied", "gameplay_session_superseded"].includes(x), x);
  for (let i = 0; i < accounts.length; i++) {
    const h = hero(accounts[i].userId);
    if (first[i] === "gameplay_session_superseded") assert.equal(h, null, "superseded: nothing written");
    await begin(accounts[i]); // the original device reclaims
    const r = await rpc(accounts[i], "vs01e_encounter_claim", claimBody(accounts[i], tickets[i].ticket_id, keys[i]));
    assert.ok(["applied", "replayed"].includes(reason(r)), reason(r));
    assert.equal(hero(accounts[i].userId).revision, 1, "exactly once after reclaim");
  }
});

test("FS-10: database load of one settled claim (evidence only, not pass/fail)", async (t) => {
  const stats = () => {
    const [ins, upd, idx, seq] = sql("select n_tup_ins, n_tup_upd, idx_scan, seq_scan from pg_stat_user_tables where relname = 'storage'").trim().split("|").map(Number);
    return { ins, upd, scans: idx + seq };
  };
  const accounts = await Promise.all(Array.from({ length: 10 }, (_, i) => account(`fs10-${i}`)));
  const tickets = await Promise.all(accounts.map((a) => ticket(a)));
  await sleep(12000);
  const before = stats();
  for (let i = 0; i < 10; i++) assert.equal(reason(await rpc(accounts[i], "vs01e_encounter_claim", claimBody(accounts[i], tickets[i].ticket_id))), "applied");
  await sleep(12000);
  const after = stats();
  t.diagnostic(`FS-10 per settled claim: inserts ${((after.ins - before.ins) / 10).toFixed(2)}, updates ${((after.upd - before.upd) / 10).toFixed(2)}, scans ${((after.scans - before.scans) / 10).toFixed(2)}`);
});
