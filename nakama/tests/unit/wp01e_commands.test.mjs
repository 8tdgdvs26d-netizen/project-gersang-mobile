// VS-01 WP01-E: encounter begin / claim / abandon / progression read against
// the in-memory Nakama double with Nakama's md5 versions (an unchanged
// rewrite keeps its version) and a controllable server clock.
import test from "node:test";
import assert from "node:assert/strict";
import { loadModule, FakeNakama, ctxFor, call, VERSION_CONFLICT, DB_FAULT } from "./harness.mjs";

const clock = { t: 1_800_000_000_000, now() { return this.t; } };
const m = loadModule(clock);
const U1 = "11111111-1111-1111-1111-111111111111";
const U2 = "22222222-2222-2222-2222-222222222222";
const INVALID_ARGUMENT = 3, NOT_FOUND = 5, ALREADY_EXISTS = 6, RESOURCE_EXHAUSTED = 8, FAILED_PRECONDITION = 9,
  ABORTED = 10, INTERNAL = 13, UNAVAILABLE = 14;
const G1 = "prototype_monster_01", G2 = "prototype_monster_02", G3 = "prototype_monster_03";
const MIN_AGE = 10000, TTL = 900000;

let keySeq = 0;
const newKey = () => `e-unit-key-${String(++keySeq).padStart(8, "0")}`;

function fresh() {
  clock.t = 1_800_000_000_000;
  return new FakeNakama({ md5: true });
}
function session(nk, user = U1) {
  const r = call(m, "rpcSessionBegin", nk, ctxFor(user), "{}");
  assert.ok(r.ok, JSON.stringify(r));
  return r.value.gameplay_session_id;
}
function begin(nk, gsid, groups = [G1], user = U1, env = {}) {
  return call(m, "rpcEncounterBegin", nk, ctxFor(user, env), { gameplay_session_id: gsid, group_ids: groups });
}
function claim(nk, gsid, ticketId, o = {}, user = U1, env = {}) {
  return call(m, "rpcEncounterClaim", nk, ctxFor(user, env), {
    gameplay_session_id: gsid, idempotency_key: o.key ?? newKey(), ticket_id: ticketId,
    outcome: o.outcome ?? "victory", kills: o.kills ?? 10, hero_alive: o.hero_alive ?? true,
  });
}
function abandon(nk, gsid, ticketId, o = {}, user = U1, env = {}) {
  return call(m, "rpcEncounterAbandon", nk, ctxFor(user, env), {
    gameplay_session_id: gsid, idempotency_key: o.key ?? newKey(), ticket_id: ticketId, confirm: o.confirm ?? true,
  });
}
function progression(nk, gsid, user = U1, env = {}) {
  return call(m, "rpcProgressionGet", nk, ctxFor(user, env), { gameplay_session_id: gsid });
}
function obj(nk, collection, key, user = U1) {
  return nk.storageRead([{ collection, key, userId: user }])[0];
}
function okBegin(nk, gsid, groups = [G1]) {
  const r = begin(nk, gsid, groups);
  assert.ok(r.ok, JSON.stringify(r));
  return r.value.ticket;
}
function refused(r, code, message) {
  assert.equal(r.ok, false, JSON.stringify(r));
  assert.equal(r.message, message);
  assert.equal(r.code, code);
}
function hero(nk, user = U1) {
  const o = obj(nk, "vs01_wp01e_hero_progression", "hero", user);
  return o ? o.value : null;
}

test("begin issues one server ticket; the account then holds one unresolved ticket", () => {
  const nk = fresh();
  const g = session(nk);
  const r = begin(nk, g, [G1, G3]);
  assert.ok(r.ok, JSON.stringify(r));
  const t = r.value.ticket;
  assert.match(t.ticket_id, /^[0-9a-f]{32}$/);
  assert.equal(t.enemy_count, 15);
  assert.equal(t.issued_at_ms, clock.t);
  assert.equal(t.min_claim_at_ms, clock.t + MIN_AGE);
  assert.equal(t.expires_at_ms, clock.t + TTL);
  assert.deepEqual(r.value.progression, { level: 1, exp: 0, exp_to_next: 100, revision: 0 });
  assert.equal(obj(nk, "vs01_wp01e_encounter_state", "state").value.open_ticket_id, t.ticket_id);
  for (const c of ["vs01_wp01e_tickets", "vs01_wp01e_encounter_state"]) {
    const o = nk.storageRead([{ collection: c, key: c.endsWith("state") ? "state" : t.ticket_id, userId: U1 }])[0];
    assert.equal(o.permissionRead, 0);
    assert.equal(o.permissionWrite, 0);
  }
  refused(begin(nk, g, [G2]), FAILED_PRECONDITION, "ticket_unsettled");
});

test("begin refuses malformed group lists", () => {
  const nk = fresh();
  const g = session(nk);
  for (const groups of [[], ["nope"], [G1, G1], [G1, G2, G3, G1], "x"]) refused(begin(nk, g, groups), INVALID_ARGUMENT, "invalid_group_ids");
  refused(call(m, "rpcEncounterBegin", nk, ctxFor(U1), { gameplay_session_id: g, group_ids: [G1], exp: 999 }), INVALID_ARGUMENT, "unexpected_fields");
});

test("a VICTORY claim settles once with server-computed EXP and Level", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  clock.t += MIN_AGE;
  const r = claim(nk, g, t.ticket_id, { key: "victory-key-000001", kills: 10 });
  assert.ok(r.ok, JSON.stringify(r));
  assert.equal(r.value.replayed, false);
  const rc = r.value.receipt;
  assert.equal(rc.exp_awarded, 100);
  assert.deepEqual([rc.level_before, rc.exp_before, rc.level_after, rc.exp_after], [1, 0, 2, 0]);
  assert.deepEqual([...rc.cooldown_groups], [G1]);
  assert.deepEqual(r.value.progression, { level: 2, exp: 0, exp_to_next: 150, revision: 1 });
  assert.equal(obj(nk, "vs01_wp01e_tickets", t.ticket_id).value.status, "CLAIMED");
  assert.equal(obj(nk, "vs01_wp01e_encounter_state", "state").value.open_ticket_id, "");
  assert.ok(obj(nk, "vs01_wp01e_ticket_claims", t.ticket_id));
  assert.equal(obj(nk, "vs01_wp01e_claim_intents", t.ticket_id).value.state, "DECIDED");
  // Any other key for the same ticket cannot pay again.
  refused(claim(nk, g, t.ticket_id, { kills: 10 }), ALREADY_EXISTS, "ticket_already_claimed");
  assert.equal(hero(nk).level, 2);
});

test("replay returns the identical receipt (also after the deadline) and never pays twice", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  clock.t += MIN_AGE;
  const first = claim(nk, g, t.ticket_id, { key: "replay-key-0000001" });
  assert.ok(first.ok);
  clock.t += TTL + 3600000;
  const again = claim(nk, g, t.ticket_id, { key: "replay-key-0000001" });
  assert.ok(again.ok, JSON.stringify(again));
  assert.equal(again.value.replayed, true);
  assert.deepEqual(again.value.receipt, first.value.receipt, "receipt content identical");
  assert.deepEqual(again.value.progression, first.value.progression);
  assert.equal(hero(nk).revision, 1, "no second award");
  refused(claim(nk, g, t.ticket_id, { key: "replay-key-0000001", kills: 9, outcome: "retreat" }), INVALID_ARGUMENT, "idempotency_key_reused");
});

test("R-1: an early legitimate win is too_early (intent kept, no receipt), then settles once", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  clock.t += MIN_AGE - 1;
  refused(claim(nk, g, t.ticket_id, { key: "early-key-00000001" }), FAILED_PRECONDITION, "too_early");
  assert.equal(obj(nk, "vs01_wp01e_receipts", "early-key-00000001"), undefined, "no receipt for a transient refusal");
  assert.equal(hero(nk), null);
  assert.equal(obj(nk, "vs01_wp01e_claim_intents", t.ticket_id).value.state, "RECORDED");
  refused(claim(nk, g, t.ticket_id, { key: "other-key-00000001" }), ALREADY_EXISTS, "claim_locked");
  clock.t += 1;
  const r = claim(nk, g, t.ticket_id, { key: "early-key-00000001" });
  assert.ok(r.ok, JSON.stringify(r));
  assert.equal(r.value.receipt.exp_awarded, 100);
  assert.equal(r.value.receipt.intent_first_seen_at_ms, clock.t - 1);
});

test("MC-1 C: an intent recorded before the deadline is decided after it; none recorded = explicit expiry", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  clock.t += 5000;
  refused(claim(nk, g, t.ticket_id, { key: "late-key-000000001" }), FAILED_PRECONDITION, "too_early");
  clock.t = t.expires_at_ms + 7 * 24 * 3600000;
  refused(begin(nk, g, [G2]), FAILED_PRECONDITION, "ticket_unsettled");
  assert.equal(progression(nk, g).value.unresolved_ticket.intent_recorded, true);
  const r = claim(nk, g, t.ticket_id, { key: "late-key-000000001" });
  assert.ok(r.ok, JSON.stringify(r));
  assert.equal(r.value.receipt.exp_awarded, 100);

  // Without an intent before the deadline: explicit loss, slot freed.
  const t2 = okBegin(nk, g, [G2]);
  clock.t = t2.expires_at_ms;
  refused(claim(nk, g, t2.ticket_id), FAILED_PRECONDITION, "ticket_expired");
  assert.equal(obj(nk, "vs01_wp01e_tickets", t2.ticket_id).value.status, "EXPIRED");
  assert.equal(obj(nk, "vs01_wp01e_encounter_state", "state").value.open_ticket_id, "");
  assert.equal(obj(nk, "vs01_wp01e_claim_intents", t2.ticket_id), undefined);
  assert.ok(begin(nk, g, [G3]).ok);
});

test("MC-1 C: a claim throttled before the deadline keeps its intent and is decided later", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  clock.t = t.expires_at_ms - 1000;
  refused(claim(nk, g, t.ticket_id, { key: "throttle-key-00001" }, U1, { MYRIAL_RL_E_CLAIM_PER_60S: "0" }), RESOURCE_EXHAUSTED, "rate_limited");
  assert.equal(obj(nk, "vs01_wp01e_claim_intents", t.ticket_id).value.state, "RECORDED");
  clock.t = t.expires_at_ms + 120000;
  const r = claim(nk, g, t.ticket_id, { key: "throttle-key-00001" });
  assert.ok(r.ok, JSON.stringify(r));
  assert.equal(r.value.receipt.exp_awarded, 100);
});

test("MC-1 C: a superseded session records no intent and gets no extension", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  const g2 = session(nk); // takeover
  clock.t += 5000;
  refused(claim(nk, g, t.ticket_id), ABORTED, "gameplay_session_superseded");
  assert.equal(obj(nk, "vs01_wp01e_claim_intents", t.ticket_id), undefined);
  clock.t = t.expires_at_ms;
  refused(claim(nk, g2, t.ticket_id), FAILED_PRECONDITION, "ticket_expired");
});

test("MC-2 Q1+F3: abandon is explicit, consumes begin quota, adds no wait or cooldown, never revokes", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  refused(abandon(nk, g, t.ticket_id, { confirm: false }), INVALID_ARGUMENT, "confirm_required");
  const a = abandon(nk, g, t.ticket_id, { key: "abandon-key-000001" }); // at age 0: no age gate
  assert.ok(a.ok, JSON.stringify(a));
  assert.equal(a.value.receipt.kind, "abandon");
  assert.equal(a.value.receipt.exp_awarded, 0);
  assert.equal(obj(nk, "vs01_wp01e_tickets", t.ticket_id).value.status, "ABANDONED");
  assert.deepEqual(obj(nk, "vs01_wp01e_encounter_state", "state").value.group_available_at_ms, {}, "no abandon cooldown");
  assert.equal(abandon(nk, g, t.ticket_id, { key: "abandon-key-000001" }).value.replayed, true);
  refused(abandon(nk, g, t.ticket_id), FAILED_PRECONDITION, "ticket_abandoned");
  refused(claim(nk, g, t.ticket_id), FAILED_PRECONDITION, "ticket_abandoned");
  assert.ok(begin(nk, g, [G1]).ok, "same group immediately (no abandon cooldown)");

  // A settled claim is never revoked by abandon.
  const nk2 = fresh();
  const h = session(nk2);
  const t2 = okBegin(nk2, h, [G1]);
  clock.t += MIN_AGE;
  assert.ok(claim(nk2, h, t2.ticket_id).ok);
  refused(abandon(nk2, h, t2.ticket_id), ALREADY_EXISTS, "ticket_already_claimed");
  assert.equal(hero(nk2).level, 2);
});

test("MC-2 Q1: begin + abandon share 6 per rolling 60 s (no free reroll)", () => {
  const nk = fresh();
  const g = session(nk);
  let cycles = 0;
  for (let i = 0; i < 6; i++) {
    const b = begin(nk, g, [G1]);
    if (!b.ok) { refused(b, RESOURCE_EXHAUSTED, "rate_limited"); break; }
    const a = abandon(nk, g, b.value.ticket.ticket_id);
    if (!a.ok) { refused(a, RESOURCE_EXHAUSTED, "rate_limited"); break; }
    cycles += 1;
  }
  assert.equal(cycles, 3, "each reroll costs two units of the begin quota");
  clock.t += 60000;
  assert.ok(begin(nk, g, [G1]).ok, "the window rolls");
  assert.equal(hero(nk), null, "rerolls never award EXP");
});

test("R-4: positive EXP (VICTORY or RETREAT) cools the groups >= 10 s; zero EXP does not", () => {
  const nk = fresh();
  const g = session(nk);
  let t = okBegin(nk, g, [G1, G2]);
  clock.t += MIN_AGE;
  assert.ok(claim(nk, g, t.ticket_id, { outcome: "retreat", kills: 3 }).ok);
  const settled = clock.t;
  clock.t = settled + 9999;
  refused(begin(nk, g, [G2]), FAILED_PRECONDITION, "cooldown_active");
  t = okBegin(nk, g, [G3]); // other group unaffected
  clock.t += MIN_AGE;
  assert.ok(claim(nk, g, t.ticket_id, { outcome: "defeat", kills: 4, hero_alive: false }).ok);
  assert.equal(hero(nk).exp, 30);
  assert.ok(begin(nk, g, [G3]).ok, "zero-EXP outcome sets no cooldown");
});

test("policy A: a superseded session cannot claim, replay or read; the reclaimed device resends the same key once", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  clock.t += MIN_AGE;
  const g2 = session(nk); // another device takes over
  refused(claim(nk, g, t.ticket_id, { key: "reclaim-key-000001" }), ABORTED, "gameplay_session_superseded");
  refused(progression(nk, g), ABORTED, "gameplay_session_superseded");
  const g3 = session(nk); // the original device reclaims
  const r = claim(nk, g3, t.ticket_id, { key: "reclaim-key-000001" });
  assert.ok(r.ok, JSON.stringify(r));
  refused(claim(nk, g2, t.ticket_id, { key: "reclaim-key-000001" }), ABORTED, "gameplay_session_superseded");
  assert.equal(claim(nk, g3, t.ticket_id, { key: "reclaim-key-000001" }).value.replayed, true);
  assert.equal(hero(nk).revision, 1);
});

test("ACK-1: the Trade v1 object is rewritten with an identical value: content and version unchanged", () => {
  const nk = fresh();
  const g = session(nk);
  const before = obj(nk, "vs01_wp01_progress", "trade");
  const t = okBegin(nk, g, [G1]);
  clock.t += MIN_AGE;
  assert.ok(claim(nk, g, t.ticket_id).ok);
  assert.ok(okBegin(nk, g, [G2]));
  const after = obj(nk, "vs01_wp01_progress", "trade");
  assert.equal(after.version, before.version, "md5 version unchanged");
  assert.deepEqual(after.value, before.value, "Trade v1 content unchanged");
  // Trade keeps working on the same object afterwards.
  const tr = call(m, "rpcTrade", nk, ctxFor(U1), { gameplay_session_id: g, idempotency_key: newKey(), action: "buy", city_id: "A", good_id: "test_good_01", quantity: 10 });
  assert.ok(tr.ok, JSON.stringify(tr));
  assert.equal(tr.value.receipt.status, "applied");
});

test("ACK-1: a takeover between the claim's read and write aborts the claim (nothing written)", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  clock.t += MIN_AGE;
  let hooked = 0;
  nk.beforeWrite = (n) => { hooked += 1; call(m, "rpcSessionBegin", n, ctxFor(U1), "{}"); };
  refused(claim(nk, g, t.ticket_id), ABORTED, "gameplay_session_superseded");
  assert.equal(hooked, 1);
  assert.equal(hero(nk), null);
  assert.equal(obj(nk, "vs01_wp01e_tickets", t.ticket_id).value.status, "OPEN");
  assert.equal(obj(nk, "vs01_wp01e_ticket_claims", t.ticket_id), undefined);
});

test("ACK-1: a trade committing between the claim's read and write makes the claim retry, both apply once", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  clock.t += MIN_AGE;
  nk.beforeWrite = (n) => {
    const tr = call(m, "rpcTrade", n, ctxFor(U1), { gameplay_session_id: g, idempotency_key: "race-trade-0000001", action: "buy", city_id: "A", good_id: "test_good_01", quantity: 1 });
    assert.ok(tr.ok, JSON.stringify(tr));
  };
  const r = claim(nk, g, t.ticket_id);
  assert.ok(r.ok, JSON.stringify(r));
  assert.equal(hero(nk).level, 2);
  const p = obj(nk, "vs01_wp01_progress", "trade").value;
  assert.equal(p.backpack.test_good_01, 1, "the trade applied exactly once");
});

test("concurrency: the same key committed by a competing request is replayed, EXP once", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  clock.t += MIN_AGE;
  nk.beforeWrite = (n) => { assert.ok(claim(n, g, t.ticket_id, { key: "same-key-000000001" }).ok); };
  const r = claim(nk, g, t.ticket_id, { key: "same-key-000000001" });
  assert.ok(r.ok, JSON.stringify(r));
  assert.equal(r.value.replayed, true);
  assert.equal(hero(nk).revision, 1);
});

test("concurrency: a different key settling the ticket first leaves the loser ticket_already_claimed", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  clock.t += MIN_AGE;
  nk.beforeWrite = (n) => { assert.ok(claim(n, g, t.ticket_id, { key: "winner-key-0000001" }).ok); };
  // The loser re-reads after its lost race: the ticket is settled.
  refused(claim(nk, g, t.ticket_id, { key: "loser-key-00000001" }), ALREADY_EXISTS, "ticket_already_claimed");
  assert.equal(hero(nk).revision, 1);
});

test("concurrency: claim vs abandon on one ticket: exactly one commits", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  clock.t += MIN_AGE;
  nk.beforeWrite = (n) => { assert.ok(abandon(n, g, t.ticket_id).ok); };
  refused(claim(nk, g, t.ticket_id), FAILED_PRECONDITION, "ticket_abandoned");
  assert.equal(hero(nk), null);
});

test("lost races retry; a non-conflict storage fault fails fast with nothing written", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  clock.t += MIN_AGE;
  nk.faultNextWrites = 1;
  refused(claim(nk, g, t.ticket_id, { key: "fault-key-00000001" }), UNAVAILABLE, "storage_unavailable");
  assert.equal(hero(nk), null);
  assert.equal(obj(nk, "vs01_wp01e_receipts", "fault-key-00000001"), undefined);
  nk.failNextWrites = 3;
  const r = claim(nk, g, t.ticket_id, { key: "fault-key-00000001" });
  assert.ok(r.ok, JSON.stringify(r));
  assert.equal(r.value.replayed, false);
  assert.equal(hero(nk).revision, 1);
});

test("R-3: begin 6, claim 12, replay 30 per rolling 60 s, per account, not reset by a new session", () => {
  const nk = fresh();
  let g = session(nk);
  const t = okBegin(nk, g, [G1]);
  for (let i = 0; i < 5; i++) refused(begin(nk, g, [G2]), FAILED_PRECONDITION, "ticket_unsettled");
  g = session(nk);
  refused(begin(nk, g, [G2]), RESOURCE_EXHAUSTED, "rate_limited");
  clock.t += MIN_AGE;
  const key = "quota-key-00000001";
  assert.ok(claim(nk, g, t.ticket_id, { key }).ok);
  let replays = 0;
  for (let i = 0; i < 31; i++) { const r = claim(nk, g, t.ticket_id, { key }); if (r.ok) replays += 1; else refused(r, RESOURCE_EXHAUSTED, "rate_limited"); }
  assert.equal(replays, 30);
  refused(progression(nk, g), RESOURCE_EXHAUSTED, "rate_limited");
  clock.t += 60000;
  assert.ok(progression(nk, g).ok);
});

test("R-3: claim requests (incl. too_early) are limited to 12 per rolling 60 s; refusals before a ticket decision cost no quota", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  const key = "early-quota-000001";
  let tooEarly = 0;
  for (let i = 0; i < 13; i++) {
    const r = claim(nk, g, t.ticket_id, { key });
    if (r.code === RESOURCE_EXHAUSTED) { refused(r, RESOURCE_EXHAUSTED, "rate_limited"); break; }
    refused(r, FAILED_PRECONDITION, "too_early");
    tooEarly += 1;
  }
  assert.equal(tooEarly, 12);
  clock.t += 60000; // the window rolls and the ticket is old enough
  const r = claim(nk, g, t.ticket_id, { key });
  assert.ok(r.ok, JSON.stringify(r));
  assert.equal(hero(nk).revision, 1);
});

test("progression read shows the server Level, the unresolved ticket and cooldowns", () => {
  const nk = fresh();
  const g = session(nk);
  assert.deepEqual(progression(nk, g).value.unresolved_ticket, null);
  const t = okBegin(nk, g, [G2]);
  const p = progression(nk, g).value;
  assert.equal(p.unresolved_ticket.ticket_id, t.ticket_id);
  clock.t += MIN_AGE;
  assert.ok(claim(nk, g, t.ticket_id).ok);
  const q = progression(nk, g).value;
  assert.equal(q.unresolved_ticket, null);
  assert.equal(q.group_available_at_ms[G2], clock.t + 10000);
  assert.equal(q.progression.level, 2);
});

test("accounts are isolated: another account's ticket is not found", () => {
  const nk = fresh();
  const g1 = session(nk, U1);
  const g2 = session(nk, U2);
  const t = okBegin(nk, g1, [G1]);
  clock.t += MIN_AGE;
  refused(claim(nk, g2, t.ticket_id, {}, U2), NOT_FOUND, "ticket_not_found");
  refused(abandon(nk, g2, t.ticket_id, {}, U2), NOT_FOUND, "ticket_not_found");
  assert.equal(hero(nk, U2), null);
});

test("forged or malformed claims change nothing", () => {
  const nk = fresh();
  const g = session(nk);
  const t = okBegin(nk, g, [G1]);
  clock.t += MIN_AGE;
  refused(claim(nk, g, t.ticket_id, { kills: 9 }), INVALID_ARGUMENT, "invalid_claim");
  refused(claim(nk, g, t.ticket_id, { kills: 11 }), INVALID_ARGUMENT, "invalid_claim");
  refused(claim(nk, g, t.ticket_id, { outcome: "defeat", hero_alive: true, kills: 0 }), INVALID_ARGUMENT, "invalid_claim");
  refused(claim(nk, g, t.ticket_id, { kills: -1 }), INVALID_ARGUMENT, "invalid_claim");
  refused(claim(nk, g, "zz"), INVALID_ARGUMENT, "invalid_ticket_id");
  refused(call(m, "rpcEncounterClaim", nk, ctxFor(U1), { gameplay_session_id: g, idempotency_key: newKey(), ticket_id: t.ticket_id,
    outcome: "victory", kills: 10, hero_alive: true, exp: 99999 }), INVALID_ARGUMENT, "unexpected_fields");
  refused(claim(nk, g, "0".repeat(32)), NOT_FOUND, "ticket_not_found");
  assert.equal(hero(nk), null);
  assert.equal(obj(nk, "vs01_wp01e_tickets", t.ticket_id).value.status, "OPEN");
});

test("Level cap: Lv99 + enough EXP ends at Lv100 with 0 EXP", () => {
  const nk = fresh();
  const g = session(nk);
  nk.storageWrite([{ collection: "vs01_wp01e_hero_progression", key: "hero", userId: U1, permissionRead: 0, permissionWrite: 0,
    value: { contract: "myrial.vs01.wp01e.hero_progression", contract_version: 1, revision: 7, level: 99, exp: 4950 } }]);
  const t = okBegin(nk, g, [G1]);
  clock.t += MIN_AGE;
  const r = claim(nk, g, t.ticket_id);
  assert.ok(r.ok, JSON.stringify(r));
  assert.deepEqual([r.value.receipt.level_after, r.value.receipt.exp_after], [100, 0]);
});

test("tampered or client-made WP01-E objects fail closed", () => {
  const nk = fresh();
  const g = session(nk);
  nk.storageWrite([{ collection: "vs01_wp01e_hero_progression", key: "hero", userId: U1, permissionRead: 0, permissionWrite: 0,
    value: { contract: "myrial.vs01.wp01e.hero_progression", contract_version: 1, revision: 0, level: 5, exp: 9999 } }]);
  refused(progression(nk, g), INTERNAL, "wp01e_object_not_trusted");
  const nk2 = fresh();
  const h = session(nk2);
  nk2.storageWrite([{ collection: "vs01_wp01e_hero_progression", key: "hero", userId: U1, permissionRead: 1, permissionWrite: 1,
    value: { contract: "myrial.vs01.wp01e.hero_progression", contract_version: 1, revision: 0, level: 5, exp: 0 } }]);
  refused(progression(nk2, h), INTERNAL, "wp01e_object_not_trusted");
});

test("a claim without a gameplay session is refused", () => {
  const nk = fresh();
  refused(claim(nk, "00000000-0000-0000-0000-000000000000", "0".repeat(32)), FAILED_PRECONDITION, "no_gameplay_session");
  refused(begin(nk, "00000000-0000-0000-0000-000000000000", [G1]), FAILED_PRECONDITION, "no_gameplay_session");
});

void VERSION_CONFLICT; void DB_FAULT;
