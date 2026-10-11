// VS-01 WP01-E — isolated Online TEST: server-confirmed Hero EXP / Level from a
// bounded combat claim (approved M1: the server bounds the claim, it does NOT
// prove the victory). Schema v1 per "WP01-E Contract & Schema Review v1.0"
// (Charlie, 2026-10-11) with the current-Level EXP correction.
//
// Client commands (authenticated; every one checks the active gameplay
// session first, policy A):
//   vs01e_encounter_begin    issue one encounter ticket (one unresolved per account)
//   vs01e_encounter_claim    settle a ticket once: server-computed EXP / Level
//   vs01e_encounter_abandon  explicit, confirmed abandon of the unresolved ticket
//   vs01e_progression_get    read the Hero progression and the unresolved ticket
//
// Data (all server-only, permissionRead 0 / permissionWrite 0, per account):
//   vs01_wp01e_hero_progression / hero    {level, exp} (current-Level EXP)
//   vs01_wp01e_encounter_state / state    {open_ticket_id, group_available_at_ms}
//   vs01_wp01e_tickets / <ticket_id>      OPEN -> CLAIMED | EXPIRED | ABANDONED
//   vs01_wp01e_claim_intents / <ticket>   MC-1 Option C: a claim seen before the deadline
//   vs01_wp01e_ticket_claims / <ticket>   create-only: at most one settlement per ticket
//   vs01_wp01e_receipts / <idem key>      create-only receipts (claims and abandons)
//   vs01_wp01e_rate_limits / <name>       sliding-window logs (R-3, per account)
//
// Every state change is ONE nk.multiUpdate (one PostgreSQL transaction) that
// writes, with a version check (or create-only), every object the decision
// read, plus the Trade v1 progress object rewritten with its IDENTICAL value
// as the policy A session guard (ACK-1, conditional: see tests). Trade v1 is
// otherwise untouched.

const E_HERO_COLLECTION = "vs01_wp01e_hero_progression";
const E_STATE_COLLECTION = "vs01_wp01e_encounter_state";
const E_TICKET_COLLECTION = "vs01_wp01e_tickets";
const E_INTENT_COLLECTION = "vs01_wp01e_claim_intents";
const E_CLAIM_COLLECTION = "vs01_wp01e_ticket_claims";
const E_RECEIPT_COLLECTION = "vs01_wp01e_receipts";
const E_RATE_COLLECTION = "vs01_wp01e_rate_limits";
const E_HERO_KEY = "hero";
const E_STATE_KEY = "state";

const E_HERO_CONTRACT = "myrial.vs01.wp01e.hero_progression";
const E_STATE_CONTRACT = "myrial.vs01.wp01e.encounter_state";
const E_TICKET_CONTRACT = "myrial.vs01.wp01e.ticket";
const E_INTENT_CONTRACT = "myrial.vs01.wp01e.claim_intent";
const E_CLAIM_CONTRACT = "myrial.vs01.wp01e.ticket_claim";
const E_RECEIPT_CONTRACT = "myrial.vs01.wp01e.receipt";
const E_CONTRACT_VERSION = 1;

const E_TICKET_ID_PATTERN = /^[0-9a-f]{32}$/;
const E_MAX_ATTEMPTS = 32;

// R-3 (Charlie, design approval): account-scoped, rolling 60 s, never reset
// by a new gameplay session. Abandon is charged to encounter_begin (MC-2 Q1);
// progression reads to receipt_replay (ACK-2).
const E_LIMITS: { [name: string]: { env: string; perWindow: number; windowMs: number } } = {
  encounter_begin: { env: "MYRIAL_RL_E_BEGIN_PER_60S", perWindow: 6, windowMs: 60000 },
  encounter_claim: { env: "MYRIAL_RL_E_CLAIM_PER_60S", perWindow: 12, windowMs: 60000 },
  receipt_replay: { env: "MYRIAL_RL_E_REPLAY_PER_60S", perWindow: 30, windowMs: 60000 },
};

interface EObj { value: any; version: string; }

// ---------- validation of stored objects (fail closed) ----------

function eBase(v: any, contract: string, keys: string[]): boolean {
  return progressKeysExactly(v, keys) && v.contract === contract && v.contract_version === E_CONTRACT_VERSION;
}

function eIsNonNegInt(v: any): boolean {
  return rulesIsInt(v) && v >= 0;
}

function eHeroValid(v: any): boolean {
  return eBase(v, E_HERO_CONTRACT, ["contract", "contract_version", "revision", "level", "exp"])
    && eIsNonNegInt(v.revision) && eIsValidLevelExp(v.level, v.exp);
}

function eStateValid(v: any): boolean {
  if (!eBase(v, E_STATE_CONTRACT, ["contract", "contract_version", "revision", "open_ticket_id", "group_available_at_ms"])) return false;
  if (!eIsNonNegInt(v.revision) || typeof v.open_ticket_id !== "string") return false;
  if (v.open_ticket_id !== "" && !E_TICKET_ID_PATTERN.test(v.open_ticket_id)) return false;
  const g = v.group_available_at_ms;
  if (g === null || typeof g !== "object" || Object.prototype.toString.call(g) !== "[object Object]") return false;
  const ids = Object.keys(g);
  for (let i = 0; i < ids.length; i++) {
    if (E_GROUP_IDS.indexOf(ids[i]) < 0 || !eIsNonNegInt(g[ids[i]])) return false;
  }
  return true;
}

function eTicketValid(v: any): boolean {
  if (!eBase(v, E_TICKET_CONTRACT, ["contract", "contract_version", "revision", "ticket_id", "issued_session_id",
    "issued_at_ms", "expires_at_ms", "group_ids", "enemy_count", "status", "intent_recorded", "resolved_at_ms"])) return false;
  if (!eIsNonNegInt(v.revision) || typeof v.ticket_id !== "string" || !E_TICKET_ID_PATTERN.test(v.ticket_id)) return false;
  if (typeof v.issued_session_id !== "string") return false;
  if (!eIsNonNegInt(v.issued_at_ms) || v.expires_at_ms !== v.issued_at_ms + E_TICKET_TTL_MS) return false;
  if (eEnemyCount(v.group_ids) === 0 || v.enemy_count !== eEnemyCount(v.group_ids)) return false;
  if (["OPEN", "CLAIMED", "EXPIRED", "ABANDONED"].indexOf(v.status) < 0 || typeof v.intent_recorded !== "boolean") return false;
  if (!rulesIsInt(v.resolved_at_ms) || (v.status === "OPEN" ? v.resolved_at_ms !== -1 : v.resolved_at_ms < 0)) return false;
  return true;
}

function eIntentValid(v: any): boolean {
  if (!eBase(v, E_INTENT_CONTRACT, ["contract", "contract_version", "revision", "ticket_id", "idempotency_key",
    "request_hash", "claim", "first_seen_at_ms", "first_seen_session_id", "state"])) return false;
  if (!eIsNonNegInt(v.revision) || !E_TICKET_ID_PATTERN.test(v.ticket_id)) return false;
  if (typeof v.idempotency_key !== "string" || !GUARD_IDEMPOTENCY_KEY_PATTERN.test(v.idempotency_key)) return false;
  if (typeof v.request_hash !== "string" || typeof v.first_seen_session_id !== "string") return false;
  if (!progressKeysExactly(v.claim, ["outcome", "kills", "hero_alive"])) return false;
  if (!eIsNonNegInt(v.first_seen_at_ms)) return false;
  return ["RECORDED", "DECIDED", "ABANDONED"].indexOf(v.state) >= 0;
}

function eClaimMarkerValid(v: any): boolean {
  return eBase(v, E_CLAIM_CONTRACT, ["contract", "contract_version", "ticket_id", "idempotency_key", "decided_at_ms"])
    && E_TICKET_ID_PATTERN.test(v.ticket_id) && typeof v.idempotency_key === "string" && eIsNonNegInt(v.decided_at_ms);
}

const E_RECEIPT_KEYS = ["contract", "contract_version", "kind", "idempotency_key", "request_hash", "user_id",
  "gameplay_session_id", "ticket_id", "status", "outcome", "kills_claimed", "kills_accepted", "hero_alive",
  "exp_awarded", "level_before", "exp_before", "level_after", "exp_after", "progression_revision",
  "cooldown_groups", "intent_first_seen_at_ms", "server_time_ms"];

function eReceiptValid(v: any): boolean {
  if (!eBase(v, E_RECEIPT_CONTRACT, E_RECEIPT_KEYS)) return false;
  if (v.kind !== "claim" && v.kind !== "abandon") return false;
  if (typeof v.idempotency_key !== "string" || typeof v.request_hash !== "string" || typeof v.ticket_id !== "string") return false;
  return v.status === "applied" && eIsNonNegInt(v.exp_awarded) && eIsNonNegInt(v.progression_revision);
}

const E_VALIDATORS: { [collection: string]: (v: any) => boolean } = {};
E_VALIDATORS[E_HERO_COLLECTION] = eHeroValid;
E_VALIDATORS[E_STATE_COLLECTION] = eStateValid;
E_VALIDATORS[E_TICKET_COLLECTION] = eTicketValid;
E_VALIDATORS[E_INTENT_COLLECTION] = eIntentValid;
E_VALIDATORS[E_CLAIM_COLLECTION] = eClaimMarkerValid;
E_VALIDATORS[E_RECEIPT_COLLECTION] = eReceiptValid;
E_VALIDATORS[E_RATE_COLLECTION] = guardRateLimitValue;

// ---------- reads / writes ----------

interface ESnapshot {
  progress: nkruntime.StorageObject | null;
  objects: { [id: string]: EObj };
}

function eId(collection: string, key: string): string {
  return collection + "/" + key;
}

// ONE storageRead of all objects (one user: one SELECT in Nakama v3.25.0,
// server/core_storage.go StorageReadObjects, i.e. one snapshot). Every WP01-E
// object must be server-written and valid; anything else fails closed.
function eRead(nk: nkruntime.Nakama, userId: string, ids: string[][]): ESnapshot {
  const req: nkruntime.StorageReadRequest[] = [{ collection: PROGRESS_COLLECTION, key: PROGRESS_KEY, userId: userId }];
  for (let i = 0; i < ids.length; i++) req.push({ collection: ids[i][0], key: ids[i][1], userId: userId });
  const found = nk.storageRead(req);
  const snap: ESnapshot = { progress: null, objects: {} };
  for (let i = 0; i < found.length; i++) {
    const o = found[i];
    if (o.collection === PROGRESS_COLLECTION && o.key === PROGRESS_KEY) { snap.progress = o; continue; }
    const validate = E_VALIDATORS[o.collection];
    if (!validate || o.permissionWrite !== 0 || !validate(o.value)) {
      throw guardError(nkruntime.Codes.INTERNAL, "wp01e_object_not_trusted");
    }
    snap.objects[eId(o.collection, o.key)] = { value: o.value, version: o.version };
  }
  return snap;
}

function eGet(snap: ESnapshot, collection: string, key: string): EObj | null {
  const o = snap.objects[eId(collection, key)];
  return o === undefined ? null : o;
}

function eWrite(collection: string, key: string, userId: string, value: any, version: string): nkruntime.StorageWriteRequest {
  return { collection: collection, key: key, userId: userId, value: value, version: version, permissionRead: 0, permissionWrite: 0 };
}

// ACK-1: the Trade v1 progress object written back with the value it was read
// with, version-checked. If any session_begin (or trade) committed since the
// read, the whole transaction is rejected and the caller re-reads, so no
// WP01-E state can change under a superseded session.
function eSessionGuard(userId: string, current: { progress: TradeProgress; version: string }): nkruntime.StorageWriteRequest {
  return progressWrite(userId, current.progress, current.version);
}

// One multiUpdate. Returns false on a lost race (the caller re-reads); any
// other error fails fast: the outcome may be unknown, the client retries the
// same key.
function eCommit(logger: nkruntime.Logger, nk: nkruntime.Nakama, where: string, writes: nkruntime.StorageWriteRequest[]): boolean {
  try {
    nk.multiUpdate(null, writes, null, null, false);
    return true;
  } catch (e) {
    if (!guardIsVersionConflict(e)) throw guardStorageUnavailable(logger, where, e);
    return false;
  }
}

// ---------- rate limits (R-3), same sliding-window log as WP01 ----------

// Charges one request to `name`. `pre` is the limiter object from the
// command's combined read (C-7: a refused request costs that one read and no
// write); later attempts after a lost race re-read just the limiter.
function eCharge(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, userId: string, name: string, pre: EObj | null, now0: number): void {
  const rule = E_LIMITS[name];
  let limit = rule.perWindow;
  const override = ctx.env ? ctx.env[rule.env] : undefined;
  if (override !== undefined && /^[0-9]+$/.test(override)) limit = parseInt(override, 10);
  let obj: EObj | null = pre;
  for (let attempt = 0; attempt < GUARD_RATE_MAX_ATTEMPTS; attempt++) {
    if (attempt > 0) obj = eGet(eRead(nk, userId, [[E_RATE_COLLECTION, name]]), E_RATE_COLLECTION, name);
    const previous: number[] = obj === null ? [] : obj.value.accepted_ms;
    const last = previous.length > 0 ? previous[previous.length - 1] : 0;
    const now = Math.max(now0, last); // never step back in time
    const recent: number[] = [];
    for (let i = 0; i < previous.length; i++) if (previous[i] > now - rule.windowMs) recent.push(previous[i]);
    if (recent.length >= limit) throw guardError(nkruntime.Codes.RESOURCE_EXHAUSTED, "rate_limited");
    recent.push(now);
    try {
      nk.storageWrite([eWrite(E_RATE_COLLECTION, name, userId,
        { seq: obj === null ? 1 : obj.value.seq + 1, accepted_ms: recent }, obj === null ? "*" : obj.version)]);
      return;
    } catch (e) {
      if (!guardIsVersionConflict(e)) throw guardStorageUnavailable(logger, "rate_limit", e);
    }
  }
  throw guardError(nkruntime.Codes.RESOURCE_EXHAUSTED, "rate_limit_contention");
}

// ---------- payloads ----------

function eParseKey(v: any): string {
  if (typeof v !== "string" || !GUARD_IDEMPOTENCY_KEY_PATTERN.test(v)) throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "invalid_idempotency_key");
  return v;
}

function eParseTicketId(v: any): string {
  if (typeof v !== "string" || !E_TICKET_ID_PATTERN.test(v)) throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "invalid_ticket_id");
  return v;
}

// Same key + same command = same outcome; the session id is left out so a
// reclaimed device can resend the same command (S5).
function eClaimHash(ticketId: string, outcome: string, kills: number, heroAlive: boolean): string {
  return ["claim", ticketId, outcome, String(kills), heroAlive ? "1" : "0"].join("|");
}

function eAbandonHash(ticketId: string): string {
  return "abandon|" + ticketId;
}

// ---------- views ----------

function eHeroOrDefault(o: EObj | null): any {
  return o === null
    ? { contract: E_HERO_CONTRACT, contract_version: E_CONTRACT_VERSION, revision: 0, level: E_START_LEVEL, exp: 0 }
    : o.value;
}

function eStateOrDefault(o: EObj | null): any {
  return o === null
    ? { contract: E_STATE_CONTRACT, contract_version: E_CONTRACT_VERSION, revision: 0, open_ticket_id: "", group_available_at_ms: {} }
    : o.value;
}

function eProgressionView(hero: any): { [key: string]: any } {
  return { level: hero.level, exp: hero.exp, exp_to_next: eRequiredExp(hero.level), revision: hero.revision };
}

function eTicketView(t: any): { [key: string]: any } {
  return {
    ticket_id: t.ticket_id, issued_at_ms: t.issued_at_ms, expires_at_ms: t.expires_at_ms,
    min_claim_at_ms: t.issued_at_ms + E_MIN_CLAIM_AGE_MS, group_ids: t.group_ids.slice(0),
    enemy_count: t.enemy_count, status: t.status, intent_recorded: t.intent_recorded,
  };
}

// An OPEN ticket is unresolved until settled / abandoned, or until its
// deadline when no claim intent was recorded before it (MC-1 Option C).
function eIsUnresolved(t: any, now0: number): boolean {
  return t.status === "OPEN" && (t.intent_recorded || now0 < t.expires_at_ms);
}

function eWithRevision(v: any, changes: { [key: string]: any }): any {
  const next = JSON.parse(JSON.stringify(v));
  const keys = Object.keys(changes);
  for (let i = 0; i < keys.length; i++) next[keys[i]] = changes[keys[i]];
  next.revision = v.revision + 1;
  return next;
}

// Writes that expire an OPEN ticket whose deadline passed with no intent
// (lazy expiry) and free the account's slot.
function eExpireWrites(userId: string, ticket: EObj, state: EObj | null, now0: number): nkruntime.StorageWriteRequest[] {
  const writes = [eWrite(E_TICKET_COLLECTION, ticket.value.ticket_id, userId,
    eWithRevision(ticket.value, { status: "EXPIRED", resolved_at_ms: now0 }), ticket.version)];
  if (state !== null && state.value.open_ticket_id === ticket.value.ticket_id) {
    writes.push(eWrite(E_STATE_COLLECTION, E_STATE_KEY, userId, eWithRevision(state.value, { open_ticket_id: "" }), state.version));
  }
  return writes;
}

// ---------- RPCs ----------

function rpcEncounterBegin(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, payload: string): string {
  const userId = guardRequireUser(ctx);
  const d = guardParsePayload(payload, ["gameplay_session_id", "group_ids"]);
  const gameplaySessionId = guardParseSessionId(d.gameplay_session_id);
  const enemyCount = eEnemyCount(d.group_ids);
  if (enemyCount === 0) throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "invalid_group_ids");
  const groupIds: string[] = d.group_ids.slice(0);
  const now0 = Date.now();
  let charged = false;
  for (let attempt = 0; attempt < E_MAX_ATTEMPTS; attempt++) {
    const snap = eRead(nk, userId, [[E_STATE_COLLECTION, E_STATE_KEY], [E_HERO_COLLECTION, E_HERO_KEY], [E_RATE_COLLECTION, "encounter_begin"]]);
    const current = requireActiveSession(trustProgress(snap.progress), gameplaySessionId);
    if (!charged) { eCharge(ctx, logger, nk, userId, "encounter_begin", eGet(snap, E_RATE_COLLECTION, "encounter_begin"), now0); charged = true; }
    const stateObj = eGet(snap, E_STATE_COLLECTION, E_STATE_KEY);
    const state = eStateOrDefault(stateObj);
    const writes: nkruntime.StorageWriteRequest[] = [];
    if (state.open_ticket_id !== "") {
      const old = eGet(eRead(nk, userId, [[E_TICKET_COLLECTION, state.open_ticket_id]]), E_TICKET_COLLECTION, state.open_ticket_id);
      if (old === null) throw guardError(nkruntime.Codes.INTERNAL, "wp01e_open_ticket_missing");
      if (eIsUnresolved(old.value, now0)) throw guardError(nkruntime.Codes.FAILED_PRECONDITION, "ticket_unsettled");
      if (old.value.status === "OPEN") {
        writes.push(eWrite(E_TICKET_COLLECTION, old.value.ticket_id, userId,
          eWithRevision(old.value, { status: "EXPIRED", resolved_at_ms: now0 }), old.version));
      }
    }
    for (let i = 0; i < groupIds.length; i++) {
      const until = state.group_available_at_ms[groupIds[i]];
      if (until !== undefined && until > now0) throw guardError(nkruntime.Codes.FAILED_PRECONDITION, "cooldown_active");
    }
    const ticketId = nk.uuidv4().replace(/-/g, "").toLowerCase();
    const ticket = {
      contract: E_TICKET_CONTRACT, contract_version: E_CONTRACT_VERSION, revision: 0, ticket_id: ticketId,
      issued_session_id: gameplaySessionId, issued_at_ms: now0, expires_at_ms: now0 + E_TICKET_TTL_MS,
      group_ids: groupIds, enemy_count: enemyCount, status: "OPEN", intent_recorded: false, resolved_at_ms: -1,
    };
    writes.push(eWrite(E_TICKET_COLLECTION, ticketId, userId, ticket, "*"));
    writes.push(eWrite(E_STATE_COLLECTION, E_STATE_KEY, userId, eWithRevision(state, { open_ticket_id: ticketId }),
      stateObj === null ? "*" : stateObj.version));
    writes.push(eSessionGuard(userId, current));
    if (!eCommit(logger, nk, "encounter_begin", writes)) continue;
    logger.info("vs01e encounter_begin user=%s ticket=%s groups=%s", userId, ticketId, groupIds.join(","));
    return JSON.stringify({ ticket: eTicketView(ticket), progression: eProgressionView(eHeroOrDefault(eGet(snap, E_HERO_COLLECTION, E_HERO_KEY))) });
  }
  throw guardError(nkruntime.Codes.ABORTED, "conflict_retry_exhausted");
}

function rpcEncounterClaim(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, payload: string): string {
  const userId = guardRequireUser(ctx);
  const d = guardParsePayload(payload, ["gameplay_session_id", "idempotency_key", "ticket_id", "outcome", "kills", "hero_alive"]);
  const gameplaySessionId = guardParseSessionId(d.gameplay_session_id);
  const key = eParseKey(d.idempotency_key);
  const ticketId = eParseTicketId(d.ticket_id);
  if (E_OUTCOMES.indexOf(d.outcome) < 0 || !rulesIsInt(d.kills) || d.kills < 0 || typeof d.hero_alive !== "boolean") {
    throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "invalid_claim");
  }
  const claim = { outcome: d.outcome as string, kills: d.kills as number, hero_alive: d.hero_alive as boolean };
  const hash = eClaimHash(ticketId, claim.outcome, claim.kills, claim.hero_alive);
  const now0 = Date.now();
  let charged = false;
  // The limiter's refusal, kept while its MC-1 intent is being made durable.
  let throttled: any = null;
  for (let attempt = 0; attempt < E_MAX_ATTEMPTS; attempt++) {
    const snap = eRead(nk, userId, [[E_RECEIPT_COLLECTION, key], [E_TICKET_COLLECTION, ticketId], [E_INTENT_COLLECTION, ticketId],
      [E_STATE_COLLECTION, E_STATE_KEY], [E_HERO_COLLECTION, E_HERO_KEY],
      [E_RATE_COLLECTION, "encounter_claim"], [E_RATE_COLLECTION, "receipt_replay"]]);
    // 1. Policy A before anything is disclosed.
    const current = requireActiveSession(trustProgress(snap.progress), gameplaySessionId);
    const heroObj = eGet(snap, E_HERO_COLLECTION, E_HERO_KEY);
    // 2. Receipt replay (the original receipt, even after the deadline).
    const receipt = eGet(snap, E_RECEIPT_COLLECTION, key);
    if (receipt !== null) {
      if (receipt.value.request_hash !== hash) throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "idempotency_key_reused");
      if (!charged) { eCharge(ctx, logger, nk, userId, "receipt_replay", eGet(snap, E_RATE_COLLECTION, "receipt_replay"), now0); charged = true; }
      return JSON.stringify({ replayed: true, receipt: receipt.value, progression: eProgressionView(eHeroOrDefault(heroObj)) });
    }
    // 3. The ticket (another account's ticket is simply not found: storage is per user).
    const ticket = eGet(snap, E_TICKET_COLLECTION, ticketId);
    if (ticket === null) throw guardError(nkruntime.Codes.NOT_FOUND, "ticket_not_found");
    const t = ticket.value;
    if (t.status === "CLAIMED") throw guardError(nkruntime.Codes.ALREADY_EXISTS, "ticket_already_claimed");
    if (t.status === "ABANDONED") throw guardError(nkruntime.Codes.FAILED_PRECONDITION, "ticket_abandoned");
    if (t.status === "EXPIRED") throw guardError(nkruntime.Codes.FAILED_PRECONDITION, "ticket_expired");
    const stateObj = eGet(snap, E_STATE_COLLECTION, E_STATE_KEY);
    if (!eIsUnresolved(t, now0)) {
      // Deadline passed with no intent recorded before it: explicit loss (MC-1 C).
      if (!eCommit(logger, nk, "encounter_expire", eExpireWrites(userId, ticket, stateObj, now0).concat([eSessionGuard(userId, current)]))) continue;
      throw guardError(nkruntime.Codes.FAILED_PRECONDITION, "ticket_expired");
    }
    // 4. Bounded claim (M1).
    const expAward = eClaimExp(claim.outcome, claim.kills, claim.hero_alive, t.enemy_count);
    if (expAward < 0) throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "invalid_claim");
    const intent = eGet(snap, E_INTENT_COLLECTION, ticketId);
    if (intent !== null) {
      if (intent.value.idempotency_key !== key || intent.value.request_hash !== hash) throw guardError(nkruntime.Codes.ALREADY_EXISTS, "claim_locked");
      if (intent.value.state !== "RECORDED") throw guardError(nkruntime.Codes.INTERNAL, "wp01e_intent_inconsistent");
    }
    // MC-1 Option C: record the claim before any transient refusal, while the
    // deadline has not passed (never for a superseded session: guarded).
    // True once the intent is durable (or none is due); false on a lost race:
    // the caller re-reads and re-checks everything before trying again.
    const recordIntent = (): boolean => {
      if (intent !== null || now0 >= t.expires_at_ms) return true;
      const value = {
        contract: E_INTENT_CONTRACT, contract_version: E_CONTRACT_VERSION, revision: 0, ticket_id: ticketId,
        idempotency_key: key, request_hash: hash, claim: claim, first_seen_at_ms: now0,
        first_seen_session_id: gameplaySessionId, state: "RECORDED",
      };
      return eCommit(logger, nk, "encounter_intent", [
        eWrite(E_INTENT_COLLECTION, ticketId, userId, value, "*"),
        eWrite(E_TICKET_COLLECTION, ticketId, userId, eWithRevision(t, { intent_recorded: true }), ticket.version),
        eSessionGuard(userId, current),
      ]);
    };
    // 5. Rate limit (R-3), then the minimum claim age (R-1). A throttled
    // claim is answered rate_limited only after its intent is confirmed
    // written: a lost race re-reads (policy A and ticket state re-checked);
    // endless races end as conflict_retry_exhausted, never as a false refusal.
    if (!charged && throttled === null) {
      try {
        eCharge(ctx, logger, nk, userId, "encounter_claim", eGet(snap, E_RATE_COLLECTION, "encounter_claim"), now0);
        charged = true;
      } catch (e) {
        if (!(e && (e as any).code === nkruntime.Codes.RESOURCE_EXHAUSTED)) throw e;
        throttled = e;
      }
    }
    if (throttled !== null) {
      if (!recordIntent()) continue;
      throw throttled;
    }
    if (now0 < t.issued_at_ms + E_MIN_CLAIM_AGE_MS) {
      if (!recordIntent()) continue;
      throw guardError(nkruntime.Codes.FAILED_PRECONDITION, "too_early");
    }
    // 6. Decide: one transaction (W1-W7).
    const hero = eHeroOrDefault(heroObj);
    const after = eGain(hero.level, hero.exp, expAward);
    const nextHero = eWithRevision(hero, { level: after[0], exp: after[1] });
    const state = eStateOrDefault(stateObj);
    const cooldowns = JSON.parse(JSON.stringify(state.group_available_at_ms));
    const cooled: string[] = [];
    if (expAward > 0) {
      for (let i = 0; i < t.group_ids.length; i++) {
        const g = t.group_ids[i];
        cooldowns[g] = Math.max(cooldowns[g] || 0, now0 + E_GROUP_COOLDOWN_MS);
        cooled.push(g);
      }
    }
    const nextState = eWithRevision(state, {
      open_ticket_id: state.open_ticket_id === ticketId ? "" : state.open_ticket_id, group_available_at_ms: cooldowns,
    });
    const receiptValue = {
      contract: E_RECEIPT_CONTRACT, contract_version: E_CONTRACT_VERSION, kind: "claim", idempotency_key: key,
      request_hash: hash, user_id: userId, gameplay_session_id: gameplaySessionId, ticket_id: ticketId, status: "applied",
      outcome: claim.outcome, kills_claimed: claim.kills, kills_accepted: claim.kills, hero_alive: claim.hero_alive,
      exp_awarded: expAward, level_before: hero.level, exp_before: hero.exp, level_after: after[0], exp_after: after[1],
      progression_revision: nextHero.revision, cooldown_groups: cooled,
      intent_first_seen_at_ms: intent === null ? -1 : intent.value.first_seen_at_ms, server_time_ms: now0,
    };
    const decidedIntent = intent === null
      ? eWrite(E_INTENT_COLLECTION, ticketId, userId, {
        contract: E_INTENT_CONTRACT, contract_version: E_CONTRACT_VERSION, revision: 0, ticket_id: ticketId,
        idempotency_key: key, request_hash: hash, claim: claim, first_seen_at_ms: now0,
        first_seen_session_id: gameplaySessionId, state: "DECIDED",
      }, "*")
      : eWrite(E_INTENT_COLLECTION, ticketId, userId, eWithRevision(intent.value, { state: "DECIDED" }), intent.version);
    const writes = [
      eWrite(E_RECEIPT_COLLECTION, key, userId, receiptValue, "*"),                                        // W1
      eWrite(E_CLAIM_COLLECTION, ticketId, userId, {
        contract: E_CLAIM_CONTRACT, contract_version: E_CONTRACT_VERSION, ticket_id: ticketId,
        idempotency_key: key, decided_at_ms: now0,
      }, "*"),                                                                                              // W2
      eWrite(E_TICKET_COLLECTION, ticketId, userId, eWithRevision(t, { status: "CLAIMED", resolved_at_ms: now0 }), ticket.version), // W3
      eWrite(E_STATE_COLLECTION, E_STATE_KEY, userId, nextState, stateObj === null ? "*" : stateObj.version), // W4
      eWrite(E_HERO_COLLECTION, E_HERO_KEY, userId, nextHero, heroObj === null ? "*" : heroObj.version),      // W5
      eSessionGuard(userId, current),                                                                         // W6
      decidedIntent,                                                                                          // W7
    ];
    if (!eCommit(logger, nk, "encounter_claim", writes)) continue;
    logger.info("vs01e claim user=%s ticket=%s outcome=%s kills=%d exp=%d level=%d->%d",
      userId, ticketId, claim.outcome, claim.kills, expAward, hero.level, after[0]);
    return JSON.stringify({ replayed: false, receipt: receiptValue, progression: eProgressionView(nextHero) });
  }
  throw guardError(nkruntime.Codes.ABORTED, "conflict_retry_exhausted");
}

function rpcEncounterAbandon(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, payload: string): string {
  const userId = guardRequireUser(ctx);
  const d = guardParsePayload(payload, ["gameplay_session_id", "idempotency_key", "ticket_id", "confirm"]);
  const gameplaySessionId = guardParseSessionId(d.gameplay_session_id);
  const key = eParseKey(d.idempotency_key);
  const ticketId = eParseTicketId(d.ticket_id);
  if (d.confirm !== true) throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "confirm_required");
  const hash = eAbandonHash(ticketId);
  const now0 = Date.now();
  let charged = false;
  for (let attempt = 0; attempt < E_MAX_ATTEMPTS; attempt++) {
    const snap = eRead(nk, userId, [[E_RECEIPT_COLLECTION, key], [E_TICKET_COLLECTION, ticketId], [E_INTENT_COLLECTION, ticketId],
      [E_STATE_COLLECTION, E_STATE_KEY], [E_HERO_COLLECTION, E_HERO_KEY],
      [E_RATE_COLLECTION, "encounter_begin"], [E_RATE_COLLECTION, "receipt_replay"]]);
    const current = requireActiveSession(trustProgress(snap.progress), gameplaySessionId);
    const heroObj = eGet(snap, E_HERO_COLLECTION, E_HERO_KEY);
    const receipt = eGet(snap, E_RECEIPT_COLLECTION, key);
    if (receipt !== null) {
      if (receipt.value.request_hash !== hash) throw guardError(nkruntime.Codes.INVALID_ARGUMENT, "idempotency_key_reused");
      if (!charged) { eCharge(ctx, logger, nk, userId, "receipt_replay", eGet(snap, E_RATE_COLLECTION, "receipt_replay"), now0); charged = true; }
      return JSON.stringify({ replayed: true, receipt: receipt.value, progression: eProgressionView(eHeroOrDefault(heroObj)) });
    }
    const ticket = eGet(snap, E_TICKET_COLLECTION, ticketId);
    if (ticket === null) throw guardError(nkruntime.Codes.NOT_FOUND, "ticket_not_found");
    const t = ticket.value;
    // A settled claim is never revoked (R-2).
    if (t.status === "CLAIMED") throw guardError(nkruntime.Codes.ALREADY_EXISTS, "ticket_already_claimed");
    if (t.status === "ABANDONED") throw guardError(nkruntime.Codes.FAILED_PRECONDITION, "ticket_abandoned");
    if (t.status === "EXPIRED") throw guardError(nkruntime.Codes.FAILED_PRECONDITION, "ticket_expired");
    const stateObj = eGet(snap, E_STATE_COLLECTION, E_STATE_KEY);
    if (!eIsUnresolved(t, now0)) {
      if (!eCommit(logger, nk, "encounter_expire", eExpireWrites(userId, ticket, stateObj, now0).concat([eSessionGuard(userId, current)]))) continue;
      throw guardError(nkruntime.Codes.FAILED_PRECONDITION, "ticket_expired");
    }
    // MC-2 Q1+F3: the existing encounter_begin quota; no age gate, no cooldown.
    if (!charged) { eCharge(ctx, logger, nk, userId, "encounter_begin", eGet(snap, E_RATE_COLLECTION, "encounter_begin"), now0); charged = true; }
    const intent = eGet(snap, E_INTENT_COLLECTION, ticketId);
    const hero = eHeroOrDefault(heroObj);
    const state = eStateOrDefault(stateObj);
    const receiptValue = {
      contract: E_RECEIPT_CONTRACT, contract_version: E_CONTRACT_VERSION, kind: "abandon", idempotency_key: key,
      request_hash: hash, user_id: userId, gameplay_session_id: gameplaySessionId, ticket_id: ticketId, status: "applied",
      outcome: null, kills_claimed: null, kills_accepted: null, hero_alive: null,
      exp_awarded: 0, level_before: hero.level, exp_before: hero.exp, level_after: hero.level, exp_after: hero.exp,
      progression_revision: hero.revision, cooldown_groups: [],
      intent_first_seen_at_ms: intent === null ? -1 : intent.value.first_seen_at_ms, server_time_ms: now0,
    };
    const writes = [
      eWrite(E_RECEIPT_COLLECTION, key, userId, receiptValue, "*"),
      eWrite(E_TICKET_COLLECTION, ticketId, userId, eWithRevision(t, { status: "ABANDONED", resolved_at_ms: now0 }), ticket.version),
      eWrite(E_STATE_COLLECTION, E_STATE_KEY, userId,
        eWithRevision(state, { open_ticket_id: state.open_ticket_id === ticketId ? "" : state.open_ticket_id }),
        stateObj === null ? "*" : stateObj.version),
      eSessionGuard(userId, current),
    ];
    if (intent !== null) {
      writes.push(eWrite(E_INTENT_COLLECTION, ticketId, userId, eWithRevision(intent.value, { state: "ABANDONED" }), intent.version));
    }
    if (!eCommit(logger, nk, "encounter_abandon", writes)) continue;
    logger.info("vs01e abandon user=%s ticket=%s intent=%s", userId, ticketId, intent === null ? "none" : "recorded");
    return JSON.stringify({ replayed: false, receipt: receiptValue, progression: eProgressionView(hero) });
  }
  throw guardError(nkruntime.Codes.ABORTED, "conflict_retry_exhausted");
}

function rpcProgressionGet(ctx: nkruntime.Context, logger: nkruntime.Logger, nk: nkruntime.Nakama, payload: string): string {
  const userId = guardRequireUser(ctx);
  const gameplaySessionId = guardParseSessionOnly(payload);
  const now0 = Date.now();
  const snap = eRead(nk, userId, [[E_STATE_COLLECTION, E_STATE_KEY], [E_HERO_COLLECTION, E_HERO_KEY], [E_RATE_COLLECTION, "receipt_replay"]]);
  requireActiveSession(trustProgress(snap.progress), gameplaySessionId);
  eCharge(ctx, logger, nk, userId, "receipt_replay", eGet(snap, E_RATE_COLLECTION, "receipt_replay"), now0);
  const state = eStateOrDefault(eGet(snap, E_STATE_COLLECTION, E_STATE_KEY));
  let unresolved: any = null;
  if (state.open_ticket_id !== "") {
    const t = eGet(eRead(nk, userId, [[E_TICKET_COLLECTION, state.open_ticket_id]]), E_TICKET_COLLECTION, state.open_ticket_id);
    if (t !== null && eIsUnresolved(t.value, now0)) unresolved = eTicketView(t.value);
  }
  return JSON.stringify({
    progression: eProgressionView(eHeroOrDefault(eGet(snap, E_HERO_COLLECTION, E_HERO_KEY))),
    unresolved_ticket: unresolved,
    group_available_at_ms: JSON.parse(JSON.stringify(state.group_available_at_ms)),
    server_time_ms: now0,
  });
}
