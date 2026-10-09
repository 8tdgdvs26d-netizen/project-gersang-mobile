// VS-01 WP01 — Nakama TypeScript runtime entry point.
//
// Client commands (all require an authenticated Nakama session):
//   vs01_session_begin       start a gameplay session; any earlier one is superseded (D2)
//   vs01_progress_get        read the server-confirmed progress
//   vs01_trade               one buy / sell order, atomic and idempotent (D3)
//   vs01_combat_reward_claim always rejected until combat validation is approved (D4)

const RECEIPT_COLLECTION = "vs01_wp01_receipts";
// Optimistic-concurrency retries per command. Each lost race means another
// command of the same player committed, so N simultaneous commands need at
// most N attempts; beyond this the command fails safely (nothing applied)
// with ABORTED and the client may retry.
const TRADE_MAX_ATTEMPTS = 32;

function readServerObject(nk: nkruntime.Nakama, collection: string, key: string, userId: string): nkruntime.StorageObject | null {
  const found = nk.storageRead([{ collection: collection, key: key, userId: userId }]);
  if (found.length === 0) return null;
  // Every WP01 object is server-written with permissionWrite 0. Anything else
  // did not come from this module: fail closed instead of trusting it.
  if (found[0].permissionWrite !== 0) throw guardError(nkruntime.Codes.INTERNAL, "server_object_not_trusted");
  return found[0];
}

function readProgress(nk: nkruntime.Nakama, userId: string): { progress: TradeProgress; version: string } | null {
  const obj = readServerObject(nk, PROGRESS_COLLECTION, PROGRESS_KEY, userId);
  if (obj === null) return null;
  if (!progressIsValid(obj.value)) throw guardError(nkruntime.Codes.INTERNAL, "progress_corrupt");
  return { progress: obj.value as TradeProgress, version: obj.version };
}

function progressWrite(userId: string, p: TradeProgress, version: string): nkruntime.StorageWriteRequest {
  return {
    collection: PROGRESS_COLLECTION, key: PROGRESS_KEY, userId: userId, value: p,
    version: version, permissionRead: 1, permissionWrite: 0,
  };
}

function rpcSessionBegin(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, payload: string): string {
  const userId = guardRequireUser(ctx);
  guardRateLimit(ctx, logger, nk, "session_begin", userId);
  guardParsePayload(payload, []);
  for (let attempt = 0; attempt < TRADE_MAX_ATTEMPTS; attempt++) {
    const current = readProgress(nk, userId);
    const next = current === null ? progressCreateDefault() : progressClone(current.progress);
    const superseded = next.gameplay_session_id;
    next.gameplay_session_id = nk.uuidv4();
    next.revision += 1;
    try {
      // "*" = create only; otherwise only if unchanged since the read.
      nk.storageWrite([progressWrite(userId, next, current === null ? "*" : current.version)]);
    } catch (e) {
      if (!guardIsVersionConflict(e)) throw guardStorageUnavailable(logger, "session_begin", e);
      continue; // a concurrent begin / trade won; re-read and take over again
    }
    logger.info("vs01 session_begin user=%s session=%s superseded=%s", userId, next.gameplay_session_id, superseded || "none");
    return JSON.stringify({ gameplay_session_id: next.gameplay_session_id, progress: progressView(next) });
  }
  throw guardError(nkruntime.Codes.ABORTED, "conflict_retry_exhausted");
}

function rpcProgressGet(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, payload: string): string {
  const userId = guardRequireUser(ctx);
  guardRateLimit(ctx, logger, nk, "progress_get", userId);
  guardParsePayload(payload, []);
  const current = readProgress(nk, userId);
  if (current === null) throw guardError(nkruntime.Codes.FAILED_PRECONDITION, "no_gameplay_session");
  // Show recovered prices without persisting; the next trade persists them.
  const view = progressClone(current.progress);
  progressAdvanceRecovery(view, Date.now());
  return JSON.stringify({ progress: progressView(view) });
}

function rpcTrade(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, payload: string): string {
  const userId = guardRequireUser(ctx);
  guardRateLimit(ctx, logger, nk, "trade", userId);
  const cmd = guardParseTrade(payload);
  const hash = guardRequestHash(cmd.req);
  for (let attempt = 0; attempt < TRADE_MAX_ATTEMPTS; attempt++) {
    // 1. Single active gameplay session (D2), checked BEFORE anything else:
    //    a superseded session gets no write, no replayed receipt and no
    //    progress. A client recovering an uncertain command first begins a
    //    new session and retries the same key from it (step 2 then replays).
    const current = readProgress(nk, userId);
    if (current === null) throw guardError(nkruntime.Codes.FAILED_PRECONDITION, "no_gameplay_session");
    if (current.progress.gameplay_session_id !== cmd.gameplaySessionId) {
      throw guardError(nkruntime.Codes.ABORTED, "gameplay_session_superseded");
    }
    // 2. Idempotency: a known key returns its original receipt, unchanged.
    const prior = readServerObject(nk, RECEIPT_COLLECTION, cmd.idempotencyKey, userId);
    if (prior !== null) {
      if (prior.value.request_hash !== hash) throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "idempotency_key_reused");
      return JSON.stringify({ replayed: true, receipt: prior.value, progress: progressView(current.progress) });
    }
    // 3. Decide on a copy with server time and server prices.
    const nowMs = Date.now();
    const next = progressClone(current.progress);
    progressAdvanceRecovery(next, nowMs);
    const before = progressClone(next);
    const decision = tradeDecide(next, cmd.req);
    const applied = decision.status === "applied";
    if (applied) next.revision += 1;
    const receipt = {
      idempotency_key: cmd.idempotencyKey,
      request_hash: hash,
      user_id: userId,
      gameplay_session_id: cmd.gameplaySessionId,
      action: cmd.req.action, city_id: cmd.req.city_id, good_id: cmd.req.good_id, quantity: cmd.req.quantity,
      status: decision.status,
      reason: decision.reason,
      unit_price: decision.unit_price,
      total: decision.total,
      money_before: before.money,
      money_after: next.money,
      carried_before: before.backpack[cmd.req.good_id] || 0,
      carried_after: next.backpack[cmd.req.good_id] || 0,
      progress_revision: next.revision,
      server_time_ms: nowMs,
    };
    const writes: nkruntime.StorageWriteRequest[] = [{
      collection: RECEIPT_COLLECTION, key: cmd.idempotencyKey, userId: userId, value: receipt,
      version: "*", permissionRead: 1, permissionWrite: 0,
    }];
    // A rejection changes no progress; only its receipt is recorded so a
    // retry of the same key gets the same answer.
    if (applied) writes.push(progressWrite(userId, next, current.version));
    try {
      // 4. One transaction: receipt (create-only) + progress (unchanged-since-read).
      nk.multiUpdate(null, writes, null, null, false);
    } catch (e) {
      // Not a version conflict: the commit outcome may be unknown. Fail now;
      // the client keeps the command pending and retries the same key.
      if (!guardIsVersionConflict(e)) throw guardStorageUnavailable(logger, "trade", e);
      continue; // lost a race: either the same key was just written, or progress moved
    }
    logger.info("vs01 trade receipt %s", JSON.stringify(receipt));
    return JSON.stringify({ replayed: false, receipt: receipt, progress: progressView(applied ? next : current.progress) });
  }
  throw guardError(nkruntime.Codes.ABORTED, "conflict_retry_exhausted");
}

// D4: no combat reward is written until a later, approved WP defines server
// validation. This endpoint exists so the client contract has a defined,
// tested rejection instead of an undefined path.
function rpcCombatRewardClaim(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, payload: string): string {
  const userId = guardRequireUser(ctx);
  logger.warn("vs01 combat_reward_claim rejected user=%s", userId);
  throw guardError(nkruntime.Codes.PERMISSION_DENIED, "combat_reward_requires_server_validation");
}

function InitModule(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, initializer: nkruntime.Initializer) {
  initializer.registerRpc("vs01_session_begin", rpcSessionBegin);
  initializer.registerRpc("vs01_progress_get", rpcProgressGet);
  initializer.registerRpc("vs01_trade", rpcTrade);
  initializer.registerRpc("vs01_combat_reward_claim", rpcCombatRewardClaim);

  // D1: Sign in with Apple is the formal method; email only for local tests.
  initializer.registerBeforeAuthenticateEmail(guardEmailTestAuthOnly);
  initializer.registerBeforeLinkEmail(guardEmailTestAuthOnly);
  initializer.registerBeforeAuthenticateDevice(guardDenyAuthMethod);
  initializer.registerBeforeAuthenticateCustom(guardDenyAuthMethod);
  initializer.registerBeforeAuthenticateFacebook(guardDenyAuthMethod);
  initializer.registerBeforeAuthenticateFacebookInstantGame(guardDenyAuthMethod);
  initializer.registerBeforeAuthenticateGameCenter(guardDenyAuthMethod);
  initializer.registerBeforeAuthenticateGoogle(guardDenyAuthMethod);
  initializer.registerBeforeAuthenticateSteam(guardDenyAuthMethod);
  initializer.registerBeforeLinkDevice(guardDenyAuthMethod);
  initializer.registerBeforeLinkCustom(guardDenyAuthMethod);
  initializer.registerBeforeLinkFacebook(guardDenyAuthMethod);
  initializer.registerBeforeLinkFacebookInstantGame(guardDenyAuthMethod);
  initializer.registerBeforeLinkGameCenter(guardDenyAuthMethod);
  initializer.registerBeforeLinkGoogle(guardDenyAuthMethod);
  initializer.registerBeforeLinkSteam(guardDenyAuthMethod);

  initializer.registerBeforeWriteStorageObjects(guardDenyClientStorageWrite);
  initializer.registerBeforeDeleteStorageObjects(guardDenyClientStorageWrite);

  logger.info("vs01 wp01 module loaded (email test auth %s)",
    ctx.env && ctx.env["MYRIAL_ALLOW_EMAIL_TEST_AUTH"] === "true" ? "ENABLED" : "disabled");
}

// Reference InitModule so the TypeScript compiler keeps it; Nakama finds it by name.
!InitModule && InitModule.bind(null);
