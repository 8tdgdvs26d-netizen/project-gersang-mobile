import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm,readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {marketExecutionQuote,MARKET_BATCH_SIZE} from '../public/marketpricing.js';
import {GOOD_DEFINITIONS,MARKET_SEED,goodNameFor} from '../public/goods.js';
import {busQuote} from '../public/bus.js';

test('batch pricing boundaries 1/10/11/20 preserve the existing ceil(qty/10) impact scale',()=>{
  assert.equal(MARKET_BATCH_SIZE,10);
  const expected=new Map([[1,{total:12,final:11,batches:1}],[10,{total:120,final:11,batches:1}],[11,{total:133,final:12,batches:2}],[20,{total:250,final:12,batches:2}]]);
  for(const [quantity,e] of expected){const q=marketExecutionQuote({referencePrice:10,spread:2,side:'BUY',quantity});assert.equal(q.total,e.total);assert.equal(q.finalReferencePrice,e.final);assert.equal(q.batches.length,e.batches)}
});

test('SELL batch repricing mirrors BUY direction and respects price floor',()=>{
  const q=marketExecutionQuote({referencePrice:10,spread:2,side:'SELL',quantity:20});
  assert.equal(q.total,150);assert.equal(q.finalReferencePrice,8);assert.deepEqual(q.batches.map(x=>x.unitPrice),[8,7]);
  const floor=marketExecutionQuote({referencePrice:1,spread:2,side:'SELL',quantity:20});assert.deepEqual(floor.batches.map(x=>x.unitPrice),[1,1]);assert.equal(floor.finalReferencePrice,1);
});

test('BUY affordability can partially fill inside a batch using exact execution cost',()=>{
  const q=marketExecutionQuote({referencePrice:10,spread:2,side:'BUY',quantity:20,budget:125});
  assert.equal(q.fillQuantity,10);assert.equal(q.total,120);assert.equal(q.finalReferencePrice,11);
});

test('goods retain stable IDs but expose Chinese player-facing names',async()=>{
  assert.deepEqual(GOOD_DEFINITIONS.map(x=>x.name),['米糧','茶葉','布匹','鐵材','木材','藥材']);
  assert.equal(goodNameFor('rice'),'米糧');assert.equal(goodNameFor('medicine'),'藥材');
  const app=await readFile(new URL('../public/app.js',import.meta.url),'utf8');assert.match(app,/goodNameFor\(m\.goodTypeId\)/);assert.match(app,/goodNameFor\(stack\.goodTypeId\)/);
});

let child,base,dir,dbPath,sessionId;
const request=async(path,options={})=>fetch(base+path,{headers:{'content-type':'application/json'},...options}).then(r=>r.json());
const post=(path,body)=>request(path,{method:'POST',body:JSON.stringify(body)});
const envelope=(payload)=>({commandId:crypto.randomUUID(),idempotencyKey:crypto.randomUUID(),sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
function resetEconomy(cityId,wallet=1000){
  const db=new DatabaseSync(dbPath);db.exec('DELETE FROM travel; DELETE FROM cargo; DELETE FROM economy_tx; DELETE FROM item_trace;');
  db.prepare(`UPDATE characters SET city_id=?,state='IN_CITY',wallet=? WHERE id='char-demo'`).run(cityId,wallet);
  const up=db.prepare(`UPDATE market SET stock=?,ref_price=?,base_price=?,spread=?,target_stock=?,restock_rate=?,version=1,last_tick_at=? WHERE city_id=? AND good_id=?`);
  const now=Date.now();for(const m of MARKET_SEED)up.run(m.stock,m.basePrice,m.basePrice,m.spread,m.targetStock,m.restockRate,now,m.cityId,m.goodTypeId);db.close();
}
async function tradeRoute(from,to,good,quantity){
  resetEconomy(from,1000);const before=(await request('/api/character/char-demo/snapshot')).walletGold;
  const buyQ=await post('/api/commands/market/quote',{goodTypeId:good,side:'BUY',requestedQuantity:quantity});const buy=await post('/api/commands/market/buy',envelope({approvedQuote:buyQ}));assert.equal(buy.status,'ACCEPTED');
  const bus=await post('/api/commands/transport/bus/start',envelope({destinationCityId:to}));assert.equal(bus.status,'ACCEPTED');assert.equal(bus.data.fareGold,busQuote(from,to).fareGold);
  const db=new DatabaseSync(dbPath);db.prepare(`UPDATE travel SET eta=? WHERE character_id='char-demo'`).run(Date.now()-1);db.close();
  const arrived=await request('/api/character/char-demo/snapshot');assert.equal(arrived.state,'IN_CITY');assert.equal(arrived.cityId,to);
  const sellQ=await post('/api/commands/market/quote',{goodTypeId:good,side:'SELL',requestedQuantity:quantity});const sell=await post('/api/commands/market/sell',envelope({approvedQuote:sellQ}));assert.equal(sell.status,'ACCEPTED');
  const after=(await request('/api/character/char-demo/snapshot')).walletGold;return {before,after,buyQ,sellQ,bus};
}

test.before(async()=>{dir=await mkdtemp(join(tmpdir(),'myrial-p3-02-'));dbPath=join(dir,'test.sqlite');child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:dbPath},stdio:['ignore','pipe','inherit']});const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`)))});base='http://127.0.0.1:'+line.match(/:(\d+)/)[1];sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

test('Harbour -> Hill tea is a complete profitable buy/bus/arrive/sell route after transport cost',async()=>{const r=await tradeRoute('harbour-city','hill-market','tea',20);assert.ok(r.after>r.before,`expected profit, before=${r.before}, after=${r.after}`);assert.deepEqual(r.buyQ.priceBatches.map(x=>x.unitPrice),[11,12]);assert.deepEqual(r.sellQ.priceBatches.map(x=>x.unitPrice),[18,17])});

test('Starter -> Hill tea is deliberately not profitable after transport cost',async()=>{const r=await tradeRoute('starter-village','hill-market','tea',20);assert.ok(r.after<r.before,`expected loss, before=${r.before}, after=${r.after}`)});
