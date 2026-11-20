// VS-01 WP01-H E3 LIVE (server layer): Combat Recorded Intent (E1 C-B1)
// against the real Nakama + PostgreSQL of ONE isolated run. AC-07, AC-08 (a)(b).
// AC-08 (c) "inconsistent" cannot be produced live without seeding claim
// intents, which R-04 does not allow (receipts only): NOT COVERED here; the
// offline E2 FIX-05 evidence stands, and the gap is reported.
// AC-16 (PR-03 five items) is evaluated from the FS-K10 round in h3 (TTL job).
// Skipped unless run by nakama/scripts/run_wp01h_e3_bounded.mjs.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { authEmail, rpc, begin, newKey, sleep } from "./live_client.mjs";
import { objects, ledger, C, runProject } from "./tools/wp01h_db.mjs";

const RUN = process.env.MYRIAL_WP01H_E3_RUN_ID ?? "";
const PHASE = process.env.MYRIAL_WP01H_E3_PHASE ?? "main";
const CASE_DIR = process.env.MYRIAL_WP01H_E3_CASE_DIR ?? "";
const SKIP = !RUN ? "WP01-H E3 only: run via nakama/scripts/run_wp01h_e3_bounded.mjs" : PHASE !== "main" ? `phase ${PHASE}` : false;
if (RUN) runProject();
const MIN_AGE_WAIT_MS = 10300; // E_MIN_CLAIM_AGE_MS 10000 (wp01e_rules.ts:24)
const reason = (r) => (r.status === 200 ? (r.body.replayed ? "replayed" : "applied") : (r.body && typeof r.body === "object" && r.body.message) || String(r.status));
function record(id, data) { if (CASE_DIR) fs.appendFileSync(`${CASE_DIR}/${id}.jsonl`, JSON.stringify({ at: new Date().toISOString(), id, ...data }) + "\n", { mode: 0o600 }); }

async function account(label) { const a = await authEmail(`wp01h-${label}`); await begin(a); return a; }
async function ticket(a) {
  const r = await rpc(a, "vs01e_encounter_begin", { gameplay_session_id: a.gsid, group_ids: ["prototype_monster_01"] });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  return r.body.ticket;
}
const claimBody = (a, t, key, o = {}) => ({ gameplay_session_id: a.gsid, idempotency_key: key, ticket_id: t.ticket_id,
  outcome: o.outcome ?? "victory", kills: o.kills ?? 10, hero_alive: o.hero_alive ?? true });
const progression = (a) => rpc(a, "vs01e_progression_get", { gameplay_session_id: a.gsid });
const claims = (a) => objects(a.userId, C.combatReceipts).map((o) => o.value).filter((r) => r.kind === "claim");

test("AC-07 recorded intent: a too_early claim is recorded; the active session reads key + claim and settles once", { skip: SKIP }, async () => {
  const a = await account("ac07");
  const t = await ticket(a);
  const key = newKey();
  const early = await rpc(a, "vs01e_encounter_claim", claimBody(a, t, key));
  assert.equal(reason(early), "too_early");
  const p = await progression(a);
  assert.equal(p.status, 200, JSON.stringify(p.body));
  const ri = p.body.recorded_intent;
  assert.equal(ri.status, "recorded");
  assert.equal(ri.ticket_id, t.ticket_id);
  assert.equal(ri.idempotency_key, key);
  assert.deepEqual(ri.claim, { outcome: "victory", kills: 10, hero_alive: true });
  await sleep(MIN_AGE_WAIT_MS);
  const ok = await rpc(a, "vs01e_encounter_claim", claimBody(a, t, ri.idempotency_key, ri.claim));
  assert.equal(reason(ok), "applied", JSON.stringify(ok.body));
  const again = await rpc(a, "vs01e_encounter_claim", claimBody(a, t, key));
  assert.equal(reason(again), "replayed");
  assert.equal(claims(a).length, 1, "one settlement");
  const other = await rpc(a, "vs01e_encounter_claim", claimBody(a, t, newKey()));
  assert.notEqual(reason(other), "applied", "a second key for the same ticket never settles");
  assert.equal(claims(a).length, 1);
  assert.deepEqual(ledger(a.userId).problems, []);
  record("AC-07", { ticket: t.ticket_id, exp: ok.body.receipt.exp_awarded });
});

test("AC-08 (a) a new session with no local command adopts the server intent; (b) a superseded session cannot use it", { skip: SKIP }, async () => {
  const a = await account("ac08");
  const t = await ticket(a);
  const key = newKey();
  assert.equal(reason(await rpc(a, "vs01e_encounter_claim", claimBody(a, t, key))), "too_early");
  const s1 = { ...a };
  await begin(a); // takeover: a = S2 (fresh process, no local command), s1 = S1
  const stale = await progression(s1);
  assert.notEqual(stale.status, 200, "(b) the superseded session reads no intent");
  assert.equal(JSON.stringify(stale.body).includes(key), false, "(b) the key is not disclosed to S1");
  await sleep(MIN_AGE_WAIT_MS);
  const s1claim = await rpc(s1, "vs01e_encounter_claim", claimBody(s1, t, key));
  assert.equal(reason(s1claim), "gameplay_session_superseded");
  const ri = (await progression(a)).body.recorded_intent;
  assert.equal(ri.status, "recorded");
  assert.equal(ri.idempotency_key, key, "(a) S2 learns the ORIGINAL key");
  const ok = await rpc(a, "vs01e_encounter_claim", claimBody(a, t, ri.idempotency_key, ri.claim));
  assert.equal(reason(ok), "applied", JSON.stringify(ok.body));
  assert.equal(claims(a).length, 1);
  record("AC-08", { covered: ["a", "b"], not_covered: ["c: inconsistent needs an intent seed (outside R-04)"] });
});
