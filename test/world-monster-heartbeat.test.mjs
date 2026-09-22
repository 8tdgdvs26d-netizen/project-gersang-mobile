import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {WORLD_MONSTER_DEFINITIONS,patrolPositionAt,patrolSegmentsBetween,segmentEntersEncounterRadius} from '../public/worldmonsters.js';
import {battleAlreadyActiveFromWorldResponse} from '../public/app.js';

// P4-03B — Active Monster -> Stationary Player Encounter. Covers acceptance tests A through U from
// the approved P4-03B Coding Order (itself following the P4-03B Audit and Design Clarification
// Gate). V/W/X/Y are regression gates reported at the npm-test level (re-running the existing test
// files / the full suite), not individual tests defined here — matching the exact precedent already
// established by test/world-monster-patrol.test.mjs's own J/K/L.

const monster=WORLD_MONSTER_DEFINITIONS[0];
const legDistance=Math.hypot(monster.patrolB.x-monster.patrolA.x,monster.patrolB.y-monster.patrolA.y);
const legDurationMs=legDistance/monster.patrolSpeed;
// Far from the patrol route (y=220, x in [440,560]), every OBSTACLES rect (x in [550,720], y in
// [400,550]), and every city's entryRadius (all four cities sit at (220|780,220|780), radius 48) —
// safely outside encounterRadius of anything relevant.
const SAFE_FAR={x:500,y:600};

// ============================================================================
// A-D: pure patrolSegmentsBetween / bounded-lookback proofs — no server needed.
// ============================================================================

// A: turnaround crossing — the naive straight previousTime->now segment misses the player entirely,
// but the real piecewise patrol path (crossing one turnaround) hits them.
test('P4-03B-A: a straight previousTime->now segment would miss the player entirely, but the real piecewise patrol path (crossing one turnaround) hits them',()=>{
  const anchor=monster.patrolAnchorAt;
  // A window straddling the A->B turnaround at anchor+legDurationMs, chosen so the naive direct
  // segment is degenerate — mirrors the exact 530->560->530 worked example from the Design
  // Clarification Gate. The +-3000ms half-width (not just any symmetric width) matters: the naive
  // degenerate point always sits patrolSpeed*halfWidth away from the turnaround apex (B); at 3000ms
  // that is 60px, comfortably outside encounterRadius (40px) — a genuine margin, not a coincidental
  // boundary value (same reasoning as P4-03A's own route-widening review fix).
  const fromTime=anchor+legDurationMs-3000,toTime=anchor+legDurationMs+3000;
  const naiveFrom=patrolPositionAt(monster,fromTime),naiveTo=patrolPositionAt(monster,toTime);
  assert.deepEqual(naiveFrom,naiveTo,'sanity: the naive straight segment must be degenerate (zero-length) for this window, which is exactly why it is wrong');
  const segments=patrolSegmentsBetween(monster,fromTime,toTime);
  assert.equal(segments.length,2,'the real path must be split at the one turnaround it crosses');
  assert.deepEqual(segments,[{from:naiveFrom,to:monster.patrolB},{from:monster.patrolB,to:naiveTo}]);
  // A player standing at patrolB itself: the real path passes through B (the turnaround apex)
  // during this window, but the degenerate naive segment (a single point, not at B) never could.
  const playerAtApex={position:monster.patrolB,encounterRadius:monster.encounterRadius};
  assert.equal(segmentEntersEncounterRadius(naiveFrom,naiveTo,playerAtApex),false,'the naive degenerate segment must NOT detect the apex hit');
  assert.equal(segments.some(seg=>segmentEntersEncounterRadius(seg.from,seg.to,playerAtApex)),true,'the real piecewise path MUST detect the apex hit — this is exactly the bug patrolSegmentsBetween fixes');
});

// B: safe sweep — a patrol window whose real path never comes near the player produces no hit on
// any segment.
test('P4-03B-B: a patrol window whose real path never comes near the player produces no hit on any segment',()=>{
  const anchor=monster.patrolAnchorAt;
  const segments=patrolSegmentsBetween(monster,anchor,anchor+legDurationMs*2.5);
  assert.ok(segments.length>=2);
  const farAwayPlayer={position:{x:monster.patrolA.x,y:monster.patrolA.y+500},encounterRadius:monster.encounterRadius};
  for(const seg of segments)assert.equal(segmentEntersEncounterRadius(seg.from,seg.to,farAwayPlayer),false);
});

// C: exact turnaround boundary — no duplicate/missing segment, and (by construction, verified
// below) no duplicate battle.
test('P4-03B-C: an interval starting or ending exactly on a turnaround timestamp produces neither a duplicate nor a missing segment',()=>{
  const anchor=monster.patrolAnchorAt;
  const startsAtTurnaround=patrolSegmentsBetween(monster,anchor+legDurationMs,anchor+legDurationMs+1500);
  assert.equal(startsAtTurnaround.length,1,'starting exactly at a turnaround must not re-add it as a spurious extra leading segment');
  assert.deepEqual(startsAtTurnaround[0].from,monster.patrolB);
  const endsAtTurnaround=patrolSegmentsBetween(monster,anchor+legDurationMs-1500,anchor+legDurationMs*2);
  assert.equal(endsAtTurnaround.length,2,'ending exactly at a turnaround must not add a spurious trailing zero-length segment');
  assert.deepEqual(endsAtTurnaround.at(-1).to,monster.patrolA);
  // Even if segment boundaries were ever (incorrectly) duplicated, server.mjs's
  // evaluateWorldMonsterExposure() only ever creates a battle on the FIRST segment whose .some()
  // predicate matches, then returns immediately — structurally impossible to create a second battle
  // from a duplicate/extra segment within one evaluation call.
  const serverSource=readFileSync(new URL('../server.mjs',import.meta.url),'utf8');
  const evalStart=serverSource.indexOf('function evaluateWorldMonsterExposure('),evalEnd=serverSource.indexOf('function worldHeartbeat(');
  const evalBody=serverSource.slice(evalStart,evalEnd);
  assert.ok(evalBody.includes('if(!hit)continue;'),'evaluateWorldMonsterExposure must only act on an actual hit');
  assert.ok(evalBody.includes('return{monsterId:m.id,battleId:battle.battleId};'),'evaluateWorldMonsterExposure must return immediately on the first hit, never continuing to check further segments/monsters in the same call');
});

// D: bounded multiple-cycle protection — a huge stale interval never causes unbounded work in the
// primitive itself, and the real server always caps the interval it hands to it.
test('P4-03B-D: patrolSegmentsBetween stays bounded and fast even for a huge interval, and server.mjs always caps the interval it is given before calling it',()=>{
  const hugeSpanMs=legDurationMs*2*1000; // 1000 full patrol cycles
  const startedAt=Date.now();
  const segments=patrolSegmentsBetween(monster,0,hugeSpanMs);
  const elapsedMs=Date.now()-startedAt;
  assert.equal(segments.length,hugeSpanMs/legDurationMs);
  assert.ok(elapsedMs<500,`patrolSegmentsBetween over 1000 cycles must stay fast (took ${elapsedMs}ms) — no unbounded/exponential blowup`);
  const serverSource=readFileSync(new URL('../server.mjs',import.meta.url),'utf8');
  const boundedStart=serverSource.indexOf('function boundedExposureFromTime(characterId,now){');
  const boundedEnd=serverSource.indexOf('function advanceWorldExposureWatermark(');
  const boundedBody=serverSource.slice(boundedStart,boundedEnd);
  assert.ok(boundedBody.includes('Math.min(now,Math.max(raw,now-MAX_WORLD_EXPOSURE_LOOKBACK_MS))'),'boundedExposureFromTime must cap the window at MAX_WORLD_EXPOSURE_LOOKBACK_MS behind now');
  assert.ok(serverSource.includes('const MAX_WORLD_EXPOSURE_LOOKBACK_MS=2000;'));
  const heartbeatStart=serverSource.indexOf('function worldHeartbeat(env){'),heartbeatEnd=serverSource.indexOf('function moveWorld(env){');
  assert.ok(serverSource.slice(heartbeatStart,heartbeatEnd).includes('boundedExposureFromTime(characterId,now)'),'worldHeartbeat must pass its window through boundedExposureFromTime before calling evaluateWorldMonsterExposure');
  const moveWorldEnd=serverSource.indexOf('async function api(');
  assert.ok(serverSource.slice(heartbeatEnd,moveWorldEnd).includes("boundedExposureFromTime('char-demo',now)"),'moveWorld must also pass its window through boundedExposureFromTime before calling evaluateWorldMonsterExposure');
});

// ============================================================================
// E-Q: real-server integration tests, sharing one spawned server/db for the whole file (spawning a
// fresh Node process per test would be prohibitively slow — same precedent as
// test/world-monster-patrol.test.mjs and test/world-encounter.test.mjs).
// ============================================================================

let child,base,dir,sessionId;
const dbPath=()=>join(dir,'test.sqlite');
const request=async(path,options={})=>{const r=await fetch(base+path,{headers:{'content-type':'application/json'},...options});return r.json()};
const post=(path,body)=>request(path,{method:'POST',body:JSON.stringify(body)});
const envelope=(key,payload)=>({commandId:crypto.randomUUID(),idempotencyKey:key,sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const setPosition=(x,y,state)=>{const fixture=new DatabaseSync(dbPath());fixture.prepare(`UPDATE characters SET world_x=?,world_y=?,state=? WHERE id='char-demo'`).run(x,y,state);fixture.close()};
const rawQuery=(sql,...params)=>{const fixture=new DatabaseSync(dbPath());const rows=fixture.prepare(sql).all(...params);fixture.close();return rows};
const rawRun=(sql,...params)=>{const fixture=new DatabaseSync(dbPath());fixture.prepare(sql).run(...params);fixture.close()};
// Test isolation between the many encounter-triggering tests below: clears the one-shot consumption
// ledger and ends any leftover ACTIVE battle from a previous test, then places the player at (x,y)
// in `state`. Deliberately does NOT touch worldExposureWatermark (an in-memory Map inside the
// spawned server process, not reachable from this test process) — tests that need a specific
// watermark state establish it themselves via a real heartbeat/moveWorld call first, matching how a
// real client would (see each test's own comment).
const resetWorldState=(x,y,state='IN_WORLD')=>{
  const fixture=new DatabaseSync(dbPath());
  fixture.prepare(`DELETE FROM world_monster_encounters WHERE character_id='char-demo'`).run();
  fixture.prepare(`UPDATE battles SET status='RETREATED' WHERE character_id='char-demo' AND status='ACTIVE'`).run();
  fixture.prepare(`UPDATE characters SET world_x=?,world_y=?,state=? WHERE id='char-demo'`).run(x,y,state);
  fixture.close();
};
let idKeyCounter=0;
const nextKey=prefix=>`${prefix}-${++idKeyCounter}-${crypto.randomUUID()}`;
let moveSeq=0;
const nextMoveSequence=()=>++moveSeq;
const spawnServer=async()=>{
  const c=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:dbPath()},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{c.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});c.on('exit',code=>reject(new Error(`server exited ${code}`)))});
  return {child:c,base:`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`};
};
// Q and R each need a decoy position that stays SAFELY far from wherever the real monster ends up
// after a several-second real-time wait, regardless of which leg/direction it happened to be on when
// the test started (uncontrolled — driven by real wall-clock time, not a seeded/mockable clock). The
// true leg midpoint sits legDistance/2=60px from BOTH turnarounds — the maximum possible margin — so
// a wait of up to 3000ms (60/0.02) can never cross a turnaround and reverse back toward the decoy by
// pure real-time phase luck, keeping distance-from-decoy a deterministic `elapsed*patrolSpeed`
// instead of something that depends on exactly where in the cycle the monster happened to be.
async function waitForPatrolMidpoint(afterTime){
  const cycleDurationMs=legDurationMs*2,anchor=monster.patrolAnchorAt;
  let target=Infinity;
  for(const c of [anchor+legDurationMs/2,anchor+legDurationMs*1.5]){
    const k=Math.ceil((afterTime-c)/cycleDurationMs),t=c+k*cycleDurationMs;
    if(t<target)target=t;
  }
  const delay=target-afterTime;
  if(delay>0)await wait(delay+50);
  return {time:target,position:patrolPositionAt(monster,target)};
}

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-world-monster-heartbeat-'));
  ({child,base}=await spawnServer());
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

// E: a genuinely stationary player — placed on the patrol route BEFORE the monster's real,
// continuing patrol motion sweeps through that exact point; a heartbeat sent only after that real
// crossing has happened must catch it.
test('P4-03B-E: a stationary player whom the monster patrols into is caught by heartbeat — exactly one battle, one consumption row',async()=>{
  resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const seed=await post('/api/commands/world/heartbeat',envelope(nextKey('e-seed'),{}));
  assert.equal(seed.status,'ACCEPTED');
  const live=await request('/api/character/char-demo/snapshot');
  assert.ok(live.worldMonsters.some(m=>m.id==='world-bandit-1'),'expected world-bandit-1 to be available before the test');
  const rendezvousAt=live.serverNowMs+800;
  const rendezvousPos=patrolPositionAt(monster,rendezvousAt);
  setPosition(rendezvousPos.x,rendezvousPos.y,'IN_WORLD');
  await wait(950); // real wall-clock time must actually pass the rendezvous instant before we check
  const hb=await post('/api/commands/world/heartbeat',envelope(nextKey('e-hit'),{}));
  assert.equal(hb.status,'ACCEPTED');
  assert.equal(hb.data.encounterTriggered,true);
  assert.equal(hb.data.monsterId,'world-bandit-1');
  assert.equal(rawQuery(`SELECT id FROM battles WHERE character_id='char-demo' AND status='ACTIVE'`).length,1);
  assert.equal(rawQuery(`SELECT * FROM world_monster_encounters WHERE character_id='char-demo' AND monster_id='world-bandit-1'`).length,1);
});

// F: repeated heartbeat — same idempotency key (idem()'s own exact-replay cache) and a brand-new key
// (blocked by battleIsActive()) — neither creates a second battle.
test('P4-03B-F: repeated heartbeat (same or new idempotency key) never creates a second battle',async()=>{
  resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const p=(await request('/api/character/char-demo/snapshot')).worldMonsters.find(m=>m.id==='world-bandit-1').position;
  setPosition(p.x,p.y,'IN_WORLD');
  const key=nextKey('f-key');
  const first=await post('/api/commands/world/heartbeat',envelope(key,{}));
  assert.equal(first.status,'ACCEPTED');assert.equal(first.data.encounterTriggered,true);
  const replay=await post('/api/commands/world/heartbeat',envelope(key,{}));
  assert.deepEqual(replay,first,'the exact same idempotency key must return the exact same cached result');
  const fresh=await post('/api/commands/world/heartbeat',envelope(nextKey('f-newkey'),{}));
  assert.equal(fresh.status,'REJECTED');
  assert.equal(fresh.errorCode,'ERR_BATTLE_ACTIVE');
  assert.equal(rawQuery(`SELECT id FROM battles WHERE character_id='char-demo' AND status='ACTIVE'`).length,1);
  assert.equal(rawQuery(`SELECT * FROM world_monster_encounters WHERE character_id='char-demo' AND monster_id='world-bandit-1'`).length,1);
});

// G: lost response retry — simulated by literally calling the same idempotencyKey a second time
// (indistinguishable, server-side, from a client that never saw the first response and retried).
test('P4-03B-G: retrying the same heartbeat command (lost-response simulation) creates exactly one battle',async()=>{
  resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const p=(await request('/api/character/char-demo/snapshot')).worldMonsters.find(m=>m.id==='world-bandit-1').position;
  setPosition(p.x,p.y,'IN_WORLD');
  const key=nextKey('g-key');
  const attempt1=await post('/api/commands/world/heartbeat',envelope(key,{}));
  const attempt2=await post('/api/commands/world/heartbeat',envelope(key,{}));
  assert.equal(attempt1.data.encounterTriggered,true);
  assert.deepEqual(attempt2,attempt1);
  assert.equal(rawQuery(`SELECT * FROM world_monster_encounters WHERE character_id='char-demo' AND monster_id='world-bandit-1'`).length,1);
});

// H: ACTIVE battle guard — a heartbeat while a battle is already ACTIVE is rejected before any
// exposure evaluation runs at all (no consumption row is written).
test('P4-03B-H: heartbeat is rejected with ERR_BATTLE_ACTIVE while a battle is already ACTIVE, with no new consumption',async()=>{
  resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  rawRun(`INSERT INTO battles VALUES(?,?,?,?,?)`,'h-fake-battle','char-demo','ACTIVE',Date.now(),Date.now());
  const p=(await request('/api/character/char-demo/snapshot')).worldMonsters.find(m=>m.id==='world-bandit-1').position;
  setPosition(p.x,p.y,'IN_WORLD');
  const hb=await post('/api/commands/world/heartbeat',envelope(nextKey('h-key'),{}));
  assert.equal(hb.status,'REJECTED');
  assert.equal(hb.errorCode,'ERR_BATTLE_ACTIVE');
  assert.equal(rawQuery(`SELECT * FROM world_monster_encounters WHERE character_id='char-demo' AND monster_id='world-bandit-1'`).length,0);
  rawRun(`UPDATE battles SET status='RETREATED' WHERE id='h-fake-battle'`);
});

// I: a consumed monster never triggers again, even when the player is placed exactly on its live
// position again.
test('P4-03B-I: a consumed monster does not trigger a second time',async()=>{
  resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const p=(await request('/api/character/char-demo/snapshot')).worldMonsters.find(m=>m.id==='world-bandit-1').position;
  setPosition(p.x,p.y,'IN_WORLD');
  const first=await post('/api/commands/world/heartbeat',envelope(nextKey('i-first'),{}));
  assert.equal(first.data.encounterTriggered,true);
  rawRun(`UPDATE battles SET status='RETREATED' WHERE character_id='char-demo' AND status='ACTIVE'`);
  const live2=await request('/api/character/char-demo/snapshot');
  assert.ok(!live2.worldMonsters.some(m=>m.id==='world-bandit-1'),'consumed monster must no longer appear in snapshot');
  setPosition(p.x,p.y,'IN_WORLD');
  const second=await post('/api/commands/world/heartbeat',envelope(nextKey('i-second'),{}));
  assert.equal(second.status,'ACCEPTED');
  assert.equal(second.data.encounterTriggered,false,'an already-consumed monster must never trigger again');
  assert.equal(rawQuery(`SELECT * FROM world_monster_encounters WHERE character_id='char-demo' AND monster_id='world-bandit-1'`).length,1);
});

// J: heartbeat and moveWorld evaluated concurrently converge on exactly one battle and one
// consumption row, whichever one actually wins the race.
test('P4-03B-J: heartbeat and moveWorld evaluated concurrently converge on exactly one battle',async()=>{
  resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const seed=await post('/api/commands/world/heartbeat',envelope(nextKey('j-seed'),{}));
  assert.equal(seed.status,'ACCEPTED');
  const p=(await request('/api/character/char-demo/snapshot')).worldMonsters.find(m=>m.id==='world-bandit-1').position;
  setPosition(p.x,p.y,'IN_WORLD');
  const [hb,mv]=await Promise.all([
    post('/api/commands/world/heartbeat',envelope(nextKey('j-hb'),{})),
    post('/api/commands/world/move',envelope(nextKey('j-mv'),{targetX:p.x,targetY:p.y,moveSequence:nextMoveSequence()}))
  ]);
  const anyTriggered=[hb,mv].some(r=>battleAlreadyActiveFromWorldResponse(r));
  assert.ok(anyTriggered,'at least one of the two concurrent requests must observe the battle');
  const battleIds=new Set([hb,mv].filter(r=>r.status==='ACCEPTED'&&r.data.battleId).map(r=>r.data.battleId));
  assert.ok(battleIds.size<=1,'both requests must agree on the same battleId when either reports one');
  assert.equal(rawQuery(`SELECT id FROM battles WHERE character_id='char-demo' AND status='ACTIVE'`).length,1);
  assert.equal(rawQuery(`SELECT * FROM world_monster_encounters WHERE character_id='char-demo' AND monster_id='world-bandit-1'`).length,1);
});

// K: active movement — with heartbeat NEVER called anywhere in this test, moveWorld() alone
// (sharing the SAME watermark, established here via moveWorld() itself) still detects and triggers
// a Monster exposure that swept into a truly stationary player.
test('P4-03B-K: with heartbeat never called, moveWorld alone still detects and triggers a Monster exposure that happened since the watermark',async()=>{
  resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const seed=await post('/api/commands/world/move',envelope(nextKey('k-seed'),{targetX:SAFE_FAR.x,targetY:SAFE_FAR.y,moveSequence:nextMoveSequence()}));
  assert.equal(seed.status,'ACCEPTED');
  const live=await request('/api/character/char-demo/snapshot');
  const rendezvousAt=live.serverNowMs+800;
  const rendezvousPos=patrolPositionAt(monster,rendezvousAt);
  setPosition(rendezvousPos.x,rendezvousPos.y,'IN_WORLD');
  await wait(950);
  const mv=await post('/api/commands/world/move',envelope(nextKey('k-hit'),{targetX:rendezvousPos.x,targetY:rendezvousPos.y,moveSequence:nextMoveSequence()}));
  assert.equal(mv.status,'ACCEPTED');
  assert.equal(mv.data.encounterTriggered,true);
  assert.equal(mv.data.monsterId,'world-bandit-1');
  assert.equal(rawQuery(`SELECT id FROM battles WHERE character_id='char-demo' AND status='ACTIVE'`).length,1);
  assert.equal(rawQuery(`SELECT * FROM world_monster_encounters WHERE character_id='char-demo' AND monster_id='world-bandit-1'`).length,1);
});

// L: when historical exposure has triggered, the player's requested movement this call must NOT
// persist — the accepted response reports the pre-move position unchanged, as if the move had never
// been attempted.
test('P4-03B-L: a historical exposure hit blocks this call\'s own requested movement — position stays at the pre-move authoritative position',async()=>{
  resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const seed=await post('/api/commands/world/move',envelope(nextKey('l-seed'),{targetX:SAFE_FAR.x,targetY:SAFE_FAR.y,moveSequence:nextMoveSequence()}));
  assert.equal(seed.status,'ACCEPTED');
  const live=await request('/api/character/char-demo/snapshot');
  const rendezvousAt=live.serverNowMs+800;
  const rendezvousPos=patrolPositionAt(monster,rendezvousAt);
  setPosition(rendezvousPos.x,rendezvousPos.y,'IN_WORLD');
  await wait(950);
  const requestedTarget={x:rendezvousPos.x+50,y:rendezvousPos.y+50}; // a real, non-trivial requested displacement
  const mv=await post('/api/commands/world/move',envelope(nextKey('l-hit'),{targetX:requestedTarget.x,targetY:requestedTarget.y,moveSequence:nextMoveSequence()}));
  assert.equal(mv.status,'ACCEPTED');
  assert.equal(mv.data.encounterTriggered,true);
  assert.deepEqual(mv.data.worldPosition,rendezvousPos,'the requested movement must NOT have been applied — worldPosition must equal the pre-move position, not the requested target');
  assert.equal(mv.data.collided,false);
});

// M: the pre-existing P4-02 Player->Monster check (player's own movement segment vs the monster's
// CURRENT live position) still works unchanged when historical exposure finds nothing.
test('P4-03B-M: the existing P4-02 encounter (player moving into the monster\'s live position) still triggers normally',async()=>{
  resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const seed=await post('/api/commands/world/heartbeat',envelope(nextKey('m-seed'),{}));
  assert.equal(seed.status,'ACCEPTED');
  assert.equal(seed.data.encounterTriggered,false);
  const p=(await request('/api/character/char-demo/snapshot')).worldMonsters.find(m=>m.id==='world-bandit-1').position;
  // A brand-new position the player has never stood at before, 50px/20px off the monster's live
  // spot — the player's own movement SEGMENT crosses directly over it, but this fresh static start
  // point was never itself on the monster's recent swept path (the watermark was just seeded).
  setPosition(p.x-50,p.y-20,'IN_WORLD');
  const mv=await post('/api/commands/world/move',envelope(nextKey('m-hit'),{targetX:p.x+50,targetY:p.y-20,moveSequence:nextMoveSequence()}));
  assert.equal(mv.status,'ACCEPTED');
  assert.equal(mv.data.encounterTriggered,true);
  assert.equal(mv.data.monsterId,'world-bandit-1');
  assert.notDeepEqual(mv.data.worldPosition,{x:p.x-50,y:p.y-20},'unlike L, a live P4-02 hit DOES apply the movement that triggered it');
});

// N: normal watermark advance — a no-hit ACCEPTED heartbeat reports a genuine, current
// worldExposureEvaluatedAt timestamp, and production commits it to the watermark only after idem()
// has already returned (the in-memory Map itself lives inside the spawned server's own process and
// is not directly reachable from here — see D/Q/R for real end-to-end proofs of the consequence).
test('P4-03B-N: a no-hit ACCEPTED heartbeat reports a genuine worldExposureEvaluatedAt, and production commits it to the watermark only after idem() returns',async()=>{
  resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const before=Date.now();
  const hb=await post('/api/commands/world/heartbeat',envelope(nextKey('n-key'),{}));
  const after=Date.now();
  assert.equal(hb.status,'ACCEPTED');
  assert.equal(hb.data.encounterTriggered,false);
  assert.ok(Number.isFinite(hb.data.worldExposureEvaluatedAt));
  assert.ok(hb.data.worldExposureEvaluatedAt>=before-50&&hb.data.worldExposureEvaluatedAt<=after+50,'worldExposureEvaluatedAt must be a real, current server timestamp');
  const serverSource=readFileSync(new URL('../server.mjs',import.meta.url),'utf8');
  const hbStart=serverSource.indexOf('function worldHeartbeat(env){'),hbEnd=serverSource.indexOf('function moveWorld(env){');
  const hbBody=serverSource.slice(hbStart,hbEnd);
  const idemCallIndex=hbBody.indexOf('const result=idem(');
  const advanceCallIndex=hbBody.indexOf('advanceWorldExposureWatermark(characterId,result)');
  assert.ok(idemCallIndex>=0&&advanceCallIndex>idemCallIndex,'advanceWorldExposureWatermark must be called AFTER idem() has already returned, not from inside its callback');
});

// O: rollback safety — a REJECTED heartbeat (here: ERR_BATTLE_ACTIVE, a real rejection path) never
// advances the watermark. The Map mutation cannot be rolled back by SQLite, so
// advanceWorldExposureWatermark's own status guard is the only thing standing between a
// rejected/rolled-back command and a silently-skipped exposure interval.
test('P4-03B-O: a REJECTED heartbeat never advances the watermark',async()=>{
  resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  rawRun(`INSERT INTO battles VALUES(?,?,?,?,?)`,'o-fake-battle','char-demo','ACTIVE',Date.now(),Date.now());
  const rejected=await post('/api/commands/world/heartbeat',envelope(nextKey('o-key'),{}));
  assert.equal(rejected.status,'REJECTED');
  assert.equal(rejected.data,undefined,'a REJECTED response must carry no worldExposureEvaluatedAt at all');
  rawRun(`UPDATE battles SET status='RETREATED' WHERE id='o-fake-battle'`);
  const serverSource=readFileSync(new URL('../server.mjs',import.meta.url),'utf8');
  const advanceStart=serverSource.indexOf('function advanceWorldExposureWatermark(characterId,result){');
  const advanceEnd=serverSource.indexOf('function evaluateWorldMonsterExposure(');
  const advanceBody=serverSource.slice(advanceStart,advanceEnd);
  assert.ok(advanceBody.includes("if(result.status!=='ACCEPTED')return;"),'advanceWorldExposureWatermark must return immediately for any non-ACCEPTED result, before touching the Map');
});

// P: monotonic — an older completion must never regress the watermark. Structural proof:
// advanceWorldExposureWatermark writes via Math.max against the existing value, never a raw
// overwrite — safe against idem()'s own duplicate-idempotencyKey replay path and any two calls
// completing out of order.
test('P4-03B-P: the watermark can only ever advance, never regress, on every write',()=>{
  const serverSource=readFileSync(new URL('../server.mjs',import.meta.url),'utf8');
  const advanceStart=serverSource.indexOf('function advanceWorldExposureWatermark(characterId,result){');
  const advanceEnd=serverSource.indexOf('function evaluateWorldMonsterExposure(');
  const advanceBody=serverSource.slice(advanceStart,advanceEnd);
  assert.ok(advanceBody.includes('worldExposureWatermark.set(characterId,Math.max(worldExposureWatermark.get(characterId)??0,evaluatedAt));'),'the watermark write must be a Math.max against its current value, never a raw overwrite');
});

// Q: exitCity() rebases the exposure watermark to the moment of exit — the next heartbeat must not
// retroactively evaluate time before that (city time, or any earlier IN_WORLD session), even though
// the decoy position IS somewhere the monster's patrol genuinely passed through earlier.
test('P4-03B-Q: exitCity() rebases the watermark — a decoy position from before entering the city is not retroactively caught after exiting',async()=>{
  resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const seed=await post('/api/commands/world/heartbeat',envelope(nextKey('q-seed'),{}));
  assert.equal(seed.status,'ACCEPTED');
  // Deliberately NOT "whatever the live position happens to be right now" (real wall-clock time is
  // uncontrolled, so the monster could be anywhere in its cycle, including close to a turnaround) —
  // waitForPatrolMidpoint anchors the decoy at the true leg midpoint (60px from both turnarounds),
  // so the fixed real-time wait below can never coincidentally reverse the monster back toward the
  // decoy by phase luck (see that helper's own comment).
  const {position:decoy}=await waitForPatrolMidpoint((await request('/api/character/char-demo/snapshot')).serverNowMs);
  // Simulate a jump into a city (city entry itself is out of this slice's scope — only exitCity()'s
  // own rebase is under test here). The city-visit wait must exceed encounterRadius/patrolSpeed
  // (40/0.02=2000ms) so the monster's position has moved a genuine >40px away from `decoy` by the
  // time we exit — otherwise a CORRECTLY rebased tiny post-exit window could still legitimately
  // reach `decoy` simply because the monster hasn't gone far in real terms yet, which would falsely
  // look like a rebase failure. This is not about the lookback clamp (also 2000ms) — an UNREBASED
  // watermark would still be exactly the pre-city timestamp itself, trivially reaching `decoy` (zero
  // distance) regardless of any clamp.
  rawRun(`UPDATE characters SET state='IN_CITY',city_id='starter-village' WHERE id='char-demo'`);
  await wait(2500); // real "time spent in the city"
  const exit=await post('/api/commands/city/exit',envelope(nextKey('q-exit'),{}));
  assert.equal(exit.status,'ACCEPTED');
  assert.equal(exit.data.state,'IN_WORLD');
  // Place the player exactly at the pre-city decoy position — if the watermark were NOT rebased on
  // exit, this heartbeat's window would still reach back to before the city visit and (incorrectly)
  // catch it.
  setPosition(decoy.x,decoy.y,'IN_WORLD');
  const afterExit=await post('/api/commands/world/heartbeat',envelope(nextKey('q-decoy'),{}));
  assert.equal(afterExit.status,'ACCEPTED');
  assert.equal(afterExit.data.encounterTriggered,false,'a position from before entering the city must not retroactively trigger after exiting');
  // Sanity: the mechanism still genuinely works post-exit — a real, current hit is still caught.
  const live=(await request('/api/character/char-demo/snapshot')).worldMonsters.find(m=>m.id==='world-bandit-1').position;
  setPosition(live.x,live.y,'IN_WORLD');
  const liveHit=await post('/api/commands/world/heartbeat',envelope(nextKey('q-live'),{}));
  assert.equal(liveHit.data.encounterTriggered,true,'heartbeat must still work normally after exitCity()');
  const serverSource=readFileSync(new URL('../server.mjs',import.meta.url),'utf8');
  const exitStart=serverSource.indexOf('function exitCity(env){'),exitEnd=serverSource.indexOf('function moveStorage(env){');
  const exitBody=serverSource.slice(exitStart,exitEnd);
  assert.ok(exitBody.includes("worldExposureWatermark.set('char-demo',Math.max(worldExposureWatermark.get('char-demo')??0,result.data.worldExposureRebasedAt));"),'exitCity() must rebase the watermark using the timestamp captured inside the idem()-cached callback — never a fresh Date.now() taken outside it (see Q2)');
  assert.ok(exitBody.includes('worldExposureRebasedAt:Date.now()'),'the exit timestamp must be captured INSIDE the idem() callback so an idempotent replay reuses the original instant from the cached result, not a fresh one');
  assert.ok(exitBody.includes('const {worldExposureRebasedAt,...publicData}=result.data;'),'the internal bookkeeping field must be stripped before the response reaches the client, keeping exitCity()\'s public response shape unchanged');
});

// Q2: exitCity idempotent replay must NOT rebase the watermark to the replay time — a replayed
// idempotencyKey returns idem()'s CACHED original result without re-running exitCity()'s body at
// all, so a fresh Date.now() taken after idem() returns (rather than the timestamp baked into that
// cached result) would silently discard legitimate Monster->Player exposure history between the
// original exit and the replay. This test fails against the pre-fix head
// (68becd87b16d027c5de854ecc2cc564bc5ba98c9) and passes after the fix.
test('P4-03B-Q2: exitCity idempotent replay does not move the watermark to replay time — exposure between the original exit and the replay is still caught',async()=>{
  resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  rawRun(`UPDATE characters SET state='IN_CITY',city_id='starter-village' WHERE id='char-demo'`);
  // Anchor T0 (the original exit) at the patrol's true leg midpoint (60px margin from either
  // turnaround — same reasoning as waitForPatrolMidpoint) so the monster's motion for the next
  // several seconds is guaranteed monotonic, no real-time phase-alignment risk.
  const {position:midpoint}=await waitForPatrolMidpoint((await request('/api/character/char-demo/snapshot')).serverNowMs);
  const exitKey=nextKey('q2-exit');
  const firstExit=await post('/api/commands/city/exit',envelope(exitKey,{})); // T0
  assert.equal(firstExit.status,'ACCEPTED');
  assert.equal(firstExit.data.worldExposureRebasedAt,undefined,'the internal rebase timestamp must never leak into the client-visible response — exitCity()\'s public shape stays exactly what it was before this fix');
  // The player stands exactly where the monster was AT T0 (the midpoint) — a correct T0-anchored
  // window's very first segment starts exactly here (distance 0), while a buggy replay-time-anchored
  // window starts wherever the monster is by then (see the math in this test's own review comment:
  // with a ~2500ms gap the monster has moved ~50px away — outside encounterRadius=40 — while the
  // correctly-clamped T0 window is only ~500ms stale, ~10px away — safely inside).
  setPosition(midpoint.x,midpoint.y,'IN_WORLD');
  await wait(2500); // real time passes; the monster's own continuing patrol moves on from `midpoint`
  const replayExit=await post('/api/commands/city/exit',envelope(exitKey,{})); // T2: exact same key
  assert.deepEqual(replayExit,firstExit,'a replayed idempotencyKey must return the exact cached original result, not re-run the exit');
  const hb=await post('/api/commands/world/heartbeat',envelope(nextKey('q2-hb'),{}));
  assert.equal(hb.status,'ACCEPTED');
  assert.equal(hb.data.encounterTriggered,true,'the watermark must stay anchored at the ORIGINAL exit (T0), not the replay time (T2) — otherwise this legitimate exposure is silently missed');
  assert.equal(hb.data.monsterId,'world-bandit-1');
});

// R: server restart fallback — a genuinely restarted server (same DB file, fresh in-memory
// process — kills and respawns the real child process) treats history as empty for its FIRST
// evaluation: a decoy captured just before the restart is not retroactively caught, while a live hit
// still works normally afterwards.
test('P4-03B-R: after a genuine server restart, a missing in-memory watermark treats history as empty rather than retroactively evaluating a previous session',async()=>{
  resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const seed=await post('/api/commands/world/heartbeat',envelope(nextKey('r-seed'),{}));
  assert.equal(seed.status,'ACCEPTED');
  // Same reasoning as Q: anchor the decoy at the true leg midpoint (60px from both turnarounds), not
  // wherever the live position uncontrollably happens to be — see waitForPatrolMidpoint's comment.
  const {position:decoy}=await waitForPatrolMidpoint((await request('/api/character/char-demo/snapshot')).serverNowMs);
  child.kill();
  await new Promise(resolve=>child.once('exit',resolve));
  ({child,base}=await spawnServer());
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
  // Same reasoning as Q's own wait: must exceed encounterRadius/patrolSpeed (2000ms) so the monster
  // has genuinely moved >40px away from `decoy` by the time we check — otherwise a CORRECTLY
  // zero-windowed post-restart check could still legitimately reach `decoy` simply because the
  // monster hasn't gone far in real terms yet (a coincidental proximity match, not a sign the
  // fallback is wrongly retroactive). Restart itself (kill+spawn+ready) rarely takes this long alone.
  await wait(2200);
  setPosition(decoy.x,decoy.y,'IN_WORLD');
  const afterRestart=await post('/api/commands/world/heartbeat',envelope(nextKey('r-decoy'),{}));
  assert.equal(afterRestart.status,'ACCEPTED');
  assert.equal(afterRestart.data.encounterTriggered,false,'a fresh server must not retroactively evaluate against a watermark that no longer exists in memory');
  const live=(await request('/api/character/char-demo/snapshot')).worldMonsters.find(m=>m.id==='world-bandit-1');
  assert.ok(live,'monster must still be available (not accidentally consumed by the decoy check above)');
  setPosition(live.position.x,live.position.y,'IN_WORLD');
  const liveHit=await post('/api/commands/world/heartbeat',envelope(nextKey('r-live'),{}));
  assert.equal(liveHit.data.encounterTriggered,true,'post-restart, a genuinely live-position hit must still trigger normally');
  const serverSource=readFileSync(new URL('../server.mjs',import.meta.url),'utf8');
  const boundedStart=serverSource.indexOf('function boundedExposureFromTime(characterId,now){');
  const boundedEnd=serverSource.indexOf('function advanceWorldExposureWatermark(');
  const boundedBody=serverSource.slice(boundedStart,boundedEnd);
  assert.ok(boundedBody.includes("if(raw===undefined||!Number.isFinite(raw))return now;"),'a missing watermark (fresh boot/restart) must default to a ZERO-length window ending at now, never a now-lookback fallback');
});

// ============================================================================
// S-U: client structural (source-scoped) proofs — no server needed.
// ============================================================================

// S: the client-side heartbeat gate itself must not send while the document is not visible — real
// fairness comes from the server's bounded lookback regardless (already proven end-to-end by D/Q/R
// above), so this is a proof of the efficiency-only client gate, not a correctness claim.
test('P4-03B-S: public/app.js\'s heartbeat interval does not send while the document is not visible',()=>{
  const appSource=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
  assert.ok(appSource.includes("document.visibilityState==='visible'&&S.battle?.status!=='ACTIVE')sendWorldHeartbeat()"),'the heartbeat interval must gate on document.visibilityState===\'visible\' before ever calling sendWorldHeartbeat');
});

// T: a heartbeat response reporting encounterTriggered:true or ERR_BATTLE_ACTIVE both drive the
// client into the existing resync path (await refresh()) via the shared, reused predicate — no
// second, hand-duplicated battle-detection path, and the client never creates a battle itself.
test('P4-03B-T: sendWorldHeartbeat() resyncs via battleAlreadyActiveFromWorldResponse + refresh(), reusing sendWorldMove\'s exact predicate',()=>{
  const appSource=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
  const start=appSource.indexOf('async function sendWorldHeartbeat(){');
  const end=appSource.indexOf('// Virtual joystick');
  const body=appSource.slice(start,end);
  assert.ok(body.includes('battleAlreadyActiveFromWorldResponse(r)'),'sendWorldHeartbeat must reuse the shared predicate, not a hand-duplicated check');
  assert.ok(body.includes('await refresh()'),'a triggered/already-active battle must resync via the existing refresh() path');
  assert.ok(!body.includes('createBattle')&&!body.includes('S.battle='),'the client must never create a battle itself — only ask the server and resync');
});

// U: the client heartbeat interval never sends while IN_CITY, TRAVELING, in an ACTIVE battle, on a
// non-map tab, or while the document is hidden — a single combined gate condition covers all five
// (IN_CITY/TRAVELING both excluded by requiring state==='IN_WORLD', since state has no fourth value).
test('P4-03B-U: the heartbeat poll gate excludes city/travel/battle/non-map-tab/hidden-document in one condition',()=>{
  const appSource=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
  const line="setInterval(()=>{if(S.tab==='map'&&S.snap?.state==='IN_WORLD'&&document.visibilityState==='visible'&&S.battle?.status!=='ACTIVE')sendWorldHeartbeat()},1000);";
  assert.ok(appSource.includes(line),'expected the exact single-line gated heartbeat interval covering all five exclusions');
});
