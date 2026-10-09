// VS-01 WP01 — request validation, rate limits and API lock-down.

const GUARD_IDEMPOTENCY_KEY_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;
const GUARD_SESSION_ID_PATTERN = /^[0-9a-f-]{36}$/;
const GUARD_MAX_PAYLOAD_BYTES = 1024;

// Per-user rate limits (A14). Security settings, not gameplay rules;
// overridable through runtime env (see config/local.yml).
//
// Sliding-window log kept in PostgreSQL (Nakama storage), one server-only
// object per user and limiter: the server times of the requests accepted in
// the last window. A request is accepted only by a version-checked write
// (compare-and-swap: Nakama runs `UPDATE ... WHERE version = <read version>`,
// or a plain INSERT for "*", in a READ COMMITTED transaction, so two writers
// can never both succeed from the same read). Hence, in every continuous
// window of `windowMs`, at most `perWindow` requests are accepted, on any
// number of Nakama nodes sharing the database, across server restarts. A lost
// race re-reads and re-checks; when retries run out the request is refused
// (fail closed), so contention can never let a request through.
//
// Nakama versions are md5(value), so a value must never repeat: `seq` grows
// on every write, which rules out an old version matching again (ABA).
const GUARD_RATE_COLLECTION = "vs01_wp01_rate_limits";
const GUARD_RATE_MAX_ATTEMPTS = 64;
const GUARD_RATE_MAX_ENTRIES = 10000; // sanity bound on the stored log
const GUARD_DEFAULT_LIMITS: { [name: string]: { env: string; perWindow: number; windowMs: number } } = {
  trade: { env: "MYRIAL_RL_TRADE_PER_10S", perWindow: 30, windowMs: 10000 },
  progress_get: { env: "MYRIAL_RL_PROGRESS_GET_PER_10S", perWindow: 60, windowMs: 10000 },
  session_begin: { env: "MYRIAL_RL_SESSION_BEGIN_PER_60S", perWindow: 10, windowMs: 60000 },
};

function guardError(code: number, message: string): { message: string; code: number } {
  return { message: message, code: code };
}

// Nakama v3.25.0 reports a failed version check (including a lost create-only
// "*" race) as runtime.ErrStorageRejectedVersion, "Storage write rejected -
// version check failed.", wrapped by the JS runtime as "failed to write
// storage objects: ..." (storageWrite) or "error running multi update: ..."
// (multiUpdate). Only that is a concurrency conflict worth retrying; any other
// write error (database down, constraint, timeout) must not be retried as one.
const GUARD_VERSION_CONFLICT_TEXT = "Storage write rejected - version check failed.";

function guardIsVersionConflict(e: any): boolean {
  const text = e !== null && typeof e === "object" && typeof e.message === "string" ? e.message : String(e);
  return text.indexOf(GUARD_VERSION_CONFLICT_TEXT) >= 0;
}

// A storage write failed for a reason other than a version conflict. Nothing
// is retried. For a transaction the outcome may be unknown (for example the
// connection broke during commit), so the client keeps the command pending
// and retries it with the same idempotency key.
function guardStorageUnavailable(logger: nkruntime.Logger | null, where: string, e: any): { message: string; code: number } {
  if (logger) logger.error("vs01 %s storage write failed (not a version conflict): %s", where, e && e.message ? e.message : String(e));
  return guardError(nkruntime.Codes.UNAVAILABLE, "storage_unavailable");
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

function guardParseSessionId(value: any): string {
  if (typeof value !== "string" || !GUARD_SESSION_ID_PATTERN.test(value)) {
    throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "invalid_gameplay_session_id");
  }
  return value;
}

// Payload of a read that only names the caller's gameplay session.
function guardParseSessionOnly(payload: string): string {
  return guardParseSessionId(guardParsePayload(payload, ["gameplay_session_id"]).gameplay_session_id);
}

function guardParseTrade(payload: string): { gameplaySessionId: string; idempotencyKey: string; req: TradeRequest } {
  const d = guardParsePayload(payload, ["gameplay_session_id", "idempotency_key", "action", "city_id", "good_id", "quantity"]);
  guardParseSessionId(d.gameplay_session_id);
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

function guardRateLimitValue(value: any): boolean {
  if (!progressKeysExactly(value, ["seq", "accepted_ms"]) || !rulesIsInt(value.seq) || value.seq < 0) return false;
  if (Object.prototype.toString.call(value.accepted_ms) !== "[object Array]" || value.accepted_ms.length > GUARD_RATE_MAX_ENTRIES) return false;
  for (let i = 0; i < value.accepted_ms.length; i++) {
    if (!rulesIsInt(value.accepted_ms[i]) || value.accepted_ms[i] < 0) return false;
    if (i > 0 && value.accepted_ms[i] < value.accepted_ms[i - 1]) return false;
  }
  return true;
}

function guardRateLimit(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, name: string, userId: string): void {
  const rule = GUARD_DEFAULT_LIMITS[name];
  let limit = rule.perWindow;
  const override = ctx.env ? ctx.env[rule.env] : undefined;
  if (override !== undefined && /^[0-9]+$/.test(override)) limit = parseInt(override, 10);
  for (let attempt = 0; attempt < GUARD_RATE_MAX_ATTEMPTS; attempt++) {
    const found = nk.storageRead([{ collection: GUARD_RATE_COLLECTION, key: name, userId: userId }]);
    const obj = found.length > 0 ? found[0] : null;
    if (obj !== null && (obj.permissionWrite !== 0 || !guardRateLimitValue(obj.value))) {
      throw guardError(nkruntime.Codes.INTERNAL, "rate_limit_state_not_trusted");
    }
    const previous: number[] = obj === null ? [] : obj.value.accepted_ms;
    // Never step back in time: on a clock step the window only gets stricter.
    const last = previous.length > 0 ? previous[previous.length - 1] : 0;
    const now = Math.max(Date.now(), last);
    const recent: number[] = [];
    for (let i = 0; i < previous.length; i++) {
      if (previous[i] > now - rule.windowMs) recent.push(previous[i]);
    }
    if (recent.length >= limit) throw guardError(nkruntime.Codes.RESOURCE_EXHAUSTED, "rate_limited");
    recent.push(now);
    try {
      nk.storageWrite([{
        collection: GUARD_RATE_COLLECTION, key: name, userId: userId,
        value: { seq: obj === null ? 1 : obj.value.seq + 1, accepted_ms: recent },
        version: obj === null ? "*" : obj.version, permissionRead: 0, permissionWrite: 0,
      }]);
      return;
    } catch (e) {
      if (!guardIsVersionConflict(e)) throw guardStorageUnavailable(logger, "rate_limit", e); // fail closed now
      continue; // another request of this user was accepted first: re-read, re-check
    }
  }
  throw guardError(nkruntime.Codes.RESOURCE_EXHAUSTED, "rate_limit_contention");
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
