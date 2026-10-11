// VS-01 WP01-E E1 corrective (GPT review): a claim refused as transient
// (rate_limited / too_early) before the ticket deadline must have its MC-1
// Option C intent durably recorded, also when the intent write loses a
// version race; otherwise the legitimate result would be lost at expiry.
import test from "node:test";
import assert from "node:assert/strict";
import { loadModule, FakeNakama, ctxFor, call } from "./harness.mjs";

const clock = { t: 1_800_000_000_000, now() { return this.t; } };
const m = loadModule(clock);
const U1 = "11111111-1111-1111-1111-111111111111";
const ALREADY_EXISTS = 6, RESOURCE_EXHAUSTED = 8, FAILED_PRECONDITION = 9, ABORTED = 10, UNAVAILABLE = 14;
const G1 = "prototype_monster_01";
const MIN_AGE = 10000;
const THROTTLED = { MYRIAL_RL_E_CLAIM_PER_60S: "0" };

function fresh() {
  clock.t = 1_800_000_000_000;
  return new FakeNakama({ md5: true });
}
function session(nk) {
  const r = call(m, "rpcSessionBegin", nk, ctxFor(U1), "{}");
  assert.ok(r.ok, JSON.stringify(r));
  return r.value.gameplay_session_id;
}
function ticket(nk, g) {
  const r = call(m, "rpcEncounterBegin", nk, ctxFor(U1), { gameplay_session_id: g, group_ids: [G1] });
  assert.ok(r.ok, JSON.stringify(r));
  return r.value.ticket;
}
function claim(nk, g, ticketId, key, env = {}) {
  return call(m, "rpcEncounterClaim", nk, ctxFor(U1, env), {
    gameplay_session_id: g, idempotency_key: key, ticket_id: ticketId, outcome: "victory", kills: 10, hero_alive: true,
  });
}
function trade(nk, g, key) {
  const r = call(m, "rpcTrade", nk, ctxFor(U1), { gameplay_session_id: g, idempotency_key: key, action: "buy", city_id: "A", good_id: "test_good_01", quantity: 1 });
  assert.ok(r.ok, JSON.stringify(r));
}
function intent(nk, ticketId) {
  const o = nk.storageRead([{ collection: "vs01_wp01e_claim_intents", key: ticketId, userId: U1 }])[0];
  return o ? o.value : null;
}
function hero(nk) {
  const o = nk.storageRead([{ collection: "vs01_wp01e_hero_progression", key: "hero", userId: U1 }])[0];
  return o ? o.value : null;
}
function refused(r, code, message) {
  assert.equal(r.ok, false, JSON.stringify(r));
  assert.equal(r.message, message);
  assert.equal(r.code, code);
}

test("REPRO: throttled claim whose intent write loses a version race (a trade lands) still persists the intent and is decided after the deadline", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  clock.t = t.expires_at_ms - 1; // the last moment before the deadline
  let races = 0;
  nk.beforeWrite = (n) => { races += 1; trade(n, g, "race-trade-key-0001"); };
  refused(claim(nk, g, t.ticket_id, "throttled-key-00001", THROTTLED), RESOURCE_EXHAUSTED, "rate_limited");
  assert.equal(races, 1, "the race was injected into the intent write");
  const rec = intent(nk, t.ticket_id);
  assert.ok(rec, "the intent must be recorded despite the lost race");
  assert.equal(rec.state, "RECORDED");
  assert.equal(rec.first_seen_at_ms, t.expires_at_ms - 1, "first seen before the deadline (server time at RPC entry)");
  clock.t = t.expires_at_ms + 60_000;
  const r = claim(nk, g, t.ticket_id, "throttled-key-00001");
  assert.ok(r.ok, `legitimate EXP must not be lost: ${JSON.stringify(r)}`);
  assert.equal(r.value.receipt.exp_awarded, 100);
  assert.equal(claim(nk, g, t.ticket_id, "throttled-key-00001").value.replayed, true);
  assert.equal(hero(nk).revision, 1, "EXP awarded exactly once");
});

test("REPRO: too_early claim whose intent write loses a version race persists the intent", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  clock.t += MIN_AGE - 1;
  nk.beforeWrite = (n) => { trade(n, g, "race-trade-key-0002"); };
  refused(claim(nk, g, t.ticket_id, "early-race-key-0001"), FAILED_PRECONDITION, "too_early");
  assert.equal(intent(nk, t.ticket_id).state, "RECORDED");
  clock.t = t.expires_at_ms + 1;
  assert.ok(claim(nk, g, t.ticket_id, "early-race-key-0001").ok);
  assert.equal(hero(nk).revision, 1);
});

test("throttled claim: repeated version races are retried on fresh reads (bounded)", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  clock.t = t.expires_at_ms - 1;
  nk.failNextWrites = 5; // five lost races on the intent write
  refused(claim(nk, g, t.ticket_id, "retry-race-key-0001", THROTTLED), RESOURCE_EXHAUSTED, "rate_limited");
  assert.equal(intent(nk, t.ticket_id).state, "RECORDED");
});

test("throttled claim: no rate_limited answer without a confirmed intent when races never end (fails as conflict_retry_exhausted)", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  clock.t = t.expires_at_ms - 1;
  nk.failNextWrites = 1000;
  refused(claim(nk, g, t.ticket_id, "endless-race-key-01", THROTTLED), ABORTED, "conflict_retry_exhausted");
  assert.equal(intent(nk, t.ticket_id), null, "nothing claimed as recorded");
});

test("throttled claim after the deadline records nothing and is an explicit expiry (no extension)", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  clock.t = t.expires_at_ms;
  refused(claim(nk, g, t.ticket_id, "late-throttle-key-1", THROTTLED), FAILED_PRECONDITION, "ticket_expired");
  assert.equal(intent(nk, t.ticket_id), null);
});

test("throttled claim racing a session takeover: superseded, no intent written (policy A)", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  clock.t = t.expires_at_ms - 1;
  nk.beforeWrite = (n) => { call(m, "rpcSessionBegin", n, ctxFor(U1), "{}"); };
  refused(claim(nk, g, t.ticket_id, "takeover-key-000001", THROTTLED), ABORTED, "gameplay_session_superseded");
  assert.equal(intent(nk, t.ticket_id), null);
  clock.t = t.expires_at_ms;
  const g2 = session(nk);
  refused(claim(nk, g2, t.ticket_id, "takeover-key-000001"), FAILED_PRECONDITION, "ticket_expired");
});

test("throttled claim racing the same key already recording: one intent, the other sees it", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  clock.t = t.expires_at_ms - 1;
  nk.beforeWrite = (n) => { refused(claim(n, g, t.ticket_id, "same-throttle-key-1", THROTTLED), RESOURCE_EXHAUSTED, "rate_limited"); };
  refused(claim(nk, g, t.ticket_id, "same-throttle-key-1", THROTTLED), RESOURCE_EXHAUSTED, "rate_limited");
  assert.equal(intent(nk, t.ticket_id).idempotency_key, "same-throttle-key-1");
});

test("throttled claim racing a DIFFERENT key that records first: claim_locked (final), no second intent", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  clock.t = t.expires_at_ms - 1;
  nk.beforeWrite = (n) => { refused(claim(n, g, t.ticket_id, "winner-throttle-k01", THROTTLED), RESOURCE_EXHAUSTED, "rate_limited"); };
  refused(claim(nk, g, t.ticket_id, "loser-throttle-k001", THROTTLED), ALREADY_EXISTS, "claim_locked");
  assert.equal(intent(nk, t.ticket_id).idempotency_key, "winner-throttle-k01");
});

test("throttled claim hitting a storage fault while recording: storage_unavailable (UNCERTAIN), nothing claimed as recorded; retry records", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  clock.t = t.expires_at_ms - 10;
  nk.faultNextWrites = 1;
  refused(claim(nk, g, t.ticket_id, "fault-throttle-k001", THROTTLED), UNAVAILABLE, "storage_unavailable");
  assert.equal(intent(nk, t.ticket_id), null);
  clock.t += 1;
  refused(claim(nk, g, t.ticket_id, "fault-throttle-k001", THROTTLED), RESOURCE_EXHAUSTED, "rate_limited");
  assert.equal(intent(nk, t.ticket_id).state, "RECORDED");
});

test("approved limits are not relaxed: a throttled request never reaches a decision", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  clock.t += MIN_AGE;
  refused(claim(nk, g, t.ticket_id, "no-relax-key-000001", THROTTLED), RESOURCE_EXHAUSTED, "rate_limited");
  assert.equal(hero(nk), null, "no EXP while throttled");
  assert.equal(intent(nk, t.ticket_id).state, "RECORDED");
});
