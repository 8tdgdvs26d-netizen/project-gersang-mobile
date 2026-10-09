// VS-01 WP01 — request validation, rate limits and API lock-down.

const GUARD_IDEMPOTENCY_KEY_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;
const GUARD_SESSION_ID_PATTERN = /^[0-9a-f-]{36}$/;
const GUARD_MAX_PAYLOAD_BYTES = 1024;

// Per-user limits per fixed window. Security settings, not gameplay rules;
// overridable through runtime env (see config/local.yml). Counters live in
// this node's local cache, so with several Nakama nodes each node counts on
// its own (documented WP01 limit).
const GUARD_DEFAULT_LIMITS: { [name: string]: { env: string; perWindow: number; windowSec: number } } = {
  trade: { env: "MYRIAL_RL_TRADE_PER_10S", perWindow: 30, windowSec: 10 },
  progress_get: { env: "MYRIAL_RL_PROGRESS_GET_PER_10S", perWindow: 60, windowSec: 10 },
  session_begin: { env: "MYRIAL_RL_SESSION_BEGIN_PER_60S", perWindow: 10, windowSec: 60 },
};

function guardError(code: number, message: string): { message: string; code: number } {
  return { message: message, code: code };
}

function guardRequireUser(ctx: nkruntime.Context): string {
  if (!ctx.userId) throw guardError(nkruntime.Codes.UNAUTHENTICATED, "unauthenticated");
  return ctx.userId;
}

// Parses a JSON object payload that must contain exactly `keys`. Extra keys
// (for example a client-supplied price or money amount) are rejected.
function guardParsePayload(payload: string, keys: string[]): { [key: string]: any } {
  if (typeof payload !== "string" || payload.length > GUARD_MAX_PAYLOAD_BYTES) {
    throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "payload_too_large");
  }
  let data: any;
  try {
    data = payload === "" ? {} : JSON.parse(payload);
  } catch (e) {
    throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "payload_not_json");
  }
  if (!progressKeysExactly(data, keys)) throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "unexpected_fields");
  return data;
}

function guardParseTrade(payload: string): { gameplaySessionId: string; idempotencyKey: string; req: TradeRequest } {
  const d = guardParsePayload(payload, ["gameplay_session_id", "idempotency_key", "action", "city_id", "good_id", "quantity"]);
  if (typeof d.gameplay_session_id !== "string" || !GUARD_SESSION_ID_PATTERN.test(d.gameplay_session_id)) {
    throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "invalid_gameplay_session_id");
  }
  if (typeof d.idempotency_key !== "string" || !GUARD_IDEMPOTENCY_KEY_PATTERN.test(d.idempotency_key)) {
    throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "invalid_idempotency_key");
  }
  if (d.action !== "buy" && d.action !== "sell") throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "invalid_action");
  if (typeof d.city_id !== "string" || d.city_id.length > 16) throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "invalid_city_id");
  if (typeof d.good_id !== "string" || d.good_id.length > 32) throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "invalid_good_id");
  if (typeof d.quantity !== "number") throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "invalid_quantity");
  return {
    gameplaySessionId: d.gameplay_session_id,
    idempotencyKey: d.idempotency_key,
    req: { action: d.action, city_id: d.city_id, good_id: d.good_id, quantity: d.quantity },
  };
}

// Same key + same command = same outcome. The session id is left out on
// purpose: a client recovering an uncertain command after reconnecting retries
// it from its NEW gameplay session and must still get the original receipt.
function guardRequestHash(req: TradeRequest): string {
  return [req.action, req.city_id, req.good_id, String(req.quantity)].join("|");
}

function guardRateLimit(ctx: nkruntime.Context, nk: nkruntime.Nakama, name: string, userId: string): void {
  const rule = GUARD_DEFAULT_LIMITS[name];
  let limit = rule.perWindow;
  const override = ctx.env ? ctx.env[rule.env] : undefined;
  if (override !== undefined && /^[0-9]+$/.test(override)) limit = parseInt(override, 10);
  const windowIndex = Math.floor(Date.now() / 1000 / rule.windowSec);
  const key = "rl:" + name + ":" + userId + ":" + windowIndex;
  const count = (nk.localcacheGet(key) || 0) + 1;
  nk.localcachePut(key, count, rule.windowSec * 2);
  if (count > limit) throw guardError(nkruntime.Codes.RESOURCE_EXHAUSTED, "rate_limited");
}

// ---------- API lock-down hooks (A3 no guest progress, A4 server authority) ----------

function guardDenyAuthMethod(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, data: any): any {
  throw guardError(nkruntime.Codes.PERMISSION_DENIED, "auth_method_not_allowed");
}

// D1: email accounts are LOCAL TEST accounts only, enabled by runtime env.
function guardEmailTestAuthOnly(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, data: any): any {
  if (!ctx.env || ctx.env["MYRIAL_ALLOW_EMAIL_TEST_AUTH"] !== "true") {
    throw guardError(nkruntime.Codes.PERMISSION_DENIED, "auth_method_not_allowed");
  }
  return data;
}

// No WP01 data is client-writable. Server-owned objects already use
// permissionWrite 0; this also stops a client from creating a look-alike
// object before the server has written the real one.
function guardDenyClientStorageWrite(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, data: any): any {
  throw guardError(nkruntime.Codes.PERMISSION_DENIED, "client_storage_write_not_allowed");
}
