import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {WORLD_MONSTER_DEFINITIONS,patrolPositionAt,segmentEntersEncounterRadius} from '../public/worldmonsters.js';
import {WORLD_BOUNDS,OBSTACLES,inflateRect,segmentIntersectsRect,PLAYER_COLLISION_RADIUS} from '../public/worldgeometry.js';
import {CITY_DEFINITIONS} from '../public/cities.js';
import {MOVE_CATCHUP_CAP_MS} from '../public/movement.js';
import {computeServerTimeOffset} from '../public/app.js';

// P4-03A — Deterministic World Monster Patrol. Covers acceptance tests P4-03A-A through P4-03A-I
// from the approved Coding Order (P4-03A-J/K/L are the P4-02/movement/full-suite regression gates,
// reported at the npm-test level via re-running the existing test files, not as individual tests
// here). Pure-function tests (A-D) need no server; server-integration tests (E-I) follow the exact
// real-spawned-server pattern already used by test/world-encounter.test.mjs. P4-03A-H was later
// split into Layer 1/Layer 2 (Review Fix round 2). P4-03A-M through P (Merge Gate fix "Account for
// Snapshot Transit Time") replace the original F — see their own comments below for why.

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

// P4-03A-H (Layer 1 — behaviour geometry): pure differential proof that the encounter check has
// genuinely switched from a static center to patrolPositionAt() — P4-03A Review Fix round 1. The
// original H (a decoy point outside the patrol's reachable range) only proved an ordinary proximity
// miss: it would have passed identically even if moveWorld() still used the OLD P4-02 static
// `position:{x:500,y:220}`, since that decoy was far from BOTH the live position AND the old static
// point. This version instead constructs a segment that is DESIGNED to hit the old static (500,220)
// reference point, then checks it against the monster's true, live, dynamic position at a known,
// fully deterministic time — no server, no sleep, no real clock at all, just
// patrolPositionAt(monster,knownTime) and the same segmentEntersEncounterRadius() primitive
// moveWorld() itself uses. At the known time `monster.patrolAnchorAt` the monster sits exactly at
// patrolA=(440,220), 60px from the old static point — outside its 40px encounterRadius with a
// genuine (not boundary-exact) margin, specifically BECAUSE the patrol route was widened from an
// initial 80px leg to 120px for exactly this reason (see public/worldmonsters.js's own comment). If a
// regression ever reintroduced a hardcoded static center, this test's own "wouldHitOldStatic" sanity
// assertion would still hold (proving the test segment is a valid trap), while "actualResult" would
// flip to true — catching the regression IN THE GEOMETRY. This is deliberately paired with the
// Layer 2 production-wiring test right below it: Layer 1 alone never touches server.mjs, so it cannot
// by itself catch a regression where moveWorld()'s real encounter check silently stops calling
// patrolPositionAt(m,now) at all — that is what Layer 2 exists to close (P4-03A Review Fix round 2).
test('P4-03A-H (Layer 1): a segment built to hit the OLD static (500,220) reference point misses the monster\'s true live position at a known time — proving the check now uses patrolPositionAt, not a fixed static center',()=>{
  const knownTime=monster.patrolAnchorAt;
  const livePosition=patrolPositionAt(monster,knownTime);
  assert.deepEqual(livePosition,monster.patrolA,'at the anchor time, the monster is exactly at patrolA');
  const oldStaticReference={x:500,y:220};
  const distanceFromOldStatic=Math.hypot(livePosition.x-oldStaticReference.x,livePosition.y-oldStaticReference.y);
  assert.ok(distanceFromOldStatic>monster.encounterRadius,`live position must be genuinely (not just barely) outside the old static center's encounter radius at this known time, got distance=${distanceFromOldStatic}`);
  // A short segment straddling (500,220): closest point is (500,200), 20px from the old static
  // center (inside its 40px radius — a static implementation WOULD trigger), but 53.85px from the
  // monster's true live position at patrolA (outside its 40px radius — the dynamic check must MISS).
  const from={x:490,y:200},to={x:510,y:200};
  const wouldHitOldStatic=segmentEntersEncounterRadius(from,to,{...monster,position:oldStaticReference});
  assert.equal(wouldHitOldStatic,true,'sanity check: this segment must be a valid trap for a static (500,220) implementation');
  const actualResult=segmentEntersEncounterRadius(from,to,{...monster,position:livePosition});
  assert.equal(actualResult,false,'checked against the monster\'s real live dynamic position, this segment must MISS — proving the check no longer uses the old static center');
});

// P4-03A-H (Layer 2 — production wiring, P4-03A Review Fix round 2): the Layer 1 test above proves
// the GEOMETRY differential (static center -> HIT, live patrol center -> MISS) by calling
// segmentEntersEncounterRadius() directly — but that alone never touches server.mjs at all, so it
// cannot by itself catch a regression where moveWorld()'s real encounter check silently stops calling
// patrolPositionAt(m,now) (e.g. reverting to a hardcoded/static monster position, or to `m.position`
// which no longer even exists on WORLD_MONSTER_DEFINITIONS). This reads server.mjs's actual source,
// narrowly scoped to moveWorld()'s own function body only (not "patrolPositionAt appears somewhere in
// this 500+ line file" — a much weaker claim that could pass even if the encounter check itself never
// used it), and asserts the exact production wiring: patrolPositionAt(m,now) is what's actually
// supplied as segmentEntersEncounterRadius()'s monster `position`. Together, Layer 1 + Layer 2 close
// the loop — if a future edit reverts moveWorld() to a static center, THIS test fails immediately, on
// the real production source, regardless of what Layer 1's own pure-geometry check would separately
// report (and Layer 1 in turn proves that choice is behaviourally meaningful, not just cosmetic).
test('P4-03A-H (Layer 2): moveWorld()\'s own encounter check is wired to pass patrolPositionAt(m,now) as segmentEntersEncounterRadius()\'s monster position',()=>{
  const serverSource=readFileSync(new URL('../server.mjs',import.meta.url),'utf8');
  const moveWorldStart=serverSource.indexOf('function moveWorld(');
  assert.ok(moveWorldStart>=0,'moveWorld() must exist in server.mjs');
  const nextFunctionStart=serverSource.indexOf('\nasync function api(',moveWorldStart);
  assert.ok(nextFunctionStart>moveWorldStart,'expected to find the next top-level function after moveWorld() to bound its body, so this assertion stays scoped to moveWorld() itself');
  const moveWorldBody=serverSource.slice(moveWorldStart,nextFunctionStart);
  assert.ok(moveWorldBody.includes('segmentEntersEncounterRadius(current,{x:nextX,y:nextY},{...m,position:patrolPositionAt(m,now)})'),'moveWorld()\'s own encounter check must pass patrolPositionAt(m,now) as the monster position given to segmentEntersEncounterRadius() — a regression to a static/hardcoded position would not match this exact wiring, and this assertion would fail');
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

// P4-03A-E: snapshot server-wiring evidence. `monster會隨時間移動` itself is already fully proven,
// deterministically, by P4-03A-A (pure formula determinism) and P4-03A-B (pure triangle-wave shape)
// — E does not need to re-prove that by sleeping and hoping the position changed. What E actually
// needs to prove is that the REAL server's snapshot() route is genuinely wired to compute
// worldMonsters[].position via patrolPositionAt(monster, its own reported serverNowMs), not some
// other value — a single read, cross-checked against the real shared formula at the server's own
// reported timestamp, is already a fully deterministic proof of that (no sleep, no real-time race:
// whatever serverNowMs the server happens to report, the cross-check either matches or it doesn't).
test('P4-03A-E: snapshot\'s worldMonsters position is server-computed via patrolPositionAt at the snapshot\'s own reported serverNowMs',async()=>{
  const snap=await request('/api/character/char-demo/snapshot');
  assert.ok(Number.isFinite(snap.serverNowMs));
  const m=snap.worldMonsters.find(m=>m.id==='world-bandit-1');
  assert.ok(m,'expected world-bandit-1 to still be available');
  assert.deepEqual(m.position,patrolPositionAt(monster,snap.serverNowMs),'snapshot\'s reported monster position must exactly equal the shared formula evaluated at the snapshot\'s own reported serverNowMs');
});

// P4-03A-M through P — P4-03A Merge Gate fix "Account for Snapshot Transit Time". The original
// computeServerTimeOffset(serverNowMs,clientNowMs) compared serverNowMs (captured on the SERVER
// before the response travelled back) against the client's RECEIPT time — silently attributing the
// entire one-way response transit time to "clock skew". At this monster's patrol speed
// (0.02px/ms), a 2000ms response delay alone would already read back as ~40px of spurious visual
// lag — the full encounterRadius. Fixed by bracketing the snapshot request with
// requestStartedAt/responseReceivedAt and using their MIDPOINT (the standard symmetric-latency
// approximation) as the client instant serverNowMs corresponds to, instead of the raw receipt time.

// P4-03A-M: zero latency. request start === response receive (no transit time at all) — the
// midpoint collapses to that single instant, and the offset must still reconstruct serverNowMs
// exactly.
test('P4-03A-M: zero latency — offset reconstructs serverNowMs exactly when request start equals response receipt',()=>{
  const requestStartedAt=1000,responseReceivedAt=1000,serverNowMs=5000;
  const offset=computeServerTimeOffset(serverNowMs,requestStartedAt,responseReceivedAt);
  assert.equal(requestStartedAt+offset,serverNowMs);
});

// P4-03A-N: symmetric RTT. Proves the helper uses the request's MIDPOINT, not the raw response
// receipt time directly — the exact defect the Merge Gate fix closes. RTT=2000ms, midpoint=2000;
// serverNowMs corresponds to that midpoint (8000), so offset must be 6000 (midpoint+offset=8000).
// The OLD (receipt-time) method would have computed serverNowMs-responseReceivedAt=8000-3000=5000 —
// wrong by exactly half the RTT (1000ms). This test explicitly asserts the new result is NOT that
// old, wrong value.
test('P4-03A-N: symmetric RTT — offset uses the request midpoint, not raw response receipt time',()=>{
  const requestStartedAt=1000,responseReceivedAt=3000,serverNowMs=8000;
  const offset=computeServerTimeOffset(serverNowMs,requestStartedAt,responseReceivedAt);
  const midpointClientTime=requestStartedAt+(responseReceivedAt-requestStartedAt)/2;
  assert.equal(offset,6000);
  assert.equal(midpointClientTime+offset,serverNowMs);
  const oldWrongOffset=serverNowMs-responseReceivedAt;
  assert.equal(oldWrongOffset,5000);
  assert.notEqual(offset,oldWrongOffset,'the new offset must NOT match the old (wrong) receipt-time-based calculation');
});

// P4-03A-O: clock skew + latency together. Simulates a device clock hours ahead of the server
// (requestStartedAt/responseReceivedAt drawn from a wildly skewed client clock domain) combined with
// non-zero RTT, and asserts the midpoint+offset still reconstructs serverNowMs exactly — proving
// device clock skew and network latency are both handled by the same single calculation.
test('P4-03A-O: clock skew combined with non-zero RTT — midpoint plus offset still reconstructs the exact server time',()=>{
  for(const [skewMs,rttMs] of [[6*60*60*1000,400],[-6*60*60*1000,1200],[10*24*60*60*1000,50],[0,2000]]){
    const skewedNow=Date.now()+skewMs;
    const requestStartedAt=skewedNow,responseReceivedAt=skewedNow+rttMs,serverNowMs=Date.now()+1234;
    const offset=computeServerTimeOffset(serverNowMs,requestStartedAt,responseReceivedAt);
    const midpointClientTime=requestStartedAt+(responseReceivedAt-requestStartedAt)/2;
    assert.equal(midpointClientTime+offset,serverNowMs,`skew=${skewMs}ms rtt=${rttMs}ms: midpoint+offset must reconstruct serverNowMs exactly`);
  }
});

// P4-03A-P: refresh() production wiring. Confirms the REAL refresh() — not just the pure helper in
// isolation — actually captures requestStartedAt before sending the snapshot request, captures
// responseReceivedAt after it resolves, and passes both (in that order) into
// computeServerTimeOffset(), rather than leaving production wired to the old, wrong single-timestamp
// call.
test('P4-03A-P: refresh() captures request start before and response receipt after the snapshot call, and passes both into computeServerTimeOffset',()=>{
  const appSource=readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
  const refreshStart=appSource.indexOf('async function refresh(){');
  assert.ok(refreshStart>=0,'refresh() must exist in public/app.js');
  const nextFunctionStart=appSource.indexOf('\nfunction setBattle(',refreshStart);
  assert.ok(nextFunctionStart>refreshStart,'expected to find the next top-level function after refresh() to bound its body');
  const refreshBody=appSource.slice(refreshStart,nextFunctionStart);
  const requestStartedIndex=refreshBody.indexOf('const requestStartedAt=Date.now();');
  const snapshotCallIndex=refreshBody.indexOf("S.snap=await req('/api/character/char-demo/snapshot');");
  const responseReceivedIndex=refreshBody.indexOf('const responseReceivedAt=Date.now();');
  const offsetCallIndex=refreshBody.indexOf('serverTimeOffset=computeServerTimeOffset(S.snap.serverNowMs,requestStartedAt,responseReceivedAt);');
  assert.ok(requestStartedIndex>=0,'refresh() must capture requestStartedAt=Date.now()');
  assert.ok(snapshotCallIndex>=0,'refresh() must still call the snapshot endpoint');
  assert.ok(responseReceivedIndex>=0,'refresh() must capture responseReceivedAt=Date.now()');
  assert.ok(offsetCallIndex>=0,'refresh() must pass requestStartedAt and responseReceivedAt into computeServerTimeOffset');
  assert.ok(requestStartedIndex<snapshotCallIndex,'requestStartedAt must be captured BEFORE the snapshot request is sent');
  assert.ok(snapshotCallIndex<responseReceivedIndex,'responseReceivedAt must be captured AFTER the snapshot request resolves');
  assert.ok(responseReceivedIndex<offsetCallIndex,'computeServerTimeOffset must be called after both timestamps are captured');
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
