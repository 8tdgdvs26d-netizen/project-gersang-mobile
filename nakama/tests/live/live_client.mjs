// Minimal Nakama HTTP client for the LIVE tests (local server only).
import { randomBytes } from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

export const BASE = process.env.MYRIAL_NAKAMA_URL ?? "http://127.0.0.1:17350";
const SERVER_KEY = process.env.MYRIAL_NAKAMA_SERVER_KEY ?? "defaultkey";
const BASIC = "Basic " + Buffer.from(`${SERVER_KEY}:`).toString("base64");
export const RUN = `${Date.now().toString(36)}${randomBytes(3).toString("hex")}`;

let accountSeq = 0;

export async function authEmail(label) {
  const email = `${label}-${RUN}-${++accountSeq}@myrial.test`;
  const res = await fetch(`${BASE}/v2/account/authenticate/email?create=true`, {
    method: "POST", headers: { Authorization: BASIC, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password: `localtest-${RUN}` }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`auth failed ${res.status} ${JSON.stringify(body)}`);
  return { email, token: body.token, userId: JSON.parse(Buffer.from(body.token.split(".")[1], "base64url")).uid };
}

export async function authRaw(path, payload) {
  const res = await fetch(`${BASE}/v2/account/authenticate/${path}?create=true`, {
    method: "POST", headers: { Authorization: BASIC, "Content-Type": "application/json" }, body: JSON.stringify(payload),
  });
  return { status: res.status, body: await res.json() };
}

// Returns {status, body}. body is the parsed RPC result, or the error object.
// `base` selects another node (multi-node test).
export async function rpc(account, id, payload, { signal, base = BASE } = {}) {
  const res = await fetch(`${base}/v2/rpc/${id}?unwrap=true`, {
    method: "POST", signal,
    headers: { Authorization: `Bearer ${account.token}`, "Content-Type": "application/json" },
    body: typeof payload === "string" ? payload : JSON.stringify(payload ?? {}),
  });
  const text = await res.text();
  let body;
  try { body = JSON.parse(text); } catch { body = text; }
  return { status: res.status, body };
}

export async function api(account, method, path, payload) {
  const res = await fetch(`${BASE}${path}`, {
    method, headers: { Authorization: `Bearer ${account.token}`, "Content-Type": "application/json" },
    body: payload === undefined ? undefined : JSON.stringify(payload),
  });
  return { status: res.status, body: await res.json().catch(() => null) };
}

export const newKey = () => randomBytes(16).toString("hex");

// Starts (takes over) the gameplay session and remembers it on the account.
export async function begin(account) {
  const r = await rpc(account, "vs01_session_begin", {});
  if (r.status !== 200) throw new Error(`begin failed ${r.status} ${JSON.stringify(r.body)}`);
  account.gsid = r.body.gameplay_session_id;
  return account.gsid;
}

export function order(gsid, overrides = {}) {
  return {
    gameplay_session_id: gsid, idempotency_key: newKey(),
    action: "buy", city_id: "A", good_id: "test_good_01", quantity: 1, ...overrides,
  };
}

// Session policy A: progress is readable only by the ACTIVE gameplay session.
export async function progress(account, gsid = account.gsid) {
  const r = await rpc(account, "vs01_progress_get", { gameplay_session_id: gsid });
  if (r.status !== 200) throw new Error(`progress failed ${r.status} ${JSON.stringify(r.body)}`);
  return r.body.progress;
}

// Receipts are server-only (policy A), so tests read them straight from the
// LOCAL test database. The user id comes from the server-issued token.
const COMPOSE_DIR = fileURLToPath(new URL("../..", import.meta.url));
export async function receipts(account) {
  if (!/^[0-9a-f-]{36}$/.test(account.userId)) throw new Error("bad user id");
  const out = execFileSync(process.env.DOCKER ?? "docker", ["compose", "exec", "-T", "postgres", "psql", "-U", "postgres", "-d", "nakama", "-tAc",
    `SELECT value FROM storage WHERE collection = 'vs01_wp01_receipts' AND user_id = '${account.userId}'`], { cwd: COMPOSE_DIR, maxBuffer: 64 * 1024 * 1024 });
  return out.toString().split("\n").filter((line) => line.trim()).map((line) => JSON.parse(line));
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
