import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {battleAlreadyActiveFromMoveResponse} from '../public/app.js';

// P4-02 Merge Gate Race Fix — public/app.js is a browser entry module (its only top-level side
// effect, `boot()`, is guarded behind `typeof document!=='undefined'` specifically so this import is
// safe and side-effect-free in Node — see that guard's own comment in public/app.js). This lets us
// exercise the real, exported decision function sendWorldMove() actually calls, rather than
// re-implementing/mocking it — the same principle test/movement.test.mjs already follows for
// public/movement.js's pure functions.
const appSource=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');

// Fixture response shapes, shaped exactly like real server.mjs /api/commands/world/move responses
// (see server.mjs's moveWorld() and test/world-encounter.test.mjs's P4-02-D/E for the real shapes).
const encounterTriggeredResponse=Object.freeze({status:'ACCEPTED',data:{worldPosition:{x:550,y:200},state:'IN_WORLD',throttled:false,collided:false,staleSequence:false,encounterTriggered:true,battleId:'battle-a',monsterId:'world-bandit-1'}});
const battleActiveRejectedResponse=Object.freeze({status:'REJECTED',errorCode:'ERR_BATTLE_ACTIVE'});
const ordinaryAcceptedResponse=Object.freeze({status:'ACCEPTED',data:{worldPosition:{x:300,y:220},state:'IN_WORLD',throttled:false,collided:false,staleSequence:false}});
const ordinaryRejectedResponse=Object.freeze({status:'REJECTED',errorCode:'ERR_INVALID_WORLD_TARGET'});

test('battleAlreadyActiveFromMoveResponse: correctly classifies every response shape sendWorldMove can receive',()=>{
  assert.equal(battleAlreadyActiveFromMoveResponse(encounterTriggeredResponse),true);
  assert.equal(battleAlreadyActiveFromMoveResponse(battleActiveRejectedResponse),true);
  assert.equal(battleAlreadyActiveFromMoveResponse(ordinaryAcceptedResponse),false);
  assert.equal(battleAlreadyActiveFromMoveResponse(ordinaryRejectedResponse),false);
  assert.equal(battleAlreadyActiveFromMoveResponse({status:'ACCEPTED',data:{encounterTriggered:false}}),false);
  assert.equal(battleAlreadyActiveFromMoveResponse(null),false);
  assert.equal(battleAlreadyActiveFromMoveResponse(undefined),false);
});

// P4-02-M: Encounter completion reorder. Reproduces the exact race the P4-02 Merge Gate review
// flagged: request A genuinely triggers a world encounter server-side and its own response carries
// encounterTriggered:true; a later request B bounces off the server's battleIsActive() guard and gets
// ERR_BATTLE_ACTIVE. Their HTTP completions can arrive in EITHER order. The fix must not depend on
// which one sendWorldMove happens to process first — both must independently signal
// "battle-already-active" so that whichever one is actually processed takes the resync path.
test('P4-02-M: encounter completion reorder — both the (delayed) encounterTriggered response and the (early) ERR_BATTLE_ACTIVE response independently force the resync path, in either processing order',()=>{
  // Order 1: B (the later request) is processed first, as the review's race describes.
  const bProcessedFirst=battleAlreadyActiveFromMoveResponse(battleActiveRejectedResponse);
  const aProcessedSecond=battleAlreadyActiveFromMoveResponse(encounterTriggeredResponse);
  assert.equal(bProcessedFirst,true,'B (ERR_BATTLE_ACTIVE) must force resync even though it completed first');
  assert.equal(aProcessedSecond,true,'A (encounterTriggered:true) must still force resync even though it completed second and arrives after B already resynced');

  // Order 2 (reversed): A is processed first, B second — the predicate takes no shared/ordering
  // state (no closure over latestCompletedMovementSequence or similar), so there is no "which one
  // came first" input for it to be sensitive to; both orders must produce identical results.
  const aProcessedFirst=battleAlreadyActiveFromMoveResponse(encounterTriggeredResponse);
  const bProcessedSecond=battleAlreadyActiveFromMoveResponse(battleActiveRejectedResponse);
  assert.equal(aProcessedFirst,bProcessedFirst);
  assert.equal(bProcessedSecond,aProcessedSecond);

  // Structural proof this predicate is actually wired in FRONT of the completion-order discard in
  // sendWorldMove — a passing predicate alone doesn't prove the race is closed if the discard could
  // still run first and `return` before the predicate is ever consulted.
  const gateIndex=appSource.indexOf('if(battleAlreadyActiveFromMoveResponse(r)){');
  const discardIndex=appSource.indexOf('if(requestSequence<latestCompletedMovementSequence){');
  assert.ok(gateIndex>=0,'battleAlreadyActiveFromMoveResponse gate must exist in sendWorldMove');
  assert.ok(discardIndex>=0,'the completion-order discard must still exist, unremoved');
  assert.ok(gateIndex<discardIndex,'the battle-already-active gate must run BEFORE the completion-order discard, or an older response could still be silently dropped before the gate ever sees it');

  // Structural proof the gate's own branch unconditionally suspends prediction and resyncs via the
  // existing refresh() — not gated behind `stale`, matching the "regardless of order" requirement,
  // and never reconstructing battle state locally (no direct S.battle assignment in this branch).
  const gateBranch=appSource.slice(gateIndex,discardIndex);
  assert.ok(/predictionSuspended=true;/.test(gateBranch));
  assert.ok(/await refresh\(\);/.test(gateBranch));
  assert.ok(!/if\(!stale\)/.test(gateBranch),'the battle-already-active branch must not be gated behind the stale-generation check');
});

// P4-02-N: ERR_BATTLE_ACTIVE alone forces resync (lost-response case). Simulates a client that, for
// any reason, never receives the original triggering response at all (e.g. it was itself the request
// that got ERR_BATTLE_ACTIVE, or the triggering response was lost/timed out) — the ONLY signal this
// client ever sees is a bare REJECTED/ERR_BATTLE_ACTIVE. That alone must still be enough to recover
// the existing ACTIVE battle, without ever having seen an encounterTriggered:true response.
test('P4-02-N: ERR_BATTLE_ACTIVE alone (no encounterTriggered response ever received) still forces prediction-suspend + resync',()=>{
  assert.equal(battleAlreadyActiveFromMoveResponse(battleActiveRejectedResponse),true);
  // The predicate needs nothing beyond {status,errorCode} — no `data`, no battleId/monsterId — proving
  // it cannot possibly depend on having seen the original triggering response's payload.
  assert.deepEqual(Object.keys(battleActiveRejectedResponse),['status','errorCode']);

  // A plain ERR_BATTLE_ACTIVE response has no `.data` at all (see server.mjs's REJECTED shape) — the
  // resync branch must tolerate that (optional chaining), never throwing on `r.data.throttled`.
  assert.doesNotThrow(()=>battleAlreadyActiveFromMoveResponse({status:'REJECTED',errorCode:'ERR_BATTLE_ACTIVE'}));
  const gateBranch=appSource.slice(appSource.indexOf('if(battleAlreadyActiveFromMoveResponse(r)){'),appSource.indexOf('if(requestSequence<latestCompletedMovementSequence){'));
  assert.ok(/r\.data\?\.throttled/.test(gateBranch)&&/r\.data\?\.collided/.test(gateBranch),'telemetry recording in the resync branch must use optional chaining, since a REJECTED response has no .data');
});

// Regression guard (requirement #5/#7 of the Merge Gate fix): a genuinely ordinary REJECTED response
// (not ERR_BATTLE_ACTIVE) must still fall through to the ORIGINAL, unmodified REJECTED handling —
// still respecting `stale`, still toasting via describeWorldMoveError — completely untouched by this
// fix. And an ordinary stale ACCEPTED response's handling block (shouldSuspendAfterAccepted/
// catchUpDebtAfterGrant, gated on `!stale`) must still exist, unremoved and unmodified in shape.
test('normal (non-battle-active) REJECTED and stale ACCEPTED handling are completely unchanged by this fix',()=>{
  assert.equal(battleAlreadyActiveFromMoveResponse(ordinaryRejectedResponse),false);
  assert.ok(appSource.includes(`console.warn('sendWorldMove: REJECTED',r.errorCode);\n      toast(describeWorldMoveError(r.errorCode));\n      predictionSuspended=true;`),'the ordinary REJECTED handling block must be byte-for-byte unchanged');
  assert.ok(appSource.includes('predictionSuspended=shouldSuspendAfterAccepted(r.data);'),'the ordinary ACCEPTED prediction-suspend decision must still exist unchanged');
  assert.ok(appSource.includes("if(r.data.collided&&!stale)toast('撞到障礙物');"),'the stale-gated collision toast must still exist unchanged');
});
