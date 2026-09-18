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
  JOYSTICK_RADIUS,
  JOYSTICK_DEADZONE,
  JOYSTICK_STEP_DISTANCE,
  JOYSTICK_SEND_INTERVAL_MS,
  MAX_PREDICTION_LEAD,
  RECONCILE_SMOOTHING_MS,
  RECONCILE_STRONG_SMOOTHING_MS,
  RECONCILE_HARD_RESET_DISTANCE
} from '../public/movement.js';
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
