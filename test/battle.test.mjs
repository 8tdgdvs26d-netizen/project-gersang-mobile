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

test('movement clears melee lock but preserves ranged lock',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE battle_units SET target_id='bandit-b' WHERE id IN ('hero','archer')`).run();fixture.close();
  await post('/api/commands/battle/move',envelope('role-move',{unitIds:['hero','archer'],row:2,col:30}));
  const check=new DatabaseSync(join(dir,'test.sqlite'));
  const hero=check.prepare(`SELECT target_id FROM battle_units WHERE id='hero'`).get(),archer=check.prepare(`SELECT target_id FROM battle_units WHERE id='archer'`).get();check.close();
  assert.equal(hero.target_id,null);assert.equal(archer.target_id,'bandit-b');
});

test('ranged unit can move and damage its locked target simultaneously',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE battle_units SET row_no=1,col_no=53,dest_row=NULL,dest_col=NULL,target_id='bandit-c',last_attack_at=0 WHERE id='archer'`).run();
  const before=fixture.prepare(`SELECT hp FROM battle_units WHERE id='bandit-c'`).get().hp;fixture.close();
  await post('/api/commands/battle/move',envelope('ranged-move-fire',{unitIds:['archer'],row:0,col:50}));
  await new Promise(r=>setTimeout(r,800));
  const battle=await request('/api/character/char-demo/battle'),archer=battle.units.find(x=>x.id==='archer'),bandit=battle.units.find(x=>x.id==='bandit-c');
  assert.ok(archer.col<53);assert.ok(bandit.hp<before);
});

test('locked target takes automatic basic-attack damage in range',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE battle_units SET row_no=1,col_no=53,target_id='bandit-a',last_attack_at=0 WHERE id='archer'`).run();fixture.close();
  await new Promise(r=>setTimeout(r,800));
  const battle=await request('/api/character/char-demo/battle');
  assert.ok(battle.units.find(x=>x.id==='bandit-a').hp<65);
});

test('group members automatically acquire another enemy after their target dies',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite'));
  fixture.prepare(`UPDATE battle_units SET target_id='bandit-a' WHERE side='PLAYER'`).run();
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

test('heavy strike is server-authoritative, idempotent, and starts cooldown',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite')),now=Date.now();
  fixture.prepare(`UPDATE battles SET status='ACTIVE',updated_at=?`).run(now);
  fixture.prepare(`UPDATE battle_units SET row_no=2,col_no=10,target_id=NULL,dest_row=NULL,dest_col=NULL,last_attack_at=? WHERE id='hero'`).run(now);
  fixture.prepare(`UPDATE battle_units SET row_no=2,col_no=12,hp=55,alive=1 WHERE id='bandit-c'`).run();
  fixture.prepare(`DELETE FROM battle_skill_cooldowns`).run();fixture.close();
  const body=envelope('heavy-strike-once',{unitId:'hero',skillId:'heavy-strike',targetId:'bandit-c'});
  const first=await post('/api/commands/battle/skill',body),retry=await post('/api/commands/battle/skill',body);
  assert.deepEqual(retry,first);assert.equal(first.status,'ACCEPTED');assert.equal(first.data.damage,32);assert.equal(first.data.targetHp,23);assert.deepEqual(first.data.targetPosition,{row:2,col:12});
  const battle=await request('/api/character/char-demo/battle'),hero=battle.units.find(x=>x.id==='hero');
  assert.equal(battle.units.find(x=>x.id==='bandit-c').hp,23);assert.ok(hero.skills.find(x=>x.id==='heavy-strike').readyInMs>0);
  const cooldown=await post('/api/commands/battle/skill',envelope('heavy-strike-too-soon',{unitId:'hero',skillId:'heavy-strike',targetId:'bandit-c'}));
  assert.equal(cooldown.errorCode,'ERR_SKILL_COOLDOWN');
});

test('heavy strike rejects out-of-range targets without damage',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite')),now=Date.now();
  fixture.prepare(`UPDATE battles SET status='ACTIVE',updated_at=?`).run(now);
  fixture.prepare(`UPDATE battle_units SET row_no=2,col_no=0,target_id=NULL WHERE id='hero'`).run();
  fixture.prepare(`UPDATE battle_units SET row_no=2,col_no=20,hp=55,alive=1 WHERE id='bandit-c'`).run();
  fixture.prepare(`UPDATE battle_skill_cooldowns SET ready_at=0 WHERE unit_id='hero' AND skill_id='heavy-strike'`).run();fixture.close();
  const result=await post('/api/commands/battle/skill',envelope('heavy-strike-far',{unitId:'hero',skillId:'heavy-strike',targetId:'bandit-c'}));
  assert.equal(result.errorCode,'ERR_SKILL_OUT_OF_RANGE');
  const check=new DatabaseSync(join(dir,'test.sqlite'));assert.equal(check.prepare(`SELECT hp FROM battle_units WHERE id='bandit-c'`).get().hp,55);check.close();
});

test('archer has an independent ranged skill and cooldown',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite')),now=Date.now();
  fixture.prepare(`UPDATE battles SET status='ACTIVE',updated_at=?`).run(now);
  fixture.prepare(`UPDATE battle_units SET row_no=1,col_no=10,target_id=NULL,dest_row=NULL,dest_col=NULL WHERE id='archer'`).run();
  fixture.prepare(`UPDATE battle_units SET row_no=1,col_no=17,hp=65,alive=1 WHERE id='bandit-b'`).run();
  fixture.prepare(`DELETE FROM battle_skill_cooldowns WHERE unit_id='archer'`).run();fixture.close();
  const result=await post('/api/commands/battle/skill',envelope('heartseeker-once',{unitId:'archer',skillId:'heartseeker-arrow',targetId:'bandit-b'}));
  assert.equal(result.status,'ACCEPTED');assert.equal(result.data.skillName,'穿心箭');assert.equal(result.data.damage,24);assert.equal(result.data.targetHp,41);
  const battle=await request('/api/character/char-demo/battle'),archer=battle.units.find(x=>x.id==='archer');
  assert.ok(archer.skills.find(x=>x.id==='heartseeker-arrow').readyInMs>0);
});

test('iron wall is self-targeted and halves incoming damage',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite')),now=Date.now();
  fixture.prepare(`UPDATE battles SET status='ACTIVE',updated_at=?`).run(now);
  fixture.prepare(`UPDATE battle_units SET row_no=2,col_no=54,hp=120,alive=1,target_id=NULL,dest_row=NULL,dest_col=NULL WHERE id='guard'`).run();
  fixture.prepare(`UPDATE battle_units SET row_no=2,col_no=56,hp=65,alive=1,target_id='guard',dest_row=NULL,dest_col=NULL,last_attack_at=0 WHERE id='bandit-a'`).run();
  fixture.prepare(`UPDATE battle_units SET row_no=0,col_no=0,target_id=NULL WHERE id='bandit-b'`).run();
  fixture.prepare(`UPDATE battle_units SET row_no=0,col_no=1,target_id=NULL WHERE id='bandit-c'`).run();
  fixture.prepare(`DELETE FROM battle_skill_cooldowns WHERE unit_id='guard'`).run();fixture.close();
  const result=await post('/api/commands/battle/skill',envelope('iron-wall-once',{unitId:'guard',skillId:'iron-wall'}));
  assert.equal(result.status,'ACCEPTED');assert.equal(result.data.effectId,'iron-wall');assert.equal(result.data.damage,0);
  const armed=new DatabaseSync(join(dir,'test.sqlite'));
  assert.equal(armed.prepare(`SELECT value FROM battle_status_effects WHERE unit_id='guard' AND effect_id='iron-wall'`).get().value,.5);
  armed.prepare(`UPDATE battle_units SET hp=120 WHERE id='guard'`).run();
  armed.prepare(`UPDATE battle_units SET last_attack_at=0 WHERE id='bandit-a'`).run();
  armed.prepare(`UPDATE battles SET updated_at=?`).run(Date.now());armed.close();
  await new Promise(r=>setTimeout(r,350));
  const battle=await request('/api/character/char-demo/battle'),guard=battle.units.find(x=>x.id==='guard');
  assert.equal(guard.hp,115);assert.ok(guard.statusEffects.find(x=>x.id==='iron-wall').expiresInMs>0);assert.ok(guard.skills.find(x=>x.id==='iron-wall').readyInMs>0);
});

test('arrow rain damages every enemy in its ground-targeted area',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite')),now=Date.now();
  fixture.prepare(`UPDATE battles SET status='ACTIVE',updated_at=?`).run(now);
  fixture.prepare(`UPDATE battle_units SET row_no=2,col_no=10,target_id=NULL,dest_row=NULL,dest_col=NULL,last_attack_at=? WHERE id='archer'`).run(now);
  fixture.prepare(`UPDATE battle_units SET row_no=2,col_no=16,hp=65,alive=1,last_attack_at=? WHERE id='bandit-a'`).run(now);
  fixture.prepare(`UPDATE battle_units SET row_no=1,col_no=16,hp=65,alive=1,last_attack_at=? WHERE id='bandit-b'`).run(now);
  fixture.prepare(`UPDATE battle_units SET row_no=4,col_no=20,hp=55,alive=1,last_attack_at=? WHERE id='bandit-c'`).run(now);
  fixture.prepare(`DELETE FROM battle_skill_cooldowns WHERE unit_id='archer' AND skill_id='arrow-rain'`).run();fixture.close();
  const result=await post('/api/commands/battle/skill',envelope('arrow-rain-once',{unitId:'archer',skillId:'arrow-rain',row:2,col:16}));
  assert.equal(result.status,'ACCEPTED');assert.equal(result.data.hits.length,2);assert.equal(result.data.damage,36);
  const battle=await request('/api/character/char-demo/battle');
  assert.equal(battle.units.find(x=>x.id==='bandit-a').hp,47);assert.equal(battle.units.find(x=>x.id==='bandit-b').hp,47);assert.equal(battle.units.find(x=>x.id==='bandit-c').hp,55);
  assert.ok(battle.units.find(x=>x.id==='archer').skills.find(x=>x.id==='arrow-rain').readyInMs>0);
});

test('heavy strike removes a defeated target immediately',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite')),now=Date.now();
  fixture.prepare(`UPDATE battles SET status='ACTIVE',updated_at=?`).run(now);
  fixture.prepare(`UPDATE battle_units SET row_no=2,col_no=10,target_id=NULL WHERE id='hero'`).run();
  fixture.prepare(`UPDATE battle_units SET row_no=2,col_no=12,hp=20,alive=1 WHERE id='bandit-c'`).run();
  fixture.prepare(`UPDATE battle_skill_cooldowns SET ready_at=0 WHERE unit_id='hero' AND skill_id='heavy-strike'`).run();fixture.close();
  const result=await post('/api/commands/battle/skill',envelope('heavy-strike-kill',{unitId:'hero',skillId:'heavy-strike',targetId:'bandit-c'}));
  assert.equal(result.status,'ACCEPTED');assert.equal(result.data.killed,true);
  const battle=await request('/api/character/char-demo/battle');assert.equal(battle.units.find(x=>x.id==='bandit-c').alive,false);
});

test('victory grants one persistent gold reward and transaction',async()=>{
  const fixture=new DatabaseSync(join(dir,'test.sqlite')),before=fixture.prepare(`SELECT wallet FROM characters WHERE id='char-demo'`).get().wallet;
  fixture.prepare(`UPDATE battles SET status='ACTIVE',updated_at=?`).run(Date.now());
  fixture.prepare(`UPDATE battle_units SET hp=0,alive=0 WHERE side='ENEMY'`).run();fixture.close();
  const victory=await request('/api/character/char-demo/battle');assert.equal(victory.status,'VICTORY');assert.equal(victory.reward.gold,100);
  await request('/api/character/char-demo/battle');
  const check=new DatabaseSync(join(dir,'test.sqlite'));
  assert.equal(check.prepare(`SELECT wallet FROM characters WHERE id='char-demo'`).get().wallet,before+100);
  assert.equal(check.prepare(`SELECT COUNT(*) count FROM battle_rewards WHERE battle_id=?`).get(victory.id).count,1);
  const tx=check.prepare(`SELECT kind,gold_delta FROM economy_tx WHERE id=?`).get(`battle-reward:${victory.id}`);check.close();
  assert.equal(tx.kind,'BATTLE_REWARD');assert.equal(tx.gold_delta,100);
});
