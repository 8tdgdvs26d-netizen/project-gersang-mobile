// VS-01 WP01-H E1: C-B1 Recorded Combat Intent recovery data in
// vs01e_progression_get (Blueprint v0.1r3 §7 / §12 PR-03), against the
// in-memory Nakama double with md5 versions and a controllable clock. The
// claim / abandon RPCs are unchanged; recovery resends the ORIGINAL key and
// claim through vs01e_encounter_claim.
import test from "node:test";
import assert from "node:assert/strict";
import { loadModule, FakeNakama, ctxFor, call } from "./harness.mjs";

const clock = { t: 1_800_000_000_000, now() { return this.t; } };
const m = loadModule(clock);
const U1 = "11111111-1111-1111-1111-111111111111";
const U2 = "22222222-2222-2222-2222-222222222222";
const ALREADY_EXISTS = 6, FAILED_PRECONDITION = 9, ABORTED = 10;
const G1 = "prototype_monster_01";
const MIN_AGE = 10000, TTL = 900000;
const INTENTS = "vs01_wp01e_claim_intents";

let keySeq = 0;
const newKey = () => `h-comb-key-${String(++keySeq).padStart(8, "0")}`;
const CLAIM = { outcome: "victory", kills: 10, hero_alive: true };

function fresh() {
  clock.t = 1_800_000_000_000;
  return new FakeNakama({ md5: true });
}
function session(nk, user = U1) {
  const r = call(m, "rpcSessionBegin", nk, ctxFor(user), "{}");
  assert.ok(r.ok, JSON.stringify(r));
  return r.value.gameplay_session_id;
}
function ticket(nk, g, user = U1) {
  const r = call(m, "rpcEncounterBegin", nk, ctxFor(user), { gameplay_session_id: g, group_ids: [G1] });
  assert.ok(r.ok, JSON.stringify(r));
  return r.value.ticket;
}
function claim(nk, g, ticketId, key, c = CLAIM, user = U1) {
  return call(m, "rpcEncounterClaim", nk, ctxFor(user), { gameplay_session_id: g, idempotency_key: key, ticket_id: ticketId, ...c });
}
function abandon(nk, g, ticketId, key, user = U1) {
  return call(m, "rpcEncounterAbandon", nk, ctxFor(user), { gameplay_session_id: g, idempotency_key: key, ticket_id: ticketId, confirm: true });
}
function progression(nk, g, user = U1) {
  return call(m, "rpcProgressionGet", nk, ctxFor(user), { gameplay_session_id: g });
}
function hero(nk, user = U1) {
  const o = nk.storageRead([{ collection: "vs01_wp01e_hero_progression", key: "hero", userId: user }])[0];
  return o ? o.value : null;
}
function refused(r, code, message) {
  assert.equal(r.ok, false, JSON.stringify(r));
  assert.equal(r.message, message);
  assert.equal(r.code, code);
}
// A too-early claim before the minimum age records a durable MC-1 intent.
function recordIntent(nk, g, t, key, c = CLAIM) {
  refused(claim(nk, g, t.ticket_id, key, c), FAILED_PRECONDITION, "too_early");
  const o = nk.storageRead([{ collection: INTENTS, key: t.ticket_id, userId: U1 }])[0];
  assert.equal(o.value.state, "RECORDED");
}

test("AC-07: no intent -> recorded_intent is null (field present, additive)", () => {
  const nk = fresh();
  const g = session(nk);
  let p = progression(nk, g);
  assert.ok(p.ok);
  assert.equal(p.value.recorded_intent, null);
  assert.equal(p.value.unresolved_ticket, null);
  const t = ticket(nk, g);
  p = progression(nk, g).value;
  assert.equal(p.unresolved_ticket.ticket_id, t.ticket_id);
  assert.equal(p.recorded_intent, null, "an open ticket without an intent shows none");
});

test("AC-07/AC-08 (app kill): the recorded intent's ORIGINAL key and claim go to the NEW active session; it settles once", () => {
  const nk = fresh();
  const g1 = session(nk);
  const t = ticket(nk, g1);
  const key = newKey();
  recordIntent(nk, g1, t, key, { outcome: "retreat", kills: 7, hero_alive: true });
  // App killed: the RAM key is gone. The player signs in again (takeover).
  const g2 = session(nk);
  const p = progression(nk, g2).value;
  assert.deepEqual(p.recorded_intent, {
    status: "recorded", ticket_id: t.ticket_id, idempotency_key: key,
    claim: { outcome: "retreat", kills: 7, hero_alive: true }, first_seen_at_ms: clock.t,
  });
  clock.t += MIN_AGE;
  const r = claim(nk, g2, t.ticket_id, p.recorded_intent.idempotency_key, p.recorded_intent.claim);
  assert.ok(r.ok, JSON.stringify(r));
  assert.equal(r.value.replayed, false);
  const exp = r.value.receipt.exp_awarded;
  assert.ok(exp > 0);
  const again = claim(nk, g2, t.ticket_id, key, p.recorded_intent.claim);
  assert.equal(again.value.replayed, true, "settled: replay, no second award");
  assert.equal(hero(nk).exp + 0, r.value.receipt.exp_after);
  const after = progression(nk, g2).value;
  assert.equal(after.recorded_intent, null);
  assert.equal(after.unresolved_ticket, null);
});

test("AC-07: a NEW key for the recorded ticket is still claim_locked (claim lock unchanged)", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  recordIntent(nk, g, t, newKey());
  clock.t += MIN_AGE;
  refused(claim(nk, g, t.ticket_id, newKey()), ALREADY_EXISTS, "claim_locked");
  refused(claim(nk, g, t.ticket_id, newKey(), { outcome: "retreat", kills: 9, hero_alive: true }), ALREADY_EXISTS, "claim_locked");
});

test("AC-08: a superseded session gets neither progression nor the intent", () => {
  const nk = fresh();
  const g1 = session(nk);
  const t = ticket(nk, g1);
  recordIntent(nk, g1, t, newKey());
  session(nk); // takeover
  refused(progression(nk, g1), ABORTED, "gameplay_session_superseded");
});

test("AC-08: a takeover BETWEEN the two reads of progression_get is caught by the second snapshot (no disclosure)", () => {
  const nk = fresh();
  const g1 = session(nk);
  const t = ticket(nk, g1);
  recordIntent(nk, g1, t, newKey());
  // The limiter write happens after the first snapshot and before the second.
  nk.beforeRateWrite = () => { session(nk); };
  refused(progression(nk, g1), ABORTED, "gameplay_session_superseded");
});

test("AC-16: a settlement BETWEEN the two reads -> no ticket and no intent shown", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  const key = newKey();
  recordIntent(nk, g, t, key);
  clock.t += MIN_AGE;
  nk.beforeRateWrite = (n) => {
    n.beforeRateWrite = null;
    assert.ok(claim(n, g, t.ticket_id, key).ok);
  };
  const p = progression(nk, g);
  assert.ok(p.ok, JSON.stringify(p));
  assert.equal(p.value.unresolved_ticket, null);
  assert.equal(p.value.recorded_intent, null);
});

test("AC-05 (server side): another account never sees the intent", () => {
  const nk = fresh();
  const g1 = session(nk, U1);
  const t = ticket(nk, g1);
  recordIntent(nk, g1, t, newKey());
  const g2 = session(nk, U2);
  const p = progression(nk, g2, U2).value;
  assert.equal(p.recorded_intent, null);
  assert.equal(p.unresolved_ticket, null);
});

// ---------- PR-03: TTL / expiry / replay / abandon ----------

test("PR-03 (a)+(b): intent recorded BEFORE expiry -> after TTL the original key settles exactly once", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  const key = newKey();
  recordIntent(nk, g, t, key);
  clock.t = t.expires_at_ms + 60_000; // well past the deadline
  const g2 = session(nk); // app kill + reclaim
  const p = progression(nk, g2).value;
  assert.equal(p.unresolved_ticket.ticket_id, t.ticket_id, "an intent keeps the ticket unresolved past TTL");
  assert.equal(p.recorded_intent.idempotency_key, key);
  const r = claim(nk, g2, t.ticket_id, key, p.recorded_intent.claim);
  assert.ok(r.ok, JSON.stringify(r));
  assert.ok(r.value.receipt.exp_awarded > 0);
  assert.equal(claim(nk, g2, t.ticket_id, key).value.replayed, true);
});

test("PR-03 (c): NO intent and no receipt -> after TTL ticket_expired, no EXP, nothing to recover", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  clock.t = t.expires_at_ms;
  const p = progression(nk, g).value;
  assert.equal(p.unresolved_ticket, null);
  assert.equal(p.recorded_intent, null);
  refused(claim(nk, g, t.ticket_id, newKey()), FAILED_PRECONDITION, "ticket_expired");
  assert.equal(hero(nk), null, "no EXP granted");
});

test("PR-03 (d): already settled -> replay after TTL, no second award; progression shows no intent", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  const key = newKey();
  clock.t += MIN_AGE;
  const first = claim(nk, g, t.ticket_id, key);
  assert.ok(first.ok);
  clock.t = t.expires_at_ms + 1;
  const again = claim(nk, g, t.ticket_id, key);
  assert.equal(again.value.replayed, true);
  assert.equal(hero(nk).exp, first.value.receipt.exp_after);
  assert.equal(progression(nk, g).value.recorded_intent, null);
});

test("PR-03 (e): abandon wins the race -> the recovered claim is refused (ticket_abandoned); the ticket never reopens", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  const key = newKey();
  recordIntent(nk, g, t, key);
  assert.ok(abandon(nk, g, t.ticket_id, newKey()).ok);
  const p = progression(nk, g).value;
  assert.equal(p.recorded_intent, null);
  assert.equal(p.unresolved_ticket, null);
  clock.t += MIN_AGE;
  refused(claim(nk, g, t.ticket_id, key), FAILED_PRECONDITION, "ticket_abandoned");
  assert.equal(hero(nk), null);
});

test("PR-03 (e): the recovered claim wins the race -> a later abandon is ticket_already_claimed", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  const key = newKey();
  recordIntent(nk, g, t, key);
  clock.t += MIN_AGE;
  assert.ok(claim(nk, g, t.ticket_id, key).ok);
  refused(abandon(nk, g, t.ticket_id, newKey()), ALREADY_EXISTS, "ticket_already_claimed");
});

test("PR-03 (e): abandon commits between the recovered claim's read and write -> the claim re-reads and is refused", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  const key = newKey();
  recordIntent(nk, g, t, key);
  clock.t += MIN_AGE;
  nk.beforeWrite = (n) => { assert.ok(abandon(n, g, t.ticket_id, newKey()).ok); };
  refused(claim(nk, g, t.ticket_id, key), FAILED_PRECONDITION, "ticket_abandoned");
  assert.equal(hero(nk), null);
});

// ---------- fail closed ----------

function tamperIntent(nk, ticketId, change) {
  const id = `${INTENTS}/${ticketId}/${U1}`;
  const o = nk.objects.get(id);
  if (change === null) { nk.objects.delete(id); return; }
  o.value = { ...o.value, ...change };
}

test("§7 fail closed: intent_recorded without a consistent intent -> 'inconsistent', no key or claim disclosed", () => {
  const cases = [
    ["intent missing", null],
    ["request_hash does not match the claim", { request_hash: "claim|x|victory|10|1" }],
    ["claim differs from its hash", { claim: { outcome: "victory", kills: 3, hero_alive: true } }],
    ["intent for another ticket", { ticket_id: "f".repeat(32) }],
  ];
  for (const [name, change] of cases) {
    const nk = fresh();
    const g = session(nk);
    const t = ticket(nk, g);
    recordIntent(nk, g, t, newKey());
    tamperIntent(nk, t.ticket_id, change);
    const p = progression(nk, g);
    assert.ok(p.ok, name + JSON.stringify(p));
    assert.deepEqual(p.value.recorded_intent, { status: "inconsistent", ticket_id: t.ticket_id }, name);
    assert.ok(p.value.progression, name + ": confirmed progression still readable (B-4A)");
  }
});

test("§7: progression_get writes nothing but its rate-limit log (read-only recovery data)", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  recordIntent(nk, g, t, newKey());
  const before = JSON.stringify([...nk.objects.entries()].filter(([, o]) => o.collection !== "vs01_wp01e_rate_limits"));
  assert.ok(progression(nk, g).ok);
  const after = JSON.stringify([...nk.objects.entries()].filter(([, o]) => o.collection !== "vs01_wp01e_rate_limits"));
  assert.equal(after, before);
});

// ---------- E1 R-2: two different fail-closed paths ----------
// (a) every stored object is valid and server-written, but the links do not
//     hold -> RPC succeeds with recorded_intent {status:"inconsistent"} and no
//     key / claim (tests above);
// (b) a stored object is malformed or not server-written -> the RPC itself
//     fails with INTERNAL wp01e_object_not_trusted. Neither is a success,
//     neither discloses a key, and neither changes or clears anything.

function planted(nk, ticketId) {
  return nk.objects.get(`${INTENTS}/${ticketId}/${U1}`);
}

test("R-2 (a): a valid intent in the wrong state (DECIDED while the ticket is open) -> 'inconsistent', RPC ok", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  recordIntent(nk, g, t, newKey());
  planted(nk, t.ticket_id).value.state = "DECIDED";
  const p = progression(nk, g);
  assert.ok(p.ok, JSON.stringify(p));
  assert.deepEqual(p.value.recorded_intent, { status: "inconsistent", ticket_id: t.ticket_id });
});

test("R-2 (b): a malformed or untrusted intent object makes progression_get fail closed (INTERNAL), discloses nothing, writes nothing", () => {
  const cases = [
    ["unknown state", (o) => { o.value.state = "WEIRD"; }],
    ["extra field", (o) => { o.value.extra = 1; }],
    ["claim missing a key", (o) => { delete o.value.claim.hero_alive; }],
    ["bad key format", (o) => { o.value.idempotency_key = "x"; }],
    ["client-writable object", (o) => { o.permissionWrite = 1; }],
  ];
  for (const [name, corrupt] of cases) {
    const nk = fresh();
    const g = session(nk);
    const t = ticket(nk, g);
    const key = newKey();
    recordIntent(nk, g, t, key);
    corrupt(planted(nk, t.ticket_id));
    const snapshot = JSON.stringify([...nk.objects.entries()].filter(([, o]) => o.collection !== "vs01_wp01e_rate_limits"));
    const p = progression(nk, g);
    refused(p, 13, "wp01e_object_not_trusted");
    assert.equal(JSON.stringify(p).includes(key), false, name + ": key not disclosed");
    assert.equal(JSON.stringify([...nk.objects.entries()].filter(([, o]) => o.collection !== "vs01_wp01e_rate_limits")), snapshot, name + ": nothing changed");
  }
});

test("R-2 (b): with a corrupt intent the unchanged claim and abandon also fail closed; no EXP, the intent is not cleared", () => {
  const nk = fresh();
  const g = session(nk);
  const t = ticket(nk, g);
  const key = newKey();
  recordIntent(nk, g, t, key);
  planted(nk, t.ticket_id).value.extra = 1;
  const before = JSON.stringify(planted(nk, t.ticket_id));
  clock.t += MIN_AGE;
  refused(claim(nk, g, t.ticket_id, key), 13, "wp01e_object_not_trusted");
  refused(abandon(nk, g, t.ticket_id, newKey()), 13, "wp01e_object_not_trusted");
  assert.equal(hero(nk), null);
  assert.equal(JSON.stringify(planted(nk, t.ticket_id)), before, "intent untouched");
});
