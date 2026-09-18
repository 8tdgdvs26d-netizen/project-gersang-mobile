import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {OBSTACLES,PLAYER_COLLISION_RADIUS,inflateRect,pointInRect} from '../public/worldgeometry.js';

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
  await wait(150);
  const moved=await post('/api/commands/world/move',envelope('roads-road-to-offroad',{targetX:400,targetY:50}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.collided,false);
  // dy=-100 exceeds MAX_WORLD_STEP=60, so the accepted candidate is clamped to (400,90), not (400,50).
  assert.deepEqual(moved.data.worldPosition,{x:400,y:90});
});

test('off-road -> off-road: a legal move between two points that are nowhere near any road works exactly like any other free move',async()=>{
  setPosition(50,50,'IN_WORLD');
  await wait(150);
  const moved=await post('/api/commands/world/move',envelope('roads-offroad-to-offroad',{targetX:90,targetY:50}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.collided,false);
  assert.deepEqual(moved.data.worldPosition,{x:90,y:50});
});

test('cross-road: a move whose clamped path crosses the ac road (y=150) partway through is accepted exactly like any other move, with no road-crossing side effect',async()=>{
  setPosition(400,100,'IN_WORLD');
  await wait(150);
  // dy=100 exceeds MAX_WORLD_STEP=60, so the server does not reach the requested target(400,200)
  // in one command; the accepted candidate is clamped to (400,160) — which is still past y=150,
  // so this single move does cross the road, just not all the way to the requested target.
  const moved=await post('/api/commands/world/move',envelope('roads-cross-road',{targetX:400,targetY:200}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.collided,false);
  assert.deepEqual(moved.data.worldPosition,{x:400,y:160});
  assert.ok(100<150&&150<160,'sanity: the road at y=150 must actually lie between the start and clamped end y-coordinates');
});

test('landing exactly on a road never triggers collision by itself',async()=>{
  setPosition(390,150,'IN_WORLD');
  await wait(150);
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
  await wait(150);
  const blocked=await post('/api/commands/world/move',envelope('roads-obstacle-still-blocks',{targetX:centerA.x,targetY:centerA.y}));
  assert.equal(blocked.status,'ACCEPTED');
  assert.equal(blocked.data.collided,true);
  assert.deepEqual(blocked.data.worldPosition,start);
});

test('MAX_WORLD_STEP movement clamp still applies normally right next to a road, unaffected by the road (a large target far past WORLD_BOUNDS only produces one normal 60-unit step, nowhere near the actual boundary — genuine WORLD_BOUNDS edge-clamp coverage lives in test/world-movement.test.mjs and test/world-collision.test.mjs)',async()=>{
  setPosition(230,150,'IN_WORLD');
  await wait(150);
  const moved=await post('/api/commands/world/move',envelope('roads-step-clamp-near-road',{targetX:-9999,targetY:150}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.collided,false);
  // dx=-10229 far exceeds MAX_WORLD_STEP=60, so the accepted candidate is clamped to exactly one
  // 60-unit step (230-60=170), same as it would be anywhere else off-road — this is the ordinary
  // MAX_WORLD_STEP clamp, not the WORLD_BOUNDS edge clamp (170 is nowhere near the 0..1000 edge).
  assert.deepEqual(moved.data.worldPosition,{x:170,y:150});
});
