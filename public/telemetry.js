import {easeTowards} from './movement.js';

// P1-07C — Mobile Movement Telemetry (diagnostic-only). Pure, DOM-free math/formatting for the
// real-device debug overlay (see Issue #21). This module never influences movement, prediction,
// reconciliation, camera, or any network control flow — it only reads values app.js already has
// and turns them into numbers/strings for display. movement.js itself is not modified; this file
// only imports easeTowards from it (read-only reuse of the existing delta-time smoothing math, not
// a new algorithm) to compute the FPS EMA.
//
// P1-07 Root Cause Measurement Test — extends the same read-only pattern to observe whether
// MAX_PREDICTION_LEAD is actually the thing stopping forward advance on a real device. Every
// function below only reads values app.js's tickMovementFrame/sendWorldMove already compute (or
// values they compute twice, once before and once after the SAME unmodified movement branch runs,
// to observe its outcome) — none of it feeds back into predictedPosition, earnedPosition,
// reconciliation, or any movement/network decision. movement.js's constants
// (MAX_PREDICTION_LEAD/RECONCILE_HARD_RESET_DISTANCE/etc.) and algorithms are not modified or
// imported for control-flow purposes here — only reused, read-only, exactly as already approved.

// Prototype Parameters — diagnostic-only tunables, unrelated to any movement/joystick/reconciliation
// constant. Never conflate these with JOYSTICK_SEND_INTERVAL_MS, MAX_PREDICTION_LEAD, etc.
export const TELEMETRY_FPS_SMOOTHING_MS=500; // ~1s-ish EMA window, per Issue #21's guidance
export const TELEMETRY_OVERLAY_PATCH_INTERVAL_MS=100; // overlay DOM writes are throttled to this;
// FPS/lead/response metrics themselves are still computed every frame/response — only the actual
// DOM write is throttled, so the debug UI itself doesn't add measurable DOM load to the FPS it's
// trying to measure.
// How close (px) leadDistance must be to MAX_PREDICTION_LEAD to count as "at/near the cap"
// (leadCapHit) — a floating-point tolerance, per the Root Cause Measurement Test's explicit
// requirement, not a behavior threshold (nothing reacts to this; it is display/counting only).
export const TELEMETRY_LEAD_CAP_TOLERANCE_PX=0.5;
// Below this much forward (ahead-component) progress in one frame, capFrozenFrame treats the frame
// as having made "no forward progress" — a tiny floating-point-noise tolerance, not a distance a
// human could perceive, so a genuinely-advancing frame (even a slow one) is never miscounted as
// frozen.
export const TELEMETRY_NO_PROGRESS_EPSILON_PX=0.01;

// P1-07C Merge Gate review — the raw, uncapped elapsed time (ms) since the previous animation
// frame, measured independently of movement's own `dt` (which app.js's tickMovementFrame clamps
// to 100ms for smoothing/prediction purposes — a real 250ms rendering stall would otherwise be
// reported to telemetry as only ~100ms, understating a real stutter as ~10fps instead of ~4fps and
// defeating the whole point of using telemetry to tell rendering stalls apart from network gaps).
// Returns null on the very first frame (no previous timestamp yet) rather than a fabricated dt.
export function nextTelemetryFrameDelta(previousTimestamp,now){
  return previousTimestamp==null?null:now-previousTimestamp;
}

// Delta-time based FPS EMA, reusing movement.js's own easeTowards (frame-rate independent
// exponential smoothing) rather than inventing a second smoothing algorithm. `dt` in ms — must be
// the raw telemetry frame delta (see nextTelemetryFrameDelta), never movement's capped dt.
export function nextFpsEma(previousEma,dt,smoothingMs=TELEMETRY_FPS_SMOOTHING_MS){
  const instantFps=dt>0?1000/dt:(previousEma??60);
  if(previousEma==null)return instantFps;
  return easeTowards(previousEma,instantFps,dt,smoothingMs);
}

// Euclidean distance between the client's predicted position and the last confirmed authoritative
// serverPosition — display-only, never fed back into prediction/reconciliation.
export function predictionLeadDistance(predicted,server){
  return Math.hypot(predicted.x-server.x,predicted.y-server.y);
}

// Unified timing computation for all three /world/move completion paths (ACCEPTED, REJECTED, a
// thrown network/command exception) — the same function, called the same way, so RTT and response
// gap can never be computed inconsistently between them. `startedAt` must be the timestamp taken
// at the true start of the network command (see sendWorldMove), never at enqueue time, so queued/
// coalesced wait time is never counted as RTT.
export function nextMoveTiming(startedAt,completedAt,previousCompletedAt){
  return{
    rttMs:completedAt-startedAt,
    responseGapMs:previousCompletedAt==null?null:completedAt-previousCompletedAt,
    completedAt
  };
}

// Display formatting — pure string conversion, no logic that affects behavior.
export function formatMs(value){
  return value==null?'–':`${Math.round(value)}ms`;
}

export function formatFlag(value){
  return value==null?'–':(value?'YES':'no');
}

export function formatLeadReadout(lead,cap){
  return `${lead.toFixed(1)} / ${cap}px`;
}

// --- P1-07 Root Cause Measurement Test — cap-freeze observation (read-only) ---

// leadCapHit: is the current forward lead distance at/near MAX_PREDICTION_LEAD? Proximity-only —
// this alone does NOT mean the frame actually failed to advance (see isCapFrozenFrame for that);
// it is the simple "close to the cap" reading the overlay shows as "Lead: xx.x / 36". Independent
// of isCapFrozenFrame below (P4-04B2) — this stays a fixed-tolerance proximity gauge for its own
// "#telemetry-leadcaphit" overlay reading, never reused as the frozen-detection rule itself.
export function isNearLeadCap(leadDistance,maxLead,tolerancePx=TELEMETRY_LEAD_CAP_TOLERANCE_PX){
  return leadDistance>=maxLead-tolerancePx;
}

// P4-04B2 — capFrozenFrame: did THIS frame actually fail to make forward progress because
// movement.js's advancePredictedPosition would have exceeded maxLead? Previously this gated on
// isNearLeadCap's FIXED pixel tolerance (0.5px) against aheadBefore — a proximity proxy that can
// miss the real freeze equilibrium value entirely: at the current MOVE_SPEED_RATE/60fps, a
// continuously-held joystick freezes at aheadBefore≈49.3px (maxLead=50), which sits OUTSIDE the old
// 49.5px tolerance window, so the old rule reported "not frozen" for a frame that had genuinely made
// zero forward progress because of the cap (P4-04B1 Diagnostic, reproduced via the real production
// functions). Fixed by deriving the SAME predicate production actually applies
// (`aheadCandidate=(forward.x-serverPosition.x)*input.dirX+(forward.y-serverPosition.y)*input.dirY;
// stepped=aheadCandidate>maxLead?current:forward` in advancePredictedPosition) instead of a
// proximity heuristic: `forwardStepPx` is the exact forward-step contribution
// (`magnitude*velocity*dt`) that same frame's `integrateInputPosition` call already computed inside
// advancePredictedPosition — projecting a step of that magnitude onto its own unit direction always
// contributes exactly `forwardStepPx` to the ahead component, so `aheadBefore+forwardStepPx` is
// mathematically identical to production's own `aheadCandidate`, not a re-derived approximation —
// avoiding two independent definitions of "frozen" that could drift apart again. The `madeProgress`
// outcome check is unchanged (aheadAfter/aheadBefore before/after the SAME unmodified branch ran) —
// still the ultimate ground truth; `wouldExceedCap` merely replaces the old proximity pre-check with
// production's own exact rule. Diagnostic-only: this module never feeds back into
// predictedPosition/earnedPosition/reconciliation/network decisions (see this file's own header).
export function isCapFrozenFrame({active,aheadBefore,aheadAfter,maxLead,forwardStepPx,progressEpsilonPx=TELEMETRY_NO_PROGRESS_EPSILON_PX}){
  if(!active||aheadBefore==null||aheadAfter==null||forwardStepPx==null)return false;
  const wouldExceedCap=(aheadBefore+forwardStepPx)>maxLead;
  const madeProgress=(aheadAfter-aheadBefore)>progressEpsilonPx;
  return wouldExceedCap&&!madeProgress;
}

// Running cap-frozen streak duration (ms): accumulates while frozen, resets the instant a frame is
// no longer frozen. Read every patch by the overlay as "Frozen current" — a purely additive counter,
// never read by movement/reconciliation.
export function nextCapFrozenStreakMs(currentStreakMs,isFrozen,dt){
  return isFrozen?currentStreakMs+dt:0;
}

// Time-based cap-frozen ratio over the whole active-movement session so far (preferred over a
// frame-count ratio per the Root Cause Measurement Test's explicit preference). 0 when there has
// been no active-movement time yet, rather than NaN/Infinity.
export function capFrozenRatio(totalFrozenMs,totalActiveMs){
  return totalActiveMs>0?totalFrozenMs/totalActiveMs:0;
}

export function formatPercent(ratio){
  return ratio==null?'–':`${(ratio*100).toFixed(1)}%`;
}

export function formatPx(value){
  return value==null?'–':`${value.toFixed(1)}px`;
}

export function formatCount(value){
  return value==null?'–':String(value);
}

// --- P4-04B2 — Recent Movement Anomaly retention (read-only, diagnostic-only) ---
//
// Charlie cannot reasonably screenshot a 450-700ms freeze event while simultaneously holding the
// joystick — by the time a real-device stutter is noticed and a screenshot taken, the event may
// already have ended. This retains the LATEST freeze event's peak readings for a short window after
// it ends, so a screenshot taken shortly afterward still shows the evidence. Memory-only: app.js
// holds the single retained event in a plain module-level variable, cleared implicitly on reload —
// no DB, no server persistence, no upload, no history list (only the most recent event, never a
// log). Every field is an EXISTING telemetry reading, peak-held across the event's duration — no
// new networking instrumentation. Hard-reset count is deliberately NOT included here: it is set by
// a structurally different tickMovementFrame branch (predictionSuspended) that cannot run in the
// same frame as the cap-freeze branch this event tracks, so attributing a hard-reset delta to a
// specific freeze event would fabricate a correlation the current per-frame branching cannot
// actually establish — the existing cumulative `#telemetry-hardresets` overlay reading already
// covers it as session-wide (not per-event) evidence.

export const RECENT_EVENT_RETENTION_MS=5000;

// Should the just-ended freeze streak (nextCapFrozenStreakMs having just reset to 0) be committed as
// the new retained event? Excludes a streak that never actually accumulated any duration (a single
// non-frozen frame is not an event).
export function shouldCommitFreezeEvent(previousStreakMs,nextStreakMs){
  return previousStreakMs>0&&nextStreakMs===0;
}

// Builds the retained snapshot at the moment a freeze streak ends, from peak values the caller
// already tracks frame-to-frame (never a new independent metric).
export function buildRecentEvent({freezeDurationMs,peakLeadPx,peakRttMs,peakGapMs,maxInFlight,now}){
  return{freezeDurationMs,peakLeadPx,peakRttMs,peakGapMs,maxInFlight,recordedAt:now};
}

// Is a retained event still worth showing, or has it aged out past RECENT_EVENT_RETENTION_MS? A
// missing event is treated as stale (nothing to show).
export function isRecentEventStale(event,now,retentionMs=RECENT_EVENT_RETENTION_MS){
  return !event||(now-event.recordedAt)>retentionMs;
}

// "N.Ns ago" — the overlay's own age readout for a still-fresh retained event.
export function formatEventAge(event,now){
  return`${((now-event.recordedAt)/1000).toFixed(1)}s ago`;
}
