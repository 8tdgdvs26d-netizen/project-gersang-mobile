// VS-01 WP01-H E3 LIVE (server layer): vs01_trade_resolve against the real
// Nakama 3.25 + PostgreSQL 16 of ONE isolated run (Blueprint v0.1r2).
// AC-01 / 02 / 03 / 10 / 12 / 14 / 15 / 19 / 20. Every case uses new accounts.
//
// Runs ONLY under nakama/scripts/run_wp01h_e3_bounded.mjs, which sets
// MYRIAL_WP01H_E3_RUN_ID and a wp01h_e3_* COMPOSE_PROJECT_NAME after the
// G1 / G2 isolation gates. Without them every test is skipped, so the old
// run_live_tests.sh (tests/live/*.test.mjs) never runs it unisolated.
//
// MYRIAL_WP01H_E3_PHASE:
//   main         (default) all server-layer cases on the E1 server
//   pre_revert   AC-14(c) / AC-19 setup: tombstones + v1 receipts, keys saved to MYRIAL_WP01H_E3_STATE
//   post_revert  the SAME database served by the BASELINE (360228cb) module: replay only, nothing executes
// AC-14 results are "Code-derived / CV-01..07 PENDING" (D-P7a), never "CV verified".
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { authEmail, authRaw, rpc, begin, newKey, sleep, BASE, RUN as CLIENT_RUN } from "./live_client.mjs";
import { objects, snapshot, snapshotDelta, ledger, C, runProject } from "./tools/wp01h_db.mjs";
import { seedReceipt, seedKey, checkStorageColumns } from "./tools/wp01h_seed.mjs";

const RUN = process.env.MYRIAL_WP01H_E3_RUN_ID ?? "";
const PHASE = process.env.MYRIAL_WP01H_E3_PHASE ?? "main";
const NODE2 = process.env.MYRIAL_NAKAMA_URL_2 ?? BASE;
const CASE_DIR = process.env.MYRIAL_WP01H_E3_CASE_DIR ?? "";
const STATE = process.env.MYRIAL_WP01H_E3_STATE ?? "";
const SEED_MANIFEST = process.env.MYRIAL_WP01H_E3_SEED_MANIFEST ?? "";
const SKIP = !RUN ? "WP01-H E3 only: run via nakama/scripts/run_wp01h_e3_bounded.mjs" : false;
if (RUN) runProject(); // refuse at load time outside the run's own project
const users = new Set(); // accounts of this run (R-04 seed allow-list)

const only = (phase) => (SKIP ? SKIP : PHASE !== phase ? `phase ${PHASE}` : false);
const reason = (r) => (r.status === 200 ? (r.body.replayed ? "replayed" : r.body.receipt?.status ?? "ok")
  : (r.body && typeof r.body === "object" && r.body.message) || String(r.status));

function record(id, data) {
  if (!CASE_DIR) return;
  fs.appendFileSync(`${CASE_DIR}/${id}.jsonl`, JSON.stringify({ at: new Date().toISOString(), id, ...data }) + "\n", { mode: 0o600 });
}
async function account(label) {
  const a = await authEmail(`wp01h-${label}`);
  users.add(a.userId);
  await begin(a);
  return a;
}
const cmd = (o = {}) => ({ action: "buy", city_id: "A", good_id: "test_good_01", quantity: 10, ...o });
const trade = (a, key, c, opt) => rpc(a, "vs01_trade", { gameplay_session_id: a.gsid, idempotency_key: key, ...c }, opt);
const resolve = (a, key, c, opt) => rpc(a, "vs01_trade_resolve", { gameplay_session_id: a.gsid, idempotency_key: key, ...c }, opt);
const receiptsOf = (a) => objects(a.userId, C.tradeReceipts).map((o) => o.value);
const receiptOf = (a, key) => receiptsOf(a).filter((r) => r.idempotency_key === key);
function noLedgerProblem(a, id) {
  const l = ledger(a.userId);
  record(id, { ledger: l });
  assert.deepEqual(l.problems, [], `${id} ledger: ${l.problems.join("; ")}`);
}

// ---- main phase ----------------------------------------------------------------

test("AC-01 applied: one final result; same key via vs01_trade x5 and resolve x5 replays it unchanged", { skip: only("main") }, async () => {
  const a = await account("ac01");
  const key = newKey();
  const first = await trade(a, key, cmd());
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.equal(first.body.receipt.status, "applied");
  const again = await Promise.all([...Array(5)].map(() => trade(a, key, cmd())).concat([...Array(5)].map(() => resolve(a, key, cmd()))));
  for (const r of again) {
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.replayed, true);
    assert.deepEqual(r.body.receipt, first.body.receipt);
  }
  assert.equal(receiptOf(a, key).length, 1);
  noLedgerProblem(a, "AC-01");
});

test("AC-02 rejected: replayed by resolve, never turned into voided or applied", { skip: only("main") }, async () => {
  const a = await account("ac02");
  for (const c of [cmd({ action: "sell", quantity: 1 }), cmd({ city_id: "Z", quantity: 1 })]) {
    const key = newKey();
    const before = snapshot(a.userId);
    const first = await trade(a, key, c);
    assert.equal(first.status, 200, JSON.stringify(first.body));
    assert.equal(first.body.receipt.status, "rejected");
    const r = await resolve(a, key, c);
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.replayed, true);
    assert.deepEqual(r.body.receipt, first.body.receipt);
    const t = await trade(a, key, c);
    assert.deepEqual(t.body.receipt, first.body.receipt);
    assert.equal(receiptOf(a, key).length, 1);
    assert.deepEqual(snapshot(a.userId).progress, before.progress, "a rejection moves no progress");
  }
  noLedgerProblem(a, "AC-02");
});

test("AC-03 / AC-10 voided: resolve of a never-sent key writes a v2 tombstone; the late original replays it", { skip: only("main") }, async () => {
  const a = await account("ac03");
  const key = newKey();
  const before = snapshot(a.userId);
  const v = await resolve(a, key, cmd());
  assert.equal(v.status, 200, JSON.stringify(v.body));
  const rc = v.body.receipt;
  assert.equal(rc.status, "voided"); assert.equal(rc.reason, "recovery_voided");
  assert.equal(rc.contract, "myrial.vs01.wp01.trade_receipt"); assert.equal(rc.contract_version, 2);
  assert.equal(rc.resolved_by_session_id, a.gsid);
  assert.equal("gameplay_session_id" in rc, false);
  const late = await trade(a, key, cmd());
  assert.equal(late.status, 200, JSON.stringify(late.body));
  assert.equal(late.body.replayed, true);
  assert.deepEqual(late.body.receipt, rc);
  const after = snapshot(a.userId);
  assert.deepEqual(after.progress, before.progress, "AC-10: a void moves nothing, not even the revision");
  assert.equal(receiptOf(a, key).length, 1);
  noLedgerProblem(a, "AC-10");
});

test("AC-03 race: original trade and resolve sent together (2 nodes, 50 keys) -> exactly one receipt per key", { skip: only("main") }, async () => {
  const a = await account("ac03r");
  const keys = [...Array(50)].map(() => newKey());
  const outcomes = { applied: 0, voided: 0 };
  for (let i = 0; i < keys.length; i += 10) {
    await Promise.all(keys.slice(i, i + 10).flatMap((k, j) => {
      const c = cmd({ quantity: 1 });
      const [b1, b2] = (i + j) % 2 === 0 ? [BASE, NODE2] : [NODE2, BASE];
      return [trade(a, k, c, { base: b1 }), resolve(a, k, c, { base: b2 })];
    }));
    await sleep(4000); // 10 trades + 10 resolves per 4 s: under 30 per 10 s each (guards.ts:27,31)
  }
  for (const k of keys) {
    let rs = receiptOf(a, k);
    assert.ok(rs.length <= 1, `key ${k}: ${rs.length} receipts`);
    if (rs.length === 0) { // both requests refused (e.g. rate limit): settle it now, still one outcome
      await sleep(1000);
      await resolve(a, k, cmd({ quantity: 1 }));
      rs = receiptOf(a, k);
    }
    assert.equal(rs.length, 1, `key ${k}: ${rs.length} receipts`);
    assert.ok(["applied", "voided", "rejected"].includes(rs[0].status), rs[0].status);
    if (rs[0].status in outcomes) outcomes[rs[0].status] += 1;
  }
  record("AC-03", { race_outcomes: outcomes });
  noLedgerProblem(a, "AC-03");
});

test("AC-12 takeover: a superseded session can neither resolve nor trade; the active one voids", { skip: only("main") }, async () => {
  const a = await account("ac12");
  const s1 = { ...a };
  await begin(a); // device 2 takes over: a.gsid is now S2, s1.gsid the old S1
  assert.notEqual(s1.gsid, a.gsid);
  const key = newKey();
  const before = snapshot(a.userId);
  const r1 = await resolve(s1, key, cmd());
  const t1 = await trade(s1, key, cmd());
  assert.notEqual(r1.status, 200); assert.equal(reason(r1), "gameplay_session_superseded");
  assert.notEqual(t1.status, 200); assert.equal(reason(t1), "gameplay_session_superseded");
  assert.deepEqual(snapshotDelta(before, snapshot(a.userId)), [], "nothing written by the superseded session");
  const r2 = await resolve(a, key, cmd());
  assert.equal(r2.status, 200, JSON.stringify(r2.body));
  assert.equal(r2.body.receipt.status, "voided");
  assert.equal(r2.body.receipt.resolved_by_session_id, a.gsid);
  noLedgerProblem(a, "AC-12");
});

test("AC-14 (a)(b) [Code-derived / CV PENDING]: v1 applied / rejected and v2 voided replay field for field", { skip: only("main") }, async () => {
  const a = await account("ac14");
  const kinds = [["applied", cmd()], ["rejected", cmd({ action: "sell", quantity: 1 })]];
  for (const [status, c] of kinds) {
    const key = newKey();
    const first = await trade(a, key, c);
    assert.equal(first.body.receipt.status, status);
    assert.equal(Object.keys(first.body.receipt).length, 18, "legacy v1 has 18 fields");
    const r = await resolve(a, key, c);
    assert.deepEqual(r.body.receipt, first.body.receipt);
  }
  const key = newKey();
  const v = await resolve(a, key, cmd());
  assert.equal(Object.keys(v.body.receipt).length, 20, "voided v2 has 20 fields");
  const again = await resolve(a, key, cmd());
  assert.equal(again.body.replayed, true);
  assert.deepEqual(again.body.receipt, v.body.receipt);
  record("AC-14", { label: "Code-derived / CV-01..07 PENDING" });
});

test("AC-15 strict matching: malformed or foreign stored receipts fail closed and change nothing", { skip: only("main") }, async (t) => {
  if (!SEED_MANIFEST) { t.skip("no seed manifest path (launcher sets MYRIAL_WP01H_E3_SEED_MANIFEST)"); return; }
  checkStorageColumns(); // G2-6 again, right before seeding
  const a = await account("ac15");
  const other = await account("ac15o");
  const real = await trade(a, newKey(), cmd()); // a genuine v1 to derive malformed copies from
  const base = real.body.receipt;
  const c = cmd();
  const cases = [
    ["bad_hash", (v) => ({ ...v, request_hash: "buy|A|test_good_01|1" }), "idempotency_key_reused", 0],
    ["missing_field", (v) => { const x = { ...v }; delete x.server_time_ms; return x; }, "receipt_unrecognized", 0],
    ["extra_field", (v) => ({ ...v, note: "x" }), "receipt_unrecognized", 0],
    ["wrong_version", (v) => ({ ...v, contract: "myrial.vs01.wp01.trade_receipt", contract_version: 3 }), "receipt_unrecognized", 0],
    ["foreign_user", (v) => ({ ...v, user_id: other.userId }), "receipt_not_trusted", 0],
    ["readable", (v) => v, "receipt_not_trusted", 2],
  ];
  // The key is derived from the label first, so the seeded value carries its own key.
  for (const [label, mutate, want, read] of cases) {
    const l = `ac15_${label}`;
    const key = seedKey(l);
    seedReceipt({ userId: a.userId, label: l, value: { ...mutate(base), idempotency_key: key }, read }, users, SEED_MANIFEST);
    const before = snapshot(a.userId);
    const r = await resolve(a, key, c);
    assert.notEqual(r.status, 200, `${label}: must not succeed`);
    assert.equal(reason(r), want, `${label}: ${JSON.stringify(r.body)}`);
    const tr = await trade(a, key, c);
    assert.notEqual(tr.status === 200 && tr.body.receipt?.status === "applied" && !tr.body.replayed, true, `${label}: original trade must not execute`);
    assert.deepEqual(snapshotDelta(before, snapshot(a.userId)), [], `${label}: nothing changed`);
    record("AC-15", { label, reason: reason(r) });
  }
});

test("AC-20 legacy rules: rejected replay, match, key reuse, missing field, invalid command without tombstone, race", { skip: only("main") }, async () => {
  const a = await account("ac20");
  // 1 + 2: a real v1 rejection of a command the catalog never accepts (city Z) still replays.
  const k1 = newKey(), bad = cmd({ city_id: "Z", quantity: 1 });
  const rej = await trade(a, k1, bad);
  assert.equal(rej.body.receipt.status, "rejected");
  const r1 = await resolve(a, k1, bad);
  assert.equal(r1.status, 200); assert.deepEqual(r1.body.receipt, rej.body.receipt);
  // 3: same key, different command.
  const r3 = await resolve(a, k1, cmd({ quantity: 1 }));
  assert.equal(reason(r3), "idempotency_key_reused");
  // 4: legacy missing field -> covered by AC-15 "missing_field" (seed), fail closed.
  // 5: no receipt + invalid command -> resolve_command_invalid and NO tombstone.
  const k5 = newKey();
  const r5 = await resolve(a, k5, cmd({ good_id: "no_such_good" }));
  assert.equal(reason(r5), "resolve_command_invalid");
  assert.equal(receiptOf(a, k5).length, 0, "no tombstone for an invalid command");
  // 6: original trade and resolve at the same time -> one receipt.
  const k6 = newKey();
  await Promise.all([trade(a, k6, cmd({ quantity: 1 })), resolve(a, k6, cmd({ quantity: 1 }), { base: NODE2 })]);
  assert.equal(receiptOf(a, k6).length, 1);
  noLedgerProblem(a, "AC-20");
});

// ---- AC-14(c) / AC-19 code revert on the SAME database --------------------------

test("AC-19 pre_revert: write tombstones + v1 receipts and save their keys", { skip: only("pre_revert") }, async () => {
  assert.ok(STATE, "MYRIAL_WP01H_E3_STATE is required");
  const a = await account("ac19");
  const voided = newKey(), applied = newKey();
  const v = await resolve(a, voided, cmd());
  assert.equal(v.body.receipt.status, "voided");
  const ap = await trade(a, applied, cmd());
  assert.equal(ap.body.receipt.status, "applied");
  // client_run: live_client.mjs derives the disposable test password from it.
  fs.writeFileSync(STATE, JSON.stringify({ account: { email: a.email, userId: a.userId }, client_run: CLIENT_RUN, voided, applied, cmd: cmd(),
    snapshot: snapshot(a.userId), receipts: receiptsOf(a).length }) + "\n", { mode: 0o600, flag: "wx" });
});

test("AC-14(c) / AC-19 post_revert: the baseline server replays the tombstone, executes nothing, deletes nothing", { skip: only("post_revert") }, async () => {
  const st = JSON.parse(fs.readFileSync(STATE, "utf8"));
  const auth = await authRaw("email", { email: st.account.email, password: `localtest-${st.client_run}` });
  assert.equal(auth.status, 200, "re-login of the pre_revert account");
  const a = { email: st.account.email, token: auth.body.token, userId: st.account.userId };
  await begin(a);
  const before = snapshot(a.userId);
  const t = await trade(a, st.voided, st.cmd);
  assert.equal(t.status, 200, JSON.stringify(t.body));
  assert.equal(t.body.replayed, true, "baseline replays the stored tombstone");
  assert.equal(t.body.receipt.status, "voided");
  const t2 = await trade(a, st.applied, st.cmd);
  assert.equal(t2.body.replayed, true);
  const r = await resolve(a, newKey(), st.cmd);
  assert.notEqual(r.status, 200, "the baseline server has no vs01_trade_resolve");
  const after = snapshot(a.userId);
  assert.deepEqual(after.trade_receipts, before.trade_receipts, "no receipt added or removed (tombstones kept)");
  assert.equal(after.progress.money, before.progress.money);
  assert.deepEqual(after.progress.backpack, before.progress.backpack);
  record("AC-19", { receipts_before: Object.keys(before.trade_receipts).length, receipts_after: Object.keys(after.trade_receipts).length });
});
