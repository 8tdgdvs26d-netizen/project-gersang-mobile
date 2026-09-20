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
  dir=await mkdtemp(join(tmpdir(),'myrial-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:join(dir,'test.sqlite')},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`))) });
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

test('lost response retry applies a purchase exactly once',async()=>{
  const quote=await post('/api/commands/market/quote',{goodTypeId:'rice',side:'BUY',requestedQuantity:2});
  const command=envelope('lost-response-buy',{approvedQuote:quote});
  const first=await post('/api/commands/market/buy',command);
  const retry=await post('/api/commands/market/buy',command);
  assert.deepEqual(retry,first);
  const snap=await request('/api/character/char-demo/snapshot');
  assert.equal(snap.walletGold,1000-first.data.actualTotal);
  assert.equal(snap.cargo.stacks.find(x=>x.goodTypeId==='rice').quantity,2);
});

test('reconfirm does not consume the key and corrected payload can reuse it',async()=>{
  const stale=await post('/api/commands/market/quote',{goodTypeId:'tea',side:'BUY',requestedQuantity:1});
  const moverQuote=await post('/api/commands/market/quote',{goodTypeId:'tea',side:'BUY',requestedQuantity:1});
  await post('/api/commands/market/buy',envelope('move-tea-price',{approvedQuote:moverQuote}));
  const first=await post('/api/commands/market/buy',envelope('reconfirm-reuse',{approvedQuote:stale}));
  assert.equal(first.status,'RECONFIRM_REQUIRED');
  const corrected=await post('/api/commands/market/buy',envelope('reconfirm-reuse',{approvedQuote:first.data}));
  assert.equal(corrected.status,'ACCEPTED');
});

test('rejected command does not consume its key',async()=>{
  const key='rejected-reuse';
  const rejected=await post('/api/commands/travel/resolve-arrival',envelope(key,{}));
  assert.equal(rejected.status,'REJECTED');
  const started=await post('/api/commands/travel/start',envelope('start-trip',{destinationCityId:'harbour-city'}));
  assert.equal(started.status,'ACCEPTED');
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));fixture.prepare(`UPDATE travel SET eta=? WHERE character_id='char-demo'`).run(Date.now()-1);fixture.close();
  const accepted=await post('/api/commands/travel/resolve-arrival',envelope(key,{}));
  assert.equal(accepted.status,'ACCEPTED');
});

test('paid bus journeys cannot be rerouted mid-trip',async()=>{
  await post('/api/commands/travel/start',envelope('start-reroute',{destinationCityId:'hill-market'}));
  await new Promise(r=>setTimeout(r,100));
  const rerouted=await post('/api/commands/travel/reroute',envelope('reroute-trip',{destinationCityId:'starter-village'}));
  assert.equal(rerouted.errorCode,'ERR_BUS_REROUTE_UNAVAILABLE');
  const active=await request('/api/character/char-demo/snapshot');
  assert.equal(active.state,'TRAVELING');
  assert.equal(active.activeTravel.toCityId,'hill-market');
});
