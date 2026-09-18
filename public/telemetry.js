import {easeTowards} from './movement.js';

// P1-07C — Mobile Movement Telemetry (diagnostic-only). Pure, DOM-free math/formatting for the
// real-device debug overlay (see Issue #21). This module never influences movement, prediction,
// reconciliation, camera, or any network control flow — it only reads values app.js already has
// and turns them into numbers/strings for display. movement.js itself is not modified; this file
// only imports easeTowards from it (read-only reuse of the existing delta-time smoothing math, not
// a new algorithm) to compute the FPS EMA.

// Prototype Parameters — diagnostic-only tunables, unrelated to any movement/joystick/reconciliation
// constant. Never conflate these with JOYSTICK_SEND_INTERVAL_MS, MAX_PREDICTION_LEAD, etc.
export const TELEMETRY_FPS_SMOOTHING_MS=500; // ~1s-ish EMA window, per Issue #21's guidance
export const TELEMETRY_OVERLAY_PATCH_INTERVAL_MS=100; // overlay DOM writes are throttled to this;
// FPS/lead/response metrics themselves are still computed every frame/response — only the actual
// DOM write is throttled, so the debug UI itself doesn't add measurable DOM load to the FPS it's
// trying to measure.

// Delta-time based FPS EMA, reusing movement.js's own easeTowards (frame-rate independent
// exponential smoothing) rather than inventing a second smoothing algorithm. `dt` in ms.
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
