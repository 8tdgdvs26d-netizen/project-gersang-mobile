// VS-01 WP01-H E3 LIVE tool: FS-K10 / AC-16 server-time evidence and verdict.
//
// Blueprint v0.1r2 §4 (REV-01, F-01): the VERDICT uses only server-recorded
// processing times (now0) against the server-recorded expires_at_ms. Client
// time is used ONLY to schedule requests near the deadline.
//
// Server evidence (E1 wp01e.ts, read-only verified):
//   claim receipt server_time_ms = now0 (:461), abandon receipt (:535),
//   intent first_seen_at_ms = now0 (:407, also on too_early / rate_limited
//   :430-436), expiry ticket resolved_at_ms = now0 (:293-295, first observer
//   only); unresolved iff intent_recorded || now0 < expires_at_ms (:280).
// Pure functions below are unit-tested offline (tests/unit/wp01h_e3_launcher.test.mjs).

export const TTL_MS = 900000;          // wp01e_rules.ts:25 (never changed by E3)
export const BIN_WINDOW_MS = 500;
export const BIN_MIN = 2;
export const BINS = ["A", "B", "C", "D"];

const isInt = (v) => Number.isSafeInteger(v);

// ---- scheduling aid (never used for a verdict) ------------------------------

// samples: [{send, recv, server}] (ms). Picks the minimum-RTT sample.
export function estimateOffset(samples) {
  const ok = samples.filter((s) => isInt(s.server) && s.recv >= s.send);
  if (!ok.length) return null;
  const best = ok.reduce((a, b) => (b.recv - b.send < a.recv - a.send ? b : a));
  const rtt = best.recv - best.send;
  return { offset: best.server - (best.send + best.recv) / 2, u: rtt / 2, rtt, n: ok.length };
}

// Server times returned by progression_get must never go backwards (IC-3).
export function serverTimeRegressed(samples) {
  for (let i = 1; i < samples.length; i++) if (samples[i].server < samples[i - 1].server) return true;
  return false;
}

// Client wall time at which to send so the request is processed near
// `targetServerMs` (aim only).
export function sendAtClientMs(targetServerMs, est) {
  return targetServerMs - est.offset - est.rtt / 2;
}

// ---- evidence of one critical request ---------------------------------------

// The server time of the ticket's ONE critical request (its first request),
// or null when the server left no record of it (IC-1).
export function criticalServerTime(t) {
  const r = (t.claim_receipts ?? []).find((x) => x.idempotency_key === t.critical_key)
    ?? (t.abandon_receipts ?? []).find((x) => x.idempotency_key === t.critical_key);
  if (r) return r.server_time_ms;
  if (t.status === "EXPIRED" && t.critical_was_first && isInt(t.resolved_at_ms)) return t.resolved_at_ms;
  return null;
}

// ---- TTL-1..6 ----------------------------------------------------------------

// t = { ticket_id, issued_at_ms, expires_at_ms, status, intent_recorded,
//       resolved_at_ms, intent: {ticket_id, first_seen_at_ms, state}|null,
//       claim_receipts: [...], abandon_receipts: [...], hero, critical_key,
//       critical_was_first, design_bin, lossy }
export function ticketChecks(t) {
  const fail = [], warn = [];
  const exp = t.expires_at_ms, intent = t.intent ?? null;
  const claims = t.claim_receipts ?? [], abandons = t.abandon_receipts ?? [];
  // TTL-1
  if (!isInt(t.issued_at_ms) || exp - t.issued_at_ms !== TTL_MS) fail.push(`TTL-1 expires-issued=${exp - t.issued_at_ms}`);
  // TTL-5 (one final state, at most one settlement)
  const settlements = claims.length + abandons.length;
  if (settlements > 1) fail.push(`TTL-5 ${settlements} settlement receipts`);
  if (!["OPEN", "CLAIMED", "EXPIRED", "ABANDONED"].includes(t.status)) fail.push(`TTL-5 unknown status ${t.status}`);
  if (t.status === "CLAIMED" && claims.length !== 1) fail.push("TTL-5 CLAIMED without exactly one claim receipt");
  if (t.status === "ABANDONED" && abandons.length !== 1) fail.push("TTL-5 ABANDONED without exactly one abandon receipt");
  if ((t.status === "EXPIRED" || t.status === "OPEN") && settlements !== 0) fail.push(`TTL-5 ${t.status} with a settlement receipt`);
  // TTL-2
  if (t.status === "CLAIMED" && claims.length === 1) {
    const r = claims[0];
    const before = r.server_time_ms < exp;
    const viaIntent = intent !== null && r.intent_first_seen_at_ms !== -1 && r.intent_first_seen_at_ms === intent.first_seen_at_ms
      && intent.first_seen_at_ms < exp && intent.ticket_id === t.ticket_id;
    if (!before && !viaIntent) fail.push("TTL-2 claim settled after expiry without a pre-expiry intent");
    if (r.ticket_id !== t.ticket_id || r.kind !== "claim" || r.status !== "applied") fail.push("TTL-2 claim receipt does not belong to the ticket");
    if (t.hero && (t.hero.level !== r.level_after || t.hero.exp !== r.exp_after)) fail.push("TTL-5 hero progression differs from the claim receipt");
  }
  // TTL-3
  if (t.status === "EXPIRED") {
    if (!isInt(t.resolved_at_ms) || t.resolved_at_ms < exp) fail.push("TTL-3 expired before expires_at_ms");
    if (intent !== null || t.intent_recorded) fail.push("TTL-3 expired although an intent was recorded");
  }
  // TTL-4 (F-01): intent alone is never evidence of a legal late abandon.
  if (t.status === "ABANDONED" && abandons.length === 1) {
    const r = abandons[0];
    const before = r.server_time_ms < exp;
    const late = intent !== null && r.intent_first_seen_at_ms !== -1                          // (a)
      && r.intent_first_seen_at_ms === intent.first_seen_at_ms                                  // (b)
      && intent.first_seen_at_ms < exp                                                          // (c)
      && intent.first_seen_at_ms <= r.server_time_ms                                            // (d)
      && intent.ticket_id === t.ticket_id && intent.state === "ABANDONED"                       // (e)
      && t.intent_recorded === true && t.resolved_at_ms === r.server_time_ms;                   // (f)
    if (!before && !late) fail.push("TTL-4 abandon after expiry without full (a)-(f) intent evidence");
    if (before && t.resolved_at_ms !== r.server_time_ms) fail.push("TTL-4 resolved_at_ms differs from the abandon receipt");
    if (claims.length) fail.push("TTL-4 abandoned ticket has a claim receipt");
    if (r.kind !== "abandon" || r.status !== "applied" || r.exp_awarded !== 0) fail.push("TTL-4 abandon receipt shape");
  }
  // TTL-6 (monotonic server times) -> IC-3, not FAIL (Blueprint §4).
  const times = [t.issued_at_ms];
  if (intent) times.push(intent.first_seen_at_ms);
  const end = claims[0]?.server_time_ms ?? abandons[0]?.server_time_ms ?? (t.status === "EXPIRED" ? t.resolved_at_ms : null);
  if (isInt(end)) times.push(end);
  for (let i = 1; i < times.length; i++) if (times[i] < times[i - 1]) warn.push("TTL-6 server times not monotonic");
  return { fail, warn };
}

// Coverage bin from SERVER evidence (not from the design intent).
export function serverBin(t) {
  if (t.design_bin === "D") return "D";
  const st = criticalServerTime(t);
  if (st === null) return null;
  const exp = t.expires_at_ms;
  const hadIntent = t.intent !== null && t.intent !== undefined && t.intent.first_seen_at_ms < exp;
  if (!hadIntent && st >= exp - BIN_WINDOW_MS && st < exp) return "A";
  if (!hadIntent && st >= exp && st <= exp + BIN_WINDOW_MS) return "B";
  if (hadIntent && st >= exp) return "C";
  return "outside";
}

// Round verdict: FAIL > INCONCLUSIVE > PASS.
export function roundVerdict(tickets, { serverTimeRegress = false, containerRestarted = false } = {}) {
  const fails = [], inconclusive = [], bins = { A: 0, B: 0, C: 0, D: 0 };
  for (const t of tickets) {
    const c = ticketChecks(t);
    for (const f of c.fail) fails.push(`${t.ticket_id}: ${f}`);
    if (c.warn.length) inconclusive.push(`IC-3 ${t.ticket_id}: ${c.warn.join("; ")}`);
    const bin = serverBin(t);
    if (bin === null) { inconclusive.push(`IC-1 ${t.ticket_id}: critical request left no server time`); continue; }
    if (t.lossy && (bin === "A" || bin === "B")) inconclusive.push(`IC-5 ${t.ticket_id}: lossy request inside bin ${bin}`);
    if (bin in bins) bins[bin] += 1;
  }
  for (const b of BINS) if (bins[b] < BIN_MIN) inconclusive.push(`IC-2 bin ${b}: ${bins[b]} < ${BIN_MIN}`);
  if (serverTimeRegress) inconclusive.push("IC-3 progression server_time_ms went backwards");
  if (containerRestarted) inconclusive.push("IC-4 nakama container restarted or node changed during the round");
  const verdict = fails.length ? "FAIL" : inconclusive.length ? "INCONCLUSIVE" : "PASS";
  return { verdict, fails, inconclusive, bins };
}
