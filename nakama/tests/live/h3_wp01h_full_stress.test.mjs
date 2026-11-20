// VS-01 WP01-H E3 FULL STRESS (server layer) against ONE isolated run.
// FS IDs are PROVISIONAL (D-P6 PENDING): numbered in the order Blueprint
// v0.1r3 §9 lists the ten topics. Covered here: FS-K2 (client-side lost
// replies), FS-K3, FS-K4, FS-K7, FS-K9 (ledger part), FS-K10 (+ AC-16).
// FS-K9 live mutation is NOT RUN (needs separate approval).
// FS-K10 runs only with MYRIAL_WP01H_E3_TTL=1 (real 15-minute TTL, one node,
// nothing else running) and is judged ONLY from server-recorded times
// (tools/wp01h_clock.mjs, Blueprint v0.1r2 REV-01 / F-01).
// Skipped unless run by nakama/scripts/run_wp01h_e3_bounded.mjs.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { authEmail, rpc, begin, newKey, sleep, BASE } from "./live_client.mjs";
import { objects, ledger, C, runProject } from "./tools/wp01h_db.mjs";
import { estimateOffset, serverTimeRegressed, sendAtClientMs, roundVerdict, TTL_MS } from "./tools/wp01h_clock.mjs";

const RUN = process.env.MYRIAL_WP01H_E3_RUN_ID ?? "";
const PHASE = process.env.MYRIAL_WP01H_E3_PHASE ?? "main";
const TTL = process.env.MYRIAL_WP01H_E3_TTL === "1";
const NODE2 = process.env.MYRIAL_NAKAMA_URL_2 ?? BASE;
const CASE_DIR = process.env.MYRIAL_WP01H_E3_CASE_DIR ?? "";
const NOT_RUN = !RUN ? "WP01-H E3 only: run via nakama/scripts/run_wp01h_e3_bounded.mjs" : PHASE !== "main" ? `phase ${PHASE}` : false;
const STRESS = NOT_RUN || (TTL ? "TTL job runs FS-K10 only" : false);
const ROUND = NOT_RUN || (!TTL ? "set MYRIAL_WP01H_E3_TTL=1 (TTL job, ~16 min)" : false);
if (RUN) runProject();
const accounts = [];
const reason = (r) => (r.status === 200 ? (r.body.replayed ? "replayed" : r.body.receipt?.status ?? "ok") : (r.body && typeof r.body === "object" && r.body.message) || (r.error ?? String(r.status)));
function record(id, data) { if (CASE_DIR) fs.appendFileSync(`${CASE_DIR}/${id}.jsonl`, JSON.stringify({ at: new Date().toISOString(), id, ...data }) + "\n", { mode: 0o600 }); }
async function account(label) { const a = await authEmail(`wp01h-${label}`); await begin(a); accounts.push(a); return a; }
const cmd = (o = {}) => ({ action: "buy", city_id: "A", good_id: "test_good_01", quantity: 1, ...o });
const trade = (a, key, c, opt) => rpc(a, "vs01_trade", { gameplay_session_id: a.gsid, idempotency_key: key, ...c }, opt);
const resolve = (a, key, c, opt) => rpc(a, "vs01_trade_resolve", { gameplay_session_id: a.gsid, idempotency_key: key, ...c }, opt);
const tradeReceipts = (a, key) => objects(a.userId, C.tradeReceipts).map((o) => o.value).filter((r) => key === undefined || r.idempotency_key === key);
async function settle(a, key, c) { // one sequential resolve until the key has its single receipt
  for (let i = 0; i < 5 && tradeReceipts(a, key).length === 0; i++) { await resolve(a, key, c); if (!tradeReceipts(a, key).length) await sleep(2000); }
  return tradeReceipts(a, key);
}
const safe = (p) => p.catch((e) => ({ status: 0, body: null, error: e.name || String(e) }));

test("FS-K2 lost replies (client aborts at random points): every key ends with exactly one receipt", { skip: STRESS }, async () => {
  const a = await account("k2");
  const keys = [];
  for (let i = 0; i < 24; i++) {
    const key = newKey(); keys.push(key);
    await safe(trade(a, key, cmd(), { signal: AbortSignal.timeout(5 + Math.floor(Math.random() * 120)) }));
    await sleep(400); // 25 trades / 10 s at most
  }
  await sleep(10000);
  for (const k of keys) { const rs = await settle(a, k, cmd()); assert.equal(rs.length, 1, `key ${k}: ${rs.length}`); await sleep(400); }
  assert.deepEqual(ledger(a.userId).problems, []);
  record("FS-K2", { keys: keys.length, outcomes: keys.map((k) => tradeReceipts(a, k)[0].status) });
});

test("FS-K3 race: same key (100 requests, 2 nodes), 50 different keys, 100 trade/resolve pairs", { skip: STRESS }, async () => {
  const a = await account("k3a");
  const key = newKey();
  const all = await Promise.all([...Array(50)].flatMap((_, i) => [safe(trade(a, key, cmd(), { base: i % 2 ? NODE2 : BASE })), safe(resolve(a, key, cmd(), { base: i % 2 ? BASE : NODE2 }))]));
  assert.ok(tradeReceipts(a, key).length <= 1);
  assert.equal((await settle(a, key, cmd())).length, 1, "(a) one receipt for the hot key");
  const statuses = new Set(all.filter((r) => r.status === 200).map((r) => r.body.receipt.status));
  assert.ok(statuses.size <= 1, `(a) every success shows the same outcome: ${[...statuses]}`);
  const b = await account("k3b");
  await Promise.all([...Array(50)].map((_, i) => safe(trade(b, newKey(), cmd(), { base: i % 2 ? NODE2 : BASE }))));
  assert.deepEqual(ledger(b.userId).problems, [], "(b) money / carried equal the applied receipts, nothing negative");
  const c = await account("k3c");
  const pairs = [...Array(100)].map(() => newKey());
  for (let i = 0; i < pairs.length; i += 10) {
    await Promise.all(pairs.slice(i, i + 10).flatMap((k) => [safe(trade(c, k, cmd())), safe(resolve(c, k, cmd(), { base: NODE2 }))]));
    await sleep(4000);
  }
  for (const k of pairs) { const rs = await settle(c, k, cmd()); assert.equal(rs.length, 1, `(c) key ${k}`); }
  assert.deepEqual(ledger(c.userId).problems, []);
  record("FS-K3", { hot_key_outcome: tradeReceipts(a, key)[0].status });
});

test("FS-K4 takeover: superseded sessions write nothing; one outcome per key / ticket after reclaim", { skip: STRESS }, async () => {
  for (let n = 0; n < 20; n++) {
    const a = await account(`k4_${n}`);
    const tk = (await rpc(a, "vs01e_encounter_begin", { gameplay_session_id: a.gsid, group_ids: ["prototype_monster_01"] })).body.ticket;
    const tkey = newKey(), ckey = newKey();
    await rpc(a, "vs01e_encounter_claim", { gameplay_session_id: a.gsid, idempotency_key: ckey, ticket_id: tk.ticket_id, outcome: "victory", kills: 10, hero_alive: true });
    const s1 = { ...a };
    await begin(a); // S2
    const [r1, t1, c1, r2] = await Promise.all([
      safe(resolve(s1, tkey, cmd())), safe(trade(s1, tkey, cmd())),
      safe(rpc(s1, "vs01e_encounter_abandon", { gameplay_session_id: s1.gsid, idempotency_key: newKey(), ticket_id: tk.ticket_id, confirm: true })),
      safe(resolve(a, tkey, cmd())),
    ]);
    for (const r of [r1, t1, c1]) assert.equal(reason(r), "gameplay_session_superseded", `S1 must not write: ${JSON.stringify(r.body)}`);
    assert.ok(r2.status === 200 || reason(r2) === "rate_limited", JSON.stringify(r2.body));
    await begin(s1); // S1 reclaims; S2 is superseded now
    const back = await resolve(s1, tkey, cmd());
    assert.equal(back.status, 200, JSON.stringify(back.body));
    const rs = tradeReceipts(a, tkey);
    assert.equal(rs.length, 1);
    if (rs[0].status === "voided") assert.ok([a.gsid, s1.gsid].includes(rs[0].resolved_by_session_id), "tombstone written by an active session");
    const settlements = objects(a.userId, C.combatReceipts).map((o) => o.value).filter((r) => r.ticket_id === tk.ticket_id);
    assert.ok(settlements.length <= 1);
    assert.deepEqual(ledger(a.userId).problems, []);
  }
  record("FS-K4", { accounts: 20 });
});

test("FS-K7 rate limit: the resolve limiter is shared by both nodes; refused requests write nothing; the key settles once", { skip: STRESS }, async () => {
  const a = await account("k7");
  const key = newKey();
  const burst = await Promise.all([...Array(45)].map((_, i) => safe(resolve(a, key, cmd(), { base: i % 2 ? NODE2 : BASE }))));
  const ok = burst.filter((r) => r.status === 200).length, limited = burst.filter((r) => reason(r) === "rate_limited").length;
  assert.ok(ok <= 30, `at most 30 per 10 s across nodes (guards.ts:31): ${ok}`);
  assert.ok(limited >= 1, "the limiter refused some");
  assert.equal(tradeReceipts(a, key).length, 1);
  await sleep(10500);
  const t = await trade(a, key, cmd());
  assert.equal(t.body.replayed, true);
  assert.deepEqual(ledger(a.userId).problems, []);
  record("FS-K7", { ok, limited });
});

test("FS-K9 ledger: every account of this file reconciles (live mutation NOT RUN)", { skip: STRESS }, async () => {
  const problems = accounts.flatMap((a) => ledger(a.userId).problems.map((p) => `${a.userId}: ${p}`));
  assert.deepEqual(problems, []);
  record("FS-K9", { accounts: accounts.length, live_mutation: "NOT RUN (separate approval)" });
});

// ---- FS-K10 / AC-16: one round on the REAL 15-minute TTL ----------------------

async function clockSamples(label, n = 20) {
  const a = await account(label); // own account: progression_get spends receipt_replay (30 / 60 s)
  const s = [];
  for (let i = 0; i < n; i++) {
    const send = Date.now();
    const r = await rpc(a, "vs01e_progression_get", { gameplay_session_id: a.gsid });
    const recv = Date.now();
    if (r.status === 200) s.push({ send, recv, server: r.body.server_time_ms });
    await sleep(150);
  }
  return s;
}
const claim = (a, t, key) => rpc(a, "vs01e_encounter_claim", { gameplay_session_id: a.gsid, idempotency_key: key, ticket_id: t.ticket_id, outcome: "victory", kills: 10, hero_alive: true });
const abandon = (a, t, key) => rpc(a, "vs01e_encounter_abandon", { gameplay_session_id: a.gsid, idempotency_key: key, ticket_id: t.ticket_id, confirm: true });
const atClient = async (ms) => { const d = ms - Date.now(); if (d > 0) await sleep(d); };

test("FS-K10 + AC-16 ticket TTL / claim / abandon races judged from server time only", { skip: ROUND, timeout: 25 * 60 * 1000 }, async () => {
  const s0 = await clockSamples("k10clk0");
  const est = estimateOffset(s0);
  assert.ok(est, "no clock sample");
  const plan = [
    ...[-300, -100, 100, 300, -300, -100, 100, 300].map((aim, i) => ({ bin: aim < 0 ? "A" : "B", aim, n: i })),
    ...[100, 200, 300, 400].map((aim, i) => ({ bin: "C", aim, n: 8 + i })),
    ...[-300, -100, 100, 300].map((aim, i) => ({ bin: "D", aim, n: 12 + i })),
  ];
  const items = [];
  for (const p of plan) {
    const a = await account(`k10_${p.n}`);
    const r = await rpc(a, "vs01e_encounter_begin", { gameplay_session_id: a.gsid, group_ids: ["prototype_monster_01"] });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    const t = r.body.ticket;
    assert.equal(t.expires_at_ms - t.issued_at_ms, TTL_MS, "TTL-1 at begin");
    const key = newKey();
    if (p.bin === "C") assert.equal(reason(await claim(a, t, key)), "too_early", "bin C records its intent before the deadline");
    items.push({ ...p, a, t, key, abandonKey: newKey(), answers: [] });
  }
  const lastExp = Math.max(...items.map((x) => x.t.expires_at_ms));
  await atClient(sendAtClientMs(lastExp - 60000, est) - 40000);
  const s1 = await clockSamples("k10clk1");
  const est1 = estimateOffset(s1) ?? est;
  // Fire every critical request at its aim (scheduling only; never a verdict).
  await Promise.all(items.map(async (x) => {
    await atClient(sendAtClientMs(x.t.expires_at_ms + x.aim, est1));
    const sentAt = Date.now();
    if (x.bin === "D") x.answers = await Promise.all([safe(claim(x.a, x.t, x.key)), safe(abandon(x.a, x.t, x.abandonKey))]);
    else x.answers = [await safe(claim(x.a, x.t, x.key))];
    x.client = { sent_at: sentAt, done_at: Date.now() };
  }));
  await sleep(5000);
  // AC-16 (4): replays after the deadline (second requests: invariants only).
  for (const x of items) x.replay = [reason(await safe(claim(x.a, x.t, x.key))), reason(await safe(claim(x.a, x.t, x.key)))];
  const s2 = await clockSamples("k10clk2");
  // Server-side evidence per ticket (one account per ticket).
  const tickets = items.map((x) => {
    const tk = objects(x.a.userId, C.tickets).find((o) => o.key === x.t.ticket_id)?.value;
    const intent = objects(x.a.userId, C.intents).find((o) => o.key === x.t.ticket_id)?.value ?? null;
    const rec = objects(x.a.userId, C.combatReceipts).map((o) => o.value).filter((r) => r.ticket_id === x.t.ticket_id);
    const hero = objects(x.a.userId, C.hero).find((o) => o.key === "hero")?.value ?? null;
    return { ticket_id: x.t.ticket_id, issued_at_ms: tk.issued_at_ms, expires_at_ms: tk.expires_at_ms, status: tk.status,
      intent_recorded: tk.intent_recorded, resolved_at_ms: tk.resolved_at_ms,
      intent: intent && { ticket_id: intent.ticket_id, first_seen_at_ms: intent.first_seen_at_ms, state: intent.state },
      claim_receipts: rec.filter((r) => r.kind === "claim"), abandon_receipts: rec.filter((r) => r.kind === "abandon"),
      hero: hero && { level: hero.level, exp: hero.exp }, critical_key: x.key, critical_was_first: x.bin !== "C",
      design_bin: x.bin, lossy: false, aim_ms: x.aim, answers: x.answers.map(reason), replay: x.replay, client: x.client };
  });
  const v = roundVerdict(tickets, { serverTimeRegress: serverTimeRegressed([...s0, ...s1, ...s2].sort((p, q) => p.send - q.send)) });
  const out = { verdict: v.verdict, fails: v.fails, inconclusive: v.inconclusive, bins: v.bins, clock: { start: est, near: est1, end: estimateOffset(s2) },
    tickets: tickets.map(({ claim_receipts, abandon_receipts, ...t }) => ({ ...t, claim_receipts: claim_receipts.length, abandon_receipts: abandon_receipts.length,
      claim_server_time: claim_receipts[0]?.server_time_ms ?? null, abandon_server_time: abandon_receipts[0]?.server_time_ms ?? null })),
    ac16: { "1_recorded_before_deadline": tickets.filter((t) => t.design_bin === "C").map((t) => t.status),
      "2_same_key_after_ttl": tickets.filter((t) => t.design_bin === "C").map((t) => t.answers[0]),
      "3_no_intent_expiry": tickets.filter((t) => t.design_bin === "B").map((t) => t.status),
      "4_settled_replay": tickets.filter((t) => t.status === "CLAIMED").map((t) => t.replay),
      "5_abandon_race": tickets.filter((t) => t.design_bin === "D").map((t) => t.status) } };
  if (CASE_DIR) fs.writeFileSync(`${CASE_DIR}/FS-K10-round.json`, JSON.stringify(out, null, 2) + "\n", { mode: 0o600, flag: "wx" });
  record("AC-16", { from: "FS-K10 round", verdict: v.verdict });
  // Settled tickets must replay their own receipt; never a second settlement.
  for (const t of tickets) if (t.status === "CLAIMED") assert.deepEqual(t.replay, ["replayed", "replayed"]);
  assert.notEqual(v.verdict, "FAIL", `FS-K10 FAIL: ${v.fails.join("; ")}`);
  // INCONCLUSIVE is never PASS: it fails this test; the launcher classifies it from FS-K10-round.json.
  assert.equal(v.verdict, "PASS", `FS-K10 INCONCLUSIVE: ${v.inconclusive.join("; ")}`);
});
