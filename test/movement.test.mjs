import test from 'node:test';
import assert from 'node:assert/strict';
import {
  computeJoystickInput,
  clampJoystickKnob,
  computeJoystickTarget,
  easeTowards,
  isMovementAllowed,
  shouldSendJoystickMove,
  JOYSTICK_RADIUS,
  JOYSTICK_DEADZONE
} from '../public/movement.js';

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
