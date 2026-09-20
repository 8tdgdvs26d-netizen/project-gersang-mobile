import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {CITY_DEFINITIONS} from '../public/cities.js';
import {busQuote} from '../public/bus.js';

// P2-06 — Bus Persistence/Retry/Reconnect Hardening. Proves that reload, disconnect/retry,
// idempotency-key reuse, an ARRIVED journey's activeTravel visibility, and a genuine OS-level
// server restart can never duplicate a BUS_FARE charge, duplicate a journey, leave a stale
// activeTravel, or desync state/wallet/DB from what the server actually committed. Test-only file:
// no production behaviour beyond what's approved in server.mjs/public/app.js is touched here.

let child,base,dir,sessionId;
const request=async(path,options={})=>fetch(base+path,{headers:{'content-type':'application/json'},...options}).then(r=>r.json());
const post=(path,body)=>request(path,{method:'POST',body:JSON.stringify(body)});
const envelope=(key,payload,session=sessionId)=>({commandId:crypto.randomUUID(),idempotencyKey:key,sessionId:session,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
const city=id=>CITY_DEFINITIONS.find(x=>x.id===id);
const dbPath=()=>join(dir,'test.sqlite');
function setCharacter(cityId,wallet=1000){const c=city(cityId),db=new DatabaseSync(dbPath());db.prepare(`DELETE FROM travel WHERE character_id='char-demo'`).run();db.prepare(`UPDATE characters SET city_id=?,state='IN_CITY',wallet=?,world_x=?,world_y=? WHERE id='char-demo'`).run(cityId,wallet,c.coordinates.x,c.coordinates.y);db.close()}
function busTxCount(){const db=new DatabaseSync(dbPath());const n=db.prepare(`SELECT COUNT(*) c FROM economy_tx WHERE character_id='char-demo' AND kind='BUS_FARE'`).get().c;db.close();return n}
function readTravelRow(){const db=new DatabaseSync(dbPath());const row=db.prepare(`SELECT * FROM travel WHERE character_id='char-demo'`).get();db.close();return row}
function forceEtaPast(){const db=new DatabaseSync(dbPath());db.prepare(`UPDATE travel SET eta=? WHERE character_id='char-demo'`).run(Date.now()-1);db.close()}
function forcePendingLootSettlement(){
  const db=new DatabaseSync(dbPath()),id=`persistence-loot-${crypto.randomUUID()}`,now=Date.now();
  db.prepare(`INSERT INTO battles VALUES(?,?,?,?,?)`).run(id,'char-demo','VICTORY',now,now);
  db.prepare(`INSERT INTO battle_meta VALUES(?,?,?,?)`).run(id,'bandit-patrol',100,50);
  db.prepare(`INSERT INTO battle_rewards VALUES(?,?,?,?)`).run(id,'char-demo',100,now);
  db.close();
  return id;
}
function clearPendingLootSettlements(){const db=new DatabaseSync(dbPath());db.prepare(`DELETE FROM battles WHERE character_id='char-demo'`).run();db.prepare(`DELETE FROM battle_meta`).run();db.prepare(`DELETE FROM battle_rewards WHERE character_id='char-demo'`).run();db.close()}

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-bus-persistence-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:dbPath()},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`)))});
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

// --- A: same idempotency key repeated N times => one fare only ---

test('A: the same bus command + the same idempotency key, repeated 4 times, charges exactly one fare',async()=>{
  setCharacter('starter-village');
  const quote=busQuote('starter-village','harbour-city'),command=envelope('persist-A-repeat',{destinationCityId:'harbour-city'});
  const beforeTx=await busTxCount();
  const responses=[];
  for(let i=0;i<4;i++)responses.push(await post('/api/commands/transport/bus/start',command));
  for(const r of responses)assert.deepEqual(r,responses[0],'every repeat must return byte-identical cached result');
  assert.equal(responses[0].status,'ACCEPTED');
  const snap=await request('/api/character/char-demo/snapshot');
  assert.equal(snap.walletGold,1000-quote.fareGold);
  assert.equal(await busTxCount(),beforeTx+1);
});

// --- B: response-loss simulation / retry => one fare only ---
// The server has no way to distinguish "the client never received the response" from "the client
// resent the exact same command" — both arrive as the same idempotencyKey+payload. This is the
// correct simulation of a lost response under this server's actual retry contract (see
// server.mjs's idem()), not an approximation of it.

test('B: a lost-response retry (client never sees the first ACCEPTED response, resends the identical command) still charges exactly one fare',async()=>{
  setCharacter('starter-village');
  const quote=busQuote('starter-village','hill-market'),command=envelope('persist-B-lost-response',{destinationCityId:'hill-market'});
  const beforeTx=await busTxCount();
  await post('/api/commands/transport/bus/start',command); // simulates the response never reaching the client
  const retry=await post('/api/commands/transport/bus/start',command); // client, believing it never sent, resends
  assert.equal(retry.status,'ACCEPTED');
  assert.equal(retry.data.fareGold,quote.fareGold);
  const snap=await request('/api/character/char-demo/snapshot');
  assert.equal(snap.walletGold,1000-quote.fareGold);
  assert.equal(await busTxCount(),beforeTx+1);
});

// --- C: different idempotency key while already TRAVELING => rejected, no second debit ---

test('C: a different idempotency key while already TRAVELING is rejected before any debit, and creates no second journey',async()=>{
  setCharacter('starter-village');
  const quote=busQuote('starter-village','harbour-city');
  const first=await post('/api/commands/transport/bus/start',envelope('persist-C-first',{destinationCityId:'harbour-city'}));
  assert.equal(first.status,'ACCEPTED');
  const beforeTx=await busTxCount(),beforeWallet=(await request('/api/character/char-demo/snapshot')).walletGold;
  const second=await post('/api/commands/transport/bus/start',envelope('persist-C-second',{destinationCityId:'hill-market'}));
  assert.equal(second.status,'REJECTED');
  assert.equal(second.errorCode,'ERR_INVALID_STATE');
  const snap=await request('/api/character/char-demo/snapshot');
  assert.equal(snap.walletGold,beforeWallet);
  assert.equal(snap.walletGold,1000-quote.fareGold);
  assert.equal(snap.activeTravel.toCityId,'harbour-city','the original journey must be unchanged');
  assert.equal(await busTxCount(),beforeTx);
});

// --- D: reload/snapshot during active journey => same destination/ETA/journey, wallet unchanged ---

test('D: repeated snapshot reads mid-journey (before ETA) return the exact same destination, ETA, and journey, with wallet unchanged across all reads',async()=>{
  setCharacter('starter-village');
  const quote=busQuote('starter-village','growth-city');
  const started=await post('/api/commands/transport/bus/start',envelope('persist-D-start',{destinationCityId:'growth-city'}));
  assert.equal(started.status,'ACCEPTED');
  const reads=[];
  for(let i=0;i<3;i++)reads.push(await request('/api/character/char-demo/snapshot'));
  for(const snap of reads){
    assert.equal(snap.state,'TRAVELING');
    assert.equal(snap.activeTravel.toCityId,'growth-city');
    assert.equal(snap.activeTravel.fromCityId,'starter-village');
    assert.equal(snap.activeTravel.estimatedArrivalAt,reads[0].activeTravel.estimatedArrivalAt);
    assert.equal(snap.activeTravel.startedAt,reads[0].activeTravel.startedAt);
    assert.equal(snap.walletGold,1000-quote.fareGold);
  }
});

// --- G: multiple snapshot arrival resolutions => same final state, no duplicate transaction ---

test('G: reading snapshot repeatedly after ETA has passed resolves arrival exactly once — state/wallet/transaction count never change again after the first read',async()=>{
  setCharacter('starter-village');
  const quote=busQuote('starter-village','harbour-city');
  const started=await post('/api/commands/transport/bus/start',envelope('persist-G-start',{destinationCityId:'harbour-city'}));
  assert.equal(started.status,'ACCEPTED');
  forceEtaPast();
  const beforeTx=await busTxCount();
  const first=await request('/api/character/char-demo/snapshot');
  assert.equal(first.state,'IN_CITY');
  assert.equal(first.cityId,'harbour-city');
  assert.equal(first.walletGold,1000-quote.fareGold);
  assert.equal(first.activeTravel,null);
  for(let i=0;i<3;i++){
    const again=await request('/api/character/char-demo/snapshot');
    assert.equal(again.state,'IN_CITY');
    assert.equal(again.cityId,'harbour-city');
    assert.equal(again.walletGold,first.walletGold);
    assert.equal(again.activeTravel,null);
  }
  assert.equal(await busTxCount(),beforeTx,'arrival resolution must never insert a second BUS_FARE (or any) transaction — beforeTx already includes this journey\'s single fare');
  assert.equal(readTravelRow().status,'ARRIVED');
});

// --- H: explicit resolveArrival after snapshot already auto-resolved => rejected/no-op ---

test('H: calling resolveArrival explicitly (new idempotency key) after snapshot already auto-resolved the same journey is rejected and mutates nothing',async()=>{
  setCharacter('starter-village');
  const quote=busQuote('starter-village','hill-market');
  const started=await post('/api/commands/transport/bus/start',envelope('persist-H-start',{destinationCityId:'hill-market'}));
  assert.equal(started.status,'ACCEPTED');
  forceEtaPast();
  const autoResolved=await request('/api/character/char-demo/snapshot');
  assert.equal(autoResolved.state,'IN_CITY');
  const beforeTx=await busTxCount();
  const explicit=await post('/api/commands/travel/resolve-arrival',envelope('persist-H-explicit',{}));
  assert.equal(explicit.status,'REJECTED');
  assert.equal(explicit.errorCode,'ERR_NO_TRAVEL');
  const after=await request('/api/character/char-demo/snapshot');
  assert.equal(after.state,'IN_CITY');
  assert.equal(after.cityId,'hill-market');
  assert.equal(after.walletGold,1000-quote.fareGold);
  assert.equal(after.activeTravel,null);
  assert.equal(await busTxCount(),beforeTx,'the rejected explicit resolve must not insert a transaction');
});

// --- I: arrival complete => snapshot.activeTravel === null (Charlie Clarification 1) ---

test('I: once a journey has ARRIVED, snapshot.activeTravel is exactly null (not an object with status ARRIVED)',async()=>{
  setCharacter('growth-city');
  const started=await post('/api/commands/transport/bus/start',envelope('persist-I-start',{destinationCityId:'hill-market'}));
  assert.equal(started.status,'ACCEPTED');
  forceEtaPast();
  const snap=await request('/api/character/char-demo/snapshot');
  assert.equal(snap.state,'IN_CITY');
  assert.equal(snap.activeTravel,null);
});

// --- J: ARRIVED DB row remains present => status === 'ARRIVED' (no delete, no schema change) ---

test('J: after arrival, the travel DB row still exists (as history/debug evidence) with status ARRIVED — it is never deleted',async()=>{
  setCharacter('growth-city');
  const started=await post('/api/commands/transport/bus/start',envelope('persist-J-start',{destinationCityId:'starter-village'}));
  assert.equal(started.status,'ACCEPTED');
  forceEtaPast();
  await request('/api/character/char-demo/snapshot');
  const row=readTravelRow();
  assert.ok(row,'the travel row must still exist in the DB after arrival');
  assert.equal(row.status,'ARRIVED');
  assert.equal(row.to_city,'starter-village');
});

// --- K: pending battle settlement => bus rejected, wallet unchanged, no BUS_FARE transaction ---

test('K: a pending battle loot settlement blocks starting a bus, with zero debit and zero BUS_FARE transaction',async()=>{
  setCharacter('starter-village');
  const battleId=forcePendingLootSettlement();
  try{
    const beforeTx=await busTxCount(),beforeWallet=(await request('/api/character/char-demo/snapshot')).walletGold;
    const attempt=await post('/api/commands/transport/bus/start',envelope('persist-K-blocked',{destinationCityId:'harbour-city'}));
    assert.equal(attempt.status,'REJECTED');
    assert.equal(attempt.errorCode,'ERR_BATTLE_SETTLEMENT_REQUIRED');
    const snap=await request('/api/character/char-demo/snapshot');
    assert.equal(snap.walletGold,beforeWallet);
    assert.equal(snap.state,'IN_CITY');
    assert.equal(snap.activeTravel,null);
    assert.equal(await busTxCount(),beforeTx);
  }finally{clearPendingLootSettlements()}
});

// --- L: TRAVELING + world movement => rejected, movement/travel state unchanged ---

test('L: attempting world movement while TRAVELING is rejected and leaves travel/position state unchanged',async()=>{
  setCharacter('starter-village');
  const started=await post('/api/commands/transport/bus/start',envelope('persist-L-start',{destinationCityId:'growth-city'}));
  assert.equal(started.status,'ACCEPTED');
  const before=await request('/api/character/char-demo/snapshot');
  const moved=await post('/api/commands/world/move',envelope('persist-L-move',{targetX:999,targetY:999}));
  assert.equal(moved.status,'REJECTED');
  assert.equal(moved.errorCode,'ERR_INVALID_STATE');
  const after=await request('/api/character/char-demo/snapshot');
  assert.equal(after.state,'TRAVELING');
  assert.equal(after.activeTravel.toCityId,before.activeTravel.toCityId);
  assert.equal(after.activeTravel.estimatedArrivalAt,before.activeTravel.estimatedArrivalAt);
});

// --- M: new session invalidates old session => old-session bus retry cannot debit or create a journey ---

test('M: opening a new session invalidates the old one — a bus command retried under the stale session id is rejected, debits nothing, and starts no journey',async()=>{
  setCharacter('starter-village');
  const staleSessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
  const freshSessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId; // invalidates staleSessionId
  assert.notEqual(freshSessionId,staleSessionId);
  const beforeTx=await busTxCount();
  const attempt=await post('/api/commands/transport/bus/start',envelope('persist-M-stale',{destinationCityId:'harbour-city'},staleSessionId));
  assert.equal(attempt.status,'REJECTED');
  assert.equal(attempt.errorCode,'ERR_SESSION_REPLACED');
  const snap=await request('/api/character/char-demo/snapshot');
  assert.equal(snap.walletGold,1000);
  assert.equal(snap.state,'IN_CITY');
  assert.equal(snap.activeTravel,null);
  assert.equal(await busTxCount(),beforeTx);
  sessionId=freshSessionId; // restore the shared session for subsequent tests in this file
});

// --- N: insufficient funds => no debit, no journey, no BUS_FARE transaction ---
// (already covered by test/bus.test.mjs's dedicated insufficient-gold test; repeated here,
// self-contained, so this file's P2-06 test group stands on its own.)

test('N: insufficient funds makes zero debit and starts no journey, with zero BUS_FARE transactions',async()=>{
  setCharacter('growth-city',0);
  const beforeTx=await busTxCount();
  const attempt=await post('/api/commands/transport/bus/start',envelope('persist-N-insufficient',{destinationCityId:'starter-village'}));
  assert.equal(attempt.status,'REJECTED');
  assert.equal(attempt.errorCode,'ERR_INSUFFICIENT_GOLD');
  const snap=await request('/api/character/char-demo/snapshot');
  assert.equal(snap.walletGold,0);
  assert.equal(snap.state,'IN_CITY');
  assert.equal(snap.activeTravel,null);
  assert.equal(await busTxCount(),beforeTx);
});

// --- Race test: snapshot auto-arrival vs explicit resolve-arrival, both orderings, same final state ---

test('Race (snapshot -> explicit): once ETA has passed, snapshot auto-arrival followed by an explicit resolveArrival converges to the same final state, with no duplicate transaction',async()=>{
  setCharacter('starter-village');
  const quote=busQuote('starter-village','harbour-city');
  const started=await post('/api/commands/transport/bus/start',envelope('persist-race-a-start',{destinationCityId:'harbour-city'}));
  assert.equal(started.status,'ACCEPTED');
  forceEtaPast();
  const beforeTx=await busTxCount();
  const viaSnapshot=await request('/api/character/char-demo/snapshot');
  const viaExplicit=await post('/api/commands/travel/resolve-arrival',envelope('persist-race-a-explicit',{}));
  assert.equal(viaExplicit.status,'REJECTED');
  assert.equal(viaExplicit.errorCode,'ERR_NO_TRAVEL');
  const final=await request('/api/character/char-demo/snapshot');
  assert.equal(final.state,'IN_CITY');
  assert.equal(final.cityId,'harbour-city');
  assert.equal(final.walletGold,1000-quote.fareGold);
  assert.equal(final.activeTravel,null);
  assert.equal(await busTxCount(),beforeTx,'beforeTx already includes this journey\'s single fare — resolution must not add another');
  assert.equal(readTravelRow().status,'ARRIVED');
});

test('Race (explicit -> snapshot): once ETA has passed, an explicit resolveArrival followed by snapshot converges to the same final state, with no duplicate transaction',async()=>{
  setCharacter('starter-village');
  const quote=busQuote('starter-village','harbour-city');
  const started=await post('/api/commands/transport/bus/start',envelope('persist-race-b-start',{destinationCityId:'harbour-city'}));
  assert.equal(started.status,'ACCEPTED');
  forceEtaPast();
  const beforeTx=await busTxCount();
  const viaExplicit=await post('/api/commands/travel/resolve-arrival',envelope('persist-race-b-explicit',{}));
  assert.equal(viaExplicit.status,'ACCEPTED');
  assert.equal(viaExplicit.data.cityId,'harbour-city');
  const final=await request('/api/character/char-demo/snapshot');
  assert.equal(final.state,'IN_CITY');
  assert.equal(final.cityId,'harbour-city');
  assert.equal(final.walletGold,1000-quote.fareGold);
  assert.equal(final.activeTravel,null);
  assert.equal(await busTxCount(),beforeTx,'beforeTx already includes this journey\'s single fare — resolution must not add another');
  assert.equal(readTravelRow().status,'ARRIVED');
});

// --- E & F: genuine OS-level server restart, isolated from the shared child/DB above ---
// Same spawn/kill/re-spawn-against-the-same-DB-file pattern already established and proven in
// test/world-persistence.test.mjs — reused here verbatim, not reinvented, against travel/bus state.

async function spawnServer(path){
  const restartChild=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:path},stdio:['ignore','pipe','inherit']});
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

test('E: a genuine OS-level server restart mid-journey (before ETA) preserves the journey and leaves wallet unchanged',async()=>{
  const restartDir=await mkdtemp(join(tmpdir(),'myrial-bus-restart-mid-'));
  const restartDbPath=join(restartDir,'test.sqlite');
  let serverA,serverB;
  try{
    serverA=await spawnServer(restartDbPath);
    const reqA=(path,options={})=>fetch(serverA.base+path,{headers:{'content-type':'application/json'},...options}).then(r=>r.json());
    const postA=(path,body)=>reqA(path,{method:'POST',body:JSON.stringify(body)});
    const sessionA=(await postA('/api/session/open',{accountId:'account-demo'})).sessionId;
    const quote=busQuote('starter-village','growth-city');
    const started=await postA('/api/commands/transport/bus/start',{commandId:crypto.randomUUID(),idempotencyKey:'restart-mid-journey',sessionId:sessionA,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload:{destinationCityId:'growth-city'}});
    assert.equal(started.status,'ACCEPTED');
    const beforeSnap=await reqA('/api/character/char-demo/snapshot');
    assert.equal(beforeSnap.state,'TRAVELING');

    await killAndWaitForRealExit(serverA.child);
    assert.equal(serverA.child.hasExited,true,'child A must have genuinely exited before child B starts against the same DB file');

    serverB=await spawnServer(restartDbPath);
    const reqB=(path,options={})=>fetch(serverB.base+path,{headers:{'content-type':'application/json'},...options}).then(r=>r.json());
    const afterSnap=await reqB('/api/character/char-demo/snapshot');
    assert.equal(afterSnap.state,'TRAVELING');
    assert.equal(afterSnap.activeTravel.toCityId,'growth-city');
    assert.equal(afterSnap.activeTravel.estimatedArrivalAt,beforeSnap.activeTravel.estimatedArrivalAt);
    assert.equal(afterSnap.walletGold,1000-quote.fareGold);
  }finally{
    if(serverA)await killAndWaitForRealExit(serverA.child);
    if(serverB)await killAndWaitForRealExit(serverB.child);
    await rm(restartDir,{recursive:true,force:true});
  }
});

test('F: a genuine OS-level server restart after ETA has passed but before any resolution safely resolves arrival exactly once, on the first post-restart snapshot',async()=>{
  const restartDir=await mkdtemp(join(tmpdir(),'myrial-bus-restart-overdue-'));
  const restartDbPath=join(restartDir,'test.sqlite');
  let serverA,serverB;
  try{
    serverA=await spawnServer(restartDbPath);
    const reqA=(path,options={})=>fetch(serverA.base+path,{headers:{'content-type':'application/json'},...options}).then(r=>r.json());
    const postA=(path,body)=>reqA(path,{method:'POST',body:JSON.stringify(body)});
    const sessionA=(await postA('/api/session/open',{accountId:'account-demo'})).sessionId;
    const quote=busQuote('starter-village','hill-market');
    const started=await postA('/api/commands/transport/bus/start',{commandId:crypto.randomUUID(),idempotencyKey:'restart-overdue-journey',sessionId:sessionA,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload:{destinationCityId:'hill-market'}});
    assert.equal(started.status,'ACCEPTED');
    const overdue=new DatabaseSync(restartDbPath);overdue.prepare(`UPDATE travel SET eta=? WHERE character_id='char-demo'`).run(Date.now()-1);overdue.close();
    // Deliberately never call snapshot or resolve-arrival on server A — the ETA passes while the
    // process is still up, but nothing observes it before the restart.

    await killAndWaitForRealExit(serverA.child);
    assert.equal(serverA.child.hasExited,true);

    serverB=await spawnServer(restartDbPath);
    const reqB=(path,options={})=>fetch(serverB.base+path,{headers:{'content-type':'application/json'},...options}).then(r=>r.json());
    const first=await reqB('/api/character/char-demo/snapshot');
    assert.equal(first.state,'IN_CITY');
    assert.equal(first.cityId,'hill-market');
    assert.equal(first.walletGold,1000-quote.fareGold);
    assert.equal(first.activeTravel,null);
    const second=await reqB('/api/character/char-demo/snapshot');
    assert.equal(second.walletGold,first.walletGold);
    const txCount=new DatabaseSync(restartDbPath).prepare(`SELECT COUNT(*) c FROM economy_tx WHERE character_id='char-demo' AND kind='BUS_FARE'`).get().c;
    assert.equal(txCount,1,'exactly one BUS_FARE transaction, never duplicated across the restart+resolution');
  }finally{
    if(serverA)await killAndWaitForRealExit(serverA.child);
    if(serverB)await killAndWaitForRealExit(serverB.child);
    await rm(restartDir,{recursive:true,force:true});
  }
});
