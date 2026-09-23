import test from 'node:test';
import assert from 'node:assert/strict';
import {
  nextFpsEma,
  nextTelemetryFrameDelta,
  predictionLeadDistance,
  nextMoveTiming,
  formatMs,
  formatFlag,
  formatLeadReadout,
  TELEMETRY_FPS_SMOOTHING_MS,
  TELEMETRY_OVERLAY_PATCH_INTERVAL_MS,
  isNearLeadCap,
  isCapFrozenFrame,
  nextCapFrozenStreakMs,
  capFrozenRatio,
  formatPercent,
  formatPx,
  formatCount,
  TELEMETRY_LEAD_CAP_TOLERANCE_PX,
  TELEMETRY_NO_PROGRESS_EPSILON_PX,
  RECENT_EVENT_RETENTION_MS,
  shouldCommitFreezeEvent,
  buildRecentEvent,
  isRecentEventStale,
  formatEventAge
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

// --- nextTelemetryFrameDelta (P1-07C Merge Gate review) ---
// Must be the RAW, uncapped elapsed time — movement's own dt is clamped to 100ms for smoothing/
// prediction purposes, but telemetry needs the true stall length to tell a rendering stall apart
// from a network gap. A real 250ms/500ms frame must never be reported back as ~100ms.

test('nextTelemetryFrameDelta: the very first frame (no previous timestamp) returns null, not a fabricated dt',()=>{
  assert.equal(nextTelemetryFrameDelta(null,1000),null);
});

test('nextTelemetryFrameDelta: a 250ms real frame interval is reported as exactly 250ms, never clamped to 100ms',()=>{
  assert.equal(nextTelemetryFrameDelta(1000,1250),250);
});

test('nextTelemetryFrameDelta: a 500ms real frame interval is reported as exactly 500ms, never clamped to 100ms',()=>{
  assert.equal(nextTelemetryFrameDelta(1000,1500),500);
});

test('nextTelemetryFrameDelta: a normal ~16ms frame is reported as-is (no clamping in the normal case either)',()=>{
  assert.ok(Math.abs(nextTelemetryFrameDelta(1000,1016.7)-16.7)<1e-9);
});

test('nextFpsEma fed nextTelemetryFrameDelta\'s raw (uncapped) 250ms stall reflects the true ~4fps, not the ~10fps a 100ms-capped dt would produce',()=>{
  const rawDt=nextTelemetryFrameDelta(1000,1250); // 250ms, uncapped
  assert.equal(rawDt,250);
  const ema=nextFpsEma(60,rawDt);
  const instantFps=1000/rawDt; // ~4fps
  assert.ok(Math.abs(instantFps-4)<0.01,`test setup: expected instant fps ~4, got ${instantFps}`);
  // the EMA nudges toward ~4fps, not toward the ~10fps a 100ms-capped dt would have produced
  const emaIfWronglyCappedAt100ms=nextFpsEma(60,100);
  assert.ok(ema<emaIfWronglyCappedAt100ms,`expected the true 250ms stall to pull FPS down further than a wrongly-capped 100ms would, got ${ema} vs ${emaIfWronglyCappedAt100ms}`);
});

test('nextFpsEma fed nextTelemetryFrameDelta\'s raw 500ms stall reflects the true ~2fps direction',()=>{
  const rawDt=nextTelemetryFrameDelta(1000,1500); // 500ms, uncapped
  const instantFps=1000/rawDt;
  assert.ok(Math.abs(instantFps-2)<0.01,`test setup: expected instant fps ~2, got ${instantFps}`);
  const emaFrom500ms=nextFpsEma(60,rawDt);
  const emaFrom250ms=nextFpsEma(60,250);
  assert.ok(emaFrom500ms<emaFrom250ms,'a longer real stall must pull the FPS EMA down further than a shorter one');
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

// --- P1-07 Root Cause Measurement Test: isNearLeadCap (leadCapHit) ---

test('P1-07 Root Cause Measurement Test constants are locked at their approved diagnostic-only values',()=>{
  assert.equal(TELEMETRY_LEAD_CAP_TOLERANCE_PX,0.5);
  assert.equal(TELEMETRY_NO_PROGRESS_EPSILON_PX,0.01);
});

test('isNearLeadCap: well below the cap is false',()=>{
  assert.equal(isNearLeadCap(10,36),false);
});

test('isNearLeadCap: exactly at the cap is true',()=>{
  assert.equal(isNearLeadCap(36,36),true);
});

test('isNearLeadCap: within tolerance below the cap (35.5px, default 0.5px tolerance) is true',()=>{
  assert.equal(isNearLeadCap(35.5,36),true);
});

test('isNearLeadCap: just outside the default tolerance (35.49px) is false',()=>{
  assert.equal(isNearLeadCap(35.49,36),false);
});

test('isNearLeadCap: a custom tolerance is honored',()=>{
  assert.equal(isNearLeadCap(30,36,10),true);
  assert.equal(isNearLeadCap(20,36,10),false);
});

// --- P1-07 Root Cause Measurement Test / P4-04B2: isCapFrozenFrame (capFrozenFrame) ---
// Must measure an OUTCOME (no forward progress while the intended step would exceed maxLead), never
// a fixed-pixel proximity proxy — see movement.test.mjs's advancePredictedPosition tests for the
// production behavior this mirrors read-only. P4-04B2 replaced the old isNearLeadCap-based proximity
// gate with forwardStepPx, deriving `aheadBefore+forwardStepPx` — mathematically identical to
// production's own `aheadCandidate` — instead of a fixed 0.5px tolerance window that could miss the
// real freeze equilibrium value entirely (see the false-negative regression below).

test('isCapFrozenFrame: inactive (joystick not driving this frame) is never frozen, regardless of distance',()=>{
  assert.equal(isCapFrozenFrame({active:false,aheadBefore:36,aheadAfter:36,maxLead:36,forwardStepPx:2}),false);
});

test('isCapFrozenFrame: active, far from the cap, is never frozen even with zero progress (nothing to freeze against yet — aheadBefore+forwardStepPx still well under maxLead)',()=>{
  assert.equal(isCapFrozenFrame({active:true,aheadBefore:5,aheadAfter:5,maxLead:36,forwardStepPx:2}),false);
});

test('isCapFrozenFrame: active, the intended step would exceed maxLead, zero forward progress this frame — frozen',()=>{
  assert.equal(isCapFrozenFrame({active:true,aheadBefore:36,aheadAfter:36,maxLead:36,forwardStepPx:2}),true);
});

test('isCapFrozenFrame: active, still gaining real forward progress this frame — NOT frozen (proximity alone is never sufficient, matches the Root Cause Measurement Test\'s explicit "cannot use proximity as a crude proxy" requirement)',()=>{
  assert.equal(isCapFrozenFrame({active:true,aheadBefore:36,aheadAfter:40,maxLead:36,forwardStepPx:4}),false);
});

test('isCapFrozenFrame: active, at the cap, progress within the floating-point noise epsilon still counts as frozen',()=>{
  assert.equal(isCapFrozenFrame({active:true,aheadBefore:36,aheadAfter:36.005,maxLead:36,forwardStepPx:2}),true);
});

test('isCapFrozenFrame: null aheadBefore/aheadAfter/forwardStepPx (no active input direction to project onto, or step not supplied) is never frozen',()=>{
  assert.equal(isCapFrozenFrame({active:true,aheadBefore:null,aheadAfter:36,maxLead:36,forwardStepPx:2}),false);
  assert.equal(isCapFrozenFrame({active:true,aheadBefore:36,aheadAfter:null,maxLead:36,forwardStepPx:2}),false);
  assert.equal(isCapFrozenFrame({active:true,aheadBefore:36,aheadAfter:36,maxLead:36,forwardStepPx:null}),false);
});

test('isCapFrozenFrame: negative "ahead" (server legitimately caught up/passed predicted, P1-07D) is never near the cap, never frozen',()=>{
  assert.equal(isCapFrozenFrame({active:true,aheadBefore:-50,aheadAfter:-50,maxLead:36,forwardStepPx:2}),false);
});

// --- P4-04B2 Draft — Confirmed False-Negative Regression ---
// Reproduces the exact P4-04B1 Diagnostic finding: a continuously-held joystick at the current
// MOVE_SPEED_RATE/60fps freezes at aheadBefore≈49.3px (maxLead=50) — OUTSIDE the OLD fixed 0.5px
// tolerance window (49.5px), so the pre-P4-04B2 isNearLeadCap-gated rule would have reported "not
// frozen" for a frame that genuinely made zero forward progress because of the cap.

test('isCapFrozenFrame: P4-04B1\'s reproduced false-negative case — aheadBefore=49.3px, forwardStepPx≈2.14px (18/140*16.67ms, the production JOYSTICK_STEP_DISTANCE/JOYSTICK_SEND_INTERVAL_MS*60fps-frame step), maxLead=50 — now correctly detected as frozen',()=>{
  const aheadBefore=49.3,forwardStepPx=(18/140)*(1000/60),maxLead=50;
  assert.ok(aheadBefore<maxLead-TELEMETRY_LEAD_CAP_TOLERANCE_PX,'sanity: this aheadBefore sits OUTSIDE the old 0.5px tolerance window — the old proximity-based rule would have missed it');
  assert.equal(isCapFrozenFrame({active:true,aheadBefore,aheadAfter:aheadBefore,maxLead,forwardStepPx}),true,'the new forwardStepPx-based rule must still detect this as frozen — aheadBefore+forwardStepPx=51.4>50');
});

// --- P1-07 Root Cause Measurement Test: nextCapFrozenStreakMs (capFrozenDuration) ---

test('nextCapFrozenStreakMs: accumulates dt while frozen',()=>{
  let streak=0;
  streak=nextCapFrozenStreakMs(streak,true,16);
  streak=nextCapFrozenStreakMs(streak,true,16);
  streak=nextCapFrozenStreakMs(streak,true,16);
  assert.equal(streak,48);
});

test('nextCapFrozenStreakMs: resets to 0 the instant a frame is not frozen',()=>{
  let streak=nextCapFrozenStreakMs(0,true,100);
  assert.equal(streak,100);
  streak=nextCapFrozenStreakMs(streak,false,16);
  assert.equal(streak,0);
});

// --- P1-07 Root Cause Measurement Test: capFrozenRatio (capFrozenRatio) ---

test('capFrozenRatio: zero active time so far returns 0, not NaN/Infinity',()=>{
  assert.equal(capFrozenRatio(500,0),0);
});

test('capFrozenRatio: correct time-based ratio',()=>{
  assert.equal(capFrozenRatio(250,1000),0.25);
});

test('capFrozenRatio: never frozen returns exactly 0',()=>{
  assert.equal(capFrozenRatio(0,1000),0);
});

test('capFrozenRatio: frozen for the entire active window returns exactly 1',()=>{
  assert.equal(capFrozenRatio(1000,1000),1);
});

// --- P1-07 Root Cause Measurement Test: display formatting ---

test('formatPercent: null renders as the en-dash placeholder',()=>{
  assert.equal(formatPercent(null),'–');
});

test('formatPercent: formats as a one-decimal percentage',()=>{
  assert.equal(formatPercent(0.25),'25.0%');
  assert.equal(formatPercent(0),'0.0%');
  assert.equal(formatPercent(1),'100.0%');
});

test('formatPx: null renders as the en-dash placeholder',()=>{
  assert.equal(formatPx(null),'–');
});

test('formatPx: formats to one decimal place with a px suffix',()=>{
  assert.equal(formatPx(12.34),'12.3px');
  assert.equal(formatPx(0),'0.0px');
});

test('formatCount: null renders as the en-dash placeholder, distinct from a real zero count',()=>{
  assert.equal(formatCount(null),'–');
});

test('formatCount: formats an integer count as-is',()=>{
  assert.equal(formatCount(0),'0');
  assert.equal(formatCount(7),'7');
});

// --- P4-04B2 — Recent Movement Anomaly retention ---

test('P4-04B2 Recent Movement Anomaly constant is locked at its approved value',()=>{
  assert.equal(RECENT_EVENT_RETENTION_MS,5000);
});

test('shouldCommitFreezeEvent: a streak that just ended (previous>0, next===0) should commit',()=>{
  assert.equal(shouldCommitFreezeEvent(620,0),true);
});

test('shouldCommitFreezeEvent: a streak still in progress (next>0) never commits mid-freeze',()=>{
  assert.equal(shouldCommitFreezeEvent(600,616.67),false);
});

test('shouldCommitFreezeEvent: never-frozen frames (previous===0, next===0) never commit — a zero-duration streak is not a meaningful event',()=>{
  assert.equal(shouldCommitFreezeEvent(0,0),false);
});

test('buildRecentEvent: assembles the retained snapshot from the caller\'s already-tracked peak values, unchanged',()=>{
  const event=buildRecentEvent({freezeDurationMs:620,peakLeadPx:49.3,peakRttMs:640,peakGapMs:710,maxInFlight:5,now:12345});
  assert.deepEqual(event,{freezeDurationMs:620,peakLeadPx:49.3,peakRttMs:640,peakGapMs:710,maxInFlight:5,recordedAt:12345});
});

test('isRecentEventStale: a missing event is always stale (nothing to show)',()=>{
  assert.equal(isRecentEventStale(null,10000),true);
});

test('isRecentEventStale: within the retention window is not stale',()=>{
  const event=buildRecentEvent({freezeDurationMs:620,peakLeadPx:49.3,peakRttMs:640,peakGapMs:710,maxInFlight:5,now:10000});
  assert.equal(isRecentEventStale(event,10000+RECENT_EVENT_RETENTION_MS-1),false);
});

test('isRecentEventStale: past the retention window is stale',()=>{
  const event=buildRecentEvent({freezeDurationMs:620,peakLeadPx:49.3,peakRttMs:640,peakGapMs:710,maxInFlight:5,now:10000});
  assert.equal(isRecentEventStale(event,10000+RECENT_EVENT_RETENTION_MS+1),true);
});

test('isRecentEventStale: a custom retention window is honored',()=>{
  const event=buildRecentEvent({freezeDurationMs:620,peakLeadPx:49.3,peakRttMs:640,peakGapMs:710,maxInFlight:5,now:10000});
  assert.equal(isRecentEventStale(event,10500,1000),false);
  assert.equal(isRecentEventStale(event,11500,1000),true);
});

test('formatEventAge: formats the elapsed time since the event as "N.Ns ago"',()=>{
  const event=buildRecentEvent({freezeDurationMs:620,peakLeadPx:49.3,peakRttMs:640,peakGapMs:710,maxInFlight:5,now:10000});
  assert.equal(formatEventAge(event,12100),'2.1s ago');
});
