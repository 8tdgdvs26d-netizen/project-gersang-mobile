import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {MOVE_CATCHUP_CAP_MS} from '../public/movement.js';
import {WORLD_MONSTER_DEFINITIONS} from '../public/worldmonsters.js';

// P4-02 — First World Monster -> Encounter -> Battle Handoff. Covers acceptance tests P4-02-A
// through P4-02-K from the approved Coding Order (P4-02-L, the full-suite regression count, is
// reported at the npm-test level, not as an individual test here). Follows the exact real-server
// spawn pattern already used by test/battle.test.mjs / test/world-movement.test.mjs / etc.

let child,base,dir,sessionId;
const request=async(path,options={})=>{const r=await fetch(base+path,{headers:{'content-type':'application/json'},...options});return r.json()};
const post=(path,body)=>request(path,{method:'POST',body:JSON.stringify(body)});
const envelope=(key,payload)=>({commandId:crypto.randomUUID(),idempotencyKey:key,sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const setPosition=(x,y,state)=>{const fixture=new DatabaseSync(join(dir,'test.sqlite'));fixture.prepare(`UPDATE characters SET world_x=?,world_y=?,state=? WHERE id='char-demo'`).run(x,y,state);fixture.close()};
const rawQuery=(sql,...params)=>{const fixture=new DatabaseSync(join(dir,'test.sqlite'));const rows=fixture.prepare(sql).all(...params);fixture.close();return rows};

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-world-encounter-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:join(dir,'test.sqlite')},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`))) });
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

// P4-02-A: monster definition has stable id, level, position, encounter radius, encounter link, active.
test('P4-02-A: world monster data contract has a stable id, level, position, encounter radius, encounter link and active flag',()=>{
  assert.equal(WORLD_MONSTER_DEFINITIONS.length,1);
  const m=WORLD_MONSTER_DEFINITIONS[0];
  assert.equal(m.id,'world-bandit-1');
  assert.equal(typeof m.displayName,'string');
  assert.equal(m.level,1);
  assert.equal(m.encounterId,'bandit-patrol');
  assert.deepEqual(m.position,{x:500,y:220});
  assert.equal(m.encounterRadius,40);
  assert.equal(m.active,true);
  assert.ok(Object.isFrozen(WORLD_MONSTER_DEFINITIONS));
  assert.ok(Object.isFrozen(m));
});

// P4-02-B: before trigger, snapshot.worldMonsters contains world-bandit-1.
test('P4-02-B: snapshot.worldMonsters exposes world-bandit-1 before any encounter is triggered',async()=>{
  const snap=await request('/api/character/char-demo/snapshot');
  assert.ok(Array.isArray(snap.worldMonsters));
  const monster=snap.worldMonsters.find(m=>m.id==='world-bandit-1');
  assert.ok(monster,'expected world-bandit-1 to be present in snapshot.worldMonsters');
  assert.equal(monster.displayName,'遊蕩山賊');
  assert.equal(monster.level,1);
  assert.deepEqual(monster.position,{x:500,y:220});
  assert.equal(monster.encounterRadius,40);
  // The client must never be able to self-trigger a battle from this list — encounterId is not
  // part of the minimum required shape and is deliberately withheld here.
  assert.equal(monster.encounterId,undefined);
});

// P4-02-C: a movement segment that never touches the encounter radius must not trigger a battle,
// and the monster must remain available afterwards.
test('P4-02-C: normal movement whose segment stays outside the encounter radius does not trigger a battle',async()=>{
  await wait(MOVE_CATCHUP_CAP_MS+100);
  setPosition(300,220,'IN_WORLD');
  const moved=await post('/api/commands/world/move',envelope('move-outside-radius',{targetX:260,targetY:220}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(moved.data.encounterTriggered,undefined);
  const battle=await request('/api/character/char-demo/battle');
  assert.equal(battle,null);
  const snap=await request('/api/character/char-demo/snapshot');
  assert.ok(snap.worldMonsters.some(m=>m.id==='world-bandit-1'));
});

// P4-02-D + P4-02-E: a movement segment that starts outside the encounter radius, ends outside the
// encounter radius, but sweeps through it (tunnelling) must still trigger the encounter — and must
// do so exactly once: exactly one ACTIVE battle, exactly one persistent world_monster_encounters row.
test('P4-02-D/E: a swept movement segment that tunnels through the encounter radius triggers the encounter exactly once',async()=>{
  await wait(MOVE_CATCHUP_CAP_MS+100);
  // from (450,200) to (550,200): both endpoints are ~53.9px from the monster center (500,220),
  // outside the 40px radius, but the straight segment passes within 20px of the center at its
  // midpoint — a pure endpoint-distance check would miss this; the swept-circle check must not.
  setPosition(450,200,'IN_WORLD');
  const before=await request('/api/character/char-demo/snapshot');
  assert.equal(Math.hypot(before.worldPosition.x-500,before.worldPosition.y-220)>40,true);
  const moved=await post('/api/commands/world/move',envelope('move-encounter-trigger',{targetX:550,targetY:200}));
  assert.equal(moved.status,'ACCEPTED');
  assert.equal(Math.hypot(moved.data.worldPosition.x-500,moved.data.worldPosition.y-220)>40,true);
  assert.equal(moved.data.encounterTriggered,true);
  assert.equal(moved.data.monsterId,'world-bandit-1');
  assert.equal(typeof moved.data.battleId,'string');
  assert.ok(moved.data.battleId.length>0);
  // characters.state stays IN_WORLD — a world encounter is expressed entirely via battles.status,
  // never by repurposing characters.state (see battleIsActive()'s own comment in server.mjs).
  assert.equal(moved.data.state,'IN_WORLD');
  const battle=await request('/api/character/char-demo/battle');
  assert.equal(battle.status,'ACTIVE');
  assert.equal(battle.id,moved.data.battleId);
  assert.equal(battle.units.filter(x=>x.side==='PLAYER').length,3);
  assert.equal(battle.units.filter(x=>x.side==='ENEMY').length,3);
  const activeBattles=rawQuery(`SELECT id FROM battles WHERE character_id='char-demo' AND status='ACTIVE'`);
  assert.equal(activeBattles.length,1);
  const encounterRows=rawQuery(`SELECT * FROM world_monster_encounters WHERE character_id='char-demo' AND monster_id='world-bandit-1'`);
  assert.equal(encounterRows.length,1);
  assert.equal(encounterRows[0].battle_id,moved.data.battleId);
  const snap=await request('/api/character/char-demo/snapshot');
  assert.ok(!snap.worldMonsters.some(m=>m.id==='world-bandit-1'),'consumed monster must disappear from worldMonsters');
});

// P4-02-F: once a world-triggered battle is ACTIVE, further world movement is rejected and the
// server-side position is left completely unchanged.
test('P4-02-F: world movement is locked with ERR_BATTLE_ACTIVE while the triggered battle is ACTIVE, and position stays unchanged',async()=>{
  const before=await request('/api/character/char-demo/snapshot');
  const moved=await post('/api/commands/world/move',envelope('move-while-battle-active',{targetX:before.worldPosition.x+50,targetY:before.worldPosition.y}));
  assert.equal(moved.status,'REJECTED');
  assert.equal(moved.errorCode,'ERR_BATTLE_ACTIVE');
  const after=await request('/api/character/char-demo/snapshot');
  assert.deepEqual(after.worldPosition,before.worldPosition);
});

// P4-02-G: an ACTIVE world-triggered battle must also block escaping the fight through city entry,
// even when the server position would otherwise qualify for it.
test('P4-02-G: city entry is rejected with ERR_BATTLE_ACTIVE while the triggered battle is ACTIVE, even from a position that would otherwise qualify',async()=>{
  const cities=await request('/api/cities');
  const starter=cities.find(c=>c.id==='starter-village');
  setPosition(starter.coordinates.x,starter.coordinates.y,'IN_WORLD');
  const entered=await post('/api/commands/city/enter',envelope('enter-while-battle-active',{destinationCityId:'starter-village'}));
  assert.equal(entered.status,'REJECTED');
  assert.equal(entered.errorCode,'ERR_BATTLE_ACTIVE');
  const snap=await request('/api/character/char-demo/snapshot');
  assert.equal(snap.state,'IN_WORLD');
});

// P4-02-H: retry safety. Re-sending the exact same idempotencyKey that triggered the battle must
// not create a second battle (idem() cache), and re-sending movement across the (now-consumed,
// now-blocked) monster under a different key must not create a second battle either.
test('P4-02-H: retrying the same idempotencyKey and re-sending movement under a different key never creates a second battle',async()=>{
  const first=await request('/api/character/char-demo/battle');
  const retrySameKey=await post('/api/commands/world/move',envelope('move-encounter-trigger',{targetX:550,targetY:200}));
  assert.equal(retrySameKey.status,'ACCEPTED');
  assert.equal(retrySameKey.data.battleId,first.id);
  const retryDifferentKey=await post('/api/commands/world/move',envelope('move-encounter-retry-different-key',{targetX:551,targetY:201}));
  assert.equal(retryDifferentKey.status,'REJECTED');
  assert.equal(retryDifferentKey.errorCode,'ERR_BATTLE_ACTIVE');
  const activeBattles=rawQuery(`SELECT id FROM battles WHERE character_id='char-demo' AND status='ACTIVE'`);
  assert.equal(activeBattles.length,1);
  const encounterRows=rawQuery(`SELECT * FROM world_monster_encounters WHERE character_id='char-demo' AND monster_id='world-bandit-1'`);
  assert.equal(encounterRows.length,1);
});

// P4-02-K: battle end unlock. Retreating from the triggered battle ends it; once there is no
// longer an ACTIVE battle (and no pending loot settlement, which retreat never creates), world
// movement must become acceptable again via the existing, unmodified battle-lifecycle machinery.
test('P4-02-K: retreating from the triggered battle unlocks world movement again',async()=>{
  const retreated=await post('/api/commands/battle/retreat',envelope('retreat-world-encounter',{}));
  assert.equal(retreated.status,'ACCEPTED');
  const battle=await request('/api/character/char-demo/battle');
  assert.equal(battle.status,'RETREATED');
  await wait(MOVE_CATCHUP_CAP_MS+100);
  const before=await request('/api/character/char-demo/snapshot');
  const moved=await post('/api/commands/world/move',envelope('move-after-retreat',{targetX:before.worldPosition.x+30,targetY:before.worldPosition.y}));
  assert.equal(moved.status,'ACCEPTED');
  assert.notDeepEqual(moved.data.worldPosition,before.worldPosition);
  const activeBattles=rawQuery(`SELECT id FROM battles WHERE character_id='char-demo' AND status='ACTIVE'`);
  assert.equal(activeBattles.length,0);
});

// P4-02-I: snapshot/reload. Repeated GETs never re-trigger anything (GET performs no movement),
// the battle id stays the same across reloads, and the consumed monster stays absent.
test('P4-02-I: repeated snapshot/battle reads are stable across reload — no re-trigger, stable battle id, monster stays consumed',async()=>{
  const battleBefore=await request('/api/character/char-demo/battle');
  const snap1=await request('/api/character/char-demo/snapshot');
  const snap2=await request('/api/character/char-demo/snapshot');
  const battleAfter=await request('/api/character/char-demo/battle');
  assert.equal(battleBefore.id,battleAfter.id);
  assert.deepEqual(snap1.worldMonsters,snap2.worldMonsters);
  assert.ok(!snap1.worldMonsters.some(m=>m.id==='world-bandit-1'));
  assert.ok(!snap2.worldMonsters.some(m=>m.id==='world-bandit-1'));
  const activeBattles=rawQuery(`SELECT id FROM battles WHERE character_id='char-demo' AND status='ACTIVE'`);
  assert.equal(activeBattles.length,0);
});

// P4-02-J: the existing manual city battle path is completely unchanged by the P4-02 refactor —
// IN_CITY still starts a battle normally via the public /battle/start route, and IN_WORLD is still
// rejected with ERR_INVALID_STATE (proving startBattle()'s precondition was never loosened to
// IN_CITY || IN_WORLD, which the Coding Order explicitly called an exploitable backdoor).
test('P4-02-J: the existing manual /battle/start route is unaffected — still IN_CITY-only, IN_WORLD still ERR_INVALID_STATE',async()=>{
  setPosition(220,220,'IN_WORLD');
  const fromWorld=await post('/api/commands/battle/start',envelope('manual-battle-from-world',{}));
  assert.equal(fromWorld.status,'REJECTED');
  assert.equal(fromWorld.errorCode,'ERR_INVALID_STATE');
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE characters SET state='IN_CITY',city_id='starter-village' WHERE id='char-demo'`).run();
  fixture.close();
  const fromCity=await post('/api/commands/battle/start',envelope('manual-battle-from-city',{}));
  assert.equal(fromCity.status,'ACCEPTED');
  const battle=await request('/api/character/char-demo/battle');
  assert.equal(battle.status,'ACTIVE');
  assert.equal(battle.units.filter(x=>x.side==='PLAYER').length,3);
  assert.equal(battle.units.filter(x=>x.side==='ENEMY').length,3);
});
