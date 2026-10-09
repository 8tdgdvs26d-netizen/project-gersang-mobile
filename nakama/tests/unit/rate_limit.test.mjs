// A14 rate limit: PostgreSQL-backed sliding-window log with compare-and-swap.
// The clock is controlled so window edges are exact.
import test from "node:test";
import assert from "node:assert/strict";
import { loadModule, FakeNakama, ctxFor, call } from "./harness.mjs";

const clock = { t: 1_000_000, now() { return this.t; } };
const m = loadModule(clock);
const U = "33333333-3333-3333-3333-333333333333";
const RESOURCE_EXHAUSTED = 8, INTERNAL = 13;
let seq = 0;

function setup() {
  clock.t = 1_000_000 + (++seq) * 10_000_000;
  const nk = new FakeNakama();
  const g = JSON.parse(m.rpcSessionBegin(ctxFor(U), { info() {} }, nk, "{}")).gameplay_session_id;
  return { nk, g };
}

// Returns "ok" | "limited" | error message. Uses a cheap valid order.
function hit(nk, g, env = {}) {
  const r = call(m, "rpcTrade", nk, ctxFor(U, env), {
    gameplay_session_id: g, idempotency_key: `rate-${String(++seq).padStart(12, "0")}`,
    action: "buy", city_id: "A", good_id: "test_good_01", quantity: 1,
  });
  if (r.ok) return "ok";
  return r.code === RESOURCE_EXHAUSTED && r.message === "rate_limited" ? "limited" : r.message;
}

function log(nk) {
  return nk.storageRead([{ collection: "vs01_wp01_rate_limits", key: "trade", userId: U }])[0];
}

test("exactly 30 accepted in a 10 s window; the 31st and later are refused", () => {
  const { nk, g } = setup();
  const out = Array.from({ length: 45 }, () => hit(nk, g));
  assert.equal(out.filter((x) => x === "ok").length, 30);
  assert.equal(out.filter((x) => x === "limited").length, 15);
  assert.deepEqual(out.slice(0, 30), Array(30).fill("ok"));
  assert.equal(log(nk).permissionWrite, 0);
  assert.equal(log(nk).permissionRead, 0);
});

test("sliding window: a request becomes allowed exactly when the oldest leaves the window", () => {
  const { nk, g } = setup();
  const t0 = clock.t;
  for (let i = 0; i < 30; i++) { clock.t = t0 + i * 100; assert.equal(hit(nk, g), "ok"); }
  clock.t = t0 + 9_999;             // first entry (t0) still inside (t0+9999-10000, t0+9999]
  assert.equal(hit(nk, g), "limited");
  clock.t = t0 + 10_000;            // t0 is now outside: one slot frees up
  assert.equal(hit(nk, g), "ok");
  assert.equal(hit(nk, g), "limited");
  clock.t = t0 + 10_100;            // t0+100 leaves
  assert.equal(hit(nk, g), "ok");
  assert.equal(hit(nk, g), "limited");
});

test("fixed-window edge burst is refused (30 just before + 30 just after any boundary)", () => {
  const { nk, g } = setup();
  const boundary = Math.ceil(clock.t / 10_000) * 10_000 + 10_000;
  clock.t = boundary - 50;
  const before = Array.from({ length: 30 }, () => hit(nk, g));
  clock.t = boundary + 50;
  const after = Array.from({ length: 30 }, () => hit(nk, g));
  assert.equal(before.filter((x) => x === "ok").length, 30);
  assert.equal(after.filter((x) => x === "ok").length, 0, "no second allowance at a window boundary");
});

test("every continuous 10 s window holds at most 30 accepted requests (randomised)", () => {
  const { nk, g } = setup();
  let r = 12345;
  const rnd = () => (r = (r * 1103515245 + 12345) % 2147483648) / 2147483648;
  const accepted = [];
  for (let i = 0; i < 2000; i++) {
    clock.t += Math.floor(rnd() * 700);
    if (hit(nk, g) === "ok") accepted.push(clock.t);
  }
  assert.ok(accepted.length > 100);
  for (let i = 0; i + 30 < accepted.length; i++) {
    assert.ok(accepted[i + 30] - accepted[i] >= 10_000, `31 accepted within ${accepted[i + 30] - accepted[i]} ms`);
  }
});

test("a competing writer between read and write is detected; the limit still holds", () => {
  const { nk, g } = setup();
  const env = { MYRIAL_RL_TRADE_PER_10S: "3" };
  assert.equal(hit(nk, g, env), "ok");
  assert.equal(hit(nk, g, env), "ok");
  // This request reads 2 entries; another node accepts one first (3 = full).
  let inner;
  nk.beforeRateWrite = () => { inner = hit(nk, g, env); };
  const outer = hit(nk, g, env);
  assert.equal(inner, "ok");
  assert.equal(outer, "limited", "the loser of the race re-reads and is refused");
  assert.equal(log(nk).value.accepted_ms.length, 3);
});

test("retries never bypass the limit: exhausted retries fail closed", () => {
  const { nk, g } = setup();
  const before = JSON.stringify(log(nk));
  nk.failNextRateWrites = 1000;
  const r = call(m, "rpcTrade", nk, ctxFor(U), {
    gameplay_session_id: g, idempotency_key: "rate-exhaust-0000001", action: "buy", city_id: "A", good_id: "test_good_01", quantity: 1,
  });
  assert.equal(r.code, RESOURCE_EXHAUSTED);
  assert.equal(r.message, "rate_limit_contention");
  assert.equal(JSON.stringify(log(nk)), before, "nothing recorded");
  assert.equal(nk.storageRead([{ collection: "vs01_wp01_receipts", key: "rate-exhaust-0000001", userId: U }]).length, 0, "no trade happened");
  nk.failNextRateWrites = 0;
});

test("every write carries a new seq (no repeated value, so no md5-version ABA)", () => {
  const { nk, g } = setup();
  const seen = new Set();
  for (let i = 0; i < 40; i++) {
    hit(nk, g);
    const v = log(nk).value;
    seen.add(JSON.stringify(v));
  }
  assert.equal(log(nk).value.seq, 30, "40 requests, 30 accepted: seq counts accepted writes only");
  assert.equal(seen.size, 30, "every stored value is distinct");
});

test("a clock step backwards cannot reopen the window or corrupt the log", () => {
  const { nk, g } = setup();
  for (let i = 0; i < 29; i++) assert.equal(hit(nk, g), "ok");
  clock.t -= 60_000; // server clock jumps back a minute with one slot left
  assert.equal(hit(nk, g), "ok", "the last free slot");
  assert.equal(hit(nk, g), "limited", "still full: the log stays ordered and trusted");
  const times = log(nk).value.accepted_ms;
  assert.deepEqual([...times].sort((a, b) => a - b), times);
  clock.t += 60_000 + 9_999;
  assert.equal(hit(nk, g), "limited", "entries recorded at the later time keep their full window");
});

test("tampered or client-made rate state fails closed", () => {
  const { nk, g } = setup();
  hit(nk, g);
  const obj = nk.objects.get(`vs01_wp01_rate_limits/trade/${U}`);
  obj.value.accepted_ms = "x";
  assert.equal(hit(nk, g), "rate_limit_state_not_trusted");
  obj.value.accepted_ms = [];
  obj.permissionWrite = 1;
  assert.equal(hit(nk, g), "rate_limit_state_not_trusted");
});

test("session begin and progress reads are limited with the same mechanism", () => {
  const { nk } = setup();
  let begins = 0;
  for (let i = 0; i < 15; i++) if (call(m, "rpcSessionBegin", nk, ctxFor(U), "{}").ok) begins += 1;
  assert.equal(begins, 9, "10 per 60 s, one already used by setup");
  let reads = 0;
  for (let i = 0; i < 70; i++) if (call(m, "rpcProgressGet", nk, ctxFor(U), "{}").ok) reads += 1;
  assert.equal(reads, 60);
});
