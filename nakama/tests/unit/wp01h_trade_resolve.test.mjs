// VS-01 WP01-H E1: vs01_trade_resolve (Resolve-or-Void, Blueprint v0.1r3
// §4 / §5 / §12) against the in-memory Nakama double. md5 versions (an
// unchanged rewrite keeps its version, as in Nakama v3.25.0) unless a test
// says otherwise. Each test names the AC / PR / FS item it covers.
import test from "node:test";
import assert from "node:assert/strict";
import { loadModule, FakeNakama, ctxFor, call } from "./harness.mjs";

const clock = { t: 1_800_000_000_000, now() { return this.t; } };
const m = loadModule(clock);
const U1 = "11111111-1111-1111-1111-111111111111";
const U2 = "22222222-2222-2222-2222-222222222222";
const INVALID_ARGUMENT = 3, FAILED_PRECONDITION = 9, ABORTED = 10, RESOURCE_EXHAUSTED = 8, INTERNAL = 13, UNAVAILABLE = 14, UNAUTHENTICATED = 16;
const RECEIPTS = "vs01_wp01_receipts", PROGRESS = "vs01_wp01_progress";
const V2_KEYS = ["contract", "contract_version", "idempotency_key", "request_hash", "user_id",
  "resolved_by_session_id", "action", "city_id", "good_id", "quantity", "status", "reason",
  "unit_price", "total", "money_before", "money_after", "carried_before", "carried_after",
  "progress_revision", "server_time_ms"];

let keySeq = 0;
const newKey = () => `h-unit-key-${String(++keySeq).padStart(8, "0")}`;

function fresh(opts = { md5: true }) {
  clock.t = 1_800_000_000_000;
  return new FakeNakama(opts);
}
function begin(nk, user = U1) {
  const r = call(m, "rpcSessionBegin", nk, ctxFor(user), "{}");
  assert.ok(r.ok, JSON.stringify(r));
  return r.value.gameplay_session_id;
}
const CMD = { action: "buy", city_id: "A", good_id: "test_good_01", quantity: 10 };
function trade(nk, gsid, key, cmd = CMD, user = U1, env = {}) {
  return call(m, "rpcTrade", nk, ctxFor(user, env), { gameplay_session_id: gsid, idempotency_key: key, ...cmd });
}
function resolve(nk, gsid, key, cmd = CMD, user = U1, env = {}) {
  return call(m, "rpcTradeResolve", nk, ctxFor(user, env), { gameplay_session_id: gsid, idempotency_key: key, ...cmd });
}
function receiptObj(nk, key, user = U1) {
  return nk.storageRead([{ collection: RECEIPTS, key, userId: user }])[0] ?? null;
}
function progressObj(nk, user = U1) {
  return nk.storageRead([{ collection: PROGRESS, key: "trade", userId: user }])[0];
}
function refused(r, code, message) {
  assert.equal(r.ok, false, JSON.stringify(r));
  assert.equal(r.message, message);
  assert.equal(r.code, code);
}
function receiptCount(nk) {
  return [...nk.objects.values()].filter((o) => o.collection === RECEIPTS).length;
}
// A server-written receipt planted directly (legacy fixtures / tampering).
function plant(nk, key, value, user = U1, perms = { permissionRead: 0, permissionWrite: 0 }) {
  nk.objects.set(`${RECEIPTS}/${key}/${user}`, { collection: RECEIPTS, key, userId: user, value, version: "planted-" + key, ...perms });
}
function legacyV1(key, cmd, over = {}) {
  return {
    idempotency_key: key, request_hash: [cmd.action, cmd.city_id, cmd.good_id, String(cmd.quantity)].join("|"),
    user_id: U1, gameplay_session_id: "00000000-0000-0000-0000-000000000000",
    action: cmd.action, city_id: cmd.city_id, good_id: cmd.good_id, quantity: cmd.quantity,
    status: "rejected", reason: "invalid_quantity", unit_price: 0, total: 0,
    money_before: 10000, money_after: 10000, carried_before: 0, carried_after: 0,
    progress_revision: 1, server_time_ms: 1, ...over,
  };
}

// ---------- void / replay ----------

test("AC-01/AC-02/AC-10: no receipt -> one create-only Voided v2 tombstone; progress, money and revision unchanged", () => {
  const nk = fresh();
  const g = begin(nk);
  const before = progressObj(nk);
  const key = newKey();
  const r = resolve(nk, g, key);
  assert.ok(r.ok, JSON.stringify(r));
  assert.equal(r.value.replayed, false);
  const v = r.value.receipt;
  assert.deepEqual(Object.keys(v).sort(), [...V2_KEYS].sort(), "exact Voided v2 field set");
  assert.equal(v.contract, "myrial.vs01.wp01.trade_receipt");
  assert.equal(v.contract_version, 2);
  assert.equal(v.status, "voided");
  assert.equal(v.reason, "recovery_voided");
  assert.equal(v.unit_price, 0);
  assert.equal(v.total, 0);
  assert.equal(v.money_before, 10000);
  assert.equal(v.money_after, v.money_before);
  assert.equal(v.carried_after, v.carried_before);
  assert.equal(v.resolved_by_session_id, g);
  assert.equal("gameplay_session_id" in v, false, "the resolving session never poses as the original session");
  assert.equal(v.request_hash, "buy|A|test_good_01|10", "the unchanged v1 hash");
  assert.equal(v.user_id, U1);
  const after = progressObj(nk);
  assert.deepEqual(after.value, before.value, "progress value unchanged");
  assert.equal(after.version, before.version, "md5: identical rewrite keeps the version");
  assert.equal(v.progress_revision, before.value.revision, "PR-04: revision from progress, no bump");
  const o = receiptObj(nk, key);
  assert.equal(o.permissionRead, 0);
  assert.equal(o.permissionWrite, 0);
  assert.equal(nk.writeCalls.multiUpdate, 1, "one transaction");
});

test("AC-01: a voided key replays unchanged on every later resolve (no second write)", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  const first = resolve(nk, g, key).value.receipt;
  const writes = nk.writeCalls.multiUpdate;
  const again = resolve(nk, g, key);
  assert.ok(again.ok);
  assert.equal(again.value.replayed, true);
  assert.deepEqual(again.value.receipt, first);
  assert.equal(nk.writeCalls.multiUpdate, writes, "replay writes nothing");
});

test("AC-02/AC-14/AC-19: a late original vs01_trade for a voided key replays the tombstone and never executes (unchanged rpcTrade)", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  const voided = resolve(nk, g, key).value.receipt;
  const late = trade(nk, g, key);
  assert.ok(late.ok, JSON.stringify(late));
  assert.equal(late.value.replayed, true);
  assert.deepEqual(late.value.receipt, voided);
  const p = progressObj(nk).value;
  assert.equal(p.money, 10000, "no money moved");
  assert.equal(p.backpack.test_good_01, undefined, "no goods moved");
  assert.equal(p.market.A.test_good_01.current_stock, 100, "no stock moved");
});

test("AC-01/AC-14: an applied Legacy v1 receipt replays exactly; resolve writes nothing", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  const applied = trade(nk, g, key);
  assert.equal(applied.value.receipt.status, "applied");
  const writes = nk.writeCalls.multiUpdate;
  const r = resolve(nk, g, key);
  assert.ok(r.ok);
  assert.equal(r.value.replayed, true);
  assert.deepEqual(r.value.receipt, applied.value.receipt);
  assert.equal(nk.writeCalls.multiUpdate, writes);
  assert.equal(progressObj(nk).value.money, 9160, "money moved exactly once");
});

test("AC-01: a rules-rejected Legacy v1 receipt (insufficient_cargo) replays", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  const sell = { action: "sell", city_id: "A", good_id: "test_good_01", quantity: 1 };
  const rejected = trade(nk, g, key, sell);
  assert.equal(rejected.value.receipt.status, "rejected");
  const r = resolve(nk, g, key, sell);
  assert.ok(r.ok);
  assert.equal(r.value.replayed, true);
  assert.deepEqual(r.value.receipt, rejected.value.receipt);
});

// ---------- AC-20 / AC-15 ----------

test("AC-20: a legacy rejected receipt for a command the catalog refuses (quantity 3) still replays when the command matches", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  const odd = { action: "buy", city_id: "A", good_id: "test_good_01", quantity: 3 };
  const original = trade(nk, g, key, odd);
  assert.equal(original.value.receipt.reason, "invalid_quantity");
  const r = resolve(nk, g, key, odd);
  assert.ok(r.ok, JSON.stringify(r));
  assert.equal(r.value.replayed, true);
  assert.deepEqual(r.value.receipt, original.value.receipt);
});

test("AC-20: a legacy rejected receipt for an unknown city / good replays (planted legacy fixture)", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  const bad = { action: "buy", city_id: "Z", good_id: "gone_good", quantity: 10 };
  plant(nk, key, legacyV1(key, bad, { reason: "invalid_city_or_good" }));
  const r = resolve(nk, g, key, bad);
  assert.ok(r.ok, JSON.stringify(r));
  assert.equal(r.value.receipt.reason, "invalid_city_or_good");
});

test("AC-20: no receipt + invalid command -> resolve_command_invalid and NO tombstone", () => {
  for (const bad of [
    { action: "buy", city_id: "A", good_id: "test_good_01", quantity: 3 },
    { action: "buy", city_id: "A", good_id: "test_good_01", quantity: 2.5 },
    { action: "buy", city_id: "C", good_id: "test_good_01", quantity: 10 },
    { action: "sell", city_id: "A", good_id: "no_such_good", quantity: 1 },
  ]) {
    const nk = fresh();
    const g = begin(nk);
    const key = newKey();
    refused(resolve(nk, g, key, bad), INVALID_ARGUMENT, "resolve_command_invalid");
    assert.equal(receiptObj(nk, key), null, JSON.stringify(bad));
    assert.equal(nk.writeCalls.multiUpdate, 0);
  }
});

test("AC-15/AC-20: same key, different command -> idempotency_key_reused for v1 and v2; receipts untouched", () => {
  const nk = fresh();
  const g = begin(nk);
  const k1 = newKey(), k2 = newKey();
  const applied = trade(nk, g, k1).value.receipt;
  const voided = resolve(nk, g, k2).value.receipt;
  for (const k of [k1, k2]) {
    refused(resolve(nk, g, k, { ...CMD, quantity: 1 }), INVALID_ARGUMENT, "idempotency_key_reused");
    refused(resolve(nk, g, k, { ...CMD, action: "sell" }), INVALID_ARGUMENT, "idempotency_key_reused");
    refused(resolve(nk, g, k, { ...CMD, city_id: "B" }), INVALID_ARGUMENT, "idempotency_key_reused");
  }
  assert.deepEqual(receiptObj(nk, k1).value, applied);
  assert.deepEqual(receiptObj(nk, k2).value, voided);
});

test("AC-15: a request-hash collision ('A|b' + 'c' vs 'A' + 'b|c') is caught by the field-by-field compare", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  const odd = { action: "buy", city_id: "A|test", good_id: "good_01", quantity: 1 };
  const other = { action: "buy", city_id: "A", good_id: "test|good_01", quantity: 1 };
  const original = trade(nk, g, key, odd).value.receipt; // legacy rejected, invalid_city_or_good
  assert.equal(original.request_hash, "buy|A|test|good_01|1");
  refused(resolve(nk, g, key, other), INVALID_ARGUMENT, "idempotency_key_reused");
  assert.equal(resolve(nk, g, key, odd).value.replayed, true);
});

test("AC-15: unrecognised or untrusted stored receipts fail closed; nothing is written or guessed", () => {
  const cases = [
    ["legacy missing a field", (k) => { const v = legacyV1(k, CMD); delete v.carried_after; return v; }, INTERNAL, "receipt_unrecognized"],
    ["legacy extra field", (k) => ({ ...legacyV1(k, CMD), price: 1 }), INTERNAL, "receipt_unrecognized"],
    ["legacy unknown status", (k) => legacyV1(k, CMD, { status: "voided" }), INTERNAL, "receipt_unrecognized"],
    ["unknown contract version", (k) => ({ ...legacyV1(k, CMD), contract: "myrial.vs01.wp01.trade_receipt", contract_version: 3 }), INTERNAL, "receipt_unrecognized"],
    ["v2 that moved money", (k) => voidedLike(k, { money_after: 1 }), INTERNAL, "receipt_unrecognized"],
    ["v2 with a price", (k) => voidedLike(k, { unit_price: 84, total: 840 }), INTERNAL, "receipt_unrecognized"],
    ["v2 with the old session field", (k) => ({ ...voidedLike(k), gameplay_session_id: "x" }), INTERNAL, "receipt_unrecognized"],
    ["v2 wrong contract", (k) => voidedLike(k, { contract: "other" }), INTERNAL, "receipt_unrecognized"],
    ["other account's user_id", (k) => legacyV1(k, CMD, { user_id: U2 }), INTERNAL, "receipt_not_trusted"],
    ["key field differs", (k) => legacyV1(k, CMD, { idempotency_key: "something-else-0001" }), INTERNAL, "receipt_not_trusted"],
  ];
  for (const [name, make, code, message] of cases) {
    const nk = fresh();
    const g = begin(nk);
    const key = newKey();
    const value = make(key);
    plant(nk, key, value);
    const r = resolve(nk, g, key);
    assert.equal(r.ok, false, name);
    assert.equal(r.code, code, name);
    assert.equal(r.message, message, name);
    assert.deepEqual(receiptObj(nk, key).value, value, name + ": untouched");
    assert.equal(nk.writeCalls.multiUpdate, 0, name);
  }
});

test("AC-15: a receipt not written by the server (permissionWrite / permissionRead) fails closed", () => {
  for (const [perms, message] of [[{ permissionRead: 0, permissionWrite: 1 }, "server_object_not_trusted"], [{ permissionRead: 1, permissionWrite: 0 }, "receipt_not_trusted"]]) {
    const nk = fresh();
    const g = begin(nk);
    const key = newKey();
    plant(nk, key, legacyV1(key, CMD), U1, perms);
    refused(resolve(nk, g, key), INTERNAL, message);
  }
});

function voidedLike(key, over = {}) {
  return {
    contract: "myrial.vs01.wp01.trade_receipt", contract_version: 2, idempotency_key: key,
    request_hash: "buy|A|test_good_01|10", user_id: U1, resolved_by_session_id: "s",
    action: "buy", city_id: "A", good_id: "test_good_01", quantity: 10, status: "voided", reason: "recovery_voided",
    unit_price: 0, total: 0, money_before: 10000, money_after: 10000, carried_before: 0, carried_after: 0,
    progress_revision: 1, server_time_ms: 1, ...over,
  };
}

test("AC-14: a planted Voided v2 replays through BOTH the new resolve and the unchanged rpcTrade", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  plant(nk, key, voidedLike(key));
  assert.equal(resolve(nk, g, key).value.receipt.status, "voided");
  const t = trade(nk, g, key);
  assert.equal(t.value.replayed, true);
  assert.equal(t.value.receipt.status, "voided");
  assert.equal(progressObj(nk).value.money, 10000);
});

// ---------- PR-01 / AC-03: races ----------

test("PR-01/AC-03 FS-K3: the original trade commits between resolve's read and write -> resolve replays 'applied'; one result", () => {
  for (const md5 of [true, false]) {
    const nk = fresh({ md5 });
    const g = begin(nk);
    const key = newKey();
    let original = null;
    nk.beforeWrite = (n) => { original = trade(n, g, key); };
    const r = resolve(nk, g, key);
    assert.ok(original.ok && original.value.receipt.status === "applied", JSON.stringify(original));
    assert.ok(r.ok, JSON.stringify(r));
    assert.equal(r.value.replayed, true);
    assert.deepEqual(r.value.receipt, original.value.receipt);
    assert.equal(receiptObj(nk, key).value.status, "applied");
    assert.equal(progressObj(nk).value.money, 9160, "applied exactly once");
  }
});

test("PR-01/AC-03: resolve commits between the original trade's read and write -> the trade replays 'voided'; nothing applied", () => {
  for (const md5 of [true, false]) {
    const nk = fresh({ md5 });
    const g = begin(nk);
    const key = newKey();
    let voided = null;
    nk.beforeWrite = (n) => { voided = resolve(n, g, key); };
    const t = trade(nk, g, key);
    assert.ok(voided.ok && voided.value.receipt.status === "voided", JSON.stringify(voided));
    assert.ok(t.ok, JSON.stringify(t));
    assert.equal(t.value.replayed, true);
    assert.equal(t.value.receipt.status, "voided");
    const p = progressObj(nk).value;
    assert.equal(p.money, 10000);
    assert.equal(p.market.A.test_good_01.current_stock, 100);
  }
});

test("PR-01/AC-03: resolve vs a rules-rejected original (receipt-only write) -> one receipt per key", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  const sell = { action: "sell", city_id: "A", good_id: "test_good_01", quantity: 1 }; // nothing carried: rejected
  nk.beforeWrite = (n) => { assert.ok(resolve(n, g, key, sell).ok); };
  const t = trade(nk, g, key, sell);
  assert.equal(t.value.replayed, true);
  assert.equal(t.value.receipt.status, "voided");
  assert.equal(receiptCount(nk), 1);
});

test("AC-03: two concurrent resolves of one key -> one tombstone, the loser replays it", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  let inner = null;
  nk.beforeWrite = (n) => { inner = resolve(n, g, key); };
  const outer = resolve(nk, g, key);
  assert.equal(inner.value.replayed, false);
  assert.equal(outer.value.replayed, true);
  assert.deepEqual(outer.value.receipt, inner.value.receipt);
  assert.equal(receiptCount(nk), 1);
});

test("FS-K9 mutation guard: a trade on ANOTHER key between read and write does not block the void (progress moved -> re-read)", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  nk.beforeWrite = (n) => { assert.ok(trade(n, g, newKey()).ok); };
  const r = resolve(nk, g, key);
  assert.ok(r.ok, JSON.stringify(r));
  assert.equal(r.value.receipt.status, "voided");
  assert.equal(r.value.receipt.money_before, 9160, "taken from the re-read progress");
  assert.equal(r.value.receipt.progress_revision, progressObj(nk).value.revision);
});

// ---------- AC-12: session guard ----------

test("AC-12: a takeover between resolve's read and write -> re-read -> superseded; no tombstone", () => {
  for (const md5 of [true, false]) {
    const nk = fresh({ md5 });
    const g = begin(nk);
    const key = newKey();
    nk.beforeWrite = () => { begin(nk); };
    refused(resolve(nk, g, key), ABORTED, "gameplay_session_superseded");
    assert.equal(receiptObj(nk, key), null);
  }
});

test("AC-12: a superseded session gets no void and no replay of an existing receipt", () => {
  const nk = fresh();
  const g1 = begin(nk);
  const applied = newKey(), unknown = newKey();
  assert.ok(trade(nk, g1, applied).ok);
  const g2 = begin(nk);
  refused(resolve(nk, g1, applied), ABORTED, "gameplay_session_superseded");
  refused(resolve(nk, g1, unknown), ABORTED, "gameplay_session_superseded");
  assert.equal(receiptObj(nk, unknown), null);
  assert.equal(resolve(nk, g2, applied).value.replayed, true, "the active session can");
});

test("AC-12: no gameplay session yet -> no_gameplay_session; unauthenticated -> refused", () => {
  const nk = fresh();
  refused(resolve(nk, "00000000-0000-0000-0000-000000000000", newKey()), FAILED_PRECONDITION, "no_gameplay_session");
  const r = call(m, "rpcTradeResolve", nk, ctxFor(""), { gameplay_session_id: "00000000-0000-0000-0000-000000000000", idempotency_key: newKey(), ...CMD });
  refused(r, UNAUTHENTICATED, "unauthenticated");
});

// ---------- failures / limits / isolation ----------

test("§5 (6): a non-conflict storage error -> storage_unavailable (outcome unknown), nothing recorded", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  nk.faultNextWrites = 1;
  refused(resolve(nk, g, key), UNAVAILABLE, "storage_unavailable");
  assert.equal(receiptObj(nk, key), null);
});

test("§5 (6): endless lost races end as conflict_retry_exhausted, never a false void", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  nk.failNextWrites = 1000;
  refused(resolve(nk, g, key), ABORTED, "conflict_retry_exhausted");
  assert.equal(receiptObj(nk, key), null);
});

test("FS-K7: resolve has its own limiter (MYRIAL_RL_TRADE_RESOLVE_PER_10S); a refusal reads / writes no receipt", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  refused(resolve(nk, g, key, CMD, U1, { MYRIAL_RL_TRADE_RESOLVE_PER_10S: "0" }), RESOURCE_EXHAUSTED, "rate_limited");
  assert.equal(receiptObj(nk, key), null);
  assert.ok(resolve(nk, g, key, CMD, U1, { MYRIAL_RL_TRADE_PER_10S: "0" }).ok, "the trade limit does not block recovery");
  refused(trade(nk, g, newKey(), CMD, U1, { MYRIAL_RL_TRADE_RESOLVE_PER_10S: "0", MYRIAL_RL_TRADE_PER_10S: "0" }), RESOURCE_EXHAUSTED, "rate_limited");
});

test("FS-K7: 30 resolves per 10 s, the 31st is refused, the window slides", () => {
  const nk = fresh();
  const g = begin(nk);
  for (let i = 0; i < 30; i++) assert.ok(resolve(nk, g, newKey()).ok, String(i));
  refused(resolve(nk, g, newKey()), RESOURCE_EXHAUSTED, "rate_limited");
  clock.t += 10_001;
  assert.ok(resolve(nk, g, newKey()).ok);
});

test("AC-05 (server side): accounts are isolated; another account's key is never seen or voided", () => {
  const nk = fresh();
  const g1 = begin(nk, U1), g2 = begin(nk, U2);
  const key = newKey();
  const applied = trade(nk, g1, key).value.receipt;
  const r = resolve(nk, g2, key, CMD, U2);
  assert.ok(r.ok);
  assert.equal(r.value.replayed, false, "U2 sees no receipt of U1");
  assert.equal(r.value.receipt.user_id, U2);
  assert.deepEqual(receiptObj(nk, key, U1).value, applied, "U1 untouched");
  assert.equal(progressObj(nk, U1).value.money, 9160);
});

test("§5 (1): basic format is vs01_trade's; forged or missing fields are refused before any read", () => {
  const nk = fresh();
  const g = begin(nk);
  const base = { gameplay_session_id: g, idempotency_key: newKey(), ...CMD };
  const bad = [
    [{ ...base, unit_price: 1 }, "unexpected_fields"],
    [{ ...base, money: 99999 }, "unexpected_fields"],
    [(() => { const b = { ...base }; delete b.quantity; return b; })(), "unexpected_fields"],
    [{ ...base, idempotency_key: "short" }, "invalid_idempotency_key"],
    [{ ...base, action: "steal" }, "invalid_action"],
    [{ ...base, quantity: "10" }, "invalid_quantity"],
    [{ ...base, gameplay_session_id: "nope" }, "invalid_gameplay_session_id"],
  ];
  for (const [payload, message] of bad) {
    refused(call(m, "rpcTradeResolve", nk, ctxFor(U1), payload), INVALID_ARGUMENT, message);
  }
  assert.equal(receiptCount(nk), 0);
});

test("AC-10: ledger audit over all receipts: only 'applied' moves money; voided keys contribute nothing", () => {
  const nk = fresh();
  const g = begin(nk);
  const keys = [];
  for (let i = 0; i < 6; i++) {
    const key = newKey(); keys.push(key);
    if (i % 2 === 0) assert.ok(trade(nk, g, key, { ...CMD, quantity: 1 }).ok);
    else assert.ok(resolve(nk, g, key, { ...CMD, quantity: 1 }).ok);
  }
  for (const key of keys) trade(nk, g, key, { ...CMD, quantity: 1 }); // late originals: replays only
  let moved = 0, applied = 0, voided = 0;
  for (const o of nk.objects.values()) {
    if (o.collection !== RECEIPTS) continue;
    moved += o.value.money_before - o.value.money_after;
    if (o.value.status === "applied") applied += 1;
    if (o.value.status === "voided") voided += 1;
  }
  assert.equal(applied, 3);
  assert.equal(voided, 3);
  assert.equal(10000 - progressObj(nk).value.money, moved, "money spent == sum over applied receipts");
});

test("AC-14: the existing vs01_trade RPC and its receipt are unchanged (v1 shape, no contract field)", () => {
  const nk = fresh();
  const g = begin(nk);
  const r = trade(nk, g, newKey()).value.receipt;
  assert.equal("contract" in r, false);
  assert.equal("gameplay_session_id" in r, true);
  assert.equal(Object.keys(r).length, 18);
});

// ---------- E1 R-1: parser parity with vs01_trade (no stricter) ----------

function raw(gsid, key, quantityJson, extra = "") {
  return `{"gameplay_session_id":"${gsid}","idempotency_key":"${key}","action":"buy","city_id":"A","good_id":"test_good_01","quantity":${quantityJson}${extra}}`;
}
const PARSE_MESSAGES = new Set(["payload_too_large", "payload_not_json", "unexpected_fields", "invalid_gameplay_session_id",
  "invalid_idempotency_key", "invalid_action", "invalid_city_id", "invalid_good_id", "invalid_quantity"]);

test("R-1: guardParseTradeResolve accepts / refuses exactly what vs01_trade's parser does (special numbers included)", () => {
  const quantities = ["1e999", "-1e999", "-0", "0", "1.5", "1e308", "10", "1", "-10", "\"10\"", "null", "true", "[]", "{}"];
  for (const q of quantities) {
    const nkT = fresh(), nkR = fresh();
    const gT = begin(nkT), gR = begin(nkR);
    const key = newKey();
    const t = call(m, "rpcTrade", nkT, ctxFor(U1), raw(gT, key, q));
    const r = call(m, "rpcTradeResolve", nkR, ctxFor(U1), raw(gR, key, q));
    const tParse = !t.ok && PARSE_MESSAGES.has(t.message);
    const rParse = !r.ok && PARSE_MESSAGES.has(r.message);
    assert.equal(rParse, tParse, `quantity ${q}: parse-stage outcome must match (trade=${JSON.stringify(t)} resolve=${JSON.stringify(r)})`);
    if (tParse) assert.deepEqual([r.code, r.message], [t.code, t.message], `quantity ${q}`);
  }
});

test("R-1: a non-finite quantity with NO receipt is refused at the catalog step; no tombstone is written", () => {
  for (const q of ["1e999", "-1e999"]) {
    const nk = fresh();
    const g = begin(nk);
    const key = newKey();
    refused(call(m, "rpcTradeResolve", nk, ctxFor(U1), raw(g, key, q)), INVALID_ARGUMENT, "resolve_command_invalid");
    assert.equal(receiptObj(nk, key), null, q);
    assert.equal(nk.writeCalls.multiUpdate, 0, q);
  }
});

test("R-1: a legacy receipt from a non-finite quantity (stored JSON turns it into null) fails closed on resolve; unchanged rpcTrade still replays it", () => {
  const nk = fresh();
  const g = begin(nk);
  const key = newKey();
  const original = call(m, "rpcTrade", nk, ctxFor(U1), raw(g, key, "1e999"));
  assert.ok(original.ok, JSON.stringify(original));
  const stored = receiptObj(nk, key).value;
  assert.equal(stored.status, "rejected");
  assert.equal(stored.quantity, null, "the double stores JSON: Infinity becomes null");
  assert.equal(stored.request_hash, "buy|A|test_good_01|Infinity");
  // Unchanged legacy behaviour (not altered by WP01-H): rpcTrade replays by hash.
  assert.equal(call(m, "rpcTrade", nk, ctxFor(U1), raw(g, key, "1e999")).value.replayed, true);
  // Resolve never guesses that null meant Infinity: fail closed, nothing written.
  const before = nk.writeCalls.multiUpdate;
  refused(call(m, "rpcTradeResolve", nk, ctxFor(U1), raw(g, key, "1e999")), INTERNAL, "receipt_unrecognized");
  assert.deepEqual(receiptObj(nk, key).value, stored);
  assert.equal(nk.writeCalls.multiUpdate, before);
});

test("R-1/AC-20: existing legacy rejected receipts for -0, 1.5 and 1e308 replay; -0 and 0 are the same stored command", () => {
  for (const [q, alsoMatches] of [["-0", ["0"]], ["1.5", []], ["1e308", []]]) {
    const nk = fresh();
    const g = begin(nk);
    const key = newKey();
    const original = call(m, "rpcTrade", nk, ctxFor(U1), raw(g, key, q));
    assert.equal(original.value.receipt.reason, "invalid_quantity", q);
    for (const qq of [q, ...alsoMatches]) {
      const r = call(m, "rpcTradeResolve", nk, ctxFor(U1), raw(g, key, qq));
      assert.ok(r.ok, `${q} via ${qq}: ${JSON.stringify(r)}`);
      assert.equal(r.value.replayed, true);
      assert.deepEqual(r.value.receipt, original.value.receipt);
    }
    refused(call(m, "rpcTradeResolve", nk, ctxFor(U1), raw(g, key, "10")), INVALID_ARGUMENT, "idempotency_key_reused");
  }
});
