import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';

let child,base,dir,sessionId;
const request=async(path,options={})=>{const r=await fetch(base+path,{headers:{'content-type':'application/json'},...options});return r.json()};
const post=(path,body)=>request(path,{method:'POST',body:JSON.stringify(body)});
const envelope=(key,payload)=>({commandId:crypto.randomUUID(),idempotencyKey:key,sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-world-movement-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:join(dir,'test.sqlite')},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`))) });
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

test('a legal move is accepted, transitions IN_CITY to IN_WORLD, and updates worldPosition',async()=>{
  const before=await request('/api/character/char-demo/snapshot');
  assert.equal(before.state,'IN_CITY');
  const moved=await post('/api/commands/world/move',envelope('move-legal-1',{targetX:before.worldPosition.x+40,targetY:before.worldPosition.y}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.state,'IN_WORLD');
  assert.equal(moved.data.throttled,false);
  assert.deepEqual(moved.data.worldPosition,{x:before.worldPosition.x+40,y:before.worldPosition.y});
});

test('IN_WORLD accepts further legal moves',async()=>{
  await wait(150);
  const before=await request('/api/character/char-demo/snapshot');
  assert.equal(before.state,'IN_WORLD');
  const moved=await post('/api/commands/world/move',envelope('move-legal-2',{targetX:before.worldPosition.x,targetY:before.worldPosition.y+30}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.state,'IN_WORLD');
  assert.deepEqual(moved.data.worldPosition,{x:before.worldPosition.x,y:before.worldPosition.y+30});
});

test("world/move clamps a single command's displacement to the server's max step distance, preventing a one-shot teleport",async()=>{
  await wait(150);
  const before=await request('/api/character/char-demo/snapshot');
  const moved=await post('/api/commands/world/move',envelope('move-teleport-attempt',{targetX:before.worldPosition.x+99999,targetY:before.worldPosition.y}));
  assert.equal(moved.status,'ACCEPTED');
  const distance=Math.hypot(moved.data.worldPosition.x-before.worldPosition.x,moved.data.worldPosition.y-before.worldPosition.y);
  assert.ok(distance<=60.0001,`expected displacement <=60, got ${distance}`);
  assert.ok(distance>0);
});

test('world/move clamps a target outside world bounds so the result stays within [0,1000]x[0,1000]',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE characters SET world_x=5,world_y=5,state='IN_WORLD' WHERE id='char-demo'`).run();
  fixture.close();
  await wait(150);
  const moved=await post('/api/commands/world/move',envelope('move-bounds-clamp',{targetX:-99999,targetY:-99999}));
  assert.equal(moved.status,'ACCEPTED');
  assert.ok(moved.data.worldPosition.x>=0,`x should clamp to >=0, got ${moved.data.worldPosition.x}`);
  assert.ok(moved.data.worldPosition.y>=0,`y should clamp to >=0, got ${moved.data.worldPosition.y}`);
  assert.equal(moved.data.worldPosition.x,0);
  assert.equal(moved.data.worldPosition.y,0);
});

test('a command sent sooner than the minimum movement interval produces no additional displacement',async()=>{
  await wait(150);
  const first=await post('/api/commands/world/move',envelope('move-throttle-a',{targetX:500,targetY:500}));
  assert.equal(first.status,'ACCEPTED');
  assert.equal(first.data.throttled,false);
  const second=await post('/api/commands/world/move',envelope('move-throttle-b',{targetX:900,targetY:900}));
  assert.equal(second.status,'ACCEPTED');
  assert.equal(second.data.throttled,true);
  assert.deepEqual(second.data.worldPosition,first.data.worldPosition);
});

test('world/move is rejected while TRAVELING, and leaves the stored position unchanged',async()=>{
  await wait(150);
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE characters SET state='IN_CITY' WHERE id='char-demo'`).run();
  fixture.close();
  const cities=await request('/api/cities');
  const before=await request('/api/character/char-demo/snapshot');
  const started=await post('/api/commands/travel/start',envelope('move-travel-block-start',{destinationCityId:cities.find(c=>c.id!==before.cityId).id}));
  assert.equal(started.status,'ACCEPTED');
  const beforeMove=await request('/api/character/char-demo/snapshot');
  assert.equal(beforeMove.state,'TRAVELING');
  const moved=await post('/api/commands/world/move',envelope('move-during-travel',{targetX:beforeMove.worldPosition.x+10,targetY:beforeMove.worldPosition.y}));
  assert.equal(moved.status,'REJECTED');
  assert.equal(moved.errorCode,'ERR_INVALID_STATE');
  const check=new DatabaseSync(join(dir,'test.sqlite'));
  const row=check.prepare(`SELECT world_x,world_y,state FROM characters WHERE id='char-demo'`).get();
  check.close();
  assert.equal(row.state,'TRAVELING');
  assert.equal(row.world_x,beforeMove.worldPosition.x);
  assert.equal(row.world_y,beforeMove.worldPosition.y);
});

test('existing IN_CITY-only city functions (market buy, storage move) remain rejected once the character has left for IN_WORLD',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE travel SET eta=? WHERE character_id='char-demo'`).run(Date.now()-1);
  fixture.close();
  const arrived=await post('/api/commands/travel/resolve-arrival',envelope('move-leave-city-arrive',{}));
  assert.equal(arrived.status,'ACCEPTED');
  const snap=await request('/api/character/char-demo/snapshot');
  assert.equal(snap.state,'IN_CITY');
  await wait(150);
  const moved=await post('/api/commands/world/move',envelope('move-leave-city',{targetX:snap.worldPosition.x+40,targetY:snap.worldPosition.y}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.state,'IN_WORLD');
  const buyAttempt=await post('/api/commands/market/buy',envelope('move-market-blocked',{approvedQuote:{cityId:snap.cityId,goodTypeId:'rice',requestedQuantity:1,unitPrice:9999,total:9999}}));
  assert.equal(buyAttempt.status,'REJECTED');
  assert.equal(buyAttempt.errorCode,'ERR_INVALID_CONTEXT');
  const moveGoods=await post('/api/commands/container/move',envelope('move-storage-blocked',{direction:'CARGO_TO_STORAGE',cityId:snap.cityId,goodTypeId:'rice',quantity:1}));
  assert.equal(moveGoods.status,'REJECTED');
  assert.equal(moveGoods.errorCode,'ERR_PHYSICAL_PRESENCE_REQUIRED');
});

test("worldPosition set by world/move survives a fresh snapshot request (reload/reconnect simulation)",async()=>{
  const snap=await request('/api/character/char-demo/snapshot');
  const reloaded=await request('/api/character/char-demo/snapshot');
  assert.deepEqual(reloaded.worldPosition,snap.worldPosition);
  assert.equal(reloaded.state,snap.state);
});

test('world/move rejects a non-numeric or missing target payload without crashing the server',async()=>{
  await wait(150);
  const before=await request('/api/character/char-demo/snapshot');
  const badString=await post('/api/commands/world/move',envelope('move-invalid-string',{targetX:'abc',targetY:150}));
  assert.equal(badString.status,'REJECTED');
  assert.equal(badString.errorCode,'ERR_INVALID_WORLD_TARGET');
  const missing=await post('/api/commands/world/move',envelope('move-invalid-missing',{}));
  assert.equal(missing.status,'REJECTED');
  assert.equal(missing.errorCode,'ERR_INVALID_WORLD_TARGET');
  const after=await request('/api/character/char-demo/snapshot');
  assert.deepEqual(after.worldPosition,before.worldPosition);
});
