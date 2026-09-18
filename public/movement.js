import {pointInRect,segmentIntersectsRect} from './worldgeometry.js';

// Pure, DOM-free movement/joystick/prediction math (P1-07A/P1-07B) — Client Input Layer only.
// Server remains the sole authoritative source of world position (see server.mjs's moveWorld());
// these functions only decide (a) what target to *ask* the server for, from the joystick's
// direction+magnitude, and (b) how to *predict* a continuous visual position while the joystick
// is held, bounded by the same collision/bounds rules as the server and by a hard lead cap —
// they never move the character themselves, never persist, and are never treated as truth: the
// prediction is always reconciled back toward the latest confirmed serverPosition.

// Prototype Parameters — tunable, not a final UX spec; expected to be re-tuned after real-device
// (iPhone) testing per P1-07A/P1-07B's acceptance gate.
export const JOYSTICK_RADIUS=52;
export const JOYSTICK_DEADZONE=10;
export const JOYSTICK_STEP_DISTANCE=18;
// 140ms, not 120ms: must stay above server.mjs's MOVEMENT_MIN_INTERVAL_MS=120 with a margin
// (20ms buffer), otherwise a client cadence at or below the server's own throttle window
// produces accepted-move / throttled-zero-move / accepted-move oscillation — authoritative
// position would then only advance roughly every 2 client sends (~every 200ms+), directly
// re-introducing the double-throttle stutter P1-07A exists to fix.
export const JOYSTICK_SEND_INTERVAL_MS=140;

// P1-07B — Continuous Visual Movement + Server Reconciliation. P1-07A's discrete
// serverPosition-snapshot + exponential-easing model produced visible "velocity pulsing": every
// ~140ms the server position jumps by a full JOYSTICK_STEP_DISTANCE, and two independent easing
// chains (character + camera) each re-accelerate to chase that jump, then decay until the next
// one — a sawtooth in perceived speed, worse on camera (120ms) than character (80ms). P1-07B
// replaces this with a client-side *predicted* position that advances continuously every frame
// while the joystick is held, capped at MAX_PREDICTION_LEAD ahead of the last confirmed
// serverPosition, and both the hero marker and the camera now render from this single continuous
// position (see app.js's tickMovementFrame) — removing the old CHARACTER_SMOOTHING_MS/
// CAMERA_SMOOTHING_MS constants entirely, since there is no longer a discrete jump to smooth.

// How far (px) the predicted position may lead the last confirmed serverPosition. Prediction
// self-caps at this distance and simply stops advancing (waits for the server to catch up) —
// this is normal, expected lead, not an error, and must never actively pull the prediction back.
export const MAX_PREDICTION_LEAD=36;
// Correction smoothing (ms) used only while actively reconciling (see reconciliationSmoothingMs)
// and the current divergence is still within MAX_PREDICTION_LEAD.
export const RECONCILE_SMOOTHING_MS=40;
// Correction smoothing (ms) used while actively reconciling and divergence is between
// MAX_PREDICTION_LEAD and RECONCILE_HARD_RESET_DISTANCE — same value as RECONCILE_SMOOTHING_MS
// today, kept as an independently tunable constant for real-device re-tuning.
export const RECONCILE_STRONG_SMOOTHING_MS=40;
// Beyond this divergence (px, 3x JOYSTICK_STEP_DISTANCE), easing would itself look like an odd
// slide across an unrelated distance — snap predicted position straight to serverPosition instead.
export const RECONCILE_HARD_RESET_DISTANCE=54;

// Raw pointer offset (dx,dy) from the joystick's fixed center, in px, mapped to a normalized
// direction + magnitude. Anything within the deadzone is treated as no input at all. Magnitude
// ramps 0→1 between the deadzone edge and the outer radius; distances beyond the radius clamp to
// magnitude 1 (direction keeps following the finger, speed does not increase further).
export function computeJoystickInput(dx,dy,radius=JOYSTICK_RADIUS,deadzone=JOYSTICK_DEADZONE){
  const distance=Math.hypot(dx,dy);
  if(distance<=deadzone)return{active:false,dirX:0,dirY:0,magnitude:0};
  const clamped=Math.min(distance,radius);
  const magnitude=Math.max(0,Math.min(1,(clamped-deadzone)/(radius-deadzone)));
  return{active:true,dirX:dx/distance,dirY:dy/distance,magnitude};
}

// Clamps a raw pointer offset to within the joystick's radius, purely for rendering the knob —
// the knob must never visually leave its base circle even when the finger drags further.
export function clampJoystickKnob(dx,dy,radius=JOYSTICK_RADIUS){
  const distance=Math.hypot(dx,dy);
  if(distance<=radius)return{x:dx,y:dy};
  const ratio=radius/distance;
  return{x:dx*ratio,y:dy*ratio};
}

// The next world/move target: a small step from the *last known server position* in the
// joystick's direction, scaled by magnitude — never from a client-predicted/extrapolated
// position. Returns null when there is no active input (nothing to send this tick).
export function computeJoystickTarget(serverPosition,input,stepDistance=JOYSTICK_STEP_DISTANCE){
  if(!input?.active)return null;
  return{x:serverPosition.x+input.dirX*input.magnitude*stepDistance,y:serverPosition.y+input.dirY*input.magnitude*stepDistance};
}

// Delta-time based exponential smoothing (frame-rate independent): eases `current` toward
// `target` by an amount that depends on elapsed real time `dt` (ms), not on how many frames have
// passed. Composable: applying this twice with dt1 then dt2 produces (up to floating-point
// precision) the same result as one application with dt1+dt2 — verified in tests.
export function easeTowards(current,target,dt,smoothingMs){
  if(smoothingMs<=0)return target;
  const factor=1-Math.exp(-dt/smoothingMs);
  return current+(target-current)*factor;
}

// Full Map is inspection-only: while active, movement intent must not drive the character.
export function isMovementAllowed(mapView){
  return mapView!=='full';
}

// Pure gating decision for whether a joystick tick should actually send a world/move command.
export function shouldSendJoystickMove(mapView,joystickInputActive){
  return isMovementAllowed(mapView)&&!!joystickInputActive;
}

// P1-07 Movement Failure Diagnostic Hotfix — maps a /api/commands/world/move REJECTED
// errorCode to a readable message, so a rejection is never silently swallowed by the UI.
// This is display-only: it does not change, retry, or interpret server behavior in any way.
// Root cause of the real-device "joystick responds but character never moves" report is NOT
// yet confirmed — this mapping only makes whatever the server actually returns visible.
const WORLD_MOVE_ERROR_MESSAGES={
  ERR_SESSION_REPLACED:'Session已被另一個登入取代，請重新整理頁面',
  ERR_INVALID_STATE:'目前狀態不能移動（例如旅行中）',
  ERR_BATTLE_SETTLEMENT_REQUIRED:'有戰鬥獎勵未處理，請先到戰鬥頁面結算',
  ERR_INVALID_WORLD_TARGET:'移動目標座標無效',
  ERR_IDEMPOTENCY_KEY_REQUIRED:'指令格式錯誤（缺少idempotency key）',
  ERR_COMMAND_CONFLICT:'指令衝突，請重試'
};

// Unknown/unmapped errorCode: return it as-is rather than a generic "unknown error" string, so
// the raw server errorCode always stays visible for diagnosis.
export function describeWorldMoveError(errorCode){
  return WORLD_MOVE_ERROR_MESSAGES[errorCode]||errorCode||'移動指令被拒絕（原因不明）';
}

// P1-07B — the predicted-position advance speed, derived from the existing joystick constants
// rather than a new independent tunable: JOYSTICK_STEP_DISTANCE px accepted roughly every
// JOYSTICK_SEND_INTERVAL_MS ms is the server's own long-run average accepted speed, so predicting
// at this exact derived velocity keeps the client's visual speed from drifting away from the
// server's true speed over a long hold, regardless of what either constant is tuned to later.
export function predictionVelocity(stepDistance=JOYSTICK_STEP_DISTANCE,sendIntervalMs=JOYSTICK_SEND_INTERVAL_MS){
  return stepDistance/sendIntervalMs;
}

// Mirrors server.mjs's segmentBlocked() escape-only semantics exactly (see moveWorld()): if the
// current point already sits inside a given inflated obstacle, that specific obstacle only blocks
// the step when the candidate is STILL inside it — a candidate that lands outside is a genuine
// escape and is allowed. Every other obstacle uses the normal swept-segment check. Not exported
// from worldgeometry.js (server.mjs's own copy of this glue isn't either), so this is kept as a
// thin duplicate over the shared pointInRect/segmentIntersectsRect primitives, not a rewritten
// rule — the actual geometry truth (obstacle rects, inflation radius, intersection math) is 100%
// shared and cannot drift from server.mjs.
export function isStepBlocked(x1,y1,x2,y2,inflatedObstacles){
  return inflatedObstacles.some(rect=>pointInRect(x1,y1,rect)?pointInRect(x2,y2,rect):segmentIntersectsRect(x1,y1,x2,y2,rect));
}

// Presentation-only prediction clamp: bounds first (same clamp shape as server.mjs's moveWorld()),
// then a swept collision check from `current` to the bounded candidate. Blocked → stays at
// `current` (no partial slide toward the obstacle), exactly mirroring the server's own
// all-or-nothing step semantics. This can only ever be at least as strict as the server, never
// looser — it never determines the real outcome, only how far the prediction is allowed to
// visually lead before the server's own response is the final word.
export function clampPredictedStep(current,candidate,bounds,inflatedObstacles){
  const boundedX=Math.max(bounds.min,Math.min(bounds.max,candidate.x));
  const boundedY=Math.max(bounds.min,Math.min(bounds.max,candidate.y));
  if(isStepBlocked(current.x,current.y,boundedX,boundedY,inflatedObstacles))return{x:current.x,y:current.y};
  return{x:boundedX,y:boundedY};
}

// One frame's worth of continuous predicted-position advance: moves `current` by the joystick's
// direction+magnitude at `velocity` px/ms over `dt` ms. Self-caps at `maxLead` px from
// `serverPosition` — a candidate that would lead by more than that simply freezes prediction in
// place for this frame (waits for the server to catch up), rather than being pulled back; this is
// normal expected lead, not an error. Returns `current` unchanged when there is no active input.
export function advancePredictedPosition(current,serverPosition,input,dt,velocity,maxLead){
  if(!input?.active)return current;
  const candidate={x:current.x+input.dirX*input.magnitude*velocity*dt,y:current.y+input.dirY*input.magnitude*velocity*dt};
  if(Math.hypot(candidate.x-serverPosition.x,candidate.y-serverPosition.y)>maxLead)return current;
  return candidate;
}

// P1-07B reconciliation banding: given the current predicted/server divergence, returns which
// easing smoothing constant to actively correct with, or `null` to signal an immediate hard reset
// (divergence too large for easing to look right). Reconciliation is only ever actively run by the
// caller for the specific triggers approved for P1-07B (REJECTED, a network/command exception, or
// a divergence that has grown past `maxLead` on its own) — a normal successful, non-colliding
// response never calls this at all, since normal lead within `maxLead` is expected, not an error.
export function reconciliationSmoothingMs(distance,maxLead=MAX_PREDICTION_LEAD,hardResetDistance=RECONCILE_HARD_RESET_DISTANCE,smoothingMs=RECONCILE_SMOOTHING_MS,strongSmoothingMs=RECONCILE_STRONG_SMOOTHING_MS){
  if(distance>hardResetDistance)return null;
  return distance>maxLead?strongSmoothingMs:smoothingMs;
}
