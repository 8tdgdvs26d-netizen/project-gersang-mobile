import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {CITY_DEFINITIONS} from '../public/cities.js';
import {cityEntryCandidate,renderWorldMapHtml} from '../public/worldmap.js';

let child,base,dir,sessionId;
const request=async(path,options={})=>{const r=await fetch(base+path,{headers:{'content-type':'application/json'},...options});return r.json()};
const post=(path,body)=>request(path,{method:'POST',body:JSON.stringify(body)});
const envelope=(key,payload)=>({commandId:crypto.randomUUID(),idempotencyKey:key,sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
const setCharacter=(cityId,position,state='IN_WORLD')=>{const fixture=new DatabaseSync(join(dir,'test.sqlite'));fixture.prepare(`DELETE FROM travel WHERE character_id='char-demo'`).run();fixture.prepare(`UPDATE characters SET city_id=?,world_x=?,world_y=?,state=? WHERE id='char-demo'`).run(cityId,position.x,position.y,state);fixture.close()};

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-city-entry-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:join(dir,'test.sqlite')},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`)))});
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

test('map offers an explicit entry action only while IN_WORLD within a city entry radius',()=>{
  const city=CITY_DEFINITIONS[0];
  const nearby={state:'IN_WORLD',cityId:'growth-city',worldPosition:{...city.coordinates}};
  assert.equal(cityEntryCandidate(nearby,CITY_DEFINITIONS)?.id,city.id);
  assert.ok(renderWorldMapHtml({snap:nearby,cities:CITY_DEFINITIONS,roads:[]}).includes(`data-enter-city="${city.id}"`));
  const remote={state:'IN_WORLD',cityId:'growth-city',worldPosition:{x:0,y:0}};
  assert.equal(cityEntryCandidate(remote,CITY_DEFINITIONS),null);
  assert.ok(!renderWorldMapHtml({snap:remote,cities:CITY_DEFINITIONS,roads:[]}).includes('data-enter-city='));
  assert.equal(cityEntryCandidate({...nearby,state:'IN_CITY'},CITY_DEFINITIONS),null);
});

test('every canonical city accepts an explicit server-validated entry at its configured radius',async()=>{
  for(const city of CITY_DEFINITIONS){
    const position={x:city.coordinates.x+city.entryRadius,y:city.coordinates.y};
    setCharacter('starter-village',position);
    const entered=await post('/api/commands/city/enter',envelope(`enter-${city.id}`,{destinationCityId:city.id}));
    assert.equal(entered.status,'ACCEPTED',city.id);
    assert.deepEqual(entered.data,{cityId:city.id,state:'IN_CITY',worldPosition:position});
    const after=await request('/api/character/char-demo/snapshot');
    assert.equal(after.cityId,city.id);
    assert.equal(after.state,'IN_CITY');
    assert.deepEqual(after.worldPosition,position);
  }
});

test('server rejects remote, unknown, and invalid-state city entry without changing state or position',async()=>{
  const remotePosition={x:0,y:0};
  setCharacter('starter-village',remotePosition);
  const remote=await post('/api/commands/city/enter',envelope('enter-remote',{destinationCityId:'starter-village'}));
  assert.equal(remote.errorCode,'ERR_CITY_ENTRY_OUT_OF_RANGE');
  const unchanged=await request('/api/character/char-demo/snapshot');
  assert.equal(unchanged.cityId,'starter-village');
  assert.equal(unchanged.state,'IN_WORLD');
  assert.deepEqual(unchanged.worldPosition,remotePosition);
  const starter=CITY_DEFINITIONS[0];
  setCharacter('starter-village',starter.coordinates);
  const wrongCity=await post('/api/commands/city/enter',envelope('enter-wrong-city',{destinationCityId:'growth-city'}));
  assert.equal(wrongCity.errorCode,'ERR_CITY_ENTRY_OUT_OF_RANGE');
  const unknown=await post('/api/commands/city/enter',envelope('enter-unknown',{destinationCityId:'missing-city'}));
  assert.equal(unknown.errorCode,'ERR_CITY_NOT_FOUND');
  setCharacter('starter-village',CITY_DEFINITIONS[0].coordinates,'TRAVELING');
  const travelling=await post('/api/commands/city/enter',envelope('enter-travelling',{destinationCityId:'starter-village'}));
  assert.equal(travelling.errorCode,'ERR_INVALID_STATE');
});

test('city entry is idempotent and the accepted state survives a fresh snapshot',async()=>{
  const city=CITY_DEFINITIONS.find(x=>x.id==='growth-city');
  setCharacter('starter-village',city.coordinates);
  const command=envelope('enter-retry',{destinationCityId:city.id});
  const first=await post('/api/commands/city/enter',command);
  const retry=await post('/api/commands/city/enter',command);
  assert.deepEqual(retry,first);
  const reloaded=await request('/api/character/char-demo/snapshot');
  assert.equal(reloaded.cityId,city.id);
  assert.equal(reloaded.state,'IN_CITY');
  assert.deepEqual(reloaded.worldPosition,city.coordinates);
});

test('unsettled battle loot blocks city entry without changing the world snapshot',async()=>{
  const city=CITY_DEFINITIONS[0],before={...city.coordinates};
  setCharacter('starter-village',before);
  const fixture=new DatabaseSync(join(dir,'test.sqlite')),now=Date.now();
  fixture.prepare(`INSERT INTO battles VALUES('entry-pending-loot','char-demo','VICTORY',?,?)`).run(now,now);
  fixture.prepare(`INSERT INTO battle_meta VALUES('entry-pending-loot','bandit-patrol',100,50)`).run();
  fixture.prepare(`INSERT INTO battle_rewards VALUES('entry-pending-loot','char-demo',100,?)`).run(now);
  fixture.close();
  const blocked=await post('/api/commands/city/enter',envelope('enter-pending-loot',{destinationCityId:city.id}));
  assert.equal(blocked.errorCode,'ERR_BATTLE_SETTLEMENT_REQUIRED');
  const after=await request('/api/character/char-demo/snapshot');
  assert.equal(after.cityId,'starter-village');
  assert.equal(after.state,'IN_WORLD');
  assert.deepEqual(after.worldPosition,before);
  const cleanup=new DatabaseSync(join(dir,'test.sqlite'));cleanup.prepare(`DELETE FROM battle_rewards WHERE battle_id='entry-pending-loot'`).run();cleanup.prepare(`DELETE FROM battle_meta WHERE battle_id='entry-pending-loot'`).run();cleanup.prepare(`DELETE FROM battles WHERE id='entry-pending-loot'`).run();cleanup.close();
});
