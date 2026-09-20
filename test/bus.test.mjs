import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {CITY_DEFINITIONS} from '../public/cities.js';
import {BUS_TIME_RATIO,busQuote} from '../public/bus.js';

let child,base,dir,sessionId;
const request=async(path,options={})=>fetch(base+path,{headers:{'content-type':'application/json'},...options}).then(r=>r.json());
const post=(path,body)=>request(path,{method:'POST',body:JSON.stringify(body)});
const envelope=(key,payload)=>({commandId:crypto.randomUUID(),idempotencyKey:key,sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
const city=id=>CITY_DEFINITIONS.find(x=>x.id===id);
function setCharacter(cityId,wallet=1000){const c=city(cityId),db=new DatabaseSync(join(dir,'test.sqlite'));db.prepare(`DELETE FROM travel WHERE character_id='char-demo'`).run();db.prepare(`UPDATE characters SET city_id=?,state='IN_CITY',wallet=?,world_x=?,world_y=? WHERE id='char-demo'`).run(cityId,wallet,c.coordinates.x,c.coordinates.y);db.close()}

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-bus-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:join(dir,'test.sqlite')},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`)))});
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

test('the four-city bus quote matrix is complete, symmetric, distance-priced, and fixed at 70% of walking reference time',()=>{
  const quotes=[];
  for(const from of CITY_DEFINITIONS)for(const to of CITY_DEFINITIONS)if(from.id!==to.id){const quote=busQuote(from.id,to.id);assert.ok(quote,`${from.id} -> ${to.id}`);assert.equal(quote.travelMs,Math.round(quote.walkingMs*BUS_TIME_RATIO));quotes.push(quote)}
  assert.equal(quotes.length,12);
  for(const quote of quotes){const reverse=busQuote(quote.toCityId,quote.fromCityId);assert.equal(quote.fareGold,reverse.fareGold);assert.equal(quote.travelMs,reverse.travelMs)}
  const side=busQuote('starter-village','hill-market'),diagonal=busQuote('starter-village','harbour-city');
  assert.ok(diagonal.distance>side.distance);
  assert.ok(diagonal.fareGold>side.fareGold);
  assert.ok(diagonal.travelMs>side.travelMs);
});

test('every city can pay once for a server-authoritative bus trip to every other city',async()=>{
  for(const from of CITY_DEFINITIONS)for(const to of CITY_DEFINITIONS)if(from.id!==to.id){
    setCharacter(from.id);
    const quote=busQuote(from.id,to.id),started=await post('/api/commands/transport/bus/start',envelope(`bus-${from.id}-${to.id}`,{destinationCityId:to.id}));
    assert.equal(started.status,'ACCEPTED',`${from.id} -> ${to.id}`);
    assert.equal(started.data.transportMode,'BUS');
    assert.equal(started.data.fareGold,quote.fareGold);
    assert.equal(started.data.totalTravelMs,quote.travelMs);
    const snap=await request('/api/character/char-demo/snapshot');
    assert.equal(snap.state,'TRAVELING');
    assert.equal(snap.cityId,from.id);
    assert.equal(snap.walletGold,1000-quote.fareGold);
    assert.equal(snap.activeTravel.toCityId,to.id);
    assert.equal(snap.activeTravel.segments[0].transportMode,'BUS');
  }
});

test('bus retries charge only once, insufficient gold does not start a trip, and mid-trip reroute is locked',async()=>{
  setCharacter('starter-village');
  const busTxCount=()=>request('/api/character/char-demo/transactions').then(rows=>rows.filter(row=>row.kind==='BUS_FARE').length);
  const beforeCharges=await busTxCount();
  const command=envelope('bus-idempotent',{destinationCityId:'harbour-city'}),first=await post('/api/commands/transport/bus/start',command),retry=await post('/api/commands/transport/bus/start',command);
  assert.deepEqual(retry,first);
  const afterRetry=await request('/api/character/char-demo/snapshot');
  assert.equal(afterRetry.walletGold,1000-first.data.fareGold);
  assert.equal(await busTxCount(),beforeCharges+1);
  const reroute=await post('/api/commands/travel/reroute',envelope('bus-no-reroute',{destinationCityId:'hill-market'}));
  assert.equal(reroute.errorCode,'ERR_BUS_REROUTE_UNAVAILABLE');
  setCharacter('growth-city',0);
  const insufficient=await post('/api/commands/transport/bus/start',envelope('bus-insufficient',{destinationCityId:'starter-village'}));
  assert.equal(insufficient.errorCode,'ERR_INSUFFICIENT_GOLD');
  const afterInsufficient=await request('/api/character/char-demo/snapshot');
  assert.equal(afterInsufficient.state,'IN_CITY');
  assert.equal(afterInsufficient.cityId,'growth-city');
  assert.equal(afterInsufficient.walletGold,0);
  assert.equal(await busTxCount(),beforeCharges+1);
});

test('a paid bus arrival persists the destination city and exact destination world position',async()=>{
  setCharacter('growth-city');
  const started=await post('/api/commands/transport/bus/start',envelope('bus-arrival',{destinationCityId:'hill-market'}));
  assert.equal(started.status,'ACCEPTED');
  const db=new DatabaseSync(join(dir,'test.sqlite'));db.prepare(`UPDATE travel SET eta=? WHERE character_id='char-demo'`).run(Date.now()-1);db.close();
  const arrived=await request('/api/character/char-demo/snapshot'),destination=city('hill-market');
  assert.equal(arrived.state,'IN_CITY');
  assert.equal(arrived.cityId,destination.id);
  assert.deepEqual(arrived.worldPosition,destination.coordinates);
});
