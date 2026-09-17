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

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-world-entity-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:join(dir,'test.sqlite')},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`))) });
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

test('snapshot() exposes worldPosition matching the starting city\'s coordinates',async()=>{
  const cities=await request('/api/cities');
  const startCity=cities.find(c=>c.id==='starter-village');
  const snap=await request('/api/character/char-demo/snapshot');
  assert.equal(snap.cityId,'starter-village');
  assert.deepEqual(snap.worldPosition,startCity.coordinates);
});

test("worldPosition persists and updates to the destination city's coordinates after travel start + resolve-arrival",async()=>{
  const cities=await request('/api/cities');
  const destination=cities.find(c=>c.id==='harbour-city');
  const started=await post('/api/commands/travel/start',envelope('world-entity-travel-start',{destinationCityId:'harbour-city'}));
  assert.equal(started.status,'ACCEPTED');
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE travel SET eta=? WHERE character_id='char-demo'`).run(Date.now()-1);
  fixture.close();
  const arrived=await post('/api/commands/travel/resolve-arrival',envelope('world-entity-resolve-arrival',{}));
  assert.equal(arrived.status,'ACCEPTED');
  assert.equal(arrived.data.cityId,'harbour-city');
  const snap=await request('/api/character/char-demo/snapshot');
  assert.equal(snap.cityId,'harbour-city');
  assert.deepEqual(snap.worldPosition,destination.coordinates);
});

test('legacy character rows with NULL world_x/world_y self-heal to the current city\'s coordinates on next snapshot(), without snapshot() writing to the database',async()=>{
  const cities=await request('/api/cities');
  const currentCity=cities.find(c=>c.id==='harbour-city');
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE characters SET world_x=NULL,world_y=NULL WHERE id='char-demo'`).run();
  fixture.close();
  const snap=await request('/api/character/char-demo/snapshot');
  assert.deepEqual(snap.worldPosition,currentCity.coordinates);
  const check=new DatabaseSync(join(dir,'test.sqlite'));
  const row=check.prepare(`SELECT world_x,world_y FROM characters WHERE id='char-demo'`).get();
  check.close();
  assert.equal(row.world_x,null);
  assert.equal(row.world_y,null);
});
