import test from 'node:test';
import assert from 'node:assert/strict';
import {
  nextFpsEma,
  predictionLeadDistance,
  nextMoveTiming,
  formatMs,
  formatFlag,
  formatLeadReadout,
  TELEMETRY_FPS_SMOOTHING_MS,
  TELEMETRY_OVERLAY_PATCH_INTERVAL_MS
} from '../public/telemetry.js';

// P1-07C — Mobile Movement Telemetry (diagnostic-only, Issue #21). All DOM-free pure functions,
// same testing convention as movement.js. None of this feeds back into movement/prediction/
// reconciliation/camera — see test/movement.test.mjs and test/worldmap.test.mjs (unchanged in this
// phase) for proof the actual movement math/tests are untouched.

// --- Prototype Parameter locks ---

test('P1-07C telemetry constants are locked at their currently-approved values',()=>{
  assert.equal(TELEMETRY_FPS_SMOOTHING_MS,500);
  assert.equal(TELEMETRY_OVERLAY_PATCH_INTERVAL_MS,100);
});

// --- nextFpsEma ---

test('nextFpsEma: a null previous EMA snaps straight to the first instant reading (no warm-up lag)',()=>{
  assert.ok(Math.abs(nextFpsEma(null,1000/60)-60)<1e-9);
  assert.ok(Math.abs(nextFpsEma(null,1000/30)-30)<1e-9);
});

test('nextFpsEma: dt=0 is treated as no new sample — falls back to the previous EMA, never divides by zero',()=>{
  assert.equal(nextFpsEma(45,0),45);
});

test('nextFpsEma: a steady dt converges toward the matching instant FPS over repeated frames',()=>{
  let ema=60;
  for(let i=0;i<200;i++)ema=nextFpsEma(ema,33.333); // steady 30fps input
  assert.ok(Math.abs(ema-30)<0.5,`expected convergence to ~30fps, got ${ema}`);
});

test('nextFpsEma: a single bad frame (one huge dt / big FPS drop) only nudges the EMA, never snaps to it',()=>{
  const ema=nextFpsEma(60,200); // one very slow ~5fps frame
  assert.ok(ema<60&&ema>10,`expected a partial dip, got ${ema}`);
});

// --- predictionLeadDistance ---

test('predictionLeadDistance: zero when predicted and server positions coincide',()=>{
  assert.equal(predictionLeadDistance({x:100,y:100},{x:100,y:100}),0);
});

test('predictionLeadDistance: correct Euclidean distance (3-4-5 triangle fixture)',()=>{
  assert.equal(predictionLeadDistance({x:0,y:0},{x:3,y:4}),5);
});

test('predictionLeadDistance: order-independent (distance is symmetric)',()=>{
  const a={x:10,y:20},b={x:130,y:60};
  assert.equal(predictionLeadDistance(a,b),predictionLeadDistance(b,a));
});

// --- nextMoveTiming: the single timing path shared by ACCEPTED/REJECTED/ERROR ---

test('nextMoveTiming: computes RTT as completedAt-startedAt',()=>{
  const timing=nextMoveTiming(1000,1140,null);
  assert.equal(timing.rttMs,140);
});

test('nextMoveTiming: response gap is null on the very first completion (no previous timestamp yet)',()=>{
  const timing=nextMoveTiming(1000,1140,null);
  assert.equal(timing.responseGapMs,null);
});

test('nextMoveTiming: response gap is completedAt-previousCompletedAt from the second completion onward',()=>{
  const timing=nextMoveTiming(1500,1650,1140);
  assert.equal(timing.responseGapMs,510);
});

test('nextMoveTiming: always returns completedAt unchanged, to be threaded as the next call\'s previousCompletedAt',()=>{
  const timing=nextMoveTiming(1000,1140,null);
  assert.equal(timing.completedAt,1140);
});

test('nextMoveTiming: identical shape/behavior regardless of which completion path calls it (ACCEPTED/REJECTED/ERROR all use the same function)',()=>{
  const accepted=nextMoveTiming(2000,2130,1800);
  const rejected=nextMoveTiming(2000,2130,1800);
  const error=nextMoveTiming(2000,2130,1800);
  assert.deepEqual(accepted,rejected);
  assert.deepEqual(rejected,error);
});

// --- Display formatting ---

test('formatMs: null renders as the en-dash placeholder, never a blank or "NaN"',()=>{
  assert.equal(formatMs(null),'–');
});

test('formatMs: rounds to the nearest millisecond and appends the unit',()=>{
  assert.equal(formatMs(139.6),'140ms');
  assert.equal(formatMs(0),'0ms');
});

test('formatFlag: null renders as the en-dash placeholder (no data yet), distinct from true/false',()=>{
  assert.equal(formatFlag(null),'–');
});

test('formatFlag: true/false render as YES/no',()=>{
  assert.equal(formatFlag(true),'YES');
  assert.equal(formatFlag(false),'no');
});

test('formatLeadReadout: matches the "31.4 / 36px" shape from Issue #21',()=>{
  assert.equal(formatLeadReadout(31.4,36),'31.4 / 36px');
});

test('formatLeadReadout: rounds the lead distance to one decimal place',()=>{
  assert.equal(formatLeadReadout(0,36),'0.0 / 36px');
  assert.equal(formatLeadReadout(35.999,36),'36.0 / 36px');
});
