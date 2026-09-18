import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {OBSTACLES,PLAYER_COLLISION_RADIUS,inflateRect,pointInRect} from '../public/worldgeometry.js';
import {MOVE_SPEED_RATE,MOVE_CATCHUP_CAP_MS} from '../public/movement.js';

let child,base,dir,sessionId;
const request=async(path,options={})=>{const r=await fetch(base+path,{headers:{'content-type':'application/json'},...options});return r.json()};
const post=(path,body)=>request(path,{method:'POST',body:JSON.stringify(body)});
const envelope=(key,payload)=>({commandId:crypto.randomUUID(),idempotencyKey:key,sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const setPosition=(x,y,state)=>{const fixture=new DatabaseSync(join(dir,'test.sqlite'));fixture.prepare(`UPDATE characters SET world_x=?,world_y=?,state=? WHERE id='char-demo'`).run(x,y,state);fixture.close()};

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-world-collision-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:join(dir,'test.sqlite')},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`))) });
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

test('every city coordinate and the spawn point sit outside every inflated obstacle',async()=>{
  const inflated=OBSTACLES.map(o=>inflateRect(o,PLAYER_COLLISION_RADIUS));
  const cities=await request('/api/cities');
  const spawn=await request('/api/character/char-demo/snapshot');
  for(const point of [...cities.map(c=>c.coordinates),spawn.worldPosition]){
    for(const rect of inflated){
      assert.equal(pointInRect(point.x,point.y,rect),false,`point (${point.x},${point.y}) must be outside obstacle ${rect.id}`);
    }
  }
});

const ridgeA=OBSTACLES.find(o=>o.id==='ridge-a'),inflatedA=inflateRect(ridgeA,PLAYER_COLLISION_RADIUS);
const centerA={x:(inflatedA.minX+inflatedA.maxX)/2,y:(inflatedA.minY+inflatedA.maxY)/2};

test('a swept move whose (unclamped) endpoint lands inside an inflated obstacle is blocked: position unchanged, collided:true, and IN_CITY does not flip to IN_WORLD',async()=>{
  const start={x:inflatedA.minX-30,y:centerA.y};
  assert.equal(pointInRect(start.x,start.y,inflatedA),false,'test setup: start point must be outside the obstacle');
  assert.equal(pointInRect(centerA.x,centerA.y,inflatedA),true,'test setup: target point must land inside the obstacle');
  assert.ok(Math.hypot(centerA.x-start.x,centerA.y-start.y)<=60,'test setup: target must be reachable in one unclamped step');
  setPosition(start.x,start.y,'IN_CITY');
  await wait(150);
  const moved=await post('/api/commands/world/move',envelope('collision-endpoint-inside',{targetX:centerA.x,targetY:centerA.y}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.collided,true);
  assert.equal(moved.data.throttled,false);
  assert.deepEqual(moved.data.worldPosition,start);
  assert.equal(moved.data.state,'IN_CITY');
  const snap=await request('/api/character/char-demo/snapshot');
  assert.equal(snap.state,'IN_CITY');
  assert.deepEqual(snap.worldPosition,start);
});

test('a swept move whose start and end points are both outside a thin obstacle, but whose clamped path crosses it, is still blocked (thin-wall / endpoint-only-would-miss case)',async()=>{
  const start={x:inflatedA.minX-6,y:centerA.y};
  const boundedEnd={x:start.x+60,y:start.y};
  assert.equal(pointInRect(start.x,start.y,inflatedA),false,'test setup: start point must be outside the obstacle');
  assert.equal(pointInRect(boundedEnd.x,boundedEnd.y,inflatedA),false,'test setup: the clamped bounded endpoint must itself be outside the obstacle, proving this is a genuine both-endpoints-outside crossing');
  setPosition(start.x,start.y,'IN_WORLD');
  await wait(150);
  const moved=await post('/api/commands/world/move',envelope('collision-thin-wall',{targetX:start.x+500,targetY:start.y}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.collided,true);
  assert.deepEqual(moved.data.worldPosition,start);
});

test('a collision-blocked move consumes the normal movement interval like any other move (an immediate follow-up is throttled), but there is no permanent lock-out: a legal move after the normal interval still succeeds',async()=>{
  const start={x:inflatedA.minX-30,y:centerA.y};
  setPosition(start.x,start.y,'IN_WORLD');
  // P1-07D: wait comfortably past MOVE_CATCHUP_CAP_MS so the elapsed-time allowance is not the
  // limiting factor for the collision-entry distance this test needs (this test is about
  // throttle/lock-out semantics, not about the allowance mechanics themselves).
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const blocked=await post('/api/commands/world/move',envelope('collision-then-legal-a',{targetX:centerA.x,targetY:centerA.y}));
  assert.equal(blocked.data.collided,true);
  assert.equal(blocked.data.throttled,false);
  const immediateFollowUp=await post('/api/commands/world/move',envelope('collision-then-legal-immediate',{targetX:start.x,targetY:start.y-60}));
  assert.equal(immediateFollowUp.data.throttled,true,'a collision-blocked move must still consume the normal MOVEMENT_MIN_INTERVAL_MS window, same as any other move');
  assert.deepEqual(immediateFollowUp.data.worldPosition,start);
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const legalTarget={x:start.x,y:start.y-60};
  const legal=await post('/api/commands/world/move',envelope('collision-then-legal-b',{targetX:legalTarget.x,targetY:legalTarget.y}));
  assert.equal(legal.status,'ACCEPTED');
  assert.equal(legal.data.collided,false);
  assert.deepEqual(legal.data.worldPosition,legalTarget);
});

test('a genuinely legal (non-zero, uncollided) move from IN_CITY transitions to IN_WORLD',async()=>{
  setPosition(50,50,'IN_CITY');
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const moved=await post('/api/commands/world/move',envelope('collision-legal-transition',{targetX:90,targetY:50}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.collided,false);
  assert.equal(moved.data.state,'IN_WORLD');
  assert.deepEqual(moved.data.worldPosition,{x:90,y:50});
});

test('a throttled (zero-displacement) move does not transition IN_CITY to IN_WORLD',async()=>{
  setPosition(50,50,'IN_CITY');
  await wait(150);
  const first=await post('/api/commands/world/move',envelope('collision-throttle-a',{targetX:50,targetY:50}));
  assert.equal(first.status,'ACCEPTED');
  assert.equal(first.data.state,'IN_CITY');
  const second=await post('/api/commands/world/move',envelope('collision-throttle-b',{targetX:400,targetY:400}));
  assert.equal(second.status,'ACCEPTED');
  assert.equal(second.data.throttled,true);
  assert.equal(second.data.state,'IN_CITY');
  assert.deepEqual(second.data.worldPosition,{x:50,y:50});
});

test('legacy compatibility: a persisted position already inside an inflated obstacle (pre-dating the obstacle) can escape outward',async()=>{
  const ridgeB=OBSTACLES.find(o=>o.id==='ridge-b'),inflatedB=inflateRect(ridgeB,PLAYER_COLLISION_RADIUS);
  const center={x:(inflatedB.minX+inflatedB.maxX)/2,y:(inflatedB.minY+inflatedB.maxY)/2};
  assert.equal(pointInRect(center.x,center.y,inflatedB),true,'test setup: legacy position must start inside the obstacle');
  setPosition(center.x,center.y,'IN_CITY');
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const escaped=await post('/api/commands/world/move',envelope('collision-legacy-escape',{targetX:center.x,targetY:center.y-135}));
  assert.equal(escaped.status,'ACCEPTED');
  assert.equal(escaped.data.collided,false);
  assert.equal(escaped.data.state,'IN_WORLD');
  assert.equal(pointInRect(escaped.data.worldPosition.x,escaped.data.worldPosition.y,inflatedB),false,'escaped position must now be outside the obstacle');
});

test('legacy compatibility: while still inside the obstacle, a move whose candidate stays inside the same obstacle is blocked — escape-only means the candidate must actually land outside, not just "started inside so anything goes"',async()=>{
  const ridgeB=OBSTACLES.find(o=>o.id==='ridge-b'),inflatedB=inflateRect(ridgeB,PLAYER_COLLISION_RADIUS);
  const center={x:(inflatedB.minX+inflatedB.maxX)/2,y:(inflatedB.minY+inflatedB.maxY)/2};
  const stillInside={x:center.x+15,y:center.y};
  assert.equal(pointInRect(center.x,center.y,inflatedB),true,'test setup: legacy position must start inside the obstacle');
  assert.equal(pointInRect(stillInside.x,stillInside.y,inflatedB),true,'test setup: candidate must still land inside the same obstacle');
  setPosition(center.x,center.y,'IN_CITY');
  await wait(150);
  const blocked=await post('/api/commands/world/move',envelope('collision-legacy-still-inside',{targetX:stillInside.x,targetY:stillInside.y}));
  assert.equal(blocked.status,'ACCEPTED');
  assert.equal(blocked.data.collided,true);
  assert.equal(blocked.data.state,'IN_CITY');
  assert.deepEqual(blocked.data.worldPosition,center);
});

test('legacy compatibility: once escaped, re-entering the same obstacle from outside is blocked again',async()=>{
  const ridgeB=OBSTACLES.find(o=>o.id==='ridge-b'),inflatedB=inflateRect(ridgeB,PLAYER_COLLISION_RADIUS);
  const center={x:(inflatedB.minX+inflatedB.maxX)/2,y:(inflatedB.minY+inflatedB.maxY)/2};
  const outside={x:center.x,y:inflatedB.minY-10};
  assert.equal(pointInRect(outside.x,outside.y,inflatedB),false,'test setup: start point must be outside the obstacle');
  setPosition(outside.x,outside.y,'IN_WORLD');
  await wait(150);
  const blocked=await post('/api/commands/world/move',envelope('collision-legacy-reentry',{targetX:center.x,targetY:center.y+150}));
  assert.equal(blocked.status,'ACCEPTED');
  assert.equal(blocked.data.collided,true);
  assert.deepEqual(blocked.data.worldPosition,outside);
});

test('P1-07D: a much longer swept segment (enabled by the elapsed-time allowance, well beyond the old flat MAX_WORLD_STEP=60 scale) is still correctly blocked by segmentBlocked — the swept-segment check was always designed for arbitrary-length segments, and the allowance change does not weaken it',async()=>{
  const start={x:inflatedA.minX-100,y:centerA.y}; // ~124px from centerA — beyond the old 60px cap,
                                                    // within the new elapsed-time allowance
  const requestedDistance=Math.hypot(centerA.x-start.x,centerA.y-start.y);
  assert.ok(requestedDistance>60,`test setup: requested distance ${requestedDistance} must exceed the old flat cap to prove this is a genuinely longer segment`);
  assert.ok(requestedDistance<MOVE_SPEED_RATE*MOVE_CATCHUP_CAP_MS,`test setup: requested distance ${requestedDistance} must be reachable within a single command's allowance`);
  assert.equal(pointInRect(start.x,start.y,inflatedA),false,'test setup: start point must be outside the obstacle');
  assert.equal(pointInRect(centerA.x,centerA.y,inflatedA),true,'test setup: target point must land inside the obstacle');
  setPosition(start.x,start.y,'IN_WORLD');
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const blocked=await post('/api/commands/world/move',envelope('collision-long-segment',{targetX:centerA.x,targetY:centerA.y}));
  assert.equal(blocked.status,'ACCEPTED');
  assert.equal(blocked.data.collided,true);
  assert.deepEqual(blocked.data.worldPosition,start);
});

test('world/bounds clamp continues to work correctly alongside the new obstacle collision check',async()=>{
  setPosition(5,5,'IN_WORLD');
  await wait(150);
  const moved=await post('/api/commands/world/move',envelope('collision-bounds-still-work',{targetX:-9999,targetY:-9999}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.collided,false);
  assert.deepEqual(moved.data.worldPosition,{x:0,y:0});
});
