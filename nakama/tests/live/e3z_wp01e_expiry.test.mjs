// VS-01 WP01-E E3 LIVE: claims racing the REAL 15-minute ticket deadline.
// Long (~15.5 min): runs only with MYRIAL_E3_EXPIRY=1.
//
// Eight accounts begin a ticket at the same time. Accounts 0-2 and 7 record
// an MC-1 intent (a too_early claim) right away; 3-6 do not. At the deadline
// accounts 0-5 send the same key at -300, -100, 0, +100 and +300 ms; accounts
// 6 (no intent) and 7 (intent) send ONLY after it, at +50 and +300 ms.
// Expected:
//   with intent    -> settled exactly once, before or after the deadline
//   without intent -> settled once if a request reached the server before the
//                     deadline (later ones replay); otherwise explicitly expired
// and in every case ticket status, receipts and Hero EXP agree.
import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { authEmail, rpc, begin, newKey, sleep } from "./live_client.mjs";

const COMPOSE_DIR = fileURLToPath(new URL("../..", import.meta.url));
const DOCKER = process.env.DOCKER ?? "docker";
const RUN = process.env.MYRIAL_E3_EXPIRY === "1";

function rows(userId, collection) {
  const out = execFileSync(DOCKER, ["compose", "exec", "-T", "postgres", "psql", "-U", "postgres", "-d", "nakama", "-tAc",
    `SELECT value::text FROM storage WHERE collection = '${collection}' AND user_id = '${userId}'`], { cwd: COMPOSE_DIR }).toString();
  return out.split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l));
}
const reason = (r) => (r.status === 200 ? (r.body.replayed ? "replayed" : "applied") : (r.body && r.body.message) || String(r.status));

test("claims racing the 15-minute deadline: with / without a recorded intent", { skip: !RUN && "set MYRIAL_E3_EXPIRY=1 (takes ~15.5 min)", timeout: 20 * 60 * 1000 }, async (t) => {
  const accounts = [];
  const N = 8;
  const hasIntent = (i) => i < 3 || i === 7;
  const offsetsFor = (i) => (i >= 6 ? [50, 300] : [-300, -100, 0, 100, 300]);
  for (let i = 0; i < N; i++) { const a = await authEmail(`e3x-${i}`); await begin(a); accounts.push(a); }
  const tickets = await Promise.all(accounts.map(async (a) =>
    (await rpc(a, "vs01e_encounter_begin", { gameplay_session_id: a.gsid, group_ids: ["prototype_monster_01"] })).body.ticket));
  const keys = accounts.map(() => newKey());
  const body = (i) => ({ gameplay_session_id: accounts[i].gsid, idempotency_key: keys[i], ticket_id: tickets[i].ticket_id, outcome: "victory", kills: 10, hero_alive: true });
  for (let i = 0; i < N; i++) {
    if (!hasIntent(i)) continue;
    assert.equal(reason(await rpc(accounts[i], "vs01e_encounter_claim", body(i))), "too_early", "intent recorded");
    assert.equal(rows(accounts[i].userId, "vs01_wp01e_claim_intents").length, 1);
  }
  const deadline = tickets[0].expires_at_ms;
  t.diagnostic(`waiting ${Math.round((deadline - Date.now()) / 1000)} s for the deadline`);
  await sleep(deadline - Date.now() - 1000);
  const results = await Promise.all(accounts.map((a, i) => Promise.all(offsetsFor(i).map(async (off) => {
    await sleep(Math.max(0, tickets[i].expires_at_ms + off - Date.now()));
    return reason(await rpc(a, "vs01e_encounter_claim", body(i)));
  }))));
  results.forEach((out, i) => {
    const a = accounts[i];
    const status = rows(a.userId, "vs01_wp01e_tickets")[0].status;
    const hero = rows(a.userId, "vs01_wp01e_hero_progression");
    t.diagnostic(`account ${i} (${hasIntent(i) ? "intent" : "no intent"}, offsets ${offsetsFor(i).join("/")} ms): ${out.join(",")} -> ticket ${status}, hero ${hero.length ? `rev ${hero[0].revision}` : "none"}`);
    const applied = out.filter((x) => x === "applied").length;
    assert.ok(applied <= 1, "never settled twice");
    if (hasIntent(i)) {
      assert.equal(status, "CLAIMED", "an intent recorded before the deadline is always settled");
      assert.equal(applied, 1);
      for (const x of out) assert.ok(["applied", "replayed"].includes(x), x);
    }
    if (i === 6) assert.equal(status, "EXPIRED", "no intent and nothing before the deadline: explicit expiry");
    if (status === "CLAIMED") {
      assert.equal(hero[0].revision, 1);
      assert.equal(rows(a.userId, "vs01_wp01e_receipts").length, 1);
      for (const x of out.slice(out.indexOf("applied") + 1)) assert.equal(x, "replayed", "after settlement the key replays, even past the deadline");
    } else {
      assert.equal(status, "EXPIRED");
      assert.equal(hero.length, 0, "an expired ticket pays nothing");
      for (const x of out) assert.equal(x, "ticket_expired");
    }
  });
});
