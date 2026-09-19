import test from 'node:test';
import assert from 'node:assert/strict';
import {
  computeJoystickInput,
  clampJoystickKnob,
  computeJoystickTarget,
  easeTowards,
  isMovementAllowed,
  shouldSendJoystickMove,
  describeWorldMoveError,
  predictionVelocity,
  isStepBlocked,
  clampPredictedStep,
  advancePredictedPosition,
  reconciliationSmoothingMs,
  shouldSuspendAfterAccepted,
  JOYSTICK_RADIUS,
  JOYSTICK_DEADZONE,
  JOYSTICK_STEP_DISTANCE,
  JOYSTICK_SEND_INTERVAL_MS,
  MAX_PREDICTION_LEAD,
  RECONCILE_SMOOTHING_MS,
  RECONCILE_STRONG_SMOOTHING_MS,
  RECONCILE_HARD_RESET_DISTANCE,
  MOVE_CATCHUP_CAP_MS,
  MOVE_SPEED_RATE,
  DIRECTION_CHANGE_COS_THRESHOLD,
  MAGNITUDE_CHANGE_THRESHOLD,
  IDLE_SETTLE_EPSILON_PX,
  integrateInputPosition,
  movementDivergence,
  catchUpDebtAfterGrant,
  nextCatchUpDebt,
  clampEarnedTarget,
  nextEarnedPosition,
  idleSettlePosition,
  nextGenerationAnchor,
  guardStaleGeneration,
  applyMovementIntent
} from '../public/movement.js';
import {createCoalescingSender} from '../public/asyncqueue.js';
import {WORLD_BOUNDS,PLAYER_COLLISION_RADIUS,OBSTACLES,inflateRect,pointInRect} from '../public/worldgeometry.js';

// --- Client/server throttle timing: must never oscillate against each other ---

test("JOYSTICK_SEND_INTERVAL_MS stays safely above server.mjs's MOVEMENT_MIN_INTERVAL_MS (120ms) with a margin, so a joystick held at a steady cadence never lands inside the server's own throttle window — a client interval at or below the server's would alternate accepted-move / throttled-zero-move / accepted-move, only advancing the authoritative position roughly every second send and re-introducing the double-throttle stutter this feature exists to fix. (server.mjs's constant isn't exported/importable here, so this value is kept in sync manually — see server.mjs's moveWorld() section.)",()=>{
  const SERVER_MOVEMENT_MIN_INTERVAL_MS=120;
  assert.ok(JOYSTICK_SEND_INTERVAL_MS>SERVER_MOVEMENT_MIN_INTERVAL_MS,`expected JOYSTICK_SEND_INTERVAL_MS (${JOYSTICK_SEND_INTERVAL_MS}) to exceed the server's MOVEMENT_MIN_INTERVAL_MS (${SERVER_MOVEMENT_MIN_INTERVAL_MS})`);
  assert.equal(JOYSTICK_SEND_INTERVAL_MS,140,'locks the currently-approved 140ms value (120ms server minimum + 20ms buffer)');
});

// --- computeJoystickInput: deadzone / magnitude / direction ---

test('computeJoystickInput: within the deadzone is treated as no input at all',()=>{
  const result=computeJoystickInput(5,0,52,10);
  assert.deepEqual(result,{active:false,dirX:0,dirY:0,magnitude:0});
});

test('computeJoystickInput: exactly at the deadzone edge is still inactive (inclusive boundary)',()=>{
  const result=computeJoystickInput(10,0,52,10);
  assert.equal(result.active,false);
  assert.equal(result.magnitude,0);
});

test('computeJoystickInput: a zero-length vector never divides by zero and stays inactive',()=>{
  const result=computeJoystickInput(0,0,52,10);
  assert.deepEqual(result,{active:false,dirX:0,dirY:0,magnitude:0});
});

test('computeJoystickInput: magnitude ramps linearly from 0 at the deadzone edge to 1 at the outer radius',()=>{
  const radius=52,deadzone=10;
  const midpoint=computeJoystickInput((radius+deadzone)/2,0,radius,deadzone);
  assert.equal(midpoint.active,true);
  assert.ok(Math.abs(midpoint.magnitude-0.5)<1e-9,`expected magnitude~0.5, got ${midpoint.magnitude}`);
});

test('computeJoystickInput: distance at or beyond the outer radius clamps magnitude to exactly 1',()=>{
  const atRadius=computeJoystickInput(JOYSTICK_RADIUS,0,JOYSTICK_RADIUS,JOYSTICK_DEADZONE);
  assert.equal(atRadius.magnitude,1);
  const beyondRadius=computeJoystickInput(JOYSTICK_RADIUS*3,0,JOYSTICK_RADIUS,JOYSTICK_DEADZONE);
  assert.equal(beyondRadius.magnitude,1);
});

test('computeJoystickInput: direction is a correct unit vector regardless of magnitude clamping',()=>{
  const right=computeJoystickInput(100,0,52,10);
  assert.ok(Math.abs(right.dirX-1)<1e-9);
  assert.ok(Math.abs(right.dirY)<1e-9);
  const up=computeJoystickInput(0,-52,52,10);
  assert.ok(Math.abs(up.dirY-(-1))<1e-9);
  assert.ok(Math.abs(up.dirX)<1e-9);
  const diagonal=computeJoystickInput(30,40,52,10); // 3-4-5 triangle, distance=50
  assert.ok(Math.abs(diagonal.dirX-0.6)<1e-9);
  assert.ok(Math.abs(diagonal.dirY-0.8)<1e-9);
});

// --- clampJoystickKnob: rendering-only clamp ---

test('clampJoystickKnob: an offset within the radius is returned unchanged',()=>{
  assert.deepEqual(clampJoystickKnob(10,10,52),{x:10,y:10});
});

test('clampJoystickKnob: an offset beyond the radius is clamped to exactly the radius, same direction',()=>{
  const clamped=clampJoystickKnob(100,0,52);
  assert.ok(Math.abs(clamped.x-52)<1e-9);
  assert.ok(Math.abs(clamped.y)<1e-9);
  const diagonalClamped=clampJoystickKnob(300,400,50); // 3-4-5 triangle far beyond radius 50
  assert.ok(Math.abs(diagonalClamped.x-30)<1e-9);
  assert.ok(Math.abs(diagonalClamped.y-40)<1e-9);
});

test('clampJoystickKnob: a zero vector stays zero',()=>{
  assert.deepEqual(clampJoystickKnob(0,0,52),{x:0,y:0});
});

// --- computeJoystickTarget: never predicts past the server, always a small step from it ---

test('computeJoystickTarget: inactive input sends nothing (returns null)',()=>{
  assert.equal(computeJoystickTarget({x:100,y:100},{active:false,dirX:0,dirY:0,magnitude:0},18),null);
});

test('computeJoystickTarget: full-magnitude input steps exactly stepDistance from the server position, in the input direction',()=>{
  const target=computeJoystickTarget({x:100,y:100},{active:true,dirX:1,dirY:0,magnitude:1},18);
  assert.deepEqual(target,{x:118,y:100});
});

test('computeJoystickTarget: half-magnitude input steps half the distance',()=>{
  const target=computeJoystickTarget({x:100,y:100},{active:true,dirX:0,dirY:1,magnitude:0.5},18);
  assert.deepEqual(target,{x:100,y:109});
});

test('computeJoystickTarget: is always computed from the given serverPosition, never an independent/predicted position',()=>{
  const t1=computeJoystickTarget({x:0,y:0},{active:true,dirX:1,dirY:0,magnitude:1},18);
  const t2=computeJoystickTarget({x:500,y:500},{active:true,dirX:1,dirY:0,magnitude:1},18);
  assert.deepEqual(t1,{x:18,y:0});
  assert.deepEqual(t2,{x:518,y:500});
});

// --- easeTowards: delta-time based, frame-rate independent ---

test('easeTowards: zero elapsed time produces no change at all',()=>{
  assert.equal(easeTowards(100,200,0,80),100);
});

test('easeTowards: a very large elapsed time converges (almost) exactly onto the target',()=>{
  const result=easeTowards(0,1000,100000,80);
  assert.ok(Math.abs(result-1000)<1e-6,`expected ~1000, got ${result}`);
});

test('easeTowards: smoothingMs<=0 snaps immediately to the target (no smoothing at all)',()=>{
  assert.equal(easeTowards(0,1000,16,0),1000);
  assert.equal(easeTowards(0,1000,16,-5),1000);
});

test('easeTowards: is frame-rate independent — two small steps (dt1 then dt2) match one big step (dt1+dt2) within floating-point precision',()=>{
  const current=0,target=1000,smoothingMs=80;
  const afterTwoSteps=easeTowards(easeTowards(current,target,7,smoothingMs),target,9,smoothingMs);
  const afterOneStep=easeTowards(current,target,16,smoothingMs);
  assert.ok(Math.abs(afterTwoSteps-afterOneStep)<1e-9,`expected composable results, got ${afterTwoSteps} vs ${afterOneStep}`);
});

test('easeTowards: the same composability property holds for many small steps summing to the same total dt',()=>{
  const target=500,smoothingMs=120;
  let manySteps=100;
  for(let i=0;i<50;i++)manySteps=easeTowards(manySteps,target,2,smoothingMs); // 50 steps of 2ms = 100ms
  const oneStep=easeTowards(100,target,100,smoothingMs);
  assert.ok(Math.abs(manySteps-oneStep)<1e-6,`expected ~${oneStep}, got ${manySteps}`);
});

// --- isMovementAllowed / shouldSendJoystickMove: Full Map is inspection-only ---

test('isMovementAllowed: follow view allows movement, full map does not',()=>{
  assert.equal(isMovementAllowed('follow'),true);
  assert.equal(isMovementAllowed('full'),false);
});

test('isMovementAllowed: any non-"full" value (including undefined) defaults to allowed',()=>{
  assert.equal(isMovementAllowed(undefined),true);
  assert.equal(isMovementAllowed('anything-else'),true);
});

test('shouldSendJoystickMove: full map blocks sending even when the joystick itself is actively pushed',()=>{
  assert.equal(shouldSendJoystickMove('full',true),false);
});

test('shouldSendJoystickMove: follow view only sends when the joystick input is actually active',()=>{
  assert.equal(shouldSendJoystickMove('follow',true),true);
  assert.equal(shouldSendJoystickMove('follow',false),false);
});

// --- describeWorldMoveError (P1-07 Movement Failure Diagnostic Hotfix) ---
// Display-only mapping so a /world/move REJECTED response is never silently swallowed by the UI.

test('describeWorldMoveError: every known server.mjs world/move errorCode has a distinct, readable message',()=>{
  const knownCodes=[
    'ERR_SESSION_REPLACED',
    'ERR_INVALID_STATE',
    'ERR_BATTLE_SETTLEMENT_REQUIRED',
    'ERR_INVALID_WORLD_TARGET',
    'ERR_IDEMPOTENCY_KEY_REQUIRED',
    'ERR_COMMAND_CONFLICT'
  ];
  const messages=knownCodes.map(describeWorldMoveError);
  for(const message of messages)assert.notEqual(message,undefined);
  for(let i=0;i<knownCodes.length;i++)assert.notEqual(messages[i],knownCodes[i],`expected a human-readable message for ${knownCodes[i]}, not the raw code`);
  assert.equal(new Set(messages).size,messages.length,'expected every known errorCode to map to a distinct message');
});

test('describeWorldMoveError: an unmapped/unknown errorCode is returned as-is, never hidden behind a generic label',()=>{
  assert.equal(describeWorldMoveError('ERR_SOME_FUTURE_CODE_NOT_YET_MAPPED'),'ERR_SOME_FUTURE_CODE_NOT_YET_MAPPED');
});

test('describeWorldMoveError: a missing/empty errorCode still returns a non-empty fallback message (never blank)',()=>{
  assert.equal(typeof describeWorldMoveError(undefined),'string');
  assert.ok(describeWorldMoveError(undefined).length>0);
  assert.equal(typeof describeWorldMoveError(null),'string');
  assert.ok(describeWorldMoveError(null).length>0);
});

// --- P1-07B: Continuous Visual Movement + Server Reconciliation ---

// --- predictionVelocity: derived from existing constants, not an independent speed ---

test('predictionVelocity: defaults to exactly JOYSTICK_STEP_DISTANCE / JOYSTICK_SEND_INTERVAL_MS, not a separately-tuned constant',()=>{
  assert.equal(predictionVelocity(),JOYSTICK_STEP_DISTANCE/JOYSTICK_SEND_INTERVAL_MS);
});

test('predictionVelocity: computes correctly for arbitrary step/interval inputs',()=>{
  assert.equal(predictionVelocity(36,120),0.3);
  assert.equal(predictionVelocity(10,100),0.1);
});

// --- Prototype Parameter locks ---

test('P1-07B reconciliation constants are locked at their currently-approved values',()=>{
  assert.equal(MAX_PREDICTION_LEAD,36);
  assert.equal(RECONCILE_SMOOTHING_MS,40);
  assert.equal(RECONCILE_STRONG_SMOOTHING_MS,40);
  assert.equal(RECONCILE_HARD_RESET_DISTANCE,54);
  assert.equal(RECONCILE_HARD_RESET_DISTANCE,JOYSTICK_STEP_DISTANCE*3,'hard reset distance is documented as 3x JOYSTICK_STEP_DISTANCE');
});

// --- isStepBlocked / clampPredictedStep: must be at least as strict as server.mjs's own
// segmentBlocked()/moveWorld() — parity tests using the exact same obstacle fixtures as
// test/world-collision.test.mjs, so client prediction and server truth cannot silently drift. ---

const inflatedObstacles=OBSTACLES.map(o=>inflateRect(o,PLAYER_COLLISION_RADIUS));
const ridgeA=OBSTACLES.find(o=>o.id==='ridge-a'),inflatedA=inflateRect(ridgeA,PLAYER_COLLISION_RADIUS);
const ridgeB=OBSTACLES.find(o=>o.id==='ridge-b'),inflatedB=inflateRect(ridgeB,PLAYER_COLLISION_RADIUS);
const centerA={x:(inflatedA.minX+inflatedA.maxX)/2,y:(inflatedA.minY+inflatedA.maxY)/2};
const centerB={x:(inflatedB.minX+inflatedB.maxX)/2,y:(inflatedB.minY+inflatedB.maxY)/2};

test('isStepBlocked: a step landing inside an inflated obstacle from clean outside space is blocked (parity with server.mjs collision behavior)',()=>{
  const start={x:inflatedA.minX-30,y:centerA.y};
  assert.equal(isStepBlocked(start.x,start.y,centerA.x,centerA.y,inflatedObstacles),true);
});

test('isStepBlocked: escape-only legacy semantics — already inside an obstacle, a step that lands outside is allowed (mirrors server.mjs collision-legacy-escape fixture)',()=>{
  assert.equal(pointInRect(centerB.x,centerB.y,inflatedB),true,'test setup: start must be inside the obstacle');
  const escapeTarget={x:centerB.x,y:centerB.y-135};
  assert.equal(pointInRect(escapeTarget.x,escapeTarget.y,inflatedB),false,'test setup: escape target must land outside');
  assert.equal(isStepBlocked(centerB.x,centerB.y,escapeTarget.x,escapeTarget.y,inflatedObstacles),false);
});

test('isStepBlocked: escape-only legacy semantics — already inside an obstacle, a step that stays inside the SAME obstacle is still blocked (mirrors server.mjs collision-legacy-still-inside fixture)',()=>{
  const stillInside={x:centerB.x+15,y:centerB.y};
  assert.equal(pointInRect(stillInside.x,stillInside.y,inflatedB),true,'test setup: candidate must still land inside the same obstacle');
  assert.equal(isStepBlocked(centerB.x,centerB.y,stillInside.x,stillInside.y,inflatedObstacles),true);
});

test('clampPredictedStep: an unobstructed, in-bounds candidate passes through unchanged',()=>{
  const current={x:500,y:500},candidate={x:510,y:505};
  assert.deepEqual(clampPredictedStep(current,candidate,WORLD_BOUNDS,inflatedObstacles),candidate);
});

test('clampPredictedStep: a candidate beyond WORLD_BOUNDS is clamped to the edge, same shape as server.mjs\'s own bounds clamp',()=>{
  const current={x:5,y:500},candidate={x:-40,y:1500};
  const result=clampPredictedStep(current,candidate,WORLD_BOUNDS,inflatedObstacles);
  assert.equal(result.x,WORLD_BOUNDS.min);
  assert.equal(result.y,WORLD_BOUNDS.max);
});

test('clampPredictedStep: a candidate that would collide freezes at current (no partial slide toward the obstacle)',()=>{
  const current={x:inflatedA.minX-30,y:centerA.y};
  const result=clampPredictedStep(current,{x:centerA.x,y:centerA.y},WORLD_BOUNDS,inflatedObstacles);
  assert.deepEqual(result,current);
});

test('clampPredictedStep: escape-only — starting inside an obstacle, stepping outward is allowed',()=>{
  const escapeTarget={x:centerB.x,y:centerB.y-135};
  const result=clampPredictedStep(centerB,escapeTarget,WORLD_BOUNDS,inflatedObstacles);
  assert.deepEqual(result,escapeTarget);
});

// --- advancePredictedPosition: per-frame continuous advance, self-capped at MAX_PREDICTION_LEAD ---

test('advancePredictedPosition: inactive input leaves the position unchanged',()=>{
  const current={x:100,y:100},server={x:100,y:100};
  const inactive={active:false,dirX:0,dirY:0,magnitude:0};
  assert.deepEqual(advancePredictedPosition(current,server,inactive,16,0.1286,36),current);
});

test('advancePredictedPosition: dt=0 produces no movement',()=>{
  const current={x:100,y:100},server={x:100,y:100};
  const input={active:true,dirX:1,dirY:0,magnitude:1};
  assert.deepEqual(advancePredictedPosition(current,server,input,0,0.1286,36),current);
});

test('advancePredictedPosition: full-magnitude input advances by velocity*dt in the input direction',()=>{
  const current={x:100,y:100},server={x:100,y:100};
  const input={active:true,dirX:1,dirY:0,magnitude:1};
  const result=advancePredictedPosition(current,server,input,100,0.2,36);
  assert.ok(Math.abs(result.x-120)<1e-9,`expected x~120, got ${result.x}`);
  assert.equal(result.y,100);
});

test('advancePredictedPosition: a candidate exactly at maxLead from serverPosition is allowed (inclusive boundary, matches this codebase\'s existing boundary convention)',()=>{
  const current={x:100,y:100},server={x:100,y:100};
  const input={active:true,dirX:1,dirY:0,magnitude:1};
  const result=advancePredictedPosition(current,server,input,180,0.2,36); // delta = 0.2*180 = 36 exactly
  assert.ok(Math.abs(result.x-136)<1e-9);
});

test('advancePredictedPosition: a candidate that would exceed maxLead freezes prediction at current instead of overshooting',()=>{
  const current={x:100,y:100},server={x:100,y:100};
  const input={active:true,dirX:1,dirY:0,magnitude:1};
  const result=advancePredictedPosition(current,server,input,200,0.2,36); // delta = 40, would exceed 36
  assert.deepEqual(result,current);
});

test('advancePredictedPosition: the lead cap is measured against serverPosition, not the origin — a predicted position already leading is only free to advance further up to the same cap',()=>{
  const current={x:130,y:100},server={x:100,y:100}; // already leading by 30
  const input={active:true,dirX:1,dirY:0,magnitude:1};
  const smallStep=advancePredictedPosition(current,server,input,10,0.2,36); // +2px -> lead 32, within cap
  assert.ok(Math.abs(smallStep.x-132)<1e-9);
  const bigStep=advancePredictedPosition(current,server,input,100,0.2,36); // +20px -> lead 50, exceeds cap
  assert.deepEqual(bigStep,current);
});

// --- reconciliationSmoothingMs: distance-based correction banding ---

test('reconciliationSmoothingMs: within MAX_PREDICTION_LEAD returns the gentle smoothing constant',()=>{
  assert.equal(reconciliationSmoothingMs(10),RECONCILE_SMOOTHING_MS);
  assert.equal(reconciliationSmoothingMs(0),RECONCILE_SMOOTHING_MS);
});

test('reconciliationSmoothingMs: exactly at MAX_PREDICTION_LEAD is still the gentle band (inclusive boundary)',()=>{
  assert.equal(reconciliationSmoothingMs(MAX_PREDICTION_LEAD),RECONCILE_SMOOTHING_MS);
});

test('reconciliationSmoothingMs: between MAX_PREDICTION_LEAD and RECONCILE_HARD_RESET_DISTANCE returns the strong smoothing constant',()=>{
  assert.equal(reconciliationSmoothingMs(MAX_PREDICTION_LEAD+1),RECONCILE_STRONG_SMOOTHING_MS);
  assert.equal(reconciliationSmoothingMs(45),RECONCILE_STRONG_SMOOTHING_MS);
});

test('reconciliationSmoothingMs: exactly at RECONCILE_HARD_RESET_DISTANCE is still the strong band (inclusive boundary)',()=>{
  assert.equal(reconciliationSmoothingMs(RECONCILE_HARD_RESET_DISTANCE),RECONCILE_STRONG_SMOOTHING_MS);
});

test('reconciliationSmoothingMs: beyond RECONCILE_HARD_RESET_DISTANCE returns null to signal an immediate hard reset',()=>{
  assert.equal(reconciliationSmoothingMs(RECONCILE_HARD_RESET_DISTANCE+1),null);
  assert.equal(reconciliationSmoothingMs(1000),null);
});

test('reconciliationSmoothingMs: custom thresholds/constants are honored, not hardcoded internally',()=>{
  assert.equal(reconciliationSmoothingMs(10,5,20,111,222),222);
  assert.equal(reconciliationSmoothingMs(10,20,20,111,222),111);
  assert.equal(reconciliationSmoothingMs(30,20,20,111,222),null);
});

// --- shouldSuspendAfterAccepted (P1-07B Merge Gate review) ---
// A collided:true ACCEPTED response must suspend prediction (client's per-frame swept prediction
// and server.mjs's own single-sweep moveWorld() can briefly disagree on a fast turn against an
// obstacle); a normal, non-colliding ACCEPTED response must resume it, not leave it suspended.

test('shouldSuspendAfterAccepted: a collided:true ACCEPTED response suspends prediction',()=>{
  assert.equal(shouldSuspendAfterAccepted({worldPosition:{x:1,y:1},state:'IN_CITY',throttled:false,collided:true}),true);
});

test('shouldSuspendAfterAccepted: a normal, non-collided ACCEPTED response resumes prediction (does not stay suspended)',()=>{
  assert.equal(shouldSuspendAfterAccepted({worldPosition:{x:1,y:1},state:'IN_WORLD',throttled:false,collided:false}),false);
});

test('shouldSuspendAfterAccepted: a throttled (zero-displacement, non-collided) ACCEPTED response still resumes prediction — throttling alone is not a collision',()=>{
  assert.equal(shouldSuspendAfterAccepted({worldPosition:{x:1,y:1},state:'IN_CITY',throttled:true,collided:false}),false);
});

test('shouldSuspendAfterAccepted: missing/undefined response data defaults to not suspended (never throws)',()=>{
  assert.equal(shouldSuspendAfterAccepted(undefined),false);
  assert.equal(shouldSuspendAfterAccepted({}),false);
});

// =====================================================================================
// P1-07D — Latency-Decoupled Movement (Issue #23), Architecture Plan v4/v4.1/v4.2/v4.3/v4.4
// =====================================================================================

// --- integrateInputPosition: pure, single-purpose frame integration (Blocker 1, v4.1) ---

test('integrateInputPosition: inactive input leaves the position unchanged',()=>{
  const position={x:10,y:10};
  assert.deepEqual(integrateInputPosition(position,{active:false,dirX:0,dirY:0,magnitude:0},16,0.1286),position);
});

test('integrateInputPosition: advances by velocity*dt*magnitude in the input direction, with no lead cap and no bleed of any kind',()=>{
  const position={x:0,y:0},input={active:true,dirX:1,dirY:0,magnitude:1};
  const result=integrateInputPosition(position,input,1000,0.2); // 200px — far beyond any MAX_PREDICTION_LEAD
  assert.ok(Math.abs(result.x-200)<1e-9,`expected an uncapped 200px advance, got ${result.x}`);
  assert.equal(result.y,0);
});

test('integrateInputPosition: half magnitude halves the advance',()=>{
  const result=integrateInputPosition({x:0,y:0},{active:true,dirX:1,dirY:0,magnitude:0.5},100,0.2);
  assert.ok(Math.abs(result.x-10)<1e-9);
});

// --- advancePredictedPosition (v4.1/v4.2/v4.4): directional forward-freeze + lateral bleed-off,
// now built on integrateInputPosition, must never contaminate earnedPosition (see below) ---

test('advancePredictedPosition: predicted LEGITIMATELY BEHIND server along the input direction never freezes — only being too far AHEAD does (v4.1 fix for the large-grant freeze-deadlock)',()=>{
  const current={x:0,y:0},server={x:90,y:0}; // predicted is 90px behind server, same axis as input
  const input={active:true,dirX:1,dirY:0,magnitude:1};
  const result=advancePredictedPosition(current,server,input,16,0.1286,36);
  assert.ok(result.x>current.x,`expected forward progress even while far behind, got x=${result.x}`);
});

test('advancePredictedPosition: predicted too far AHEAD along the input direction still freezes (unchanged, directional not Euclidean)',()=>{
  const current={x:136,y:0},server={x:100,y:0}; // already leading by 36 = maxLead
  const input={active:true,dirX:1,dirY:0,magnitude:1};
  const result=advancePredictedPosition(current,server,input,16,0.1286,36);
  assert.deepEqual(result,current);
});

test('advancePredictedPosition: lateral bleed-off never changes the ahead (forward-direction) component',()=>{
  const current={x:30,y:20},server={x:0,y:0}; // ahead=30 (along +X), lateral=20
  const input={active:true,dirX:1,dirY:0,magnitude:1};
  const result=advancePredictedPosition(current,server,input,16,0.1286,36,0.1286);
  const expectedAhead=30+0.1286*16; // forward step, entirely unaffected by bleed
  assert.ok(Math.abs(result.x-expectedAhead)<1e-6,`expected ahead component ${expectedAhead}, got ${result.x}`);
  assert.ok(result.y<20,'expected the lateral component to have bled down, not stayed at 20');
});

test('advancePredictedPosition: lateral divergence monotonically decreases each frame and fully resolves within the expected bounded window',()=>{
  let predicted={x:0,y:54},server={x:0,y:0}; // 54px purely lateral to a +X hold
  const input={active:true,dirX:1,dirY:0,magnitude:1};
  let previousLateral=54;
  for(let i=0;i<50;i++){
    predicted=advancePredictedPosition(predicted,server,input,16,0.1286,36,0.1286);
    const lateral=Math.abs(predicted.y-server.y);
    assert.ok(lateral<=previousLateral+1e-9,`lateral divergence must never increase (frame ${i}: ${lateral} > ${previousLateral})`);
    previousLateral=lateral;
  }
  assert.ok(previousLateral<1,`expected the 54px lateral offset to have resolved to well under 1px within 50 frames (~800ms), got ${previousLateral}`);
});

// --- movementDivergence: signed ahead/lateral decomposition ---

test('movementDivergence: no active input falls back to plain Euclidean distance as `ahead`, with lateral=0',()=>{
  const result=movementDivergence({x:10,y:0},{x:0,y:0},null);
  assert.equal(result.ahead,10);
  assert.equal(result.lateral,0);
});

test('movementDivergence: predicted directly ahead of server along the input direction gives a positive ahead, zero lateral',()=>{
  const result=movementDivergence({x:36,y:0},{x:0,y:0},{active:true,dirX:1,dirY:0,magnitude:1});
  assert.ok(Math.abs(result.ahead-36)<1e-9);
  assert.ok(Math.abs(result.lateral)<1e-9);
});

test('movementDivergence: server ahead of predicted along the input direction gives a NEGATIVE ahead (never dangerous, however large)',()=>{
  const result=movementDivergence({x:0,y:0},{x:90,y:0},{active:true,dirX:1,dirY:0,magnitude:1});
  assert.ok(Math.abs(result.ahead-(-90))<1e-9);
});

test('movementDivergence: pure perpendicular offset gives ahead=0, full magnitude as lateral',()=>{
  const result=movementDivergence({x:0,y:54},{x:0,y:0},{active:true,dirX:1,dirY:0,magnitude:1});
  assert.ok(Math.abs(result.ahead)<1e-9);
  assert.ok(Math.abs(result.lateral-54)<1e-9);
});

// --- catchUpDebtAfterGrant: ahead-only credit (v4.4 cleanup) ---

test('catchUpDebtAfterGrant: no intent direction (e.g. grant landed while idle) credits nothing',()=>{
  assert.equal(catchUpDebtAfterGrant({x:0,y:0},{x:90,y:0},null),0);
});

test('catchUpDebtAfterGrant: a pure ahead-direction grant credits its full magnitude',()=>{
  const debt=catchUpDebtAfterGrant({x:0,y:0},{x:90,y:0},{dirX:1,dirY:0});
  assert.ok(Math.abs(debt-90)<1e-9);
});

test('catchUpDebtAfterGrant: server moving BEHIND predicted along the intent direction credits zero, never a negative debt',()=>{
  const debt=catchUpDebtAfterGrant({x:90,y:0},{x:0,y:0},{dirX:1,dirY:0});
  assert.equal(debt,0);
});

test('catchUpDebtAfterGrant: only the ahead-projected component is credited, never the lateral one — concrete counter-example proving Euclidean debt would self-mask an unrelated lateral divergence',()=>{
  const predicted={x:0,y:0},intentDirection={dirX:1,dirY:0},newServerPosition={x:80,y:40}; // 80 ahead, 40 lateral, mixed in one grant
  const debt=catchUpDebtAfterGrant(predicted,newServerPosition,intentDirection);
  assert.equal(debt,80,'lateral component must never be credited into catchUpDebt');
  const euclidean=Math.hypot(80,40),oldBudget=MAX_PREDICTION_LEAD+euclidean,newBudget=MAX_PREDICTION_LEAD+debt;
  assert.ok(120<oldBudget,'sanity: the old (Euclidean) design would have masked a 120px unrelated lateral divergence');
  assert.ok(120>newBudget,'the new (ahead-only) design correctly still flags a 120px unrelated lateral divergence as dangerous');
});

// --- nextCatchUpDebt: clearing rules ---

test('nextCatchUpDebt: caught back up (distance<=maxLead) clears to 0',()=>{
  assert.equal(nextCatchUpDebt(90,20,36,false),0);
  assert.equal(nextCatchUpDebt(90,36,36,false),0);
});

test('nextCatchUpDebt: shouldClear forces 0 regardless of distance',()=>{
  assert.equal(nextCatchUpDebt(90,200,36,true),0);
});

test('nextCatchUpDebt: otherwise holds steady (no continuous time-based decay — see catchUpDebtAfterGrant header for why)',()=>{
  assert.equal(nextCatchUpDebt(90,54,36,false),90);
});

// --- clampEarnedTarget: request target lies on [serverPosition, earnedPosition] ---

test('clampEarnedTarget: within the catch-up cap, the target is earnedPosition itself, unshortened',()=>{
  const earned={x:20,y:0},server={x:0,y:0};
  assert.deepEqual(clampEarnedTarget(earned,server,1000,0.1286),earned);
});

test('clampEarnedTarget: beyond the cap, the target is a point on the segment [server,earned], never beyond earned',()=>{
  const earned={x:1000,y:0},server={x:0,y:0},cap=1000,velocity=0.1286;
  const target=clampEarnedTarget(earned,server,cap,velocity);
  const maxDist=velocity*cap;
  const dist=Math.hypot(target.x-server.x,target.y-server.y);
  assert.ok(Math.abs(dist-maxDist)<1e-6,`expected target distance ~${maxDist}, got ${dist}`);
  assert.ok(target.x<earned.x,'target must be shortened toward server, never extrapolated beyond earnedPosition');
});

// --- nextEarnedPosition: IN_CITY bootstrap (v4.2 Blocker 1) + press-rebase ---

test('nextEarnedPosition: shouldReset snaps to serverPosition',()=>{
  assert.deepEqual(nextEarnedPosition({x:99,y:99},{x:0,y:0},{active:true,dirX:1,dirY:0,magnitude:1},true,16,0.1286,true),{x:0,y:0});
});

test('nextEarnedPosition: inactive input leaves earnedPosition unchanged',()=>{
  const earned={x:5,y:5};
  assert.deepEqual(nextEarnedPosition(earned,{x:0,y:0},{active:false,dirX:0,dirY:0,magnitude:0},false,16,0.1286,false),earned);
});

test('nextEarnedPosition: a fresh press (wasActiveLastFrame=false) rebases from serverPosition before integrating, discarding any stale earnedPosition',()=>{
  const staleEarned={x:500,y:500},server={x:0,y:0},input={active:true,dirX:1,dirY:0,magnitude:1};
  const result=nextEarnedPosition(staleEarned,server,input,false,16,0.1286,false);
  const expectedDelta=0.1286*16;
  assert.ok(Math.abs(result.x-expectedDelta)<1e-6,`expected a fresh-press small step from server truth (~${expectedDelta}), got ${result.x} (stale earnedPosition must have been discarded)`);
});

test('nextEarnedPosition: state-independent — a genuinely IN_CITY position (the function takes no state argument at all) still accumulates a non-zero first target, proving the IN_CITY→IN_WORLD bootstrap deadlock (v4.2 Blocker 1) cannot recur',()=>{
  const serverPos={x:100,y:100}; // this position could equally represent IN_CITY or IN_WORLD — the
                                   // function has no way to distinguish, which is exactly the fix
  const input={active:true,dirX:1,dirY:0,magnitude:1};
  const first=nextEarnedPosition(serverPos,serverPos,input,false,140,MOVE_SPEED_RATE,false);
  assert.ok(Math.abs(first.x-serverPos.x)>0,'expected a non-zero first accumulated target');
  const target=clampEarnedTarget(first,serverPos,MOVE_CATCHUP_CAP_MS,MOVE_SPEED_RATE);
  assert.notDeepEqual(target,serverPos,'the request target actually sent must not equal serverPosition — a target equal to serverPosition is exactly the zero-displacement deadlock this fix prevents');
});

test('nextEarnedPosition: sustained hold (wasActiveLastFrame=true) keeps accumulating from the current earnedPosition, not rebasing to server truth every frame',()=>{
  const earned={x:20,y:0},server={x:0,y:0},input={active:true,dirX:1,dirY:0,magnitude:1};
  const result=nextEarnedPosition(earned,server,input,true,16,0.1286,false);
  const expected=20+0.1286*16;
  assert.ok(Math.abs(result.x-expected)<1e-6);
});

// --- idleSettlePosition: idle/release presentation reconciliation (v4.2 Blocker 3) ---

test('idleSettlePosition: within epsilon, snaps exactly to server truth (negligible, imperceptible remainder)',()=>{
  assert.deepEqual(idleSettlePosition({x:0.01,y:0},{x:0,y:0},16),{x:0,y:0});
});

test('idleSettlePosition: 5/20/35px release gaps all converge to the server truth within a bounded number of frames, never getting stuck',()=>{
  for(const gap of [5,20,35]){
    let predicted={x:gap,y:0},server={x:0,y:0};
    for(let i=0;i<500;i++)predicted=idleSettlePosition(predicted,server,16);
    const remaining=Math.hypot(predicted.x,predicted.y);
    assert.ok(remaining<=IDLE_SETTLE_EPSILON_PX,`gap ${gap}px did not converge within 500 frames, remaining=${remaining}`);
  }
});

test('idleSettlePosition: never hard-resets even far beyond RECONCILE_HARD_RESET_DISTANCE — a stale-accepted grant landing after release glides, it never snaps',()=>{
  const predicted={x:80,y:0},server={x:0,y:0}; // 80 > RECONCILE_HARD_RESET_DISTANCE (54)
  const next=idleSettlePosition(predicted,server,16);
  assert.notDeepEqual(next,server,'expected a smooth ease step, not an immediate snap to server truth');
  assert.ok(next.x<predicted.x&&next.x>server.x,'expected genuine but partial progress toward truth');
});

// --- nextGenerationAnchor: anchor-relative direction+magnitude drift detection (v4.3/v4.4) ---

test('nextGenerationAnchor: press/release always bump regardless of angle or magnitude',()=>{
  assert.equal(nextGenerationAnchor(null,{active:true,dirX:1,dirY:0,magnitude:1}).bump,true);
  assert.equal(nextGenerationAnchor({active:true,dirX:1,dirY:0,magnitude:1},{active:false}).bump,true);
});

test('nextGenerationAnchor: 0→2→-2→3° stays within tolerance of the same anchor, never bumps',()=>{
  let anchor={active:true,dirX:1,dirY:0,magnitude:1};
  for(const deg of [2,-2,3]){
    const rad=deg*Math.PI/180,next={active:true,dirX:Math.cos(rad),dirY:Math.sin(rad),magnitude:1};
    const result=nextGenerationAnchor(anchor,next);
    assert.equal(result.bump,false,`${deg}° should not bump`);
    anchor=result.anchor;
  }
});

test('nextGenerationAnchor: 0→5→10→14° stays within tolerance of the ORIGINAL 0° anchor (anchor unchanged while not bumping)',()=>{
  let anchor={active:true,dirX:1,dirY:0,magnitude:1};
  for(const deg of [5,10,14]){
    const rad=deg*Math.PI/180,next={active:true,dirX:Math.cos(rad),dirY:Math.sin(rad),magnitude:1};
    const result=nextGenerationAnchor(anchor,next);
    assert.equal(result.bump,false,`${deg}° (vs fixed 0° anchor) should not bump`);
    anchor=result.anchor;
  }
});

test('nextGenerationAnchor: 0→5→10→16° bumps at 16°, still measured against the original 0° anchor — proves anchor-relative (not previous-frame) comparison catches gradual drift',()=>{
  let anchor={active:true,dirX:1,dirY:0,magnitude:1};
  for(const deg of [5,10]){
    const rad=deg*Math.PI/180;
    anchor=nextGenerationAnchor(anchor,{active:true,dirX:Math.cos(rad),dirY:Math.sin(rad),magnitude:1}).anchor;
  }
  const rad16=16*Math.PI/180,next16={active:true,dirX:Math.cos(rad16),dirY:Math.sin(rad16),magnitude:1};
  const result=nextGenerationAnchor(anchor,next16);
  assert.equal(result.bump,true,'16° cumulative drift from the original anchor must bump');
  assert.ok(Math.abs(result.anchor.dirX-next16.dirX)<1e-9,'anchor must reset to the 16° direction after bumping');
});

test('nextGenerationAnchor: after bumping at 16°, 16→25→31° stays within tolerance of the NEW 16° anchor',()=>{
  let anchor={active:true,dirX:Math.cos(16*Math.PI/180),dirY:Math.sin(16*Math.PI/180),magnitude:1};
  for(const deg of [25,31]){
    const rad=deg*Math.PI/180,next={active:true,dirX:Math.cos(rad),dirY:Math.sin(rad),magnitude:1};
    const result=nextGenerationAnchor(anchor,next);
    assert.equal(result.bump,false,`${deg}° (within 15° of the 16° anchor) should not bump`);
    anchor=result.anchor;
  }
});

test('nextGenerationAnchor: 16→32° bumps (16° drift from the 16° anchor)',()=>{
  const anchor={active:true,dirX:Math.cos(16*Math.PI/180),dirY:Math.sin(16*Math.PI/180),magnitude:1};
  const rad32=32*Math.PI/180,next={active:true,dirX:Math.cos(rad32),dirY:Math.sin(rad32),magnitude:1};
  assert.equal(nextGenerationAnchor(anchor,next).bump,true);
});

test('nextGenerationAnchor: a gradual 0°→90° sweep (10°/step) produces multiple bumps, never zero — cannot evade detection via small per-frame steps',()=>{
  let anchor={active:true,dirX:1,dirY:0,magnitude:1},bumps=0;
  for(let deg=10;deg<=90;deg+=10){
    const rad=deg*Math.PI/180,next={active:true,dirX:Math.cos(rad),dirY:Math.sin(rad),magnitude:1};
    const result=nextGenerationAnchor(anchor,next);
    if(result.bump)bumps++;
    anchor=result.anchor;
  }
  // At a 15° threshold sampled every 10°, a bump recurs roughly every other sample (20° of actual
  // drift) — the required guarantee is "multiple, not just one", not an exact count.
  assert.ok(bumps>=3,`expected multiple bumps across a 90° gradual sweep, got ${bumps}`);
});

test('nextGenerationAnchor: magnitude 1.00→0.95 does not bump (Δ=0.05, tremor)',()=>{
  const anchor={active:true,dirX:1,dirY:0,magnitude:1.00};
  assert.equal(nextGenerationAnchor(anchor,{active:true,dirX:1,dirY:0,magnitude:0.95}).bump,false);
});

test('nextGenerationAnchor: magnitude 1.00→0.80 bumps (Δ=0.20 exceeds the 0.15 threshold)',()=>{
  const anchor={active:true,dirX:1,dirY:0,magnitude:1.00};
  assert.equal(nextGenerationAnchor(anchor,{active:true,dirX:1,dirY:0,magnitude:0.80}).bump,true);
});

test('nextGenerationAnchor: magnitude 1.00→0.50 bumps',()=>{
  const anchor={active:true,dirX:1,dirY:0,magnitude:1.00};
  assert.equal(nextGenerationAnchor(anchor,{active:true,dirX:1,dirY:0,magnitude:0.50}).bump,true);
});

test('nextGenerationAnchor: magnitude 0.30→0.35 does not bump (same Δ=0.05 as the tremor case, regardless of base level — proves the threshold is an absolute delta, not relative)',()=>{
  const anchor={active:true,dirX:1,dirY:0,magnitude:0.30};
  assert.equal(nextGenerationAnchor(anchor,{active:true,dirX:1,dirY:0,magnitude:0.35}).bump,false);
});

test('nextGenerationAnchor: gradual magnitude drift accumulates against a fixed anchor, eventually bumping — cannot evade detection via small per-frame steps',()=>{
  let anchor={active:true,dirX:1,dirY:0,magnitude:1.00},bumps=0;
  for(let m=0.90;m>=0.10;m-=0.10){
    const next={active:true,dirX:1,dirY:0,magnitude:Number(m.toFixed(2))};
    const result=nextGenerationAnchor(anchor,next);
    if(result.bump)bumps++;
    anchor=result.anchor;
  }
  assert.ok(bumps>=1,'a gradual 1.00→0.10 magnitude drift must bump at least once');
});

test('nextGenerationAnchor: direction unchanged but a major magnitude drop still bumps — an in-flight response bound to the old (high-magnitude) generation must be treated as stale',()=>{
  const anchor={active:true,dirX:1,dirY:0,magnitude:1.0};
  const result=nextGenerationAnchor(anchor,{active:true,dirX:1,dirY:0,magnitude:0.2});
  assert.equal(result.bump,true);
});

// --- v4.4 §6.1 simulation table: 0°/45°/90°/180° × debt(D)=20/36/54/90px, reconstructed against
// the ACTUAL exported gate primitives (movementDivergence + the same dangerousAhead/dangerousLateral
// formulas app.js uses), not just asserted as prose ---

test('simulation table: at every angle 0/45/90°, catchUpDebt=D always keeps the reprojected divergence safe (dangerousAhead=false, dangerousLateral=false) for D=20/36/54/90',()=>{
  for(const D of [20,36,54,90]){
    for(const deg of [0,45,90]){
      const rad=deg*Math.PI/180;
      // offset purely along the OLD (0°) direction, magnitude D, now viewed via a NEW direction `deg` away
      const predicted={x:-D,y:0},server={x:0,y:0}; // ahead_old=-D relative to 0° direction
      const input={active:true,dirX:Math.cos(rad),dirY:Math.sin(rad),magnitude:1};
      const divergence=movementDivergence(predicted,server,input);
      const dangerousAhead=divergence.ahead>MAX_PREDICTION_LEAD;
      const dangerousLateral=divergence.lateral>MAX_PREDICTION_LEAD+D;
      assert.equal(dangerousAhead,false,`angle ${deg}° D=${D}: expected ahead safe, got ahead=${divergence.ahead}`);
      assert.equal(dangerousLateral,false,`angle ${deg}° D=${D}: expected lateral safe, got lateral=${divergence.lateral} budget=${MAX_PREDICTION_LEAD+D}`);
    }
  }
});

test('simulation table: at 180°, dangerousAhead triggers once D>MAX_PREDICTION_LEAD (D=54,90), stays safe for D=20/36',()=>{
  for(const D of [20,36]){
    const predicted={x:-D,y:0},server={x:0,y:0};
    const input={active:true,dirX:-1,dirY:0,magnitude:1}; // 180° reversal
    const divergence=movementDivergence(predicted,server,input);
    assert.equal(divergence.ahead>MAX_PREDICTION_LEAD,false,`D=${D}: expected safe at 180°, got ahead=${divergence.ahead}`);
  }
  for(const D of [54,90]){
    const predicted={x:-D,y:0},server={x:0,y:0};
    const input={active:true,dirX:-1,dirY:0,magnitude:1};
    const divergence=movementDivergence(predicted,server,input);
    assert.equal(divergence.ahead>MAX_PREDICTION_LEAD,true,`D=${D}: expected dangerous at 180°, got ahead=${divergence.ahead}`);
  }
});

test('simulation table: non-suspended reconciliation (dangerousAhead-triggered) never hard-resets even at D=90/180° — reconciliationSmoothingMs with hardResetDistance=Infinity always returns a finite smoothing value',()=>{
  const smoothingMs=reconciliationSmoothingMs(90,MAX_PREDICTION_LEAD,Infinity);
  assert.notEqual(smoothingMs,null);
  assert.equal(smoothingMs,RECONCILE_STRONG_SMOOTHING_MS);
});

// --- guardStaleGeneration: production-shaped sender tests using the REAL, unmodified
// createCoalescingSender — proves actual network-call side effects, not just a comparison of two
// numbers (v4.3/v4.4 Test Requirement) ---

test('guardStaleGeneration: B queued while A is in-flight, generation bumps before A resolves → B is dropped before ever reaching the network call',async()=>{
  let currentGeneration=1,callCount=0,resolveA;
  const slowNetworkCall=async({x,y})=>{
    callCount++;
    return new Promise(resolve=>{resolveA=()=>resolve({status:'ACCEPTED',data:{worldPosition:{x,y}}})});
  };
  const guardedMoveCall=guardStaleGeneration(slowNetworkCall,()=>currentGeneration);
  // Same shape as app.js's production sendWorldMove: createCoalescingSender wraps a callback that
  // awaits guardedMoveCall and inspects `.dropped` — not a hand-duplicated check.
  const sender=createCoalescingSender(async(target)=>{await guardedMoveCall(target)});

  sender({generation:1,x:1,y:1});   // A: dequeues immediately, slowNetworkCall runs synchronously up
                                      // to its own pending-Promise return — callCount is already 1 here
  sender({generation:1,x:2,y:2});   // B: in-flight, queued as `pending`, still bound to generation 1
                                      // (fresh at THIS moment — matches the exact case: B queued
                                      // before generation changes)
  currentGeneration=2;               // generation bumps only AFTER B was queued
  resolveA();                        // A resolves → asyncqueue's finally block auto-dequeues B → run(B)
  await new Promise(r=>setTimeout(r,0)); // let all pending microtasks/continuations settle
  assert.equal(callCount,1,'B must be dropped before ever reaching slowNetworkCall — only A should have counted');
});

test('guardStaleGeneration: B queued while A is in-flight, generation UNCHANGED when A resolves → B sends normally',async()=>{
  let currentGeneration=1,callCount=0,resolveA;
  const slowNetworkCall=async({x,y})=>{
    callCount++;
    return new Promise(resolve=>{resolveA=()=>resolve({status:'ACCEPTED',data:{worldPosition:{x,y}}})});
  };
  const guardedMoveCall=guardStaleGeneration(slowNetworkCall,()=>currentGeneration);
  const sender=createCoalescingSender(async(target)=>{await guardedMoveCall(target)});

  sender({generation:1,x:1,y:1});   // A
  sender({generation:1,x:2,y:2});   // B queued, generation never changes
  resolveA();
  await new Promise(r=>setTimeout(r,0));
  assert.equal(callCount,2,'B must proceed to the network call since its generation still matches at dequeue time');
});

test('guardStaleGeneration: a generation mismatch detected before any network call means the network function is never invoked, and resolves to {dropped:true}',async()=>{
  let callCount=0;
  const networkCall=async()=>{callCount++;return{status:'ACCEPTED',data:{}}};
  const guarded=guardStaleGeneration(networkCall,()=>2); // live generation is 2
  const outcome=await guarded({generation:1,x:0,y:0}); // bound to stale generation 1
  assert.deepEqual(outcome,{dropped:true});
  assert.equal(callCount,0);
});

test('guardStaleGeneration: a matching generation invokes the network function and returns {dropped:false,result}',async()=>{
  const networkCall=async(payload)=>({status:'ACCEPTED',data:{worldPosition:payload}});
  const guarded=guardStaleGeneration(networkCall,()=>1);
  const outcome=await guarded({generation:1,x:5,y:6});
  assert.deepEqual(outcome,{dropped:false,result:{status:'ACCEPTED',data:{worldPosition:{x:5,y:6}}}});
});

// --- applyMovementIntent: the single synchronous state transition (Merge Gate review — closes the
// input-event-to-next-RAF race) ---

test('applyMovementIntent: a meaningful direction change bumps generation and updates the anchor, synchronously, from pure input/output (no module-level state)',()=>{
  const state={joystickInput:{active:true,dirX:1,dirY:0,magnitude:1},movementGeneration:5,generationAnchorInput:{active:true,dirX:1,dirY:0,magnitude:1}};
  const nextInput={active:true,dirX:0,dirY:1,magnitude:1}; // 90°
  const next=applyMovementIntent(state,nextInput);
  assert.equal(next.movementGeneration,6);
  assert.deepEqual(next.joystickInput,nextInput);
  assert.deepEqual(next.generationAnchorInput,nextInput);
});

test('applyMovementIntent: a micro tremor does not bump generation, and leaves the anchor unchanged',()=>{
  const anchor={active:true,dirX:1,dirY:0,magnitude:1};
  const state={joystickInput:anchor,movementGeneration:5,generationAnchorInput:anchor};
  const rad=2*Math.PI/180,nextInput={active:true,dirX:Math.cos(rad),dirY:Math.sin(rad),magnitude:1};
  const next=applyMovementIntent(state,nextInput);
  assert.equal(next.movementGeneration,5);
  assert.deepEqual(next.generationAnchorInput,anchor);
  assert.deepEqual(next.joystickInput,nextInput,'joystickInput itself always updates, regardless of whether generation bumped');
});

test('applyMovementIntent: release (active->inactive) always bumps',()=>{
  const state={joystickInput:{active:true,dirX:1,dirY:0,magnitude:1},movementGeneration:5,generationAnchorInput:{active:true,dirX:1,dirY:0,magnitude:1}};
  const next=applyMovementIntent(state,{active:false,dirX:0,dirY:0,magnitude:0});
  assert.equal(next.movementGeneration,6);
});

// --- P1-07D Merge Gate review — race regression: movementGeneration must already be current the
// INSTANT the input changes, not just by the next animation frame. These tests deliberately never
// simulate a "tick"/RAF at all — they apply the intent change synchronously, in the same turn as
// queuing the pending request, exactly reproducing the race window an animation-frame-deferred bump
// would miss. Each uses the REAL, unmodified createCoalescingSender and the REAL guardStaleGeneration
// (imported from movement.js, never a re-implemented mock), wrapped the same way app.js's
// sendWorldMove wraps them, so the network-call count is genuine production behavior, not a
// comparison of two numbers. ---

function raceHarness(){
  let state={joystickInput:{active:true,dirX:1,dirY:0,magnitude:1},movementGeneration:5,generationAnchorInput:{active:true,dirX:1,dirY:0,magnitude:1}};
  let callCount=0,resolveA;
  const slowNetworkCall=async({x,y})=>{
    callCount++;
    return new Promise(resolve=>{resolveA=()=>resolve({status:'ACCEPTED',data:{worldPosition:{x,y}}})});
  };
  const guardedMoveCall=guardStaleGeneration(slowNetworkCall,()=>state.movementGeneration);
  // Same shape as app.js's production sendWorldMove.
  const sender=createCoalescingSender(async(target)=>{await guardedMoveCall(target)});
  return{get state(){return state},set state(next){state=next},get callCount(){return callCount},sender,resolveA:()=>resolveA()};
}

test('Race Case A — release race: B must be dropped even though the release happens synchronously, with NO animation-frame tick between the release and A resolving',async()=>{
  const h=raceHarness();
  h.sender({generation:h.state.movementGeneration,x:1,y:1}); // A: dequeues immediately, in-flight at generation 5
  h.sender({generation:h.state.movementGeneration,x:2,y:2}); // B: queued, still generation 5 at THIS moment
  h.state=applyMovementIntent(h.state,{active:false,dirX:0,dirY:0,magnitude:0}); // synchronous release, no tick simulated
  assert.equal(h.state.movementGeneration,6,'release must have already bumped generation before A resolves');
  h.resolveA(); // A resolves -> asyncqueue's finally auto-dequeues B -> run(B), which reads the NOW-current generation
  await new Promise(r=>setTimeout(r,0));
  assert.equal(h.callCount,1,'B must be dropped — release already bumped generation before A resolved, with no RAF in between');
});

test('Race Case B — direction-change race: 0°->90° mid-flight, A resolving before any tick, B must never reach the network',async()=>{
  const h=raceHarness();
  h.sender({generation:h.state.movementGeneration,x:1,y:1});
  h.sender({generation:h.state.movementGeneration,x:2,y:2});
  h.state=applyMovementIntent(h.state,{active:true,dirX:0,dirY:1,magnitude:1}); // 90° turn, synchronous
  assert.equal(h.state.movementGeneration,6);
  h.resolveA();
  await new Promise(r=>setTimeout(r,0));
  assert.equal(h.callCount,1,'B must be dropped — a 90° direction change already bumped generation before A resolved');
});

test('Race Case C — magnitude-change race: 1.0->0.2 mid-flight, A resolving before any tick, B must never reach the network',async()=>{
  const h=raceHarness();
  h.sender({generation:h.state.movementGeneration,x:1,y:1});
  h.sender({generation:h.state.movementGeneration,x:2,y:2});
  h.state=applyMovementIntent(h.state,{active:true,dirX:1,dirY:0,magnitude:0.2}); // major magnitude drop, synchronous
  assert.equal(h.state.movementGeneration,6);
  h.resolveA();
  await new Promise(r=>setTimeout(r,0));
  assert.equal(h.callCount,1,'B must be dropped — a major magnitude drop already bumped generation before A resolved');
});

test('Race Case D — micro tremor: a 2° change (below threshold) leaves generation unchanged, so B sends normally',async()=>{
  const h=raceHarness();
  h.sender({generation:h.state.movementGeneration,x:1,y:1});
  h.sender({generation:h.state.movementGeneration,x:2,y:2});
  const rad=2*Math.PI/180;
  h.state=applyMovementIntent(h.state,{active:true,dirX:Math.cos(rad),dirY:Math.sin(rad),magnitude:1}); // tremor
  assert.equal(h.state.movementGeneration,5,'a tremor must not bump generation');
  h.resolveA();
  await new Promise(r=>setTimeout(r,0));
  assert.equal(h.callCount,2,'B must send normally — its generation still matches, exactly as production would behave for a genuine still-current pending target');
});
