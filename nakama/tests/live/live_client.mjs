// Minimal Nakama HTTP client for the LIVE tests (local server only).
import { randomBytes } from "node:crypto";

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
export async function rpc(account, id, payload, { signal } = {}) {
  const res = await fetch(`${BASE}/v2/rpc/${id}?unwrap=true`, {
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

export async function begin(account) {
  const r = await rpc(account, "vs01_session_begin", {});
  if (r.status !== 200) throw new Error(`begin failed ${r.status} ${JSON.stringify(r.body)}`);
  return r.body.gameplay_session_id;
}

export function order(gsid, overrides = {}) {
  return {
    gameplay_session_id: gsid, idempotency_key: newKey(),
    action: "buy", city_id: "A", good_id: "test_good_01", quantity: 1, ...overrides,
  };
}

export async function progress(account) {
  const r = await rpc(account, "vs01_progress_get", {});
  if (r.status !== 200) throw new Error(`progress failed ${r.status}`);
  return r.body.progress;
}

export async function receipts(account) {
  const out = [];
  let cursor = "";
  do {
    const q = new URLSearchParams({ limit: "100", user_id: account.userId });
    if (cursor) q.set("cursor", cursor);
    const r = await api(account, "GET", `/v2/storage/vs01_wp01_receipts?${q}`);
    for (const o of r.body.objects ?? []) out.push(JSON.parse(o.value));
    cursor = r.body.cursor ?? "";
  } while (cursor);
  return out;
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
