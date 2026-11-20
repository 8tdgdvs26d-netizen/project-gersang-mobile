// VS-01 WP01-H (E1) — vs01_trade_resolve: Resolve-or-Void for an uncertain
// trade (Blueprint v0.1r3 §4 / §5, DEC-08-T = T-A2).
//
// A client that lost the outcome of a vs01_trade (app kill, lost reply) asks
// with the ORIGINAL idempotency key and command. Exactly one server outcome
// per key is ever recorded:
//   - a receipt already exists for the key  -> it is replayed unchanged
//     (Legacy v1 applied / rejected, or a Voided v2), after a strict check;
//   - no receipt yet                        -> a create-only Voided v2
//     tombstone is written, so the original command can never execute later.
//
// Trade v1 (rpcTrade, its request hash and its atomic write) is untouched.
// A late original vs01_trade for a voided key finds the tombstone (or loses
// the create-only race against it) and replays it: it cannot apply.
//
// Order (Blueprint §5): (1) signed-in account, rate limit, basic format;
// (2) ONE consistent read of progress + receipt, active session first;
// (3) existing receipt: strict match, then replay; (4) no receipt: current
// catalog / legal quantity, an invalid command gets no tombstone; (5) one
// multiUpdate: create-only receipt + identical-value progress session guard;
// (6) lost race -> re-read; any other storage error -> unknown outcome;
// (7) anything not recognised fails closed (no guessing, no migration).

const RESOLVE_RECEIPT_CONTRACT = "myrial.vs01.wp01.trade_receipt";
const RESOLVE_RECEIPT_CONTRACT_VERSION = 2;
const RESOLVE_VOIDED_STATUS = "voided";
const RESOLVE_VOIDED_REASON = "recovery_voided";

// Legacy v1: the exact receipt rpcTrade writes (main.ts), no contract field.
const RESOLVE_V1_KEYS = ["idempotency_key", "request_hash", "user_id", "gameplay_session_id",
  "action", "city_id", "good_id", "quantity", "status", "reason", "unit_price", "total",
  "money_before", "money_after", "carried_before", "carried_after", "progress_revision", "server_time_ms"];

// Voided v2 (Blueprint §4). No gameplay_session_id: the resolving session is
// resolved_by_session_id and must never be read as the original session.
const RESOLVE_V2_KEYS = ["contract", "contract_version", "idempotency_key", "request_hash", "user_id",
  "resolved_by_session_id", "action", "city_id", "good_id", "quantity", "status", "reason",
  "unit_price", "total", "money_before", "money_after", "carried_before", "carried_after",
  "progress_revision", "server_time_ms"];

function resolveIsNonNegInt(v: any): boolean {
  return rulesIsInt(v) && v >= 0;
}

// Fields shared by both formats: the command and its identity.
function resolveCommandFieldsValid(v: any): boolean {
  return typeof v.idempotency_key === "string" && typeof v.request_hash === "string"
    && typeof v.user_id === "string" && typeof v.action === "string"
    && typeof v.city_id === "string" && typeof v.good_id === "string"
    && typeof v.quantity === "number" && isFinite(v.quantity)
    && resolveIsNonNegInt(v.progress_revision) && resolveIsNonNegInt(v.server_time_ms);
}

function resolveIsLegacyV1(v: any): boolean {
  if (!progressKeysExactly(v, RESOLVE_V1_KEYS) || !resolveCommandFieldsValid(v)) return false;
  if (typeof v.gameplay_session_id !== "string") return false;
  if (v.status !== "applied" && v.status !== "rejected") return false;
  if (typeof v.reason !== "string") return false;
  return rulesIsInt(v.unit_price) && rulesIsInt(v.total)
    && rulesIsInt(v.money_before) && rulesIsInt(v.money_after)
    && rulesIsInt(v.carried_before) && rulesIsInt(v.carried_after);
}

function resolveIsVoidedV2(v: any): boolean {
  if (!progressKeysExactly(v, RESOLVE_V2_KEYS) || !resolveCommandFieldsValid(v)) return false;
  if (v.contract !== RESOLVE_RECEIPT_CONTRACT || v.contract_version !== RESOLVE_RECEIPT_CONTRACT_VERSION) return false;
  if (typeof v.resolved_by_session_id !== "string") return false;
  if (v.status !== RESOLVE_VOIDED_STATUS || v.reason !== RESOLVE_VOIDED_REASON) return false;
  if (v.unit_price !== 0 || v.total !== 0) return false;
  return rulesIsInt(v.money_before) && v.money_after === v.money_before
    && rulesIsInt(v.carried_before) && v.carried_after === v.carried_before;
}

// An existing receipt for the key, checked strictly before it is replayed.
// Returns normally only for a recognised receipt of exactly this command.
function resolveCheckExisting(receipt: nkruntime.StorageObject, userId: string, key: string,
  req: TradeRequest, hash: string): void {
  if (receipt.permissionRead !== 0) throw guardError(nkruntime.Codes.INTERNAL, "receipt_not_trusted");
  const v = receipt.value;
  if (!resolveIsLegacyV1(v) && !resolveIsVoidedV2(v)) {
    throw guardError(nkruntime.Codes.INTERNAL, "receipt_unrecognized");
  }
  if (v.user_id !== userId || v.idempotency_key !== key) {
    throw guardError(nkruntime.Codes.INTERNAL, "receipt_not_trusted");
  }
  // Same key, different command: the same answer rpcTrade gives.
  if (v.request_hash !== hash || v.action !== req.action || v.city_id !== req.city_id
    || v.good_id !== req.good_id || v.quantity !== req.quantity) {
    throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "idempotency_key_reused");
  }
}

// Current catalog and legal order size. Only checked when NO receipt exists:
// a legacy rejected receipt for a no-longer-valid command still replays.
function resolveCommandIsVoidable(req: TradeRequest): boolean {
  return (req.action === "buy" || req.action === "sell") && rulesCityExists(req.city_id)
    && rulesCapacityCost(req.good_id) > 0 && rulesIsAllowedQuantity(req.quantity);
}

function rpcTradeResolve(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, payload: string): string {
  const userId = guardRequireUser(ctx);
  guardRateLimit(ctx, logger, nk, "trade_resolve", userId);
  const cmd = guardParseTradeResolve(payload);
  const hash = guardRequestHash(cmd.req);
  for (let attempt = 0; attempt < TRADE_MAX_ATTEMPTS; attempt++) {
    // (2) one snapshot; policy A before anything is disclosed.
    const read = readProgressAndReceipt(nk, userId, cmd.idempotencyKey);
    const current = requireActiveSession(read.current, cmd.gameplaySessionId);
    // (3) existing receipt first (AC-20 order).
    if (read.receipt !== null) {
      resolveCheckExisting(read.receipt, userId, cmd.idempotencyKey, cmd.req, hash);
      return JSON.stringify({ replayed: true, receipt: read.receipt.value, progress: progressView(current.progress) });
    }
    // (4) no receipt: only a currently valid command gets a tombstone.
    if (!resolveCommandIsVoidable(cmd.req)) {
      throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "resolve_command_invalid");
    }
    const p = current.progress;
    const carried = p.backpack[cmd.req.good_id] || 0;
    const receipt = {
      contract: RESOLVE_RECEIPT_CONTRACT,
      contract_version: RESOLVE_RECEIPT_CONTRACT_VERSION,
      idempotency_key: cmd.idempotencyKey,
      request_hash: hash,
      user_id: userId,
      resolved_by_session_id: cmd.gameplaySessionId,
      action: cmd.req.action, city_id: cmd.req.city_id, good_id: cmd.req.good_id, quantity: cmd.req.quantity,
      status: RESOLVE_VOIDED_STATUS,
      reason: RESOLVE_VOIDED_REASON,
      unit_price: 0,
      total: 0,
      money_before: p.money,
      money_after: p.money,
      carried_before: carried,
      carried_after: carried,
      progress_revision: p.revision, // a void changes nothing: no revision bump
      server_time_ms: Date.now(),
    };
    try {
      // (5) one transaction: tombstone (create-only) + progress rewritten
      // with its identical value, version-checked (session guard, ACK-1).
      nk.multiUpdate(null, [
        { collection: RECEIPT_COLLECTION, key: cmd.idempotencyKey, userId: userId, value: receipt,
          version: "*", permissionRead: 0, permissionWrite: 0 },
        progressWrite(userId, p, current.version),
      ], null, null, false);
    } catch (e) {
      // (6) not a version conflict: outcome unknown, the client keeps Pending.
      if (!guardIsVersionConflict(e)) throw guardStorageUnavailable(logger, "trade_resolve", e);
      continue; // the original trade, another resolve or a takeover won: re-read
    }
    logger.info("vs01 trade_resolve voided %s", JSON.stringify(receipt));
    return JSON.stringify({ replayed: false, receipt: receipt, progress: progressView(p) });
  }
  throw guardError(nkruntime.Codes.ABORTED, "conflict_retry_exhausted");
}
