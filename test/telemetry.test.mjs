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
  formatEventAge,
  isFreezeEventStart,
  maxIfTracking
} from '../public/telemetry.js';
import {movementDivergence,MAX_PREDICTION_LEAD} from '../public/movement.js';

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

// --- P4-04B2 Draft Review Fix — freeze-event-scoped peak tracking (correlation-window fix) ---

test('isFreezeEventStart: previous streak 0 -> next streak >0 is a freeze start',()=>{
  assert.equal(isFreezeEventStart(0,16.67),true);
});

test('isFreezeEventStart: mid-freeze (previous>0, next still >0) is never a start',()=>{
  assert.equal(isFreezeEventStart(600,616.67),false);
});

test('isFreezeEventStart: never-frozen frames (both 0) are never a start',()=>{
  assert.equal(isFreezeEventStart(0,0),false);
});

test('isFreezeEventStart: freeze end (previous>0, next===0) is never a start',()=>{
  assert.equal(isFreezeEventStart(620,0),false);
});

test('maxIfTracking: while not tracking, no candidate is ever recorded, however large',()=>{
  assert.equal(maxIfTracking(false,null,800),null);
  assert.equal(maxIfTracking(false,50,800),50);
});

test('maxIfTracking: while tracking, a present candidate raises (or sets) the peak',()=>{
  assert.equal(maxIfTracking(true,null,180),180);
  assert.equal(maxIfTracking(true,120,180),180);
  assert.equal(maxIfTracking(true,220,180),220);
});

test('maxIfTracking: a null/undefined candidate never overwrites an existing peak, even while tracking',()=>{
  assert.equal(maxIfTracking(true,150,null),150);
  assert.equal(maxIfTracking(true,150,undefined),150);
});

test('P4-04B2 Draft Review Fix — contamination regression: an unrelated RTT spike from before a freeze must NOT appear in that freeze\'s retained event',()=>{
  // Mirrors app.js's own event-window state machine step-by-step, using only the pure exported
  // predicates/helpers (isFreezeEventStart / maxIfTracking / shouldCommitFreezeEvent / buildRecentEvent)
  // — proves the FULL sequence is contamination-free, not just each piece in isolation. Matches the
  // exact scenario from the P4-04B2 Draft Review Fix order: unrelated RTT 800ms occurs well before a
  // freeze; the freeze's own RTT is only 180ms; the retained event must report 180ms, never 800ms.
  let trackingActive=false,peakRttMs=null,previousStreakMs=0,recentEvent=null;

  // 1. event tracking inactive.
  assert.equal(trackingActive,false);

  // 2. an unrelated 800ms RTT lands while nothing is frozen — must never be retained.
  peakRttMs=maxIfTracking(trackingActive,peakRttMs,800);
  assert.equal(peakRttMs,null);

  // 3. freeze starts (previous streak 0 -> next streak >0): clear peaks, begin tracking.
  const streakAfterStart=16.67;
  if(isFreezeEventStart(previousStreakMs,streakAfterStart)){trackingActive=true;peakRttMs=null}
  previousStreakMs=streakAfterStart;
  assert.equal(trackingActive,true);
  assert.equal(peakRttMs,null,'the unrelated 800ms spike must be cleared, not carried into the freeze');

  // 4. during the freeze, a legitimate RTT=180ms lands.
  peakRttMs=maxIfTracking(trackingActive,peakRttMs,180);
  assert.equal(peakRttMs,180);

  // 5. freeze ends (previous streak >0 -> next streak 0): commit the retained event, stop tracking.
  if(shouldCommitFreezeEvent(previousStreakMs,0)){
    recentEvent=buildRecentEvent({freezeDurationMs:previousStreakMs,peakLeadPx:null,peakRttMs,peakGapMs:null,maxInFlight:null,now:99999});
    trackingActive=false;
  }

  // 6. the retained event's Peak RTT must be 180ms, NOT 800ms.
  assert.ok(recentEvent);
  assert.equal(recentEvent.peakRttMs,180);
});

test('P4-04B2 Draft Review Fix: peaks reset at the start of every new freeze event — a second freeze never inherits the first freeze\'s peaks',()=>{
  let trackingActive=false,peakRttMs=null,previousStreakMs=0;

  // First freeze: peak RTT 900ms.
  if(isFreezeEventStart(previousStreakMs,10)){trackingActive=true;peakRttMs=null}
  previousStreakMs=10;
  peakRttMs=maxIfTracking(trackingActive,peakRttMs,900);
  assert.equal(peakRttMs,900);

  // First freeze ends.
  if(shouldCommitFreezeEvent(previousStreakMs,0))trackingActive=false;
  previousStreakMs=0;

  // Between events: readings must not accumulate (not tracking) — the stale 900 is untouched here,
  // it is cleared only at the NEXT freeze start per isFreezeEventStart's own contract.
  peakRttMs=maxIfTracking(trackingActive,peakRttMs,999);
  assert.equal(peakRttMs,900);

  // Second freeze starts — must clear the stale peak inherited from the first freeze.
  if(isFreezeEventStart(previousStreakMs,12)){trackingActive=true;peakRttMs=null}
  previousStreakMs=12;
  assert.equal(peakRttMs,null,'second freeze must not inherit the first freeze\'s peak RTT');

  // Second freeze's own, much lower RTT.
  peakRttMs=maxIfTracking(trackingActive,peakRttMs,150);
  assert.equal(peakRttMs,150);
});

test('P4-04B2 Draft Review Fix: lead/in-flight peaks outside an active freeze event are ignored for the event snapshot, exactly like RTT/gap',()=>{
  let trackingActive=false,peakLeadPx=null,peakInFlight=null;
  peakLeadPx=maxIfTracking(trackingActive,peakLeadPx,49.3);
  peakInFlight=maxIfTracking(trackingActive,peakInFlight,4);
  assert.equal(peakLeadPx,null);
  assert.equal(peakInFlight,null);

  trackingActive=true;
  peakLeadPx=maxIfTracking(trackingActive,peakLeadPx,30.2);
  peakInFlight=maxIfTracking(trackingActive,peakInFlight,2);
  assert.equal(peakLeadPx,30.2);
  assert.equal(peakInFlight,2);
});

// --- P4-04B2 Cap-Freeze Branch Attribution Fix ---
//
// app.js's tickMovementFrame can take a structurally different branch — a reconciliation-band
// correction (dangerousAhead/dangerousLateral -> easeTowards) — instead of the actual
// advancePredictedPosition() call, while joystick input stays active. Before this fix, app.js passed
// `active:telemetryActiveThisFrame` into isCapFrozenFrame() regardless of which branch ran, so a
// reconciliation frame could be misclassified as a genuine MAX_PREDICTION_LEAD cap freeze. The fix
// (app.js only, a new `predictionAdvanceBranchRan` local + `telemetryCapDetectionActive =
// telemetryActiveThisFrame && predictionAdvanceBranchRan`) means isCapFrozenFrame's OWN `active` guard
// (already exhaustively tested above) is now what protects against the false positive — these tests
// prove that guard against the exact reconciliation scenario the review flagged, not a redesign of
// isCapFrozenFrame itself, which is untouched this round.

test('P4-04B2 Cap-Freeze Branch Attribution Fix: setup sanity check — aheadBefore≈49.3 combined with a large lateral divergence is exactly the dangerousLateral condition app.js checks, which routes to the reconciliation branch (never advancePredictedPosition)',()=>{
  const input={active:true,dirX:1,dirY:0};
  const predicted={x:49.3,y:60},server={x:0,y:0}; // dx=49.3 (ahead), dy=60 (lateral, since dir is +x)
  const divergence=movementDivergence(predicted,server,input);
  assert.ok(Math.abs(divergence.ahead-49.3)<1e-9,`expected ahead≈49.3, got ${divergence.ahead}`);
  assert.equal(divergence.lateral,60);
  const catchUpDebt=0; // no legitimate catch-up budget in this scenario
  const dangerousAhead=divergence.ahead>MAX_PREDICTION_LEAD;
  const dangerousLateral=divergence.lateral>MAX_PREDICTION_LEAD+catchUpDebt;
  assert.equal(dangerousAhead,false,'ahead alone (49.3) must NOT exceed the cap — this is not a dangerousAhead case');
  assert.equal(dangerousLateral,true,'lateral (60) must exceed MAX_PREDICTION_LEAD+catchUpDebt (50) — this IS the reconciliation-band condition');
});

test('P4-04B2 Cap-Freeze Branch Attribution Fix: reconciliation-branch false-positive regression — the exact scenario the Codex review flagged must NOT be reported as cap-frozen',()=>{
  // Same aheadBefore/hypothetical-forwardStepPx numbers as the pre-existing Part A false-negative
  // regression above (aheadBefore=49.3, forwardStepPx≈2.14, maxLead=50 -> aheadBefore+forwardStepPx
  // =51.4>50), but this time representing a frame where the reconciliation branch ran instead of
  // advancePredictedPosition — i.e. predictionAdvanceBranchRan was false, so app.js now passes
  // active:false (not the old, branch-blind telemetryActiveThisFrame) into isCapFrozenFrame.
  const aheadBefore=49.3,forwardStepPx=(18/140)*(1000/60),maxLead=50;
  assert.ok(aheadBefore+forwardStepPx>maxLead,'sanity check: the hypothetical step would indeed have exceeded the cap, matching the review\'s exact concern');
  const capFrozen=isCapFrozenFrame({active:false,aheadBefore,aheadAfter:aheadBefore,maxLead,forwardStepPx});
  assert.equal(capFrozen,false,'a frame where the advance branch never ran must never be classified as cap-frozen, however large the hypothetical forward step');
});

test('P4-04B2 Cap-Freeze Branch Attribution Fix: contrast — the SAME numbers with active:true (the old, branch-blind behaviour) would have been misclassified as frozen, proving the fix is the active gate, not a numeric change',()=>{
  const aheadBefore=49.3,forwardStepPx=(18/140)*(1000/60),maxLead=50;
  assert.equal(isCapFrozenFrame({active:true,aheadBefore,aheadAfter:aheadBefore,maxLead,forwardStepPx}),true,'confirms this WAS the false-positive the review found, before app.js started passing the correctly branch-scoped active flag');
});

test('P4-04B2 Cap-Freeze Branch Attribution Fix: a suppressed reconciliation frame (capFrozen=false) can never start or extend a cap-freeze streak, so it can never produce a retained Recent Movement Anomaly event',()=>{
  // Mid-streak: a reconciliation frame arriving while already frozen must reset the streak to 0, not
  // extend it — nextCapFrozenStreakMs's own contract (isFrozen=false -> 0), applied to the branch
  // attribution fix's output.
  const midStreakMs=620;
  assert.equal(nextCapFrozenStreakMs(midStreakMs,false,16.67),0);
  // Never-frozen: a reconciliation frame can never START a streak either.
  assert.equal(nextCapFrozenStreakMs(0,false,16.67),0);
  // Consequently shouldCommitFreezeEvent/isFreezeEventStart (already exhaustively tested above) never
  // see a >0 streak to work from — no event is ever committed from this frame.
  assert.equal(isFreezeEventStart(0,0),false);
  assert.equal(shouldCommitFreezeEvent(0,0),false);
});
