// Command-level behaviour of the RPCs against an in-memory Nakama double:
// atomicity, idempotency, single active session, forged input, lock-down.
import test from "node:test";
import assert from "node:assert/strict";
import { loadModule, FakeNakama, ctxFor, call } from "./harness.mjs";

const m = loadModule();
const U1 = "11111111-1111-1111-1111-111111111111";
const U2 = "22222222-2222-2222-2222-222222222222";
const INVALID_ARGUMENT = 3, PERMISSION_DENIED = 7, RESOURCE_EXHAUSTED = 8, FAILED_PRECONDITION = 9, ABORTED = 10, INTERNAL = 13, UNAUTHENTICATED = 16;

let keySeq = 0;
const newKey = () => `unit-key-${String(++keySeq).padStart(10, "0")}`;

function begin(nk, user) {
  const r = call(m, "rpcSessionBegin", nk, ctxFor(user), "{}");
  assert.ok(r.ok, JSON.stringify(r));
  return r.value.gameplay_session_id;
}

function trade(nk, user, gsid, overrides = {}, env = {}) {
  return call(m, "rpcTrade", nk, ctxFor(user, env), {
    gameplay_session_id: gsid, idempotency_key: overrides.idempotency_key ?? newKey(),
    action: "buy", city_id: "A", good_id: "test_good_01", quantity: 10, ...overrides,
  });
}

function stored(nk, user) {
  return nk.storageRead([{ collection: "vs01_wp01_progress", key: "trade", userId: user }])[0].value;
}

test("session begin creates server default progress", () => {
  const nk = new FakeNakama();
  const r = call(m, "rpcSessionBegin", nk, ctxFor(U1), "{}");
  assert.ok(r.ok);
  assert.equal(r.value.progress.money, 10000);
  assert.equal(r.value.progress.max_capacity, 100);
  assert.equal(r.value.progress.quotes.A.test_good_01.buy_price, 84);
  assert.equal(stored(nk, U1).gameplay_session_id, r.value.gameplay_session_id);
  assert.equal(nk.storageRead([{ collection: "vs01_wp01_progress", key: "trade", userId: U1 }])[0].permissionWrite, 0);
});

test("buy applies atomically and writes an audit receipt", () => {
  const nk = new FakeNakama();
  const g = begin(nk, U1);
  const r = trade(nk, U1, g, { idempotency_key: "receipt-key-00000001" });
  assert.ok(r.ok);
  assert.equal(r.value.replayed, false);
  assert.equal(r.value.receipt.status, "applied");
  assert.equal(r.value.receipt.total, 840);
  assert.equal(r.value.receipt.money_before - r.value.receipt.money_after, 840);
  const p = stored(nk, U1);
  assert.equal(p.money, 9160);
  assert.equal(p.backpack.test_good_01, 10);
  assert.equal(p.market.A.test_good_01.current_stock, 90);
  const receipt = nk.storageRead([{ collection: "vs01_wp01_receipts", key: "receipt-key-00000001", userId: U1 }])[0];
  assert.equal(receipt.permissionWrite, 0);
  assert.equal(receipt.value.progress_revision, p.revision);
});

test("same idempotency key applies once; replays return the original receipt", () => {
  const nk = new FakeNakama();
  const g = begin(nk, U1);
  const key = "replay-key-00000001";
  const first = trade(nk, U1, g, { idempotency_key: key });
  for (let i = 0; i < 5; i++) {
    const again = trade(nk, U1, g, { idempotency_key: key });
    assert.ok(again.ok);
    assert.equal(again.value.replayed, true);
    assert.deepEqual(again.value.receipt, first.value.receipt);
  }
  assert.equal(stored(nk, U1).money, 9160);
  assert.equal(stored(nk, U1).backpack.test_good_01, 10);
});

test("reusing a key for a different command is refused", () => {
  const nk = new FakeNakama();
  const g = begin(nk, U1);
  trade(nk, U1, g, { idempotency_key: "reuse-key-000000001" });
  const r = trade(nk, U1, g, { idempotency_key: "reuse-key-000000001", quantity: 1 });
  assert.equal(r.ok, false);
  assert.equal(r.code, INVALID_ARGUMENT);
  assert.equal(r.message, "idempotency_key_reused");
});

test("a business rejection changes nothing and replays the same rejection", () => {
  const nk = new FakeNakama();
  const g = begin(nk, U1);
  const before = stored(nk, U1);
  const r = trade(nk, U1, g, { idempotency_key: "reject-key-00000001", good_id: "test_good_06" });
  assert.equal(r.value.receipt.status, "rejected");
  assert.equal(r.value.receipt.reason, "insufficient_money");
  assert.deepEqual(stored(nk, U1), before);
  const again = trade(nk, U1, g, { idempotency_key: "reject-key-00000001", good_id: "test_good_06" });
  assert.equal(again.value.replayed, true);
  assert.equal(again.value.receipt.reason, "insufficient_money");
});

test("new gameplay session takes over; the old one can no longer write (D2)", () => {
  const nk = new FakeNakama();
  const oldG = begin(nk, U1);
  const newG = begin(nk, U1);
  assert.notEqual(oldG, newG);
  const stale = trade(nk, U1, oldG);
  assert.equal(stale.ok, false);
  assert.equal(stale.code, ABORTED);
  assert.equal(stale.message, "gameplay_session_superseded");
  assert.equal(stored(nk, U1).money, 10000);
  assert.ok(trade(nk, U1, newG).ok);
});

test("uncertain command retried from a NEW session returns the original receipt", () => {
  const nk = new FakeNakama();
  const g1 = begin(nk, U1);
  const key = "uncertain-key-000001";
  const first = trade(nk, U1, g1, { idempotency_key: key }); // response "lost"
  const g2 = begin(nk, U1); // client restarts / reconnects
  const retry = trade(nk, U1, g2, { idempotency_key: key });
  assert.equal(retry.value.replayed, true);
  assert.deepEqual(retry.value.receipt, first.value.receipt);
  assert.equal(stored(nk, U1).money, 9160);
});

test("trade without a gameplay session is refused", () => {
  const nk = new FakeNakama();
  const r = trade(nk, U1, "00000000-0000-0000-0000-000000000000");
  assert.equal(r.code, FAILED_PRECONDITION);
});

test("lost write races are retried and never double-apply", () => {
  const nk = new FakeNakama();
  const g = begin(nk, U1);
  nk.failNextWrites = 3;
  const r = trade(nk, U1, g, { idempotency_key: "race-key-0000000001" });
  assert.ok(r.ok);
  assert.equal(stored(nk, U1).money, 9160);
  nk.failNextWrites = 99;
  const exhausted = trade(nk, U1, g);
  assert.equal(exhausted.code, ABORTED);
  assert.equal(exhausted.message, "conflict_retry_exhausted");
  nk.failNextWrites = 0;
  assert.equal(stored(nk, U1).money, 9160);
});

test("a concurrent trade between read and write is detected and recomputed", () => {
  const nk = new FakeNakama();
  const g = begin(nk, U1);
  // Another request lands after this one read progress: both must apply,
  // each at its own correct (stock-dependent) price, none lost.
  nk.beforeWrite = (fake) => { trade(fake, U1, g, { idempotency_key: "inner-key-000000001" }); };
  const outer = trade(nk, U1, g, { idempotency_key: "outer-key-000000001" });
  assert.ok(outer.ok);
  const p = stored(nk, U1);
  assert.equal(p.backpack.test_good_01, 20);
  assert.equal(p.money, 10000 - 840 - 890);
  assert.equal(p.market.A.test_good_01.current_stock, 80);
});

test("the same key arriving concurrently is recorded once (receipt is create-only)", () => {
  const nk = new FakeNakama();
  const g = begin(nk, U1);
  const key = "concurrent-same-key-01";
  let inner;
  // Both requests read "no receipt yet"; the inner one writes first. A
  // rejection writes no progress, so only the receipt's create-only write
  // can stop the outer one from overwriting the recorded outcome.
  nk.beforeWrite = (fake) => { inner = trade(fake, U1, g, { idempotency_key: key, good_id: "test_good_06" }); };
  const outer = trade(nk, U1, g, { idempotency_key: key, good_id: "test_good_06" });
  assert.equal(inner.value.replayed, false);
  assert.equal(outer.value.replayed, true);
  assert.deepEqual(outer.value.receipt, inner.value.receipt);
  const recorded = nk.storageRead([{ collection: "vs01_wp01_receipts", key, userId: U1 }])[0].value;
  assert.deepEqual(recorded, inner.value.receipt);
});

test("forged or malformed commands are rejected before any state change", () => {
  const nk = new FakeNakama();
  const g = begin(nk, U1);
  const before = stored(nk, U1);
  const base = { gameplay_session_id: g, idempotency_key: newKey(), action: "buy", city_id: "A", good_id: "test_good_01", quantity: 10 };
  const cases = [
    [{ ...base, price: 1 }, "unexpected_fields"],
    [{ ...base, money: 99999999 }, "unexpected_fields"],
    [{ ...base, action: "grant" }, "invalid_action"],
    [{ ...base, quantity: "10" }, "invalid_quantity"],
    [{ ...base, idempotency_key: "short" }, "invalid_idempotency_key"],
    [{ ...base, idempotency_key: "../../etc/passwd-xxxxxxxx" }, "invalid_idempotency_key"],
    [{ ...base, gameplay_session_id: 5 }, "invalid_gameplay_session_id"],
    [{ action: "buy" }, "unexpected_fields"],
  ];
  for (const [payload, message] of cases) {
    const r = call(m, "rpcTrade", nk, ctxFor(U1), payload);
    assert.equal(r.ok, false, message);
    assert.equal(r.code, INVALID_ARGUMENT, message);
    assert.equal(r.message, message);
  }
  assert.equal(call(m, "rpcTrade", nk, ctxFor(U1), "{not json").message, "payload_not_json");
  assert.equal(call(m, "rpcTrade", nk, ctxFor(U1), "x".repeat(5000)).message, "payload_too_large");
  for (const quantity of [0, -10, 2, 1.5, 1e300, Number.MAX_SAFE_INTEGER]) {
    const r = trade(nk, U1, g, { quantity });
    assert.equal(r.value.receipt.status, "rejected", `quantity ${quantity}`);
    assert.equal(r.value.receipt.reason, "invalid_quantity");
  }
  assert.equal(trade(nk, U1, g, { city_id: "Z" }).value.receipt.reason, "invalid_city_or_good");
  assert.equal(trade(nk, U1, g, { good_id: "gold" }).value.receipt.reason, "invalid_city_or_good");
  assert.equal(trade(nk, U1, g, { good_id: "__proto__" }).value.receipt.reason, "invalid_city_or_good");
  assert.equal(trade(nk, U1, g, { action: "sell" }).value.receipt.reason, "insufficient_cargo");
  const after = stored(nk, U1);
  assert.equal(after.money, before.money);
  assert.deepEqual(after.backpack, before.backpack);
  assert.deepEqual(after.market, before.market);
});

test("accounts are isolated: one player's command never touches another's progress", () => {
  const nk = new FakeNakama();
  const g1 = begin(nk, U1);
  begin(nk, U2);
  // U2 presents U1's gameplay session id: still U2's own (superseding) check fails.
  const cross = trade(nk, U2, g1);
  assert.equal(cross.code, ABORTED);
  assert.equal(stored(nk, U1).money, 10000);
  assert.equal(stored(nk, U2).money, 10000);
  // Same idempotency key in two accounts = two independent commands.
  const k = "shared-key-00000001";
  assert.ok(trade(nk, U1, g1, { idempotency_key: k }).ok);
  assert.equal(stored(nk, U2).money, 10000);
});

test("unauthenticated (server-key) calls are refused", () => {
  const nk = new FakeNakama();
  for (const fn of ["rpcSessionBegin", "rpcProgressGet", "rpcTrade", "rpcCombatRewardClaim"]) {
    assert.equal(call(m, fn, nk, ctxFor(""), "{}").code, UNAUTHENTICATED, fn);
  }
});

test("rate limit rejects bursts above the per-user window", () => {
  const nk = new FakeNakama();
  const g = begin(nk, U1);
  const env = { MYRIAL_RL_TRADE_PER_10S: "5" };
  let limited = 0;
  for (let i = 0; i < 12; i++) {
    const r = trade(nk, U1, g, { quantity: 1 }, env);
    if (!r.ok && r.code === RESOURCE_EXHAUSTED) limited += 1;
  }
  assert.ok(limited >= 6, `limited ${limited}`);
  assert.ok(stored(nk, U1).backpack.test_good_01 <= 6);
});

test("combat reward claims are always refused (D4)", () => {
  const nk = new FakeNakama();
  begin(nk, U1);
  const r = call(m, "rpcCombatRewardClaim", nk, ctxFor(U1), { money: 999999, exp: 999 });
  assert.equal(r.code, PERMISSION_DENIED);
  assert.equal(r.message, "combat_reward_requires_server_validation");
  assert.equal(stored(nk, U1).money, 10000);
});

test("tampered or client-created progress objects fail closed", () => {
  const nk = new FakeNakama();
  const g = begin(nk, U1);
  const obj = nk.objects.get(`vs01_wp01_progress/trade/${U1}`);
  obj.value.money = -5;
  assert.equal(trade(nk, U1, g).code, INTERNAL);
  obj.value.money = 10000;
  obj.value.extra = true;
  assert.equal(trade(nk, U1, g).code, INTERNAL);
  delete obj.value.extra;
  obj.permissionWrite = 1; // as if a client had created it
  const r = trade(nk, U1, g);
  assert.equal(r.code, INTERNAL);
  assert.equal(r.message, "server_object_not_trusted");
});

test("API lock-down hooks: guest auth denied, email only with the local test flag", () => {
  const ctx = ctxFor("");
  assert.throws(() => m.guardDenyAuthMethod(ctx, null, null, {}), (e) => e.code === PERMISSION_DENIED);
  assert.throws(() => m.guardEmailTestAuthOnly(ctx, null, null, {}), (e) => e.code === PERMISSION_DENIED);
  assert.throws(() => m.guardEmailTestAuthOnly(ctxFor("", { MYRIAL_ALLOW_EMAIL_TEST_AUTH: "false" }), null, null, {}), (e) => e.code === PERMISSION_DENIED);
  const data = { account: { email: "a@b.test" } };
  assert.equal(m.guardEmailTestAuthOnly(ctxFor("", { MYRIAL_ALLOW_EMAIL_TEST_AUTH: "true" }), null, null, data), data);
  assert.throws(() => m.guardDenyClientStorageWrite(ctx, null, null, {}), (e) => e.code === PERMISSION_DENIED);
});

test("progress_get shows recovered prices without persisting them", () => {
  const nk = new FakeNakama();
  const g = begin(nk, U1);
  trade(nk, U1, g);
  const before = JSON.stringify(stored(nk, U1));
  const r = call(m, "rpcProgressGet", nk, ctxFor(U1), "{}");
  assert.ok(r.ok);
  assert.equal(r.value.progress.money, 9160);
  assert.equal(JSON.stringify(stored(nk, U1)), before);
});
