// VS-01 WP01-E E3: each write guard of the claim transaction (W1-W7) proven
// on its own. Between the claim's read and its multiUpdate, a competing
// writer changes ONLY the object one guard protects. The correct server sees
// the version check fail, re-reads and answers from the new state; a server
// that lost that guard (scripts/run_wp01e_mutations.sh) commits on stale data
// and fails the test.
import test from "node:test";
import assert from "node:assert/strict";
import { loadModule, FakeNakama, ctxFor, call } from "./harness.mjs";

const clock = { t: 1_800_000_000_000, now() { return this.t; } };
const m = loadModule(clock);
const U1 = "11111111-1111-1111-1111-111111111111";
const ALREADY_EXISTS = 6, FAILED_PRECONDITION = 9, ABORTED = 10;
const G1 = "prototype_monster_01", G3 = "prototype_monster_03";
const MIN_AGE = 10000;
const KEY = "guard-claim-key-0001";
const SERVER_ONLY = { permissionRead: 0, permissionWrite: 0 };

// A session, an OPEN 1-group ticket old enough to settle, and the hash of the
// claim the test sends (victory, 10 kills, Hero alive).
function setup() {
  clock.t = 1_800_000_000_000;
  const nk = new FakeNakama({ md5: true });
  const g = call(m, "rpcSessionBegin", nk, ctxFor(U1), "{}").value.gameplay_session_id;
  const t = call(m, "rpcEncounterBegin", nk, ctxFor(U1), { gameplay_session_id: g, group_ids: [G1] }).value.ticket;
  clock.t += MIN_AGE;
  return { nk, g, t, hash: m.eClaimHash(t.ticket_id, "victory", 10, true) };
}
function claim(nk, g, ticketId) {
  return call(m, "rpcEncounterClaim", nk, ctxFor(U1), {
    gameplay_session_id: g, idempotency_key: KEY, ticket_id: ticketId, outcome: "victory", kills: 10, hero_alive: true,
  });
}
function get(nk, collection, key) {
  const o = nk.storageRead([{ collection, key, userId: U1 }])[0];
  return o ? o.value : null;
}
function put(nk, collection, key, value) {
  nk.storageWrite([{ collection, key, userId: U1, value, ...SERVER_ONLY }]);
}
function refused(r, code, message) {
  assert.equal(r.ok, false, JSON.stringify(r));
  assert.equal(r.message, message);
  assert.equal(r.code, code);
}

test("W1 receipt (create-only): a receipt for the same key committed concurrently is replayed, not overwritten", () => {
  const { nk, g, t, hash } = setup();
  const theirs = {
    contract: "myrial.vs01.wp01e.receipt", contract_version: 1, kind: "claim", idempotency_key: KEY, request_hash: hash,
    user_id: U1, gameplay_session_id: g, ticket_id: t.ticket_id, status: "applied", outcome: "victory", kills_claimed: 10,
    kills_accepted: 10, hero_alive: true, exp_awarded: 100, level_before: 1, exp_before: 0, level_after: 2, exp_after: 0,
    progression_revision: 1, cooldown_groups: [G1], intent_first_seen_at_ms: -1, server_time_ms: clock.t - 1,
  };
  nk.beforeWrite = (n) => put(n, "vs01_wp01e_receipts", KEY, theirs);
  const r = claim(nk, g, t.ticket_id);
  assert.ok(r.ok, JSON.stringify(r));
  assert.equal(r.value.replayed, true, "the concurrent receipt is the answer");
  assert.equal(get(nk, "vs01_wp01e_receipts", KEY).server_time_ms, clock.t - 1, "the committed receipt is not overwritten");
  assert.equal(get(nk, "vs01_wp01e_hero_progression", "hero"), null, "this request applied nothing");
});

test("W2 ticket-claim marker (create-only): a ticket already settled by a marker is never settled again", () => {
  const { nk, g, t } = setup();
  nk.beforeWrite = (n) => put(n, "vs01_wp01e_ticket_claims", t.ticket_id,
    { contract: "myrial.vs01.wp01e.ticket_claim", contract_version: 1, ticket_id: t.ticket_id, idempotency_key: "other-key-000000001", decided_at_ms: clock.t });
  refused(claim(nk, g, t.ticket_id), ABORTED, "conflict_retry_exhausted");
  assert.equal(get(nk, "vs01_wp01e_hero_progression", "hero"), null, "no second settlement");
  assert.equal(get(nk, "vs01_wp01e_ticket_claims", t.ticket_id).idempotency_key, "other-key-000000001");
});

test("W3 ticket (version): a ticket abandoned concurrently is not claimed", () => {
  const { nk, g, t } = setup();
  nk.beforeWrite = (n) => {
    const v = get(n, "vs01_wp01e_tickets", t.ticket_id);
    put(n, "vs01_wp01e_tickets", t.ticket_id, { ...v, status: "ABANDONED", resolved_at_ms: clock.t, revision: v.revision + 1 });
  };
  refused(claim(nk, g, t.ticket_id), FAILED_PRECONDITION, "ticket_abandoned");
  assert.equal(get(nk, "vs01_wp01e_hero_progression", "hero"), null);
  assert.equal(get(nk, "vs01_wp01e_tickets", t.ticket_id).status, "ABANDONED");
});

test("W4 encounter state (version): a concurrent state change is kept, not lost", () => {
  const { nk, g, t } = setup();
  nk.beforeWrite = (n) => {
    const v = get(n, "vs01_wp01e_encounter_state", "state");
    put(n, "vs01_wp01e_encounter_state", "state", { ...v, group_available_at_ms: { ...v.group_available_at_ms, [G3]: clock.t + 999_000 }, revision: v.revision + 1 });
  };
  const r = claim(nk, g, t.ticket_id);
  assert.ok(r.ok, JSON.stringify(r));
  const s = get(nk, "vs01_wp01e_encounter_state", "state");
  assert.equal(s.group_available_at_ms[G3], clock.t + 999_000, "the concurrent change survives");
  assert.equal(s.group_available_at_ms[G1], clock.t + 10_000, "this claim's cooldown is added");
  assert.equal(s.open_ticket_id, "", "the slot is freed");
});

test("W5 Hero progression (version): a concurrent award is added to, never overwritten (no lost EXP)", () => {
  const { nk, g, t } = setup();
  nk.beforeWrite = (n) => put(n, "vs01_wp01e_hero_progression", "hero",
    { contract: "myrial.vs01.wp01e.hero_progression", contract_version: 1, revision: 5, level: 1, exp: 50 });
  const r = claim(nk, g, t.ticket_id);
  assert.ok(r.ok, JSON.stringify(r));
  assert.deepEqual(get(nk, "vs01_wp01e_hero_progression", "hero"),
    { contract: "myrial.vs01.wp01e.hero_progression", contract_version: 1, revision: 6, level: 2, exp: 50 }, "50 + 100 EXP");
});

test("W6 session guard (Trade v1 object, version): a takeover between read and write aborts the claim", () => {
  const { nk, g, t } = setup();
  nk.beforeWrite = (n) => { call(m, "rpcSessionBegin", n, ctxFor(U1), "{}"); };
  refused(claim(nk, g, t.ticket_id), ABORTED, "gameplay_session_superseded");
  assert.equal(get(nk, "vs01_wp01e_hero_progression", "hero"), null);
  assert.equal(get(nk, "vs01_wp01e_tickets", t.ticket_id).status, "OPEN");
});

test("W7 claim intent (create-only / version): an intent recorded concurrently by another key locks the ticket", () => {
  const { nk, g, t } = setup();
  nk.beforeWrite = (n) => put(n, "vs01_wp01e_claim_intents", t.ticket_id, {
    contract: "myrial.vs01.wp01e.claim_intent", contract_version: 1, revision: 0, ticket_id: t.ticket_id,
    idempotency_key: "other-key-000000002", request_hash: "claim|x", claim: { outcome: "victory", kills: 10, hero_alive: true },
    first_seen_at_ms: clock.t, first_seen_session_id: g, state: "RECORDED",
  });
  refused(claim(nk, g, t.ticket_id), ALREADY_EXISTS, "claim_locked");
  assert.equal(get(nk, "vs01_wp01e_hero_progression", "hero"), null);
  assert.equal(get(nk, "vs01_wp01e_claim_intents", t.ticket_id).idempotency_key, "other-key-000000002");
});
