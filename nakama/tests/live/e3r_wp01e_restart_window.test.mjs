// VS-01 WP01-E E3 corrective LIVE: the server-restart window of a claim,
// on both sides of the settlement COMMIT (closes the FS-7 evidence gap).
//
// FS-7 restarted the server right after sending; no request was proven to
// have reached the server. Here the boundary is controlled and observed:
//
//   RW-1 / RW-2  BEFORE COMMIT. A psql session holds the ticket row
//     (SELECT ... FOR UPDATE). The claim enters the server, opens the
//     settlement transaction and blocks on that row: observed in
//     pg_stat_activity as a backend blocked by the psql session. The server
//     is then killed (RW-1, SIGKILL) or restarted (RW-2, SIGTERM) while the
//     transaction is open. The lock is released; nothing may have committed.
//   RW-3  AFTER COMMIT. The claim goes through a proxy that waits for the
//     server's answer and drops it. The commit is observed in PostgreSQL
//     (receipt, Hero), then the server is killed and started again.
//
// After the restart the SAME idempotency key is resent (twice; RW-3 also on
// node 2). Every case must end with exactly one receipt, Hero revision 1 and
// +100 EXP, and an EXP already committed must not be lost.
import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import http from "node:http";
import { gunzipSync } from "node:zlib";
import { fileURLToPath } from "node:url";
import { authEmail, rpc, begin, newKey, sleep, BASE } from "./live_client.mjs";

const COMPOSE_DIR = fileURLToPath(new URL("../..", import.meta.url));
const DOCKER = process.env.DOCKER ?? "docker";
const NODE2 = process.env.MYRIAL_NAKAMA_URL_2 ?? BASE;
const MIN_AGE_WAIT_MS = 10300;
const BASE_PORT = Number(new URL(BASE).port);

function compose(...args) {
  return execFileSync(DOCKER, ["compose", ...args], { cwd: COMPOSE_DIR, maxBuffer: 16 * 1024 * 1024 }).toString();
}
const sql = (q) => compose("exec", "-T", "postgres", "psql", "-U", "postgres", "-d", "nakama", "-tAc", q);
function rows(userId, collection) {
  if (!/^[0-9a-f-]{36}$/.test(userId) || !/^[a-z0-9_]+$/.test(collection)) throw new Error("bad id");
  return sql(`SELECT value::text FROM storage WHERE collection = '${collection}' AND user_id = '${userId}'`)
    .split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l));
}
const reason = (r) => (r.status === 200 ? (r.body.replayed ? "replayed" : "applied")
  : ((typeof r.body === "object" && r.body !== null && r.body.message) || String(r.status)));

function snapshot(a, ticketId) {
  const hero = rows(a.userId, "vs01_wp01e_hero_progression");
  const receipts = rows(a.userId, "vs01_wp01e_receipts");
  return {
    ticket: rows(a.userId, "vs01_wp01e_tickets").find((x) => x.ticket_id === ticketId)?.status,
    receipts: receipts.length,
    receipt_exp: receipts.filter((r) => r.kind === "claim").reduce((s, r) => s + r.exp_awarded, 0),
    hero_revision: hero.length ? hero[0].revision : null,
    hero_level: hero.length ? hero[0].level : null,
    hero_exp: hero.length ? hero[0].exp : null,
    claim_markers: rows(a.userId, "vs01_wp01e_ticket_claims").length,
  };
}

async function waitHealthy(base) {
  for (let i = 0; i < 90; i++) {
    try { if ((await fetch(`${base}/healthcheck`)).ok) return; } catch { /* down */ }
    await sleep(1000);
  }
  throw new Error(`${base} not healthy`);
}

async function setup(label) {
  const a = await authEmail(label);
  await begin(a);
  const r = await rpc(a, "vs01e_encounter_begin", { gameplay_session_id: a.gsid, group_ids: ["prototype_monster_01"] });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  await sleep(MIN_AGE_WAIT_MS);
  const key = newKey();
  const body = { gameplay_session_id: a.gsid, idempotency_key: key, ticket_id: r.body.ticket.ticket_id,
    outcome: "victory", kills: 10, hero_alive: true };
  return { a, ticketId: r.body.ticket.ticket_id, key, body };
}

// A psql session that holds the account's ticket row until release().
async function lockTicketRow(userId, ticketId) {
  const p = spawn(DOCKER, ["compose", "exec", "-T", "postgres", "psql", "-U", "postgres", "-d", "nakama", "-tAq"],
    { cwd: COMPOSE_DIR, stdio: ["pipe", "pipe", "pipe"] });
  let out = "";
  p.stdout.on("data", (c) => { out += c; });
  p.stdin.write("BEGIN;\nSELECT 'PID=' || pg_backend_pid();\n" +
    `SELECT 'LOCKED=' || count(*) FROM (SELECT 1 FROM storage WHERE collection = 'vs01_wp01e_tickets' AND user_id = '${userId}' AND key = '${ticketId}' FOR UPDATE) x;\n`);
  for (let i = 0; i < 100 && !/LOCKED=\d/.test(out); i++) await sleep(100);
  assert.match(out, /LOCKED=1/, `ticket row lock: ${out}`);
  const pid = Number(out.match(/PID=(\d+)/)[1]);
  return {
    pid,
    async release() {
      p.stdin.write("ROLLBACK;\n\\q\n");
      p.stdin.end();
      await new Promise((res) => p.on("close", res));
    },
  };
}

// Backends (Nakama's settlement transaction) blocked by the psql session.
function blockedBy(pid) {
  return sql(`SELECT pid || '|' || state || '|' || coalesce(wait_event_type, '') || '|' || (now() - xact_start)::text || '|' || left(regexp_replace(query, '\\s+', ' ', 'g'), 90)
    FROM pg_stat_activity WHERE ${pid} = ANY(pg_blocking_pids(pid))`).split("\n").filter((l) => l.trim());
}

async function resendTwice(t, label, s, bases = [BASE, BASE]) {
  const out = [];
  for (const base of bases) out.push(reason(await rpc(s.a, "vs01e_encounter_claim", s.body, { base })));
  t.diagnostic(`${label} resend same key after restart: ${out.join(", ")}`);
  return out;
}

function assertSettledOnce(s, snap) {
  assert.equal(snap.ticket, "CLAIMED");
  assert.equal(snap.receipts, 1, "exactly one receipt");
  assert.equal(snap.receipt_exp, 100, "receipt EXP +100 once");
  assert.equal(snap.claim_markers, 1);
  assert.equal(snap.hero_revision, 1, "Hero changed exactly once");
  assert.equal(snap.hero_level, 2);
  assert.equal(snap.hero_exp, 0, "Lv 1 + 100 EXP = Lv 2, 0 / 150");
}

for (const [id, mode] of [["RW-1", "kill"], ["RW-2", "restart"]]) {
  test(`${id}: restart (${mode === "kill" ? "SIGKILL" : "SIGTERM"}) with the claim INSIDE the open settlement transaction: nothing commits; the same key settles once after`, { timeout: 180000 }, async (t) => {
    const s = await setup(`rw-${mode}`);
    const lock = await lockTicketRow(s.a.userId, s.ticketId);
    t.diagnostic(`${id} psql lock holder pid ${lock.pid} holds ticket ${s.ticketId}`);
    const inFlight = rpc(s.a, "vs01e_encounter_claim", s.body).then(reason, (e) => `no answer (${e.cause?.code ?? e.message})`);
    let blocked = [];
    for (let i = 0; i < 100 && blocked.length === 0; i++) { await sleep(100); blocked = blockedBy(lock.pid); }
    t.diagnostic(`${id} OBSERVED in server: blocked backend(s) [pid|state|wait|tx age|query]: ${blocked.join(" ; ")}`);
    assert.equal(blocked.length, 1, "the claim reached the server and is inside its transaction");
    const during = snapshot(s.a, s.ticketId);
    t.diagnostic(`${id} DB while open (uncommitted invisible): ${JSON.stringify(during)}`);
    assert.equal(during.receipts, 0);
    assert.equal(during.hero_revision, null);

    if (mode === "kill") compose("kill", "-s", "SIGKILL", "nakama");
    else compose("restart", "nakama");
    t.diagnostic(`${id} server ${mode === "kill" ? "killed" : "restarted"} at ${new Date().toISOString()}; client got: ${await inFlight}`);
    await lock.release();
    for (let i = 0; i < 50 && blockedBy(lock.pid).length > 0; i++) await sleep(100);
    await sleep(500);
    const orphan = sql(`SELECT count(*) FROM pg_stat_activity WHERE state LIKE 'idle in transaction%' AND datname = 'nakama'`).trim();
    const afterCrash = snapshot(s.a, s.ticketId);
    t.diagnostic(`${id} DB after crash + lock release (open transaction rolled back): ${JSON.stringify(afterCrash)}; idle-in-transaction backends: ${orphan}`);
    assert.equal(afterCrash.receipts, 0, "the interrupted transaction did not commit");
    assert.equal(afterCrash.hero_revision, null);
    assert.equal(afterCrash.ticket, "OPEN");

    if (mode === "kill") compose("start", "nakama");
    await waitHealthy(BASE);
    const out = await resendTwice(t, id, s);
    assert.deepEqual(out, ["applied", "replayed"]);
    const end = snapshot(s.a, s.ticketId);
    t.diagnostic(`${id} DB final: ${JSON.stringify(end)}`);
    assertSettledOnce(s, end);
  });
}

test("RW-3: restart AFTER the settlement committed and its reply was lost: the same key replays; EXP kept and not added again", { timeout: 180000 }, async (t) => {
  const s = await setup("rw-commit");
  // In-test proxy: forwards the claim, records the server's answer, drops it.
  const seen = [];
  const proxy = http.createServer((req, res) => {
    const up = http.request({ host: "127.0.0.1", port: BASE_PORT, method: req.method, path: req.url, headers: req.headers }, (u) => {
      const chunks = [];
      u.on("data", (c) => chunks.push(c));
      u.on("end", () => {
        const raw = Buffer.concat(chunks);
        seen.push({ status: u.statusCode, body: (u.headers["content-encoding"] === "gzip" ? gunzipSync(raw) : raw).toString() });
        req.socket.destroy();
      });
    });
    up.on("error", () => req.socket.destroy());
    req.pipe(up);
  });
  await new Promise((r) => proxy.listen(0, "127.0.0.1", r));
  const client = await rpc(s.a, "vs01e_encounter_claim", s.body, { base: `http://127.0.0.1:${proxy.address().port}` })
    .then(reason, (e) => `no answer (${e.cause?.code ?? e.message})`);
  proxy.close();
  t.diagnostic(`RW-3 client got: ${client}; server answered (dropped by proxy): ${JSON.stringify(seen)}`);
  assert.match(client, /^no answer/);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].status, 200);
  const committed = snapshot(s.a, s.ticketId);
  t.diagnostic(`RW-3 DB after commit, before restart: ${JSON.stringify(committed)}`);
  assertSettledOnce(s, committed);

  compose("kill", "-s", "SIGKILL", "nakama");
  t.diagnostic(`RW-3 server killed at ${new Date().toISOString()}`);
  compose("start", "nakama");
  await waitHealthy(BASE);
  const afterRestart = snapshot(s.a, s.ticketId);
  assert.deepEqual(afterRestart, committed, "committed EXP survives the restart");
  const out = await resendTwice(t, "RW-3", s, [BASE, NODE2]);
  assert.deepEqual(out, ["replayed", "replayed"]);
  const replay = await rpc(s.a, "vs01e_encounter_claim", s.body);
  assert.deepEqual(replay.body.receipt, JSON.parse(seen[0].body).receipt, "the replay returns the original (lost) receipt");
  assert.equal(replay.body.receipt.exp_awarded, 100);
  const end = snapshot(s.a, s.ticketId);
  t.diagnostic(`RW-3 DB final: ${JSON.stringify(end)}; replay body: ${JSON.stringify(replay.body)}`);
  assertSettledOnce(s, end);
});
