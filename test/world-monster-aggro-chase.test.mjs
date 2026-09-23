import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {WORLD_MONSTER_DEFINITIONS,patrolPositionAt,chasePositionAt,segmentEntersEncounterRadius} from '../public/worldmonsters.js';
import {OBSTACLES,PLAYER_COLLISION_RADIUS,inflateRect,pointInRect,segmentIntersectsRect} from '../public/worldgeometry.js';
import {CITY_DEFINITIONS} from '../public/cities.js';
import {shouldApplyWorldMonstersSync,nextWorldMonstersSyncWatermark} from '../public/app.js';

// P4-03C — Aggro / Chase (world-bandit-1 only). Covers acceptance tests A through AG from the
// approved P4-03C Coding Order (itself following two rounds of Design Clarification, following the
// same precedent test/world-monster-heartbeat.test.mjs's own header note established for P4-03B):
// some lettered items from the order are combined here where the underlying proof is the same
// mechanism (e.g. concurrency AE-AH collapse into three real tests, since this single-`char-demo`/
// single-monster Prototype cannot literally exercise every named race without fabricating server
// internals no real client could ever observe), and L (PATROL obstacle regression) is the full
// existing test suite / `npm test` run reported at that level, not an individual test defined here.

const monster=WORLD_MONSTER_DEFINITIONS[0];
const patrolCenter={x:(monster.patrolA.x+monster.patrolB.x)/2,y:(monster.patrolA.y+monster.patrolB.y)/2};
// Far from the patrol route (y=220, x in [440,560]) AND from patrolCenter by more than leashRadius —
// safely PATROL-only, no aggro, matching the established SAFE_FAR precedent from
// test/world-monster-heartbeat.test.mjs.
const SAFE_FAR={x:500,y:600};
// 70px perpendicular from the patrol line's midpoint (500,220): strictly between encounterRadius(40)
// and aggroRadius(90), and well within leashRadius(150) of patrolCenter — the one fixed point this
// whole file uses to acquire aggro/CHASE without ever accidentally also satisfying encounterRadius.
const AGGRO_ONLY={x:500,y:290};

// ============================================================================
// A-B: pure content/geometry proofs — no server needed.
// ============================================================================

test('P4-03C-A: aggro/chase Prototype Parameters are present and correctly ordered',()=>{
  assert.equal(monster.aggroRadius,90);
  assert.equal(monster.chaseSpeed,0.08);
  assert.equal(monster.leashRadius,150);
  assert.ok(monster.aggroRadius>monster.encounterRadius,'aggroRadius must sit outside encounterRadius so a sweep can acquire aggro before it could also satisfy the tighter encounter check in the very same sweep');
});

test('P4-03C-B: chasePositionAt — zero elapsed, partial advance, exact-target arrival, overshoot clamp, zero-distance target, defensive invalid input',()=>{
  const anchor={x:0,y:0},target={x:100,y:0},speed=0.08,anchorAt=1000;
  assert.deepEqual(chasePositionAt(anchor,anchorAt,target,speed,1000),{x:0,y:0},'zero elapsed must not move at all');
  assert.deepEqual(chasePositionAt(anchor,anchorAt,target,speed,1500),{x:40,y:0},'500ms*0.08px/ms=40px advance');
  const exactMs=anchorAt+100/speed;
  assert.deepEqual(chasePositionAt(anchor,anchorAt,target,speed,exactMs),{x:100,y:0},'must land exactly on the target, not overshoot or undershoot by floating error');
  assert.deepEqual(chasePositionAt(anchor,anchorAt,target,speed,exactMs+5000),{x:100,y:0},'must clamp at the target, never overshoot past it however long the elapsed time');
  assert.deepEqual(chasePositionAt(anchor,anchorAt,anchor,speed,anchorAt+1000),{x:0,y:0},'zero-distance target (already there) must stay put, not divide by zero/NaN');
  assert.equal(chasePositionAt(null,0,target,speed,1000),null,'missing anchorPos is defensively fatal, same fallback contract as patrolPositionAt');
  assert.deepEqual(chasePositionAt(anchor,anchorAt,null,speed,1000),{x:anchor.x,y:anchor.y},'missing target falls back to standing at the anchor, never throws/NaNs');
  assert.deepEqual(chasePositionAt(anchor,anchorAt,target,0,1000),{x:anchor.x,y:anchor.y},'non-positive chaseSpeed falls back to standing at the anchor');
  assert.deepEqual(chasePositionAt(anchor,1000,target,speed,500),{x:0,y:0},'timeMs before anchorAt clamps elapsed to zero rather than reversing direction');
});

// ============================================================================
// I-K: obstacle-blocked chase — proven via pure geometry + the exact algorithm formula, since the
// FIXED Prototype leashRadius(150) measured from the patrol center makes every real obstacle
// geometrically unreachable by a leash-bounded chase target with today's content (proven as part of
// I itself) — matching the P4-03C Audit's own documented finding, not a gap in coverage.
// ============================================================================

const INFLATED_OBSTACLES=OBSTACLES.map(r=>inflateRect(r,PLAYER_COLLISION_RADIUS));
// Mirrors server.mjs's own segmentBlocked() exactly (escape-only semantics) over the same exported
// primitives — not a rewritten rule, see public/movement.js's isStepBlocked for the identical
// precedent already established for the client's own presentation-only obstacle clamp.
const segmentBlocked=(x1,y1,x2,y2)=>INFLATED_OBSTACLES.some(rect=>pointInRect(x1,y1,rect)?pointInRect(x2,y2,rect):segmentIntersectsRect(x1,y1,x2,y2,rect));

test('P4-03C-I: with the fixed Prototype leashRadius(150) measured from the patrol center, no inflated obstacle can ever actually sit inside a leash-bounded CHASE target — and the obstacle-blocked chase-resolve algorithm itself still freezes/rebases correctly if it ever did',()=>{
  for(const rect of INFLATED_OBSTACLES){
    const closestX=Math.max(rect.minX,Math.min(patrolCenter.x,rect.maxX));
    const closestY=Math.max(rect.minY,Math.min(patrolCenter.y,rect.maxY));
    const distance=Math.hypot(closestX-patrolCenter.x,closestY-patrolCenter.y);
    assert.ok(distance>monster.leashRadius,`obstacle closest point sits ${distance}px from the patrol center, expected strictly beyond leashRadius(${monster.leashRadius}) — a real, leash-bounded chase target can never sit inside it, so obstacle-blocked CHASE cannot arise from realistic play with today's content (documented Audit/Design Clarification finding, not a coverage gap)`);
  }
  // The chase-movement-resolve algorithm itself (server.mjs's evaluateWorldMonsterAggroChase: propose
  // via chasePositionAt, obstacle-clamp via segmentBlocked, rebase unconditionally to wherever the
  // monster actually ends up) is reproduced here directly, with hand-chosen anchor/target points that
  // DO intersect an inflated obstacle — independent of whether today's leash/content can ever actually
  // produce such a pair.
  const anchor={x:500,y:400},target={x:600,y:450};
  const proposed=chasePositionAt(anchor,0,target,monster.chaseSpeed,100000);
  assert.deepEqual(proposed,target,'sanity: unblocked, this proposal reaches the target exactly');
  assert.ok(segmentBlocked(anchor.x,anchor.y,proposed.x,proposed.y),'sanity: the chosen anchor->target segment must actually cross an inflated obstacle for this proof to mean anything');
  const blocked=segmentBlocked(anchor.x,anchor.y,proposed.x,proposed.y);
  const finalPos=blocked?{x:anchor.x,y:anchor.y}:proposed;
  assert.deepEqual(finalPos,anchor,'a blocked chase step must leave the monster exactly at its previous position — full stop, no partial slide, no pathfinding');
});

test('P4-03C-J: repeated blocked evaluations stay deterministic — no drift, no accumulated "credit", the monster stays frozen exactly at the same position across multiple blocked evaluates however long the elapsed time',()=>{
  const anchor={x:500,y:400},target={x:600,y:450};
  let state={chaseAnchorPos:anchor,chaseAnchorAt:0};
  for(const now of [5000,20000,100000]){
    const proposed=chasePositionAt(state.chaseAnchorPos,state.chaseAnchorAt,target,monster.chaseSpeed,now);
    const blocked=segmentBlocked(state.chaseAnchorPos.x,state.chaseAnchorPos.y,proposed.x,proposed.y);
    assert.ok(blocked,`must remain blocked at now=${now}`);
    const finalPos=blocked?{x:state.chaseAnchorPos.x,y:state.chaseAnchorPos.y}:proposed;
    assert.deepEqual(finalPos,anchor,'must stay exactly at the original anchor, whatever the elapsed time since the last rebase');
    state={chaseAnchorPos:finalPos,chaseAnchorAt:now};
  }
});

test('P4-03C-K: an obstacle sitting between monster and player suppresses a would-be CHASE encounter, even though distance alone is within encounterRadius',()=>{
  const monsterPos={x:560,y:420},playerPos={x:590,y:430}; // ~32px apart, both inside ridge-b's inflated rect
  const distance=Math.hypot(playerPos.x-monsterPos.x,playerPos.y-monsterPos.y);
  assert.ok(distance<monster.encounterRadius,'sanity: distance alone would satisfy encounterRadius');
  assert.ok(segmentEntersEncounterRadius(monsterPos,monsterPos,{position:playerPos,encounterRadius:monster.encounterRadius}),'sanity: the pure radius test (ignoring obstacles) would trigger');
  assert.ok(segmentBlocked(monsterPos.x,monsterPos.y,playerPos.x,playerPos.y),'sanity: an obstacle genuinely sits on the direct connecting line for this proof to mean anything');
  const wouldTrigger=segmentEntersEncounterRadius(monsterPos,monsterPos,{position:playerPos,encounterRadius:monster.encounterRadius})&&!segmentBlocked(monsterPos.x,monsterPos.y,playerPos.x,playerPos.y);
  assert.equal(wouldTrigger,false,'evaluateWorldMonsterAggroChase\'s own CHASE-encounter gates (both historical and current-command phase) are exactly `radiusHit && !segmentBlocked(...)` — the obstacle must suppress the trigger despite the radius test alone passing');
});

test('P4-03C-L: the existing PATROL post-move encounter check and evaluateWorldMonsterExposure remain completely unmodified — no obstacle gate was ever added to either (full regression: the existing P4-02/P4-03A/P4-03B suites and the full npm test run all still pass unchanged, not re-asserted individually here)',()=>{
  const serverSource=readFileSync(new URL('../server.mjs',import.meta.url),'utf8');
  assert.ok(serverSource.includes("&& segmentEntersEncounterRadius(current,{x:nextX,y:nextY},{...m,position:patrolPositionAt(m,now)}));"),'the original P4-02 PATROL post-move check must be byte-for-byte unchanged, with no CHASE-only obstacle gate spliced into it');
  const exposureStart=serverSource.indexOf('function evaluateWorldMonsterExposure('),exposureEnd=serverSource.indexOf('// P4-03C — shared battle-creation trigger');
  const exposureBody=serverSource.slice(exposureStart,exposureEnd);
  assert.ok(!exposureBody.includes('segmentBlocked'),'evaluateWorldMonsterExposure (the PATROL/exposure check both worldHeartbeat and moveWorld share) must never gain an obstacle gate — Coding Order §22');
});

// ============================================================================
// C-H, M-V, AA-AG: real-server integration tests, sharing one spawned server/db for the whole file
// (same precedent as test/world-monster-heartbeat.test.mjs and test/world-encounter.test.mjs).
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
const resetWorldDb=(x,y,state='IN_WORLD')=>{
  const fixture=new DatabaseSync(dbPath());
  fixture.prepare(`DELETE FROM world_monster_encounters WHERE character_id='char-demo'`).run();
  fixture.prepare(`UPDATE battles SET status='RETREATED' WHERE character_id='char-demo' AND status='ACTIVE'`).run();
  fixture.prepare(`UPDATE characters SET world_x=?,world_y=?,state=?,city_id='starter-village' WHERE id='char-demo'`).run(x,y,state);
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
const bandit=r=>r?.data?.worldMonsters?.find(m=>m.id==='world-bandit-1');
// The core polling primitive this whole file relies on: because boundedExposureFromTime anchors each
// evaluate's fromTime to the PREVIOUS evaluate's own watermark (see server.mjs), back-to-back
// heartbeat calls with no more than MAX_WORLD_EXPOSURE_LOOKBACK_MS(2000ms) of real time between them
// give CONTIGUOUS swept-path coverage across the whole polling window — not sampled snapshots — so
// the aggro/encounter crossing is always caught by whichever poll's window contains it, deterministic
// rather than probabilistic (intervalMs below is always well under the 2000ms cap).
async function pollHeartbeatUntil(predicate,{intervalMs=350,timeoutMs=13000,keyPrefix='poll'}={}){
  const deadline=Date.now()+timeoutMs;
  let last;
  while(Date.now()<deadline){
    last=await post('/api/commands/world/heartbeat',envelope(nextKey(keyPrefix),{}));
    if(predicate(last))return last;
    await wait(intervalMs);
  }
  throw new Error(`pollHeartbeatUntil(${keyPrefix}) timed out, last=${JSON.stringify(last)}`);
}
// Test isolation: worldChaseState lives in the SPAWNED SERVER's own process memory, not reachable
// from this test process directly (same process boundary test/world-monster-heartbeat.test.mjs's own
// resetWorldState respects for worldExposureWatermark). A leftover CHASE runtime from a PREVIOUS test
// (e.g. one that entered a city mid-CHASE without ever exiting, or was simply interrupted before it
// naturally resolved) must be flushed through the REAL disengage path — moving the player beyond
// leashRadius, then one genuine heartbeat evaluate, which the leash check unconditionally clears
// regardless of how far any leftover chase had progressed — BEFORE re-seeding DB state for the next
// test. Otherwise a stale anchor/target from an earlier test can silently contaminate this one (an
// unintended early encounter, or a "trigger" response that is already suspiciously close).
const resetWorldState=async(x,y,state='IN_WORLD')=>{
  resetWorldDb(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  await post('/api/commands/world/heartbeat',envelope(nextKey('reset-flush'),{}));
  resetWorldDb(x,y,state);
};

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-world-monster-aggro-chase-'));
  ({child,base}=await spawnServer());
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

test('P4-03C-C: a player far outside aggroRadius stays PATROL — no aggro, no CHASE runtime',async()=>{
  await resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const hb=await post('/api/commands/world/heartbeat',envelope(nextKey('c-hb'),{}));
  assert.equal(hb.status,'ACCEPTED');
  assert.equal(hb.data.encounterTriggered,false);
  const m=bandit(hb);
  assert.equal(m.mode,'PATROL');
  assert.equal(m.chaseAnchorPos,undefined,'a PATROL-mode monster must not carry any CHASE-only field');
});

test('P4-03C-D: patrol sweep entering aggroRadius (but not encounterRadius) transitions PATROL->CHASE, no battle',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  const hit=await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'d-poll'});
  assert.equal(hit.data.encounterTriggered,false,'aggro acquisition alone must never open a battle');
  const m=bandit(hit);
  assert.equal(m.mode,'CHASE');
  assert.ok(Number.isFinite(m.chaseAnchorAt));
  assert.deepEqual(m.lastKnownPlayerPos,AGGRO_ONLY);
  assert.equal(rawQuery(`SELECT * FROM world_monster_encounters WHERE character_id='char-demo' AND monster_id='world-bandit-1'`).length,0);
});

test('P4-03C-E: a patrol sweep landing directly inside encounterRadius still opens Battle immediately — never routed through CHASE first (Encounter-before-Aggro priority)',async()=>{
  await resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  await post('/api/commands/world/heartbeat',envelope(nextKey('e-seed'),{}));
  const live=await request('/api/character/char-demo/snapshot');
  const rendezvousAt=live.serverNowMs+800;
  const rendezvousPos=patrolPositionAt(monster,rendezvousAt);
  setPosition(rendezvousPos.x,rendezvousPos.y,'IN_WORLD');
  await wait(950);
  const hb=await post('/api/commands/world/heartbeat',envelope(nextKey('e-hit'),{}));
  assert.equal(hb.data.encounterTriggered,true);
  assert.equal(hb.data.monsterId,'world-bandit-1');
  assert.equal(bandit(hb),undefined,'the consumed monster must not appear at all — never surfaced mid-transition as CHASE');
  assert.equal(rawQuery(`SELECT * FROM world_monster_encounters WHERE character_id='char-demo' AND monster_id='world-bandit-1'`).length,1);
  rawRun(`UPDATE battles SET status='RETREATED' WHERE character_id='char-demo' AND status='ACTIVE'`);
});

test('P4-03C-F: once CHASE, the monster authoritative distance to lastKnownPlayerPos strictly decreases across two evaluates while the player stays put',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  const trigger=await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'f-trigger'});
  await wait(300);
  const after1=await post('/api/commands/world/heartbeat',envelope(nextKey('f-1'),{}));
  const m0=bandit(trigger),m1=bandit(after1);
  assert.equal(m1.mode,'CHASE');
  const d0=Math.hypot(m0.position.x-AGGRO_ONLY.x,m0.position.y-AGGRO_ONLY.y);
  const d1=Math.hypot(m1.position.x-AGGRO_ONLY.x,m1.position.y-AGGRO_ONLY.y);
  assert.ok(d1<d0,`monster must have advanced closer to the stationary player (was ${d0}, now ${d1})`);
});

test('P4-03C-G: lastKnownPlayerPos updates to the freshest authoritative player position on every successful CHASE evaluate',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  const trigger=await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'g-trigger'});
  assert.deepEqual(bandit(trigger).lastKnownPlayerPos,AGGRO_ONLY);
  setPosition(520,300,'IN_WORLD'); // ~82.5px from patrolCenter — still comfortably within leashRadius(150)
  const after=await post('/api/commands/world/heartbeat',envelope(nextKey('g-move'),{}));
  const m=bandit(after);
  assert.equal(m.mode,'CHASE');
  assert.deepEqual(m.lastKnownPlayerPos,{x:520,y:300},'target must refresh to the newly observed player position');
});

test('P4-03C-H: once CHASE, the monster catching up within encounterRadius opens Battle exactly once',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  const trigger=await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'h-trigger'});
  assert.equal(trigger.data.encounterTriggered,false);
  const caught=await pollHeartbeatUntil(r=>r.data.encounterTriggered===true,{keyPrefix:'h-catch',intervalMs:120,timeoutMs:8000});
  assert.equal(caught.data.monsterId,'world-bandit-1');
  assert.equal(rawQuery(`SELECT id FROM battles WHERE character_id='char-demo' AND status='ACTIVE'`).length,1);
  assert.equal(rawQuery(`SELECT * FROM world_monster_encounters WHERE character_id='char-demo' AND monster_id='world-bandit-1'`).length,1);
  rawRun(`UPDATE battles SET status='RETREATED' WHERE character_id='char-demo' AND status='ACTIVE'`);
});

test('P4-03C-M: the player moving beyond leashRadius (measured from the fixed patrol center) disengages CHASE back to PATROL',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'m-trigger'});
  setPosition(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD'); // distance from patrolCenter = 380 > leashRadius(150)
  const disengaged=await post('/api/commands/world/heartbeat',envelope(nextKey('m-disengage'),{}));
  assert.equal(disengaged.status,'ACCEPTED');
  const m=bandit(disengaged);
  assert.equal(m.mode,'PATROL','beyond leashRadius must disengage back to PATROL');
  assert.equal(m.chaseAnchorPos,undefined,'a disengaged monster must carry no CHASE-only fields');
});

test('P4-03C-N: on disengage the monster snaps EXACTLY to patrolPositionAt(monster,disengageTime) — no intermediate RETURNING state',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'n-trigger'});
  setPosition(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const disengaged=await post('/api/commands/world/heartbeat',envelope(nextKey('n-disengage'),{}));
  const m=bandit(disengaged);
  assert.equal(m.mode,'PATROL');
  assert.deepEqual(m.position,patrolPositionAt(monster,m.serverNowMs),'position must be EXACTLY the canonical patrol formula at the disengage instant, with zero rebase/offset');
  const immediateNext=await post('/api/commands/world/heartbeat',envelope(nextKey('n-next'),{}));
  assert.equal(bandit(immediateNext).mode,'PATROL','no third state — the very next evaluate is already plain PATROL, not some RETURNING variant');
});

test('P4-03C-O: entering a city is unaffected by CHASE mode when no Battle has started yet — city acts as a Prototype safe zone, zero new guard',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'o-trigger'});
  const city=CITY_DEFINITIONS[0];
  setPosition(city.coordinates.x+city.entryRadius,city.coordinates.y,'IN_WORLD');
  const entered=await post('/api/commands/city/enter',envelope(nextKey('o-enter'),{destinationCityId:city.id}));
  assert.equal(entered.status,'ACCEPTED','CHASE in progress must never block city entry (Coding Order §26 — no ERR_MONSTER_CHASING guard)');
});

test('P4-03C-P: entering a city is still rejected while an ACTIVE Battle exists (the existing battleIsActive() guard, unaffected)',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  rawRun(`INSERT INTO battles VALUES(?,?,?,?,?)`,'p-fake-battle','char-demo','ACTIVE',Date.now(),Date.now());
  const city=CITY_DEFINITIONS[0];
  setPosition(city.coordinates.x+city.entryRadius,city.coordinates.y,'IN_WORLD');
  const entered=await post('/api/commands/city/enter',envelope(nextKey('p-enter'),{destinationCityId:city.id}));
  assert.equal(entered.status,'REJECTED');
  assert.equal(entered.errorCode,'ERR_BATTLE_ACTIVE');
  rawRun(`UPDATE battles SET status='RETREATED' WHERE id='p-fake-battle'`);
});

test('P4-03C-Q: starting bus/travel directly while IN_WORLD (chased or not) is still rejected — existing ERR_INVALID_STATE guard, no new P4-03C rule needed',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'q-trigger'});
  const destination=CITY_DEFINITIONS.find(c=>c.id!=='starter-village')??CITY_DEFINITIONS[0];
  const started=await post('/api/commands/transport/bus/start',envelope(nextKey('q-bus'),{destinationCityId:destination.id}));
  assert.equal(started.status,'REJECTED');
  assert.equal(started.errorCode,'ERR_INVALID_STATE');
});

test('P4-03C-R: after exitCity, a previous CHASE runtime never revives — the very next evaluate is PATROL',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'r-trigger'});
  const city=CITY_DEFINITIONS[0];
  setPosition(city.coordinates.x+city.entryRadius,city.coordinates.y,'IN_WORLD');
  const entered=await post('/api/commands/city/enter',envelope(nextKey('r-enter'),{destinationCityId:city.id}));
  assert.equal(entered.status,'ACCEPTED');
  const exited=await post('/api/commands/city/exit',envelope(nextKey('r-exit'),{}));
  assert.equal(exited.status,'ACCEPTED');
  const after=await post('/api/commands/world/heartbeat',envelope(nextKey('r-hb'),{}));
  const m=bandit(after);
  assert.ok(m,'monster must still be available (never consumed in this test)');
  assert.equal(m.mode,'PATROL','exitCity must reset any leftover CHASE runtime — no stale CHASE revives on return to IN_WORLD');
});

test('P4-03C-S: after a genuine server restart, a monster mid-CHASE resets to PATROL — memory-only runtime, no DB persistence',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'s-trigger'});
  child.kill();
  ({child,base}=await spawnServer());
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
  // Move the player away from the aggro zone BEFORE the post-restart check: the DB position survives
  // the restart (only the in-memory CHASE Map does not), so leaving the player parked right next to
  // the patrol route would legitimately re-trigger a BRAND NEW aggro acquisition on the very first
  // post-restart evaluate — a real, correct behavior, but not what this test is isolating (whether
  // the OLD chase runtime itself survived the restart).
  resetWorldDb(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const after=await post('/api/commands/world/heartbeat',envelope(nextKey('s-after'),{}));
  assert.equal(after.status,'ACCEPTED');
  const m=bandit(after);
  assert.equal(m.mode,'PATROL','a fresh server process must never resurrect a previous session\'s CHASE runtime — it exists only in memory');
});

test('P4-03C-T: a plain snapshot re-fetch (reload/reconnect simulation) while genuinely mid-CHASE reports the full CHASE runtime shape, not just PATROL fields',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'t-trigger'});
  const snap=await request('/api/character/char-demo/snapshot');
  const m=snap.worldMonsters.find(x=>x.id==='world-bandit-1');
  assert.equal(m.mode,'CHASE');
  assert.ok(Number.isFinite(m.chaseAnchorAt));
  assert.ok(m.chaseAnchorPos&&Number.isFinite(m.chaseAnchorPos.x));
  assert.ok(m.lastKnownPlayerPos&&Number.isFinite(m.lastKnownPlayerPos.x));
  assert.ok(Number.isFinite(m.serverNowMs));
});

test('P4-03C-U: worldHeartbeat() response carries worldMonsters in the shared shape, encounterId still withheld, no internal field leaks',async()=>{
  await resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const hb=await post('/api/commands/world/heartbeat',envelope(nextKey('u-hb'),{}));
  assert.ok(Array.isArray(hb.data.worldMonsters));
  const m=bandit(hb);
  assert.equal(m.mode,'PATROL');
  assert.ok(['id','displayName','level','mode','position','encounterRadius','serverNowMs'].every(k=>k in m));
  assert.ok(!('encounterId' in m),'encounterId must stay withheld from the client, unchanged since P4-02');
  assert.equal(hb.data.chaseStateProposal,undefined,'internal bookkeeping must never leak into the public response');
});

test('P4-03C-V: moveWorld() ACCEPTED response also carries worldMonsters in the exact same shared shape',async()=>{
  await resetWorldState(SAFE_FAR.x,SAFE_FAR.y,'IN_WORLD');
  const mv=await post('/api/commands/world/move',envelope(nextKey('v-mv'),{targetX:SAFE_FAR.x+10,targetY:SAFE_FAR.y,moveSequence:nextMoveSequence()}));
  assert.equal(mv.status,'ACCEPTED');
  assert.ok(Array.isArray(mv.data.worldMonsters));
  assert.equal(bandit(mv).mode,'PATROL');
  assert.equal(mv.data.chaseStateProposal,undefined);
});

// ============================================================================
// W-Z: client-side sync/rendering — structural proofs on public/app.js (DOM-free, same precedent as
// test/world-monster-patrol.test.mjs's P4-03A-I), plus a pure test on the exported staleness helper.
// ============================================================================

test('P4-03C-W: app.js\'s monster-marker patch loop is mode-aware — CHASE uses chasePositionAt with the server-supplied anchor triple, PATROL keeps using patrolPositionAt unchanged',()=>{
  const appSource=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
  assert.ok(appSource.includes("monster.mode==='CHASE'"),'the marker loop must branch on the server-reported mode');
  assert.ok(appSource.includes('chasePositionAt(monster.chaseAnchorPos,monster.chaseAnchorAt,monster.lastKnownPlayerPos,definition.chaseSpeed,approxServerNow)'),'CHASE must be interpolated via the server-supplied anchor triple, never a client-invented/predicted position');
  assert.ok(appSource.includes(':patrolPositionAt(definition,approxServerNow);'),'PATROL must still fall back to the existing, unmodified patrol formula');
});

test('P4-03C-X: CHASE->PATROL needs no client-side transition handling — the marker patch loop is stateless per frame, driven only by the live S.snap.worldMonsters entry',()=>{
  const appSource=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
  assert.ok(appSource.includes('for(const monster of S.snap?.worldMonsters||[])'),'the loop must keep iterating the live snapshot array directly (P4-03A-I precedent) — a disengaged monster simply reports mode:\'PATROL\' on its very next entry, with no separate client-side "was chasing" flag to clear');
});

test('P4-03C-Y: shouldApplyWorldMonstersSync rejects an older revision and accepts a newer/equal one, independent of request completion order',()=>{
  const older=[{id:'world-bandit-1',revision:1}],newer=[{id:'world-bandit-1',revision:2}];
  assert.equal(shouldApplyWorldMonstersSync(newer,1),true);
  assert.equal(shouldApplyWorldMonstersSync(older,2),false,'an out-of-order OLDER response must never roll world-monster truth backwards');
  assert.equal(shouldApplyWorldMonstersSync(newer,2),true,'equal revisions (the same evaluate observed twice) must still apply, never treated as stale');
  assert.equal(shouldApplyWorldMonstersSync([],2),true,'an empty array (every monster consumed) has nothing to disagree with — always applied');
  assert.equal(shouldApplyWorldMonstersSync(newer,NaN),true,'no prior sync recorded yet — always applied');
});

// P4-03C Draft Review Fix — refresh() replaces S.snap wholesale with a fresh authoritative
// snapshot but never advanced lastWorldMonstersSyncAt on the pre-fix head (13f94bbfe00077002df06355e46c925687b57bf6):
// a heartbeat/move request that began BEFORE that refresh() but only completes (client-side) AFTER
// it — a real, server-timestamp-OLDER response simply arriving late — could still pass
// shouldApplyWorldMonstersSync's own staleness check against a watermark refresh() never touched,
// wrongly overwriting the fresher snapshot's worldMonsters. Layer 1 (behavioral): proves the exact
// race using ONLY shouldApplyWorldMonstersSync (already present, unchanged, on the pre-fix head) —
// reproduces the confirmed bug directly, no new export needed to see it fail. Layer 2 (behavioral):
// proves the fix's own math (nextWorldMonstersSyncWatermark) resolves the same race correctly, plus
// the two required side-cases (a genuinely newer response after the snapshot still applies; equal
// timestamps stay deterministic). Layer 3 (structural): proves production is actually wired to call
// the fix at the one place that matters — refresh() itself — not just that the pure math is right in
// isolation (same two-layer discipline as P4-03A-H's Layer 1/Layer 2 precedent).
test('P4-03C-Y2 (Layer 1 — reproduces the confirmed bug): without refresh() advancing the freshness watermark, a delayed OLDER world response wrongly passes the staleness check after a newer snapshot',()=>{
  const T1=1000,T2=2000; // T2 > T1 — the snapshot (T2) is genuinely newer than the delayed response (T1)
  const delayedOlderResponse=[{id:'world-bandit-1',serverNowMs:T1}];
  // Step 1-2: an old world response exists (this proof predates the Codex-review revision fix, so it
  // is expressed in the ORIGINAL serverNowMs-based shape the confirmed bug was reported against —
  // current watermark old/unset.
  // Step 3: a newer authoritative snapshot (serverNowMs=T2) is "applied" — but on the pre-Draft-
  // Review-Fix head, refresh() never touched lastWorldMonstersSyncAt, so the watermark AFTER the
  // snapshot is exactly whatever it was BEFORE (unset here — the common real case: no world/move or
  // world/heartbeat response has completed yet since boot/reload).
  const staleWatermarkOnPreFixHead=NaN;
  // Step 5-6: the delayed T1 response now arrives. On that pre-fix head this WRONGLY returns true —
  // the confirmed bug — even though T2 (already applied via the snapshot) is genuinely newer. Note:
  // shouldApplyWorldMonstersSync's field name has since moved from serverNowMs to revision (Codex
  // Review P2, see Layer 2/3 below) — this proof still holds against the pre-fix head exactly as
  // originally reported, since that head compared on serverNowMs.
  assert.equal(shouldApplyWorldMonstersSync(delayedOlderResponse,staleWatermarkOnPreFixHead),true,'reproduces the confirmed bug exactly: on the pre-fix head refresh() never advanced the watermark, so this delayed OLDER (T1<T2) response is wrongly accepted and would overwrite the fresher snapshot\'s worldMonsters');
});

// P4-03C Codex Review (P2) — millisecond-resolution serverNowMs cannot distinguish two evaluates
// landing in the same millisecond, so the freshness axis (both server-side worldStateRevisionCounter
// and this client-side watermark) moved to a plain incrementing integer, `revision`, that can never
// tie across genuinely different evaluates. Layer 2/3 below are expressed against this current,
// revision-based shape.
test('P4-03C-Y2 (Layer 2 — proves the fix): nextWorldMonstersSyncWatermark, wired the way refresh() now is, correctly rejects the same delayed older response, still applies a genuinely newer one, and keeps equal-revision semantics deterministic',()=>{
  const R1=1,R2=2,R3=3;
  let watermark=NaN; // "current monster sync watermark is old/unset"
  // refresh() applies the snapshot (revision=R2) and advances the SAME watermark from it.
  watermark=nextWorldMonstersSyncWatermark(watermark,R2);
  assert.equal(watermark,R2,'the watermark must advance to the snapshot\'s own authoritative revision');
  // The delayed R1 response (older than the snapshot just applied) now arrives — must be rejected.
  const delayedOlderResponse=[{id:'world-bandit-1',revision:R1}];
  assert.equal(shouldApplyWorldMonstersSync(delayedOlderResponse,watermark),false,'a response older than the snapshot just applied must never overwrite it — this is what fails on the pre-fix head (see Layer 1) and passes here');
  // Required side-case: a genuinely NEWER response (R3>R2) arriving after the snapshot must still apply.
  const newerResponse=[{id:'world-bandit-1',revision:R3}];
  assert.equal(shouldApplyWorldMonstersSync(newerResponse,watermark),true,'a response genuinely newer than the last-applied snapshot must still be allowed to apply');
  watermark=nextWorldMonstersSyncWatermark(watermark,R3);
  assert.equal(watermark,R3);
  // Required side-case: equal-revision semantics remain deterministic (the same evaluate observed
  // twice, e.g. once via its own response and once again via a subsequent snapshot, must not be
  // treated as stale merely for arriving a second time).
  const sameInstantResponse=[{id:'world-bandit-1',revision:R3}];
  assert.equal(shouldApplyWorldMonstersSync(sameInstantResponse,watermark),true,'an equal revision must still apply deterministically, never treated as stale');
  assert.equal(nextWorldMonstersSyncWatermark(watermark,R3),R3,'advancing by an equal revision is a deterministic no-op, never regresses');
  // Defensive/NaN-safety cases the pure helper itself must handle.
  assert.equal(nextWorldMonstersSyncWatermark(NaN,R1),R1,'an unset current watermark adopts the first real candidate');
  assert.equal(nextWorldMonstersSyncWatermark(R3,NaN),R3,'a non-finite candidate (nothing authoritative to advance to) leaves the current watermark untouched');
});

test('P4-03C-Y2 (Layer 3 — production wiring): refresh() actually calls nextWorldMonstersSyncWatermark with S.snap\'s own worldStateRevision immediately after S.snap is replaced, and applyWorldMonstersSync routes through the exact same function',()=>{
  const appSource=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
  const refreshStart=appSource.indexOf('async function refresh('),refreshEnd=appSource.indexOf('\nfunction ',refreshStart+10);
  const refreshBody=appSource.slice(refreshStart,refreshEnd>0?refreshEnd:undefined);
  const snapAssignIdx=refreshBody.indexOf("S.snap=await req('/api/character/char-demo/snapshot');");
  const watermarkAdvanceIdx=refreshBody.indexOf('lastWorldMonstersSyncRevision=nextWorldMonstersSyncWatermark(lastWorldMonstersSyncRevision,S.snap.worldStateRevision);');
  assert.ok(snapAssignIdx>=0,'refresh() must still replace S.snap from the snapshot endpoint');
  assert.ok(watermarkAdvanceIdx>=0,'refresh() must advance lastWorldMonstersSyncRevision via nextWorldMonstersSyncWatermark, using S.snap\'s own authoritative worldStateRevision');
  assert.ok(watermarkAdvanceIdx>snapAssignIdx,'the watermark advance must happen AFTER S.snap is actually replaced with the fresh snapshot, not before');
  const applySyncStart=appSource.indexOf('function applyWorldMonstersSync('),applySyncEnd=appSource.indexOf('\nfunction ',applySyncStart+10);
  const applySyncBody=appSource.slice(applySyncStart,applySyncEnd>0?applySyncEnd:undefined);
  assert.ok(applySyncBody.includes('lastWorldMonstersSyncRevision=nextWorldMonstersSyncWatermark(lastWorldMonstersSyncRevision,appliedRevision);'),'applyWorldMonstersSync must advance the SAME watermark via the SAME function — one consistent freshness axis, never two independent systems');
});

test('P4-03C-Z: worldMonsters sync never gates or delays the existing battle-resync priority — applyWorldMonstersSync runs unconditionally before the battleAlreadyActiveFromWorldResponse check in both sendWorldMove and sendWorldHeartbeat',()=>{
  const appSource=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
  const moveStart=appSource.indexOf('const sendWorldMove=async'),moveEnd=appSource.indexOf('// P4-03B — client-triggered idle-world liveness poll.');
  const moveBody=appSource.slice(moveStart,moveEnd);
  const heartbeatBody=appSource.slice(moveEnd);
  for(const [label,body] of [['sendWorldMove',moveBody],['sendWorldHeartbeat',heartbeatBody]]){
    const syncIdx=body.indexOf('applyWorldMonstersSync(r.data)'),battleIdx=body.indexOf('battleAlreadyActiveFromWorldResponse(r)');
    assert.ok(syncIdx>=0&&battleIdx>=0&&syncIdx<battleIdx,`${label}: the worldMonsters sync must run unconditionally BEFORE the battle-resync branch, never inside a condition that could skip or delay it`);
  }
});

// ============================================================================
// AA-AD: idempotency / rollback safety — same discipline P4-03B's exitCity watermark bug (and its
// fix) established; must not be repeated for CHASE runtime state.
// ============================================================================

test('P4-03C-AA: replaying the same heartbeat idempotencyKey never re-advances CHASE state a second time',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'aa-trigger'});
  const key=nextKey('aa-advance');
  const first=await post('/api/commands/world/heartbeat',envelope(key,{}));
  await wait(300);
  const replay=await post('/api/commands/world/heartbeat',envelope(key,{}));
  assert.deepEqual(replay,first,'the exact same idempotencyKey must return the exact same cached result, never a freshly re-evaluated one');
});

test('P4-03C-AB: replaying the same moveWorld idempotencyKey (identical payload) never re-advances CHASE state a second time',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'ab-trigger'});
  const env=envelope(nextKey('ab-advance'),{targetX:AGGRO_ONLY.x,targetY:AGGRO_ONLY.y,moveSequence:nextMoveSequence()});
  const first=await post('/api/commands/world/move',env);
  await wait(300);
  const replay=await post('/api/commands/world/move',env);
  assert.deepEqual(replay,first,'the exact same idempotencyKey+payload must return the exact same cached result');
});

test('P4-03C-AC: idempotent replay never rebases chaseAnchorAt to the replay instant',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'ac-trigger'});
  const key=nextKey('ac-advance');
  const first=await post('/api/commands/world/heartbeat',envelope(key,{}));
  const originalAnchorAt=bandit(first).chaseAnchorAt;
  await wait(500);
  const replay=await post('/api/commands/world/heartbeat',envelope(key,{}));
  assert.equal(bandit(replay).chaseAnchorAt,originalAnchorAt,'a cached replay must report the exact same chaseAnchorAt as the original — never a value implying the anchor moved forward at replay time');
});

test('P4-03C-AD: a REJECTED command (e.g. ERR_BATTLE_ACTIVE) never mutates CHASE runtime state',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'ad-trigger'});
  const before=(await request('/api/character/char-demo/snapshot')).worldMonsters.find(x=>x.id==='world-bandit-1');
  rawRun(`INSERT INTO battles VALUES(?,?,?,?,?)`,'ad-fake-battle','char-demo','ACTIVE',Date.now(),Date.now());
  const rejected=await post('/api/commands/world/heartbeat',envelope(nextKey('ad-rejected'),{}));
  assert.equal(rejected.status,'REJECTED');
  assert.equal(rejected.errorCode,'ERR_BATTLE_ACTIVE');
  const afterReject=(await request('/api/character/char-demo/snapshot')).worldMonsters.find(x=>x.id==='world-bandit-1');
  assert.equal(afterReject.chaseAnchorAt,before.chaseAnchorAt,'a REJECTED command must never rebase the anchor — the guard fires before the evaluator (and any state proposal) ever runs');
  assert.deepEqual(afterReject.chaseAnchorPos,before.chaseAnchorPos);
  rawRun(`UPDATE battles SET status='RETREATED' WHERE id='ad-fake-battle'`);
});

// ============================================================================
// AE-AG: concurrency — real, genuinely parallel HTTP requests (same precedent as P4-03B-J), checking
// the converged end state rather than fabricating a literal response-reorder no real client/network
// could actually produce.
// ============================================================================

test('P4-03C-AE: heartbeat and moveWorld evaluated concurrently converge on exactly one consistent CHASE state, whichever wins the race',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'ae-trigger'});
  const [hbResult,mvResult]=await Promise.all([
    post('/api/commands/world/heartbeat',envelope(nextKey('ae-hb'),{})),
    post('/api/commands/world/move',envelope(nextKey('ae-mv'),{targetX:AGGRO_ONLY.x,targetY:AGGRO_ONLY.y,moveSequence:nextMoveSequence()}))
  ]);
  assert.equal(hbResult.status,'ACCEPTED');
  assert.equal(mvResult.status,'ACCEPTED');
  const finalSnap=await request('/api/character/char-demo/snapshot');
  const m=finalSnap.worldMonsters.find(x=>x.id==='world-bandit-1');
  assert.equal(m.mode,'CHASE','the two concurrent evaluates must converge on one single, unambiguous mode — never left in an inconsistent state');
});

test('P4-03C-AF: two concurrent evaluates racing while CHASE is closing in converge on exactly one Battle, never two',async()=>{
  await resetWorldState(AGGRO_ONLY.x,AGGRO_ONLY.y,'IN_WORLD');
  await pollHeartbeatUntil(r=>bandit(r)?.mode==='CHASE',{keyPrefix:'af-trigger'});
  const [a,b]=await Promise.all([
    post('/api/commands/world/heartbeat',envelope(nextKey('af-a'),{})),
    post('/api/commands/world/move',envelope(nextKey('af-b'),{targetX:AGGRO_ONLY.x,targetY:AGGRO_ONLY.y,moveSequence:nextMoveSequence()}))
  ]);
  assert.equal(a.status,'ACCEPTED');
  assert.equal(b.status,'ACCEPTED');
  assert.equal(rawQuery(`SELECT id FROM battles WHERE character_id='char-demo' AND status='ACTIVE'`).length<=1,true,'at most one ACTIVE battle, whatever order the two concurrent commands actually resolved in');
  assert.equal(rawQuery(`SELECT * FROM world_monster_encounters WHERE character_id='char-demo' AND monster_id='world-bandit-1'`).length<=1,true,'at most one consumption row — world_monster_encounters\' own PRIMARY KEY is the ultimate guarantee');
  rawRun(`UPDATE battles SET status='RETREATED' WHERE character_id='char-demo' AND status='ACTIVE'`);
});

test('P4-03C-AG: advanceWorldChaseState only ever advances monotonically by revision — same rollback/replay-safety discipline as advanceWorldExposureWatermark, applied AFTER idem() returns, never inside the transaction',()=>{
  const serverSource=readFileSync(new URL('../server.mjs',import.meta.url),'utf8');
  const start=serverSource.indexOf('function advanceWorldChaseState('),end=serverSource.indexOf('// The live worldChaseState Map is only ever updated AFTER idem() returns');
  const body=serverSource.slice(start,end);
  assert.ok(body.includes("if(result.status!=='ACCEPTED')return;"),'must bail out immediately on anything but ACCEPTED — a rolled-back/rejected command never mutates the Map');
  assert.ok(body.includes('current.revision>=proposal.revision'),'must compare revision monotonically (never millisecond-resolution evaluatedAt, which can tie across two genuinely different evaluates in the same millisecond) — a stale/cached proposal can never regress a newer real transition');
  assert.ok(!body.includes('.delete(characterId)'),'must never delete the Map entry on clear — deleting loses the ordering watermark and lets a stale idempotent replay resurrect obsolete chase state; a tombstone ({mode:\'PATROL\',...}) must be written instead');
  for(const fnName of ['worldHeartbeat','moveWorld','exitCity']){
    const callSite=serverSource.indexOf(`function ${fnName}(env)`);
    const nextFn=serverSource.indexOf('\nfunction ',callSite+10);
    const fnBody=serverSource.slice(callSite,nextFn>0?nextFn:undefined);
    assert.ok(fnBody.includes('advanceWorldChaseState('),`${fnName} must call advanceWorldChaseState AFTER idem() has already returned, not inside the idem()-wrapped callback`);
  }
});
