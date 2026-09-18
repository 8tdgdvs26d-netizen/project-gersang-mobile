import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {OBSTACLES,PLAYER_COLLISION_RADIUS,inflateRect,pointInRect} from '../public/worldgeometry.js';

// P1-06 (test-only, no production code change): proves the already-approved persistence
// contract established by P1-01/P1-02/P1-04 — accepted non-zero moves persist, zero-displacement
// moves (throttled/collision/same-position) make literally no extra DB write, and position/state
// survive both an in-process reload and a genuine OS-level server restart against the same DB file.

let child,base,dir,sessionId;
const request=async(path,options={})=>{const r=await fetch(base+path,{headers:{'content-type':'application/json'},...options});return r.json()};
const post=(path,body)=>request(path,{method:'POST',body:JSON.stringify(body)});
const envelope=(key,payload)=>({commandId:crypto.randomUUID(),idempotencyKey:key,sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const setPosition=(x,y,state)=>{const fixture=new DatabaseSync(join(dir,'test.sqlite'));fixture.prepare(`UPDATE characters SET world_x=?,world_y=?,state=? WHERE id='char-demo'`).run(x,y,state);fixture.close()};
const readCharacterRow=()=>{const fixture=new DatabaseSync(join(dir,'test.sqlite'));const row=fixture.prepare(`SELECT world_x,world_y,state FROM characters WHERE id='char-demo'`).get();fixture.close();return row};

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-world-persistence-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:join(dir,'test.sqlite')},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`))) });
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

test('IN_WORLD position survives a fresh, independent snapshot re-fetch (self-contained reload simulation, not relying on other tests\' leftover state)',async()=>{
  setPosition(333,444,'IN_WORLD');
  const first=await request('/api/character/char-demo/snapshot');
  assert.equal(first.state,'IN_WORLD');
  assert.deepEqual(first.worldPosition,{x:333,y:444});
  const second=await request('/api/character/char-demo/snapshot');
  assert.deepEqual(second.worldPosition,first.worldPosition);
  assert.equal(second.state,first.state);
});

test('throttle: the first move is accepted and establishes lastWorldMoveAt, the immediate second move is genuinely throttled, and a direct DB read proves the second command made literally zero additional write',async()=>{
  setPosition(50,50,'IN_WORLD');
  await wait(150);
  const first=await post('/api/commands/world/move',envelope('persist-throttle-first',{targetX:90,targetY:50}));
  assert.equal(first.status,'ACCEPTED');
  assert.equal(first.data.throttled,false);
  assert.deepEqual(first.data.worldPosition,{x:90,y:50});
  const rowAfterFirst=readCharacterRow();
  assert.equal(rowAfterFirst.world_x,90);
  assert.equal(rowAfterFirst.world_y,50);
  assert.equal(rowAfterFirst.state,'IN_WORLD');
  const second=await post('/api/commands/world/move',envelope('persist-throttle-second',{targetX:900,targetY:900}));
  assert.equal(second.status,'ACCEPTED');
  assert.equal(second.data.throttled,true);
  assert.deepEqual(second.data.worldPosition,{x:90,y:50});
  const rowAfterSecond=readCharacterRow();
  assert.deepEqual(rowAfterSecond,rowAfterFirst,'the throttled command must not have changed the characters row at all');
});

test('collision: a blocked move is ACCEPTED with collided:true, and a direct DB read proves it made literally zero additional write',async()=>{
  const ridgeA=OBSTACLES.find(o=>o.id==='ridge-a'),inflatedA=inflateRect(ridgeA,PLAYER_COLLISION_RADIUS);
  const centerA={x:(inflatedA.minX+inflatedA.maxX)/2,y:(inflatedA.minY+inflatedA.maxY)/2};
  const start={x:inflatedA.minX-30,y:centerA.y};
  assert.equal(pointInRect(start.x,start.y,inflatedA),false,'test setup: start must be outside the obstacle');
  assert.equal(pointInRect(centerA.x,centerA.y,inflatedA),true,'test setup: target must land inside the obstacle');
  setPosition(start.x,start.y,'IN_WORLD');
  await wait(150);
  const rowBefore=readCharacterRow();
  const blocked=await post('/api/commands/world/move',envelope('persist-collision',{targetX:centerA.x,targetY:centerA.y}));
  assert.equal(blocked.status,'ACCEPTED');
  assert.equal(blocked.data.collided,true);
  assert.deepEqual(blocked.data.worldPosition,start);
  const rowAfter=readCharacterRow();
  assert.deepEqual(rowAfter,rowBefore,'a collision-blocked command must not have changed the characters row at all');
});

test('same-position: a move whose target equals the current position is ACCEPTED with collided:false, and a direct DB read proves it made literally zero additional write',async()=>{
  setPosition(60,60,'IN_WORLD');
  await wait(150);
  const rowBefore=readCharacterRow();
  const moved=await post('/api/commands/world/move',envelope('persist-same-position',{targetX:60,targetY:60}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.collided,false);
  assert.deepEqual(moved.data.worldPosition,{x:60,y:60});
  const rowAfter=readCharacterRow();
  assert.deepEqual(rowAfter,rowBefore,'a same-position command must not have changed the characters row at all');
});

test('Travel arrival keeps cityId/state/worldPosition consistent across an additional, independent fresh snapshot fetched after arrival (reload-after-arrival simulation)',async()=>{
  const cities=await request('/api/cities');
  const before=await request('/api/character/char-demo/snapshot');
  const destination=cities.find(c=>c.id!==before.cityId);
  const fixtureCity=new DatabaseSync(join(dir,'test.sqlite'));
  fixtureCity.prepare(`UPDATE characters SET state='IN_CITY' WHERE id='char-demo'`).run();
  fixtureCity.close();
  const started=await post('/api/commands/travel/start',envelope('persist-travel-start',{destinationCityId:destination.id}));
  assert.equal(started.status,'ACCEPTED');
  const fixtureEta=new DatabaseSync(join(dir,'test.sqlite'));
  fixtureEta.prepare(`UPDATE travel SET eta=? WHERE character_id='char-demo'`).run(Date.now()-1);
  fixtureEta.close();
  const arrived=await post('/api/commands/travel/resolve-arrival',envelope('persist-travel-arrive',{}));
  assert.equal(arrived.status,'ACCEPTED');
  assert.equal(arrived.data.cityId,destination.id);
  const reloaded=await request('/api/character/char-demo/snapshot');
  assert.equal(reloaded.cityId,destination.id);
  assert.equal(reloaded.state,'IN_CITY');
  assert.deepEqual(reloaded.worldPosition,destination.coordinates);
});

// Real OS-level process restart, isolated from the shared child/DB above: its own temp dir,
// its own two independently spawned+killed server.mjs child processes against the SAME DB file.
//
// Node only sets child.exitCode for a normal exit; a signal-killed process (our case, since we
// use child.kill()/SIGTERM) reports via child.signalCode instead and exitCode stays null forever.
// So exit tracking must not rely on exitCode/signalCode at all — attach a one-time 'exit' listener
// right at spawn time and track completion with a plain flag, so killAndWaitForRealExit is safe to
// call more than once (including defensively from a finally block) without ever waiting on an
// 'exit' event that already fired before a later listener was attached.
async function spawnServer(dbPath){
  const restartChild=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:dbPath},stdio:['ignore','pipe','inherit']});
  restartChild.hasExited=false;
  restartChild.once('exit',()=>{restartChild.hasExited=true});
  const line=await new Promise((resolve,reject)=>{restartChild.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});restartChild.on('exit',code=>reject(new Error(`server exited ${code}`)))});
  return {child:restartChild,base:`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`};
}
async function killAndWaitForRealExit(proc){
  if(proc.hasExited)return;
  const exited=new Promise(resolve=>proc.once('exit',resolve));
  proc.kill();
  await exited;
}

test('a genuine OS-level process restart (kill child A, wait for its real exit, spawn child B against the exact same DB file) preserves the accepted worldPosition and IN_WORLD state',async()=>{
  const restartDir=await mkdtemp(join(tmpdir(),'myrial-world-restart-'));
  const dbPath=join(restartDir,'test.sqlite');
  let serverA,serverB;
  try{
    serverA=await spawnServer(dbPath);
    const reqA=(path,options={})=>fetch(serverA.base+path,{headers:{'content-type':'application/json'},...options}).then(r=>r.json());
    const postA=(path,body)=>reqA(path,{method:'POST',body:JSON.stringify(body)});
    const sessionIdA=(await postA('/api/session/open',{accountId:'account-demo'})).sessionId;
    const before=await reqA('/api/character/char-demo/snapshot');
    const moved=await postA('/api/commands/world/move',{commandId:crypto.randomUUID(),idempotencyKey:'restart-legal-move',sessionId:sessionIdA,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload:{targetX:before.worldPosition.x+40,targetY:before.worldPosition.y}});
    assert.equal(moved.status,'ACCEPTED');
    assert.equal(moved.data.collided,false);
    assert.equal(moved.data.state,'IN_WORLD');
    const expectedPosition=moved.data.worldPosition;

    await killAndWaitForRealExit(serverA.child);
    assert.equal(serverA.child.hasExited,true,'child A must have genuinely exited before child B starts against the same DB file');

    serverB=await spawnServer(dbPath);
    const reqB=(path,options={})=>fetch(serverB.base+path,{headers:{'content-type':'application/json'},...options}).then(r=>r.json());
    const postB=(path,body)=>reqB(path,{method:'POST',body:JSON.stringify(body)});
    const sessionIdB=(await postB('/api/session/open',{accountId:'account-demo'})).sessionId;
    assert.notEqual(sessionIdB,sessionIdA,'restart must go through a genuinely fresh session, not reuse the pre-restart one');
    const after=await reqB('/api/character/char-demo/snapshot');
    assert.deepEqual(after.worldPosition,expectedPosition);
    assert.equal(after.state,'IN_WORLD');
  }finally{
    if(serverA)await killAndWaitForRealExit(serverA.child);
    if(serverB)await killAndWaitForRealExit(serverB.child);
    await rm(restartDir,{recursive:true,force:true});
  }
});
