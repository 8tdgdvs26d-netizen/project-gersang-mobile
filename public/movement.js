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

// P1-07D — Latency-Decoupled Movement (Issue #23). Prototype Parameters, tunable, pending real-
// device (iPhone) validation — none of these are Canonical balance numbers.
//
// Bounded catch-up window (ms) shared by both the server's elapsed-time movement allowance
// (server.mjs's moveWorld()) and the client's earned-target cap (clampEarnedTarget below). This is
// a single shared constant specifically so client and server can never drift on what "a very long
// gap" means. 1000ms was chosen against P1-07C real-device telemetry showing observed RTT roughly
// 389-716ms — giving ~40% margin above the observed maximum (a judgment call, not something the
// sample data proves by itself; see the Architecture Plan's 800/1000/1500ms comparison, v4.4). This
// same constant also bounds the worst-case single-command "idle credit" burst a non-honest client
// could obtain after a long idle gap (see server.mjs's moveWorld() comment for the full, accurate
// invariant — this design does NOT prove actual joystick-held duration, only a bounded per-command
// displacement).
export const MOVE_CATCHUP_CAP_MS=1000;

// Direction-change detection threshold, expressed as cos(15°) so a dot product of two unit vectors
// can be compared directly (no acos needed). Ordinary touch/joystick tremor is expected to stay
// well under this; an intentional turn (45°/90°/180°) is far beyond it. Used by
// nextGenerationAnchor, compared against a persisted ANCHOR direction (not the previous frame) so a
// gradual, cumulative turn is still eventually detected.
export const DIRECTION_CHANGE_COS_THRESHOLD=Math.cos(15*Math.PI/180);

// Magnitude-change detection threshold (absolute delta, 0-1 fraction). 0.15 mirrors
// DIRECTION_CHANGE_COS_THRESHOLD's 15° only as a mnemonic — the two are not mathematically
// equivalent (an angle vs. a magnitude fraction). Used the same anchor-relative way as direction, so
// a gradual magnitude drift (not just an abrupt one) is still eventually detected.
export const MAGNITUDE_CHANGE_THRESHOLD=0.15;

// Below this divergence (px), idleSettlePosition treats predicted/server as already-aligned and
// snaps the negligible remainder exactly, rather than letting easeTowards's asymptotic approach
// leave a permanent sub-pixel residual forever.
export const IDLE_SETTLE_EPSILON_PX=0.05;

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

// P1-07D — the single named rate both client and server bound movement by (server.mjs imports this
// directly, see moveWorld()'s allowance calculation). Same value as predictionVelocity() — named
// separately because "MOVE_SPEED_RATE" is what the Architecture Plan's displacement invariant calls
// it, and because a shared named export (not each side computing predictionVelocity() the same way
// by coincidence) is what actually guarantees client/server can never drift on this number.
export const MOVE_SPEED_RATE=predictionVelocity();

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

// P1-07D — pure, single-purpose: exactly one frame's worth of input-integrated displacement. No
// lead cap, no bleed, no correction of any kind. This is the ONLY function earnedPosition (the
// request-truth accumulator, see nextEarnedPosition) may use for its integration step —
// request-truth integration must never share a helper whose default behavior also applies a
// presentation-only correction term (lead freeze, lateral bleed), even if that correction is
// disabled via a parameter: v4 of this Architecture Plan contaminated earnedPosition exactly this
// way (advancePredictedPosition's lateralBleedPerMs default still ran even with maxLead=Infinity),
// which is why this exists as its own function rather than a degenerate call into the other one.
export function integrateInputPosition(position,input,dt,velocity){
  if(!input?.active)return position;
  return{x:position.x+input.dirX*input.magnitude*velocity*dt,y:position.y+input.dirY*input.magnitude*velocity*dt};
}

// One frame's worth of continuous predicted-position advance (presentation-only): moves `current`
// by the joystick's direction+magnitude at `velocity` px/ms over `dt` ms, via integrateInputPosition
// above, then applies two presentation-only corrections that never feed back into earnedPosition:
//
// 1. Forward freeze: self-caps at `maxLead` px *ahead of serverPosition along the current input
//    direction* — a directional projection, not raw Euclidean distance, so a predicted position
//    that is legitimately BEHIND serverPosition (e.g. right after a large elapsed-time-scaled
//    server grant, P1-07D) is never mistaken for "too far ahead" and frozen. A candidate that would
//    lead by more than maxLead simply freezes prediction in place for this frame (waits for the
//    server to catch up); this is normal expected lead, not an error.
// 2. Lateral bleed-off: continuously eases any divergence PERPENDICULAR to the current input
//    direction back toward zero, at up to `lateralBleedPerMs` px/ms — bounded, active, and
//    independent of the forward step, so a stale lateral offset (e.g. left over from a direction
//    change) cannot sit unresolved indefinitely (P1-07D v4 Blocker — see catchUpDebt's lateral
//    budget, which this bleed-off keeps from being exploited as a permanent shield).
export function advancePredictedPosition(current,serverPosition,input,dt,velocity,maxLead,lateralBleedPerMs=velocity){
  if(!input?.active)return current;
  const forward=integrateInputPosition(current,input,dt,velocity);
  const aheadCandidate=(forward.x-serverPosition.x)*input.dirX+(forward.y-serverPosition.y)*input.dirY;
  const stepped=aheadCandidate>maxLead?current:forward;
  const dx=stepped.x-serverPosition.x,dy=stepped.y-serverPosition.y;
  const ahead=dx*input.dirX+dy*input.dirY;
  const lateralX=dx-ahead*input.dirX,lateralY=dy-ahead*input.dirY;
  const lateralMag=Math.hypot(lateralX,lateralY);
  if(lateralMag<=0)return stepped;
  const bleed=Math.min(lateralMag,lateralBleedPerMs*dt);
  const ratio=(lateralMag-bleed)/lateralMag;
  return{x:serverPosition.x+ahead*input.dirX+lateralX*ratio,y:serverPosition.y+ahead*input.dirY+lateralY*ratio};
}

// P1-07D — signed divergence decomposition between predicted and server position, relative to the
// current input direction: `ahead` is positive when predicted leads server along that direction
// (the classic, pre-existing "too eager" case), negative when server has legitimately gotten ahead
// of predicted (e.g. a large elapsed-time-scaled grant) — negative ahead is never dangerous,
// however large, since it simply means the server caught up. `lateral` is the magnitude
// perpendicular to that direction. Falls back to plain Euclidean distance (as `ahead`, with
// `lateral=0`) when there is no active input direction to project onto.
export function movementDivergence(predicted,server,input){
  const dx=predicted.x-server.x,dy=predicted.y-server.y;
  if(!input?.active)return{ahead:Math.hypot(dx,dy),lateral:0};
  const ahead=dx*input.dirX+dy*input.dirY;
  const lateral=Math.sqrt(Math.max(0,dx*dx+dy*dy-ahead*ahead));
  return{ahead,lateral};
}

// P1-07D — establishes/refreshes catchUpDebt: how much of a LATERAL safety budget (see
// movementDivergence) is currently owed because the server has legitimately gotten ahead of
// predicted along the intent direction the grant was earned under. Only the non-negative
// ahead-projected component is credited — never any lateral component the grant happened to also
// carry — so a grant that mixes a legitimate ahead component with an unrelated lateral one can
// never have that lateral part "blessed" as if it were catch-up debt (v4.3→v4.4 cleanup, with a
// concrete counter-example in the test suite). Returns 0 when there is no intent direction to
// project onto (e.g. the grant landed while idle) — nothing to credit.
export function catchUpDebtAfterGrant(predictedBeforeGrant,newServerPosition,intentDirection){
  if(!intentDirection)return 0;
  const dx=newServerPosition.x-predictedBeforeGrant.x,dy=newServerPosition.y-predictedBeforeGrant.y;
  const serverAhead=dx*intentDirection.dirX+dy*intentDirection.dirY;
  return Math.max(0,serverAhead);
}

// P1-07D — catchUpDebt's decay: cleared to 0 the moment prediction has caught back up
// (distance<=maxLead — nothing left to shield) or when the caller says it must be cleared outright
// (predictionSuspended, or no active input — see app.js's tickMovementFrame). Otherwise holds
// steady until the next grant refreshes it via catchUpDebtAfterGrant — see that function's header
// for why time-based decay of the BUDGET itself (rather than the actual divergence, which
// advancePredictedPosition's lateral bleed-off handles) was rejected: it raced against a divergence
// that wasn't shrinking and produced near-instant false positives.
export function nextCatchUpDebt(currentDebt,distance,maxLead,shouldClear){
  if(shouldClear||distance<=maxLead)return 0;
  return currentDebt;
}

// P1-07D — the request-truth target: either earnedPosition itself, or a point on the closed segment
// [serverPosition, earnedPosition] scaled down so the requested distance never exceeds
// velocity*catchUpCapMs — i.e. target is never extrapolated beyond earnedPosition (the integrated
// endpoint), only ever shortened toward serverPosition.
export function clampEarnedTarget(earnedPosition,serverPosition,catchUpCapMs,velocity){
  const dx=earnedPosition.x-serverPosition.x,dy=earnedPosition.y-serverPosition.y,distance=Math.hypot(dx,dy);
  const cap=velocity*catchUpCapMs;
  if(distance<=cap)return earnedPosition;
  const ratio=cap/distance;
  return{x:serverPosition.x+dx*ratio,y:serverPosition.y+dy*ratio};
}

// P1-07D — earnedPosition's per-frame update: the request-truth accumulator that clampEarnedTarget
// reads from. Deliberately independent of character state (IN_CITY vs IN_WORLD) — the server itself
// accepts world/move commands from either state (see server.mjs's moveWorld()), and the very first
// IN_CITY→IN_WORLD transition is driven by the first ACCEPTED non-zero displacement, so
// earnedPosition must be free to accumulate a genuine non-zero target while still IN_CITY, or that
// transition can never happen (P1-07D v4.2 Blocker 1). `shouldReset` is the caller's decision
// (predictionResetPending or predictionSuspended — never merely "not yet IN_WORLD").
export function nextEarnedPosition(earnedPosition,serverPosition,input,wasActiveLastFrame,dt,velocity,shouldReset){
  if(shouldReset)return{...serverPosition};
  if(!input?.active)return earnedPosition;
  const base=wasActiveLastFrame?earnedPosition:{...serverPosition};
  return integrateInputPosition(base,input,dt,velocity);
}

// P1-07D — idle/no-active-intent presentation reconciliation (v4.2 Blocker 3): with no direction to
// protect via ahead/lateral decomposition, ANY leftover divergence above `epsilon` eases smoothly
// toward server truth — never hard-resets (Infinity hard-reset distance passed to
// reconciliationSmoothingMs), even for a large stale-accepted grant landing after release, so a
// post-release/idle correction never looks like a snap. Settles to an exact match once within
// epsilon, avoiding easeTowards's asymptotic approach leaving a permanent sub-pixel residual.
export function idleSettlePosition(predicted,server,dt,epsilon=IDLE_SETTLE_EPSILON_PX){
  const distance=Math.hypot(predicted.x-server.x,predicted.y-server.y);
  if(distance<=epsilon)return{...server};
  const smoothingMs=reconciliationSmoothingMs(distance,MAX_PREDICTION_LEAD,Infinity);
  return{x:easeTowards(predicted.x,server.x,dt,smoothingMs),y:easeTowards(predicted.y,server.y,dt,smoothingMs)};
}

// P1-07D — generation anchor: compares the CURRENT input against a persisted ANCHOR (not the
// previous frame), on both direction (dot product vs. DIRECTION_CHANGE_COS_THRESHOLD) and magnitude
// (absolute delta vs. MAGNITUDE_CHANGE_THRESHOLD) — comparing only consecutive frames can never
// detect a gradual, cumulative drift (many small sub-threshold per-frame deltas that add up to a
// large total change); comparing against a fixed anchor always eventually catches it. Either axis
// exceeding its own threshold bumps, and resets BOTH anchor components to the current input. A
// press/release transition always bumps. Returns {bump,anchor} — the caller threads `anchor` back
// in as `anchorInput` next frame.
export function nextGenerationAnchor(anchorInput,nextInput,cosThreshold=DIRECTION_CHANGE_COS_THRESHOLD,magnitudeThreshold=MAGNITUDE_CHANGE_THRESHOLD){
  const anchorActive=!!anchorInput?.active,nextActive=!!nextInput?.active;
  if(anchorActive!==nextActive)return{bump:true,anchor:nextActive?{...nextInput}:null};
  if(!nextActive)return{bump:false,anchor:null};
  const dot=anchorInput.dirX*nextInput.dirX+anchorInput.dirY*nextInput.dirY;
  const directionChanged=dot<cosThreshold;
  const magnitudeChanged=Math.abs(nextInput.magnitude-anchorInput.magnitude)>magnitudeThreshold;
  if(directionChanged||magnitudeChanged)return{bump:true,anchor:{...nextInput}};
  return{bump:false,anchor:anchorInput};
}

// P1-07D — wraps a network-call function so it is skipped entirely (never invoked) when the
// generation bound to this call no longer matches the live one at the moment of actual invocation.
// Used by app.js's sendWorldMove so a pending target that was queued (coalesced) under one
// generation, but only actually dequeued after that generation has gone stale (release, or a
// meaningful direction/magnitude change — see nextGenerationAnchor), never reaches the server at
// all. Exported standalone — production and tests call this exact function, never a hand-duplicated
// copy of the same check (v4.3→v4.4 Test Implementation Note).
export function guardStaleGeneration(networkCall,getCurrentGeneration){
  return async({generation,...payload})=>{
    if(generation!==getCurrentGeneration())return{dropped:true};
    const result=await networkCall(payload);
    return{dropped:false,result};
  };
}

// P1-07B reconciliation banding: given the current predicted/server divergence, returns which
// easing smoothing constant to actively correct with, or `null` to signal an immediate hard reset
// (divergence too large for easing to look right). Reconciliation is only ever actively run by the
// caller for the specific triggers approved for P1-07B (REJECTED, a network/command exception, an
// ACCEPTED response with collided:true, or a divergence that has grown past `maxLead` on its own)
// — a normal successful, non-colliding response never calls this at all, since normal lead within
// `maxLead` is expected, not an error.
export function reconciliationSmoothingMs(distance,maxLead=MAX_PREDICTION_LEAD,hardResetDistance=RECONCILE_HARD_RESET_DISTANCE,smoothingMs=RECONCILE_SMOOTHING_MS,strongSmoothingMs=RECONCILE_STRONG_SMOOTHING_MS){
  if(distance>hardResetDistance)return null;
  return distance>maxLead?strongSmoothingMs:smoothingMs;
}

// P1-07B Merge Gate review — whether an ACCEPTED /world/move response should suspend prediction
// (stop it advancing further until reconciliation pulls it back in line). Client prediction sweeps
// in small per-frame steps while server.mjs's moveWorld() sweeps in one shot from the authoritative
// serverPosition to the requested target; on a fast turn right against an obstacle these two sweeps
// can briefly disagree, so collided:true must suspend exactly like REJECTED/an exception does.
// A normal, non-colliding ACCEPTED response must resume prediction, not stay suspended — that was
// the round-1 forward/backward pulsing bug this whole reconciliation design exists to avoid.
export function shouldSuspendAfterAccepted(response){
  return !!response?.collided;
}
