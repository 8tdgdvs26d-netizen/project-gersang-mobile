import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {GOOD_DEFINITIONS,MARKET_SEED} from '../public/goods.js';
import {CITY_DEFINITIONS} from '../public/cities.js';

let child,base,dir,dbPath,sessionId;
async function start(){
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:dbPath},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited \${code}`)))});
  base='http://127.0.0.1:'+line.match(/:(\d+)/)[1];
  sessionId=(await (await fetch(base+'/api/session/open',{method:'POST',headers:{'content-type':'application/json'},body:'{}'})).json()).sessionId;
}
const stop=async()=>{if(child){child.kill();await new Promise(r=>child.once('exit',r));child=null}};
const env=payload=>({commandId:crypto.randomUUID(),idempotencyKey:crypto.randomUUID(),sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
const post=async(path,body)=>{const r=await fetch(base+path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});assert.equal(r.status,200);return r.json()};

test.before(async()=>{dir=await mkdtemp(join(tmpdir(),'myrial-p3-economy-'));dbPath=join(dir,'test.sqlite');await start()});
test.after(async()=>{await stop();await rm(dir,{recursive:true,force:true})});

test('six goods are data-driven with stable unique ids and cargo units',()=>{
  assert.equal(GOOD_DEFINITIONS.length,6);assert.equal(new Set(GOOD_DEFINITIONS.map(g=>g.id)).size,6);assert.ok(GOOD_DEFINITIONS.every(g=>g.cargoUnits>0));assert.equal(MARKET_SEED.length,24);
});

test('all four cities expose market and storage facilities and six market goods',async()=>{
  assert.equal(CITY_DEFINITIONS.length,4);
  for(const city of CITY_DEFINITIONS){assert.ok(city.facilities.includes('MARKET'));assert.ok(city.facilities.includes('STORAGE'));const rows=await (await fetch(base+'/api/cities/'+city.id+'/market')).json();assert.equal(rows.length,6);assert.deepEqual(new Set(rows.map(x=>x.goodTypeId)),new Set(GOOD_DEFINITIONS.map(g=>g.id)))}
});

test('cargo capacity uses goods data and partial fill',async()=>{
  const q=await post('/api/commands/market/quote',{goodTypeId:'iron',side:'BUY',requestedQuantity:20});assert.equal(q.fillQuantity,6);
});

test('same-city buy then sell is a net loss and writes economy/item traces',async()=>{
  const before=await (await fetch(base+'/api/character/char-demo/snapshot')).json();
  const buyQ=await post('/api/commands/market/quote',{goodTypeId:'rice',side:'BUY',requestedQuantity:1});
  const buy=await post('/api/commands/market/buy',env({approvedQuote:buyQ}));assert.equal(buy.status,'ACCEPTED');
  const sellQ=await post('/api/commands/market/quote',{goodTypeId:'rice',side:'SELL',requestedQuantity:1});
  const sell=await post('/api/commands/market/sell',env({approvedQuote:sellQ}));assert.equal(sell.status,'ACCEPTED');
  const after=await (await fetch(base+'/api/character/char-demo/snapshot')).json();assert.ok(after.walletGold<before.walletGold);
  const db=new DatabaseSync(dbPath);assert.ok(db.prepare(`SELECT COUNT(*) n FROM economy_tx WHERE kind IN ('NPC_BUY','NPC_SELL')`).get().n>=2);assert.ok(db.prepare(`SELECT COUNT(*) n FROM item_trace WHERE reason IN ('NPC_BUY','NPC_SELL')`).get().n>=2);db.close();
});

test('market tick restocks gradually and drifts price toward base without hard reset',async()=>{
  const db=new DatabaseSync(dbPath);const old=Date.now()-65000;db.prepare(`UPDATE market SET stock=10,ref_price=14,base_price=10,target_stock=100,restock_rate=5,last_tick_at=? WHERE city_id='starter-village' AND good_id='rice'`).run(old);db.close();
  const rows=await (await fetch(base+'/api/cities/starter-village/market')).json(),rice=rows.find(x=>x.goodTypeId==='rice');assert.equal(rice.stock,20);assert.equal(rice.referencePrice,12);assert.equal(rice.basePrice,10);
});

test('wallet, cargo, and market state survive server restart on the same SQLite save',async()=>{
  const q=await post('/api/commands/market/quote',{goodTypeId:'tea',side:'BUY',requestedQuantity:1});const bought=await post('/api/commands/market/buy',env({approvedQuote:q}));assert.equal(bought.status,'ACCEPTED');
  const before=await (await fetch(base+'/api/character/char-demo/snapshot')).json();const marketBefore=await (await fetch(base+'/api/cities/starter-village/market')).json();await stop();await start();
  const after=await (await fetch(base+'/api/character/char-demo/snapshot')).json();const marketAfter=await (await fetch(base+'/api/cities/starter-village/market')).json();assert.equal(after.walletGold,before.walletGold);assert.deepEqual(after.cargo,before.cargo);assert.equal(marketAfter.find(x=>x.goodTypeId==='tea').stock,marketBefore.find(x=>x.goodTypeId==='tea').stock);
});
