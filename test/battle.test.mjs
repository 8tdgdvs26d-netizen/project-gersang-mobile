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
  dir=await mkdtemp(join(tmpdir(),'myrial-battle-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:join(dir,'test.sqlite')},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`)))});
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

test('starts a server-authoritative 5x60 battle',async()=>{
  const started=await post('/api/commands/battle/start',envelope('battle-start',{}));
  assert.equal(started.status,'ACCEPTED');
  const battle=await request('/api/character/char-demo/battle');
  assert.equal(battle.status,'ACTIVE');assert.equal(battle.rows,5);assert.equal(battle.columns,60);
  assert.equal(battle.units.filter(x=>x.side==='PLAYER').length,3);assert.equal(battle.units.filter(x=>x.side==='ENEMY').length,3);
});

test('rejects movement outside the battlefield and enemy control',async()=>{
  const outside=await post('/api/commands/battle/move',envelope('move-outside',{unitId:'hero',row:5,col:60}));
  assert.equal(outside.errorCode,'ERR_OUT_OF_BOUNDS');
  const enemy=await post('/api/commands/battle/move',envelope('move-enemy',{unitId:'bandit-a',row:1,col:10}));
  assert.equal(enemy.errorCode,'ERR_UNIT_NOT_CONTROLLABLE');
});

test('movement command is idempotent and server advances the unit',async()=>{
  const body=envelope('move-hero',{unitId:'hero',row:2,col:20});
  const first=await post('/api/commands/battle/move',body),retry=await post('/api/commands/battle/move',body);
  assert.deepEqual(retry,first);
  await new Promise(r=>setTimeout(r,650));
  const battle=await request('/api/character/char-demo/battle'),hero=battle.units.find(x=>x.id==='hero');
  assert.ok(hero.col>2);assert.deepEqual(hero.destination,{row:2,col:20});
});

test('group movement assigns unique formation destinations near the chosen cell',async()=>{
  const body=envelope('formation-move',{unitIds:['hero','archer','guard'],row:4,col:25});
  const first=await post('/api/commands/battle/move',body),retry=await post('/api/commands/battle/move',body);
  assert.deepEqual(retry,first);assert.equal(first.data.destinations.length,3);
  const cells=first.data.destinations.map(x=>`${x.row}:${x.col}`);
  assert.equal(new Set(cells).size,3);assert.ok(cells.includes('4:25'));
  assert.ok(first.data.destinations.every(x=>Math.max(Math.abs(x.row-4),Math.abs(x.col-25))<=1));
  const battle=await request('/api/character/char-demo/battle');
  assert.equal(new Set(battle.units.filter(x=>x.side==='PLAYER').map(x=>`${x.destination.row}:${x.destination.col}`)).size,3);
});

test('player unit can lock an enemy target',async()=>{
  const targeted=await post('/api/commands/battle/target',envelope('target-bandit',{unitId:'archer',targetId:'bandit-a'}));
  assert.equal(targeted.status,'ACCEPTED');
  const battle=await request('/api/character/char-demo/battle');
  assert.equal(battle.units.find(x=>x.id==='archer').targetId,'bandit-a');
});

test('multiple selected units lock the same target with one idempotent command',async()=>{
  const body=envelope('group-target',{unitIds:['hero','archer','guard'],targetId:'bandit-a'});
  const first=await post('/api/commands/battle/target',body),retry=await post('/api/commands/battle/target',body);
  assert.deepEqual(retry,first);assert.deepEqual([...first.data.unitIds].sort(),['archer','guard','hero']);
  const battle=await request('/api/character/char-demo/battle');
  assert.ok(battle.units.filter(x=>x.side==='PLAYER').every(x=>x.targetId==='bandit-a'));
});

test('locked target takes automatic basic-attack damage in range',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE battle_units SET row_no=1,col_no=53 WHERE id='archer'`).run();fixture.close();
  await new Promise(r=>setTimeout(r,800));
  const battle=await request('/api/character/char-demo/battle');
  assert.ok(battle.units.find(x=>x.id==='bandit-a').hp<65);
});

test('group members automatically acquire another enemy after their target dies',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE battle_units SET hp=0,alive=0 WHERE id='bandit-a'`).run();fixture.close();
  await new Promise(r=>setTimeout(r,350));
  const battle=await request('/api/character/char-demo/battle'),players=battle.units.filter(x=>x.side==='PLAYER'&&x.alive);
  assert.ok(players.every(x=>['bandit-b','bandit-c'].includes(x.targetId)));
});

test('idle player unit automatically attacks an enemy already in range',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE battle_units SET row_no=2,col_no=54,target_id=NULL,last_attack_at=0 WHERE id='hero'`).run();fixture.close();
  await new Promise(r=>setTimeout(r,800));
  const battle=await request('/api/character/char-demo/battle'),hero=battle.units.find(x=>x.id==='hero'),bandit=battle.units.find(x=>x.id==='bandit-b');
  assert.equal(hero.targetId,'bandit-b');assert.ok(bandit.hp<65);
});
