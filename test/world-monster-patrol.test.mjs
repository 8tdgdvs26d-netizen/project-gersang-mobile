import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {WORLD_MONSTER_DEFINITIONS,patrolPositionAt} from '../public/worldmonsters.js';
import {WORLD_BOUNDS,OBSTACLES,inflateRect,segmentIntersectsRect,PLAYER_COLLISION_RADIUS} from '../public/worldgeometry.js';
import {CITY_DEFINITIONS} from '../public/cities.js';
import {MOVE_CATCHUP_CAP_MS} from '../public/movement.js';
import {computeServerTimeOffset} from '../public/app.js';

// P4-03A — Deterministic World Monster Patrol. Covers acceptance tests P4-03A-A through P4-03A-I
// from the approved Coding Order (P4-03A-J/K/L are the P4-02/movement/full-suite regression gates,
// reported at the npm-test level via re-running the existing test files, not as individual tests
// here). Pure-function tests (A-D) need no server; server-integration tests (E-I) follow the exact
// real-spawned-server pattern already used by test/world-encounter.test.mjs.

const monster=WORLD_MONSTER_DEFINITIONS[0];
const legDistance=Math.hypot(monster.patrolB.x-monster.patrolA.x,monster.patrolB.y-monster.patrolA.y);
const legDurationMs=legDistance/monster.patrolSpeed;
const midpoint={x:(monster.patrolA.x+monster.patrolB.x)/2,y:(monster.patrolA.y+monster.patrolB.y)/2};

// Closest-point-on-segment-to-point distance — same closest-point math shape as
// segmentEntersEncounterRadius (public/worldmonsters.js), used here purely as a content-validation
// tool (P4-03A-D), not a runtime collision system.
function closestDistanceFromPointToSegment(point,from,to){
  const dx=to.x-from.x,dy=to.y-from.y,lengthSquared=dx*dx+dy*dy;
  const cx=point.x-from.x,cy=point.y-from.y;
  const t=lengthSquared>0?Math.max(0,Math.min(1,(cx*dx+cy*dy)/lengthSquared)):0;
  const closestX=from.x+t*dx,closestY=from.y+t*dy;
  return Math.hypot(closestX-point.x,closestY-point.y);
}

// P4-03A-A: deterministic formula — the same (monster, timeMs) always returns the same position.
test('P4-03A-A: patrolPositionAt is a deterministic pure function of (monster, timeMs)',()=>{
  for(const t of [0,1,legDurationMs/3,legDurationMs,legDurationMs*1.7,legDurationMs*2,-500,999999999]){
    const p1=patrolPositionAt(monster,t),p2=patrolPositionAt(monster,t);
    assert.deepEqual(p1,p2,`expected identical results for repeated calls at t=${t}`);
  }
});

// P4-03A-B: triangle wave — A -> midpoint -> B -> midpoint -> A over one full cycle.
test('P4-03A-B: triangle wave patrol visits A, midpoint, B, midpoint, then A again over one full cycle',()=>{
  const anchor=monster.patrolAnchorAt;
  assert.deepEqual(patrolPositionAt(monster,anchor),monster.patrolA);
  assert.deepEqual(patrolPositionAt(monster,anchor+legDurationMs/2),midpoint);
  assert.deepEqual(patrolPositionAt(monster,anchor+legDurationMs),monster.patrolB);
  assert.deepEqual(patrolPositionAt(monster,anchor+legDurationMs*1.5),midpoint);
  assert.deepEqual(patrolPositionAt(monster,anchor+legDurationMs*2),monster.patrolA);
});

// P4-03A-C: the entire patrol route stays within WORLD_BOUNDS at every sampled point across two
// full cycles (not just the endpoints).
test('P4-03A-C: the entire patrol route stays within WORLD_BOUNDS',()=>{
  for(let t=0;t<=legDurationMs*2;t+=137){
    const p=patrolPositionAt(monster,t);
    assert.ok(p.x>=WORLD_BOUNDS.min&&p.x<=WORLD_BOUNDS.max,`x out of WORLD_BOUNDS at t=${t}: ${p.x}`);
    assert.ok(p.y>=WORLD_BOUNDS.min&&p.y<=WORLD_BOUNDS.max,`y out of WORLD_BOUNDS at t=${t}: ${p.y}`);
  }
});

// P4-03A-D: obstacle-safe, city-safe content — automated data validation, not eyeballed. The
// patrolA->patrolB segment must not enter any (player-collision-inflated) static obstacle, and must
// stay clear of every city's entryRadius with a safety margin, at every point along the route (not
// just the endpoints — hence closestDistanceFromPointToSegment rather than two endpoint checks).
test('P4-03A-D: the patrol route does not enter any static obstacle and stays clear of every city entry radius with margin',()=>{
  const inflated=OBSTACLES.map(r=>inflateRect(r,PLAYER_COLLISION_RADIUS));
  for(const rect of inflated){
    assert.equal(segmentIntersectsRect(monster.patrolA.x,monster.patrolA.y,monster.patrolB.x,monster.patrolB.y,rect),false,`patrol segment must not intersect inflated obstacle ${rect.id}`);
  }
  for(const city of CITY_DEFINITIONS){
    const dist=closestDistanceFromPointToSegment(city.coordinates,monster.patrolA,monster.patrolB);
    assert.ok(dist>city.entryRadius+monster.encounterRadius,`patrol route must clear ${city.id}'s entry radius with a safety margin, got distance=${dist}`);
  }
});

let child,base,dir,sessionId;
const request=async(path,options={})=>{const r=await fetch(base+path,{headers:{'content-type':'application/json'},...options});return r.json()};
const post=(path,body)=>request(path,{method:'POST',body:JSON.stringify(body)});
const envelope=(key,payload)=>({commandId:crypto.randomUUID(),idempotencyKey:key,sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const setPosition=(x,y,state)=>{const fixture=new DatabaseSync(join(dir,'test.sqlite'));fixture.prepare(`UPDATE characters SET world_x=?,world_y=?,state=? WHERE id='char-demo'`).run(x,y,state);fixture.close()};
const rawQuery=(sql,...params)=>{const fixture=new DatabaseSync(join(dir,'test.sqlite'));const rows=fixture.prepare(sql).all(...params);fixture.close();return rows};

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-world-monster-patrol-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:join(dir,'test.sqlite')},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`))) });
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

// P4-03A-E: snapshot moving truth. Two reads at different (known, server-reported) times expose
// different, server-computed positions, each independently cross-verified against the real shared
// formula at that read's own serverNowMs — deterministic clock control via the server's own reported
// clock, never a real-sleep-and-hope-it-changed assumption.
test('P4-03A-E: snapshot exposes a moving, server-computed patrol position, cross-verified against the shared formula at each read\'s own serverNowMs',async()=>{
  const snap1=await request('/api/character/char-demo/snapshot');
  const m1=snap1.worldMonsters.find(m=>m.id==='world-bandit-1');
  assert.ok(Number.isFinite(snap1.serverNowMs));
  assert.deepEqual(m1.position,patrolPositionAt(monster,snap1.serverNowMs));
  await wait(500);
  const snap2=await request('/api/character/char-demo/snapshot');
  const m2=snap2.worldMonsters.find(m=>m.id==='world-bandit-1');
  assert.ok(snap2.serverNowMs>snap1.serverNowMs,'serverNowMs must be monotonic across reads');
  assert.deepEqual(m2.position,patrolPositionAt(monster,snap2.serverNowMs));
  assert.notDeepEqual(m1.position,m2.position,'position must actually have moved between the two reads');
});

// P4-03A-F: client clock offset. computeServerTimeOffset reconstructs the server's own clock reading
// exactly, even from a wildly skewed client clock — proving the formula itself is correct — plus a
// structural check that refresh() actually wires it in, not just an unused export.
test('P4-03A-F: computeServerTimeOffset reconstructs the exact server time from a real serverNowMs, regardless of how skewed the client clock is',async()=>{
  const snap=await request('/api/character/char-demo/snapshot');
  for(const skewMs of [0,-6*60*60*1000,6*60*60*1000,10*24*60*60*1000]){
    const skewedClientNow=Date.now()+skewMs;
    const offset=computeServerTimeOffset(snap.serverNowMs,skewedClientNow);
    assert.equal(skewedClientNow+offset,snap.serverNowMs,`offset must reconstruct serverNowMs exactly even with a ${skewMs}ms client clock skew`);
  }
  const appSource=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
  assert.ok(appSource.includes('serverTimeOffset=computeServerTimeOffset(S.snap.serverNowMs,Date.now());'),'refresh() must actually wire computeServerTimeOffset in, not leave it unused');
});

// P4-03A-H: a movement segment through a fixed point outside the monster's reachable patrol range
// never triggers. Runs BEFORE P4-03A-G (which consumes the monster) so this proves the check against
// a still-active, still-patrolling monster, not a trivial "already gone" case. Deliberately does NOT
// use a time-shifted "where was it before" decoy: for this two-point reflecting patrol, EVERY fixed
// real-time shift has some starting phase where the shifted and current positions coincide exactly
// (verified numerically while designing this test — a consequence of the triangle wave being
// continuous and periodic), so any such decoy would be phase-dependent and flaky. Instead this uses a
// point that is spatially unreachable by the patrol at ANY phase: patrolA.x=460 is the leftmost point
// the monster ever reaches, and this segment's closest approach (x=410) is already >40px away from
// it (sqrt(50^2+20^2)~=53.9), so it is provably safe regardless of the monster's current phase.
test('P4-03A-H: a movement segment through a point outside the patrol\'s reachable range never triggers, while the monster is still active',async()=>{
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const decoyFromX=monster.patrolA.x-150,decoyToX=monster.patrolA.x-50;
  setPosition(decoyFromX,200,'IN_WORLD');
  const moved=await post('/api/commands/world/move',envelope('patrol-decoy-miss',{targetX:decoyToX,targetY:200}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.encounterTriggered,undefined);
  const battle=await request('/api/character/char-demo/battle');
  assert.equal(battle,null);
  const snap=await request('/api/character/char-demo/snapshot');
  assert.ok(snap.worldMonsters.some(m=>m.id==='world-bandit-1'),'monster must remain available/unconsumed');
});

// P4-03A-G: a movement segment through the monster's freshly-read LIVE patrol position triggers
// exactly one battle and exactly one consumption row — mirroring test/world-encounter.test.mjs's
// P4-02-D/E design (query live position immediately before acting; patrol speed is slow enough that
// the negligible drift during one HTTP round trip is far under encounterRadius).
test('P4-03A-G: a movement segment through the monster\'s live patrol position triggers exactly one battle and one consumption row',async()=>{
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const live=await request('/api/character/char-demo/snapshot');
  const liveMonster=live.worldMonsters.find(m=>m.id==='world-bandit-1');
  assert.ok(liveMonster,'expected world-bandit-1 to still be available before triggering');
  const {x:liveX,y:liveY}=liveMonster.position;
  setPosition(liveX-50,liveY-20,'IN_WORLD');
  const moved=await post('/api/commands/world/move',envelope('patrol-encounter-trigger',{targetX:liveX+50,targetY:liveY-20}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.encounterTriggered,true);
  assert.equal(moved.data.monsterId,'world-bandit-1');
  const activeBattles=rawQuery(`SELECT id FROM battles WHERE character_id='char-demo' AND status='ACTIVE'`);
  assert.equal(activeBattles.length,1);
  const encounterRows=rawQuery(`SELECT * FROM world_monster_encounters WHERE character_id='char-demo' AND monster_id='world-bandit-1'`);
  assert.equal(encounterRows.length,1);
});

// P4-03A-I: once consumed (by P4-03A-G above), the monster stops appearing in snapshot, and the
// client's cosmetic rAF patch can never resurrect it — verified structurally: the patch loop reads
// S.snap.worldMonsters fresh every frame, with no separate/cached monster list it could fall back to.
test('P4-03A-I: once consumed, the monster stops appearing in snapshot, and app.js\'s marker patch loop has no cached list to resurrect it from',async()=>{
  const snap=await request('/api/character/char-demo/snapshot');
  assert.ok(!snap.worldMonsters.some(m=>m.id==='world-bandit-1'));
  const appSource=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
  assert.ok(appSource.includes('for(const monster of S.snap?.worldMonsters||[])'),'the monster marker patch loop must iterate the live snapshot array directly, never a cached/module-level list');
});
