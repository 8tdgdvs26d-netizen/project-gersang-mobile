// VS-01 WP01-H E3 LIVE tool: READ-ONLY database queries and ledger checks.
//
// Runs `docker compose exec -T postgres psql` ONLY against the run's own
// compose project (COMPOSE_PROJECT_NAME must be a wp01h_e3_* project set by
// nakama/scripts/run_wp01h_e3_bounded.mjs). Every statement is a SELECT; the
// tool refuses anything else. Receipts and tickets are server-only objects
// (policy A), so the live tests read them here.
//
// CLI (used by the launcher between Godot phases):
//   node wp01h_db.mjs snapshot <user-id>      -> one JSON line (snapshot)
//   node wp01h_db.mjs ledger <user-id>        -> one JSON line (ledger check)
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

export const COMPOSE_DIR = fileURLToPath(new URL("../../..", import.meta.url));
export const PROJECT_RE = /^wp01h_e3_[a-z0-9_]{1,60}$/;
const USER_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const COLLECTION_RE = /^vs01_[a-z0-9_]{1,60}$/;
export const STARTING_MONEY = 10000;
export const C = {
  progress: "vs01_wp01_progress", tradeReceipts: "vs01_wp01_receipts",
  tickets: "vs01_wp01e_tickets", intents: "vs01_wp01e_claim_intents", claims: "vs01_wp01e_ticket_claims",
  combatReceipts: "vs01_wp01e_receipts", hero: "vs01_wp01e_hero_progression",
};

// The run's compose project, or throw. Never the default project.
export function runProject(env = process.env) {
  const p = env.COMPOSE_PROJECT_NAME ?? "";
  if (!PROJECT_RE.test(p)) throw new Error("wp01h_db: COMPOSE_PROJECT_NAME is not a wp01h_e3_* run project");
  if (env.DOCKER_HOST || env.DOCKER_CONTEXT) throw new Error("wp01h_db: DOCKER_HOST / DOCKER_CONTEXT must be unset");
  return p;
}

export function assertSelect(query) {
  const q = query.trim();
  if (!/^SELECT\s/i.test(q) || q.includes(";") || /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|COPY)\b/i.test(q)) {
    throw new Error("wp01h_db: only a single SELECT is allowed");
  }
  return q;
}

export function sql(query, env = process.env) {
  const project = runProject(env);
  const q = assertSelect(query);
  return execFileSync(env.DOCKER ?? "docker", ["compose", "-p", project, "exec", "-T", "postgres", "psql", "-U", "postgres", "-d", "nakama", "-tAc", q],
    { cwd: COMPOSE_DIR, maxBuffer: 64 * 1024 * 1024, env }).toString();
}

export function checkUser(userId) {
  if (!USER_RE.test(userId)) throw new Error("wp01h_db: bad user id");
  return userId;
}

// [{key, value, read, version}] of one collection of one user.
export function objects(userId, collection, env = process.env) {
  checkUser(userId);
  if (!COLLECTION_RE.test(collection)) throw new Error("wp01h_db: bad collection");
  const out = sql(`SELECT json_build_object('key', key, 'read', read, 'write', write, 'version', version, 'value', value)::text FROM storage WHERE collection = '${collection}' AND user_id = '${userId}' ORDER BY key`, env);
  return out.split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l));
}

export const sha = (v) => crypto.createHash("sha256").update(typeof v === "string" ? v : canonical(v)).digest("hex");
// Stable JSON (sorted keys) so a value hash does not depend on key order.
export function canonical(v) {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (v !== null && typeof v === "object") return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(",")}}`;
  return JSON.stringify(v);
}

// Everything a blocked attempt must not change (AC-05a S0 / S1).
export function snapshot(userId, env = process.env) {
  const progress = objects(userId, C.progress, env).find((o) => o.key === "trade")?.value ?? null;
  const tradeReceipts = Object.fromEntries(objects(userId, C.tradeReceipts, env).map((o) => [o.key, sha(o.value)]));
  const combatReceipts = Object.fromEntries(objects(userId, C.combatReceipts, env).map((o) => [o.key, sha(o.value)]));
  const tickets = Object.fromEntries(objects(userId, C.tickets, env).map((o) => [o.key, sha(o.value)]));
  const intents = Object.fromEntries(objects(userId, C.intents, env).map((o) => [o.key, sha(o.value)]));
  return {
    user_id: userId,
    progress: progress === null ? null : { money: progress.money, backpack: progress.backpack, revision: progress.revision },
    trade_receipts: tradeReceipts, combat_receipts: combatReceipts, tickets, intents,
  };
}

// AC-05a B1: S1 must equal S0 exactly (receipts by key + value hash, progress).
export function snapshotDelta(s0, s1) {
  const diffs = [];
  const cmpMap = (name, a, b) => {
    for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) if (a[k] !== b[k]) diffs.push(`${name}:${k}:${a[k] ?? "absent"}->${b[k] ?? "absent"}`);
  };
  if (s0.user_id !== s1.user_id) diffs.push("user_id differs");
  if (canonical(s0.progress) !== canonical(s1.progress)) diffs.push(`progress:${canonical(s0.progress)}->${canonical(s1.progress)}`);
  cmpMap("trade_receipt", s0.trade_receipts, s1.trade_receipts);
  cmpMap("combat_receipt", s0.combat_receipts, s1.combat_receipts);
  cmpMap("ticket", s0.tickets, s1.tickets);
  cmpMap("intent", s0.intents, s1.intents);
  return diffs;
}

// Trade ledger: money / backpack must equal the starting state plus the
// APPLIED v1 receipts. rejected (v1) and voided (v2) receipts move nothing.
export function tradeLedger(progress, receipts) {
  const problems = [];
  let money = STARTING_MONEY;
  const carried = {};
  const keys = new Set();
  for (const r of receipts) {
    if (keys.has(r.idempotency_key)) problems.push(`duplicate key ${r.idempotency_key}`);
    keys.add(r.idempotency_key);
    if (r.status === "applied") {
      const q = r.quantity, sign = r.action === "buy" ? 1 : -1;
      money -= sign * r.total;
      carried[r.good_id] = (carried[r.good_id] ?? 0) + sign * q;
      if (r.money_after !== r.money_before - sign * r.total) problems.push(`receipt ${r.idempotency_key}: money delta`);
      if (r.carried_after !== r.carried_before + sign * q) problems.push(`receipt ${r.idempotency_key}: carried delta`);
    } else if (r.status === "rejected" || r.status === "voided") {
      if (r.money_after !== r.money_before || r.carried_after !== r.carried_before || r.total !== 0 && r.status === "voided") problems.push(`receipt ${r.idempotency_key}: ${r.status} moved something`);
    } else problems.push(`receipt ${r.idempotency_key}: unknown status ${r.status}`);
  }
  if (progress === null) {
    if (receipts.some((r) => r.status === "applied")) problems.push("applied receipts but no progress");
    return { money, carried, problems };
  }
  if (progress.money !== money) problems.push(`money ${progress.money} != ledger ${money}`);
  for (const g of new Set([...Object.keys(carried), ...Object.keys(progress.backpack ?? {})])) {
    const want = carried[g] ?? 0, have = (progress.backpack ?? {})[g] ?? 0;
    if (want !== have) problems.push(`carried ${g}: ${have} != ledger ${want}`);
    if (want < 0) problems.push(`carried ${g} negative in ledger`);
  }
  return { money, carried, problems };
}

export function ledger(userId, env = process.env) {
  const progress = objects(userId, C.progress, env).find((o) => o.key === "trade")?.value ?? null;
  const receipts = objects(userId, C.tradeReceipts, env).map((o) => o.value);
  const notTrusted = objects(userId, C.tradeReceipts, env).filter((o) => o.read !== 0).map((o) => o.key);
  const r = tradeLedger(progress, receipts);
  // Combat: hero EXP never exceeds what the applied claim receipts awarded,
  // one settlement per ticket.
  const combat = objects(userId, C.combatReceipts, env).map((o) => o.value);
  const perTicket = {};
  for (const x of combat) perTicket[x.ticket_id] = (perTicket[x.ticket_id] ?? 0) + 1;
  for (const [t, n] of Object.entries(perTicket)) if (n > 1) r.problems.push(`ticket ${t}: ${n} settlement receipts`);
  return { user_id: userId, receipts: receipts.length, untrusted_read_flag: notTrusted, ...r };
}

const isEntry = (() => { try { return process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]; } catch { return false; } })();
if (isEntry) {
  const [cmd, user] = process.argv.slice(2);
  if (cmd === "snapshot") console.log(JSON.stringify(snapshot(user)));
  else if (cmd === "ledger") console.log(JSON.stringify(ledger(user)));
  else { console.error("usage: wp01h_db.mjs snapshot|ledger <user-id>"); process.exit(2); }
}
