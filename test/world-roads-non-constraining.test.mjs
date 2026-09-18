import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {OBSTACLES,PLAYER_COLLISION_RADIUS,inflateRect,pointInRect} from '../public/worldgeometry.js';
import {MOVE_SPEED_RATE,MOVE_CATCHUP_CAP_MS} from '../public/movement.js';

// P1-05 (test-only, no functional code change): "roads exist, but a road is not a track."
// The 'ac' road connects starter-village{220,150} and hill-market{780,150} — since both
// endpoints share y:150, the whole road is the line y=150, 220<=x<=780. x=400 sits on that
// line, far away from both P1-04 obstacles (ridge-a/ridge-b both start at y>=386), so it's a
// safe, deterministic point to test on-road / off-road / crossing without any obstacle overlap.
let child,base,dir,sessionId;
const request=async(path,options={})=>{const r=await fetch(base+path,{headers:{'content-type':'application/json'},...options});return r.json()};
const post=(path,body)=>request(path,{method:'POST',body:JSON.stringify(body)});
const envelope=(key,payload)=>({commandId:crypto.randomUUID(),idempotencyKey:key,sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const setPosition=(x,y,state)=>{const fixture=new DatabaseSync(join(dir,'test.sqlite'));fixture.prepare(`UPDATE characters SET world_x=?,world_y=?,state=? WHERE id='char-demo'`).run(x,y,state);fixture.close()};

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-world-roads-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:join(dir,'test.sqlite')},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`))) });
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

test('test setup sanity: the chosen road-crossing region (x=400 on the ac road, y around 90-200) does not overlap any P1-04 obstacle',async()=>{
  const inflated=OBSTACLES.map(o=>inflateRect(o,PLAYER_COLLISION_RADIUS));
  for(const point of [{x:400,y:150},{x:400,y:90},{x:400,y:100},{x:400,y:160},{x:390,y:150},{x:410,y:150}]){
    for(const rect of inflated){
      assert.equal(pointInRect(point.x,point.y,rect),false,`point (${point.x},${point.y}) must be outside obstacle ${rect.id} for this test region to be obstacle-free`);
    }
  }
});

test('GET /api/roads confirms the ac road runs from starter-village{220,150} to hill-market{780,150} (both endpoints share y:150), so x=400,y=150 sits exactly on it',async()=>{
  const roads=await request('/api/roads');
  const ac=roads.find(r=>r.id==='ac');
  const cities=await request('/api/cities');
  const from=cities.find(c=>c.id===ac.fromCityId),to=cities.find(c=>c.id===ac.toCityId);
  assert.equal(from.coordinates.y,150);
  assert.equal(to.coordinates.y,150);
  assert.ok(from.coordinates.x<=400&&400<=to.coordinates.x,'x=400 must fall within the ac road\'s x range');
});

test('road -> off-road: a legal move starting exactly on the ac road ends off-road with no special handling',async()=>{
  setPosition(400,150,'IN_WORLD');
  // P1-07D: wait comfortably past MOVE_CATCHUP_CAP_MS so the elapsed-time allowance is not the
  // limiting factor — this test is about roads having no special handling, not about the allowance
  // mechanics themselves (see the dedicated clamp test below for that).
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const moved=await post('/api/commands/world/move',envelope('roads-road-to-offroad',{targetX:400,targetY:50}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.collided,false);
  // dy=-100 is within the full elapsed-time allowance after the wait above, so the accepted
  // candidate reaches the requested target exactly.
  assert.deepEqual(moved.data.worldPosition,{x:400,y:50});
});

test('off-road -> off-road: a legal move between two points that are nowhere near any road works exactly like any other free move',async()=>{
  setPosition(50,50,'IN_WORLD');
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const moved=await post('/api/commands/world/move',envelope('roads-offroad-to-offroad',{targetX:90,targetY:50}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.collided,false);
  assert.deepEqual(moved.data.worldPosition,{x:90,y:50});
});

test('cross-road: a move whose path crosses the ac road (y=150) partway through is accepted exactly like any other move, with no road-crossing side effect',async()=>{
  setPosition(400,100,'IN_WORLD');
  await wait(MOVE_CATCHUP_CAP_MS+100);
  // dy=100 is within the full elapsed-time allowance after the wait above, so the accepted
  // candidate reaches the requested target(400,200) exactly — which is past y=150, so this single
  // move does cross the road.
  const moved=await post('/api/commands/world/move',envelope('roads-cross-road',{targetX:400,targetY:200}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.collided,false);
  assert.deepEqual(moved.data.worldPosition,{x:400,y:200});
  assert.ok(100<150&&150<200,'sanity: the road at y=150 must actually lie between the start and end y-coordinates');
});

test('landing exactly on a road never triggers collision by itself',async()=>{
  setPosition(390,150,'IN_WORLD');
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const moved=await post('/api/commands/world/move',envelope('roads-on-road-no-collision',{targetX:410,targetY:150}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.collided,false);
  assert.deepEqual(moved.data.worldPosition,{x:410,y:150});
});

test('P1-04 obstacle collision continues to work unmodified: moving into an inflated obstacle is still blocked',async()=>{
  const ridgeA=OBSTACLES.find(o=>o.id==='ridge-a'),inflatedA=inflateRect(ridgeA,PLAYER_COLLISION_RADIUS);
  const centerA={x:(inflatedA.minX+inflatedA.maxX)/2,y:(inflatedA.minY+inflatedA.maxY)/2};
  const start={x:inflatedA.minX-30,y:centerA.y};
  assert.equal(pointInRect(start.x,start.y,inflatedA),false,'test setup: start point must be outside the obstacle');
  assert.equal(pointInRect(centerA.x,centerA.y,inflatedA),true,'test setup: target point must land inside the obstacle');
  setPosition(start.x,start.y,'IN_WORLD');
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const blocked=await post('/api/commands/world/move',envelope('roads-obstacle-still-blocks',{targetX:centerA.x,targetY:centerA.y}));
  assert.equal(blocked.status,'ACCEPTED');
  assert.equal(blocked.data.collided,true);
  assert.deepEqual(blocked.data.worldPosition,start);
});

// P1-07D — Latency-Decoupled Movement (Issue #23). Replaces the old flat MAX_WORLD_STEP=60 clamp
// assertion: a single command's displacement is now bounded by
// MOVE_SPEED_RATE * min(elapsedSinceLastNonThrottledAttempt, MOVE_CATCHUP_CAP_MS). Waiting well past
// MOVE_CATCHUP_CAP_MS makes the allowance deterministic (the min() saturates at the cap regardless
// of exactly how much longer the wait actually took in practice), so the exact clamped position can
// still be asserted precisely — same intent as the old test (a large target far past WORLD_BOUNDS
// only produces one normal, bounded step, unaffected by being right next to a road; genuine
// WORLD_BOUNDS edge-clamp coverage lives in test/world-movement.test.mjs and
// test/world-collision.test.mjs), just expressed against the new elapsed-time-scaled ceiling
// instead of a flat constant.
test('the elapsed-time movement allowance clamp still applies normally right next to a road, unaffected by the road',async()=>{
  setPosition(230,150,'IN_WORLD');
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const moved=await post('/api/commands/world/move',envelope('roads-step-clamp-near-road',{targetX:-9999,targetY:150}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.collided,false);
  // dx=-10229 far exceeds the allowance, so the accepted candidate is clamped to exactly one
  // MOVE_SPEED_RATE*MOVE_CATCHUP_CAP_MS-sized step, same as it would be anywhere else off-road —
  // this is the ordinary elapsed-time allowance clamp, not the WORLD_BOUNDS edge clamp (the result
  // is nowhere near the 0..1000 edge).
  const maxStep=MOVE_SPEED_RATE*MOVE_CATCHUP_CAP_MS;
  assert.equal(moved.data.worldPosition.y,150);
  assert.ok(Math.abs(moved.data.worldPosition.x-(230-maxStep))<0.01,`expected x clamped to ${230-maxStep}, got ${moved.data.worldPosition.x}`);
});
