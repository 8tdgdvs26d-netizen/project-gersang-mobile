import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';

let child,base,dir,dbPath,sessionId;

async function start(){
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:dbPath},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`)))});
  base='http://127.0.0.1:'+line.match(/:(\d+)/)[1];
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
}

const stop=async()=>{if(child){child.kill();await new Promise(r=>child.once('exit',r));child=null}};
const request=async(path,options={})=>fetch(base+path,{headers:{'content-type':'application/json'},...options}).then(r=>r.json());
const post=(path,body)=>request(path,{method:'POST',body:JSON.stringify(body)});
const envelope=(payload,{commandId=crypto.randomUUID(),idempotencyKey=crypto.randomUUID()}={})=>({commandId,idempotencyKey,sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});

function db(){return new DatabaseSync(dbPath)}
function economyRows(){const x=db();try{return x.prepare(`SELECT kind,gold_delta,city_id,good_id,quantity FROM economy_tx WHERE character_id='char-demo' ORDER BY created_at,id`).all()}finally{x.close()}}
function itemRows(){const x=db();try{return x.prepare(`SELECT good_id,quantity_delta,reason FROM item_trace WHERE character_id='char-demo' ORDER BY created_at,id`).all()}finally{x.close()}}
function marketRow(city,good){const x=db();try{return x.prepare(`SELECT stock,ref_price FROM market WHERE city_id=? AND good_id=?`).get(city,good)}finally{x.close()}}
function forceArrival(){const x=db();try{x.prepare(`UPDATE travel SET eta=? WHERE character_id='char-demo'`).run(Date.now()-1)}finally{x.close()}}

async function snapshot(){return request('/api/character/char-demo/snapshot')}
async function buy(good,quantity,key){const q=await post('/api/commands/market/quote',{goodTypeId:good,side:'BUY',requestedQuantity:quantity});const env=envelope({approvedQuote:q},{idempotencyKey:key});return {quote:q,env,result:await post('/api/commands/market/buy',env)}}
async function sell(good,quantity,key){const q=await post('/api/commands/market/quote',{goodTypeId:good,side:'SELL',requestedQuantity:quantity});const env=envelope({approvedQuote:q},{idempotencyKey:key});return {quote:q,env,result:await post('/api/commands/market/sell',env)}}

function cargoQty(snap,good){return snap.cargo.stacks.find(x=>x.goodTypeId===good)?.quantity??0}
// P4-03A — snapshot() now additively exposes serverNowMs and a live, time-varying
// worldMonsters[].position (see public/worldmonsters.js's patrolPositionAt()). Both are legitimately
// expected to differ between any two real snapshot() calls regardless of whether anything this test
// actually cares about changed, so the two idempotent-retry deepEqual comparisons below must exclude
// them — the economy invariant those comparisons exist to prove (wallet/cargo/market/economy_tx/
// item_trace conservation) is fully covered by every other assertion in this file and is completely
// untouched by this.
const omitVolatileSnapshotFields=snap=>{const {serverNowMs,worldMonsters,worldStateRevision,...rest}=snap;return rest};

await test.before(async()=>{dir=await mkdtemp(join(tmpdir(),'myrial-phase3-closeout-'));dbPath=join(dir,'test.sqlite');await start()});
await test.after(async()=>{await stop();await rm(dir,{recursive:true,force:true})});

test('Phase 3 trade route conserves wallet/item ledgers, market stock, and idempotency',async()=>{
  const good='tea',from='harbour-city',to='hill-market',quantity=20;
  const x=db();
  try{
    x.exec(`DELETE FROM economy_tx; DELETE FROM item_trace; DELETE FROM cargo; DELETE FROM travel;`);
    x.prepare(`UPDATE characters SET city_id=?,state='IN_CITY',wallet=1000 WHERE id='char-demo'`).run(from);
  }finally{x.close()}

  const before=await snapshot();
  const sourceBefore=marketRow(from,good);
  const destinationBefore=marketRow(to,good);

  const buyKey=crypto.randomUUID();
  const bought=await buy(good,quantity,buyKey);
  assert.equal(bought.result.status,'ACCEPTED');

  const afterBuy=await snapshot();
  assert.equal(afterBuy.walletGold,before.walletGold-bought.quote.total);
  assert.equal(cargoQty(afterBuy,good),bought.quote.fillQuantity);
  const sourceAfter=marketRow(from,good);
  assert.equal(sourceAfter.stock,sourceBefore.stock-bought.quote.fillQuantity);

  const economyAfterBuy=economyRows();
  const itemsAfterBuy=itemRows();
  assert.equal(economyAfterBuy.filter(r=>r.kind==='NPC_BUY').length,1);
  assert.equal(itemsAfterBuy.filter(r=>r.reason==='NPC_BUY').length,1);

  const buyRetry=await post('/api/commands/market/buy',bought.env);
  assert.deepEqual(buyRetry,bought.result);
  assert.equal(economyRows().filter(r=>r.kind==='NPC_BUY').length,1);
  assert.equal(itemRows().filter(r=>r.reason==='NPC_BUY').length,1);
  assert.deepEqual(omitVolatileSnapshotFields(await snapshot()),omitVolatileSnapshotFields(afterBuy));

  const busEnv=envelope({destinationCityId:to},{idempotencyKey:crypto.randomUUID()});
  const bus=await post('/api/commands/transport/bus/start',busEnv);
  assert.equal(bus.status,'ACCEPTED');
  const afterBus=await snapshot();
  assert.equal(afterBus.walletGold,afterBuy.walletGold-bus.data.fareGold);
  assert.equal(economyRows().filter(r=>r.kind==='BUS_FARE').length,1);

  const busRetry=await post('/api/commands/transport/bus/start',busEnv);
  assert.deepEqual(busRetry,bus);
  assert.equal(economyRows().filter(r=>r.kind==='BUS_FARE').length,1);

  forceArrival();
  const arrived=await snapshot();
  assert.equal(arrived.state,'IN_CITY');
  assert.equal(arrived.cityId,to);

  const sellKey=crypto.randomUUID();
  const sold=await sell(good,quantity,sellKey);
  assert.equal(sold.result.status,'ACCEPTED');
  const after=await snapshot();
  assert.equal(cargoQty(after,good),0);

  const destinationAfter=marketRow(to,good);
  assert.equal(destinationAfter.stock,destinationBefore.stock+sold.quote.fillQuantity);

  const economy=economyRows();
  const itemTrace=itemRows();
  const goldDelta=economy.reduce((sum,row)=>sum+row.gold_delta,0);
  assert.equal(after.walletGold-before.walletGold,goldDelta);
  assert.equal(goldDelta,-bought.quote.total-bus.data.fareGold+sold.quote.total);

  const tracedGoodDelta=itemTrace.filter(r=>r.good_id===good).reduce((sum,row)=>sum+row.quantity_delta,0);
  assert.equal(cargoQty(after,good)-cargoQty(before,good),tracedGoodDelta);
  assert.equal(tracedGoodDelta,0);
  assert.equal(itemTrace.filter(r=>r.reason==='NPC_BUY').length,1);
  assert.equal(itemTrace.filter(r=>r.reason==='NPC_SELL').length,1);

  const sellRetry=await post('/api/commands/market/sell',sold.env);
  assert.deepEqual(sellRetry,sold.result);
  assert.equal(economyRows().filter(r=>r.kind==='NPC_SELL').length,1);
  assert.equal(itemRows().filter(r=>r.reason==='NPC_SELL').length,1);
  assert.deepEqual(omitVolatileSnapshotFields(await snapshot()),omitVolatileSnapshotFields(after));
});
