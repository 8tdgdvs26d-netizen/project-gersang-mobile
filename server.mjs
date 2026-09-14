import { createServer } from "node:http";
import { readFileSync, existsSync, mkdirSync } from "node:fs";
import { extname, join, normalize, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { createHash, randomUUID } from "node:crypto";

const __dirname = fileURLToPath(new URL(".", import.meta.url));
const PUBLIC_DIR = join(__dirname, "public");
const DB_PATH = process.env.DB_PATH ?? join(__dirname, "first-playable.sqlite");
const PORT = Number(process.env.PORT ?? 8788);
mkdirSync(dirname(DB_PATH), { recursive: true });

const db = new DatabaseSync(DB_PATH);
db.exec(`
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS accounts(id TEXT PRIMARY KEY, active_session_id TEXT);
CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, account_id TEXT NOT NULL, state TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS characters(id TEXT PRIMARY KEY, account_id TEXT NOT NULL, city_id TEXT NOT NULL, state TEXT NOT NULL, wallet INTEGER NOT NULL CHECK(wallet>=0), cargo_capacity INTEGER NOT NULL CHECK(cargo_capacity>=0));
CREATE TABLE IF NOT EXISTS cargo(character_id TEXT NOT NULL, good_id TEXT NOT NULL, quantity INTEGER NOT NULL CHECK(quantity>=0), cargo_units INTEGER NOT NULL CHECK(cargo_units>0), PRIMARY KEY(character_id,good_id));
CREATE TABLE IF NOT EXISTS storage(character_id TEXT NOT NULL, city_id TEXT NOT NULL, good_id TEXT NOT NULL, quantity INTEGER NOT NULL CHECK(quantity>=0), PRIMARY KEY(character_id,city_id,good_id));
CREATE TABLE IF NOT EXISTS market(city_id TEXT NOT NULL, good_id TEXT NOT NULL, stock INTEGER NOT NULL CHECK(stock>=0), ref_price INTEGER NOT NULL CHECK(ref_price>0), spread INTEGER NOT NULL CHECK(spread>=0), version INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(city_id,good_id));
CREATE TABLE IF NOT EXISTS roads(id TEXT PRIMARY KEY, from_city TEXT NOT NULL, to_city TEXT NOT NULL, travel_ms INTEGER NOT NULL CHECK(travel_ms>0));
CREATE TABLE IF NOT EXISTS travel(character_id TEXT PRIMARY KEY, from_city TEXT NOT NULL, to_city TEXT NOT NULL, route_json TEXT NOT NULL, started_at INTEGER NOT NULL, eta INTEGER NOT NULL, status TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS idempo(key TEXT PRIMARY KEY, payload_hash TEXT NOT NULL, result_json TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS economy_tx(id TEXT PRIMARY KEY, character_id TEXT NOT NULL, kind TEXT NOT NULL, gold_delta INTEGER NOT NULL, city_id TEXT NOT NULL, good_id TEXT, quantity INTEGER, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS item_trace(id TEXT PRIMARY KEY, character_id TEXT NOT NULL, good_id TEXT NOT NULL, quantity_delta INTEGER NOT NULL, reason TEXT NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS battles(id TEXT PRIMARY KEY, character_id TEXT NOT NULL, status TEXT NOT NULL, updated_at INTEGER NOT NULL, created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS battle_units(battle_id TEXT NOT NULL, id TEXT NOT NULL, side TEXT NOT NULL, name TEXT NOT NULL, role TEXT NOT NULL, row_no INTEGER NOT NULL, col_no INTEGER NOT NULL, dest_row INTEGER, dest_col INTEGER, hp INTEGER NOT NULL, max_hp INTEGER NOT NULL, attack_power INTEGER NOT NULL, attack_range INTEGER NOT NULL, attack_interval INTEGER NOT NULL, last_attack_at INTEGER NOT NULL, target_id TEXT, alive INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(battle_id,id));
CREATE TABLE IF NOT EXISTS battle_skill_cooldowns(battle_id TEXT NOT NULL, unit_id TEXT NOT NULL, skill_id TEXT NOT NULL, ready_at INTEGER NOT NULL, PRIMARY KEY(battle_id,unit_id,skill_id));
CREATE TABLE IF NOT EXISTS battle_status_effects(battle_id TEXT NOT NULL, unit_id TEXT NOT NULL, effect_id TEXT NOT NULL, value REAL NOT NULL, expires_at INTEGER NOT NULL, PRIMARY KEY(battle_id,unit_id,effect_id));
CREATE TABLE IF NOT EXISTS roster_units(character_id TEXT NOT NULL, unit_id TEXT NOT NULL, name TEXT NOT NULL, level INTEGER NOT NULL DEFAULT 1 CHECK(level>=1), xp INTEGER NOT NULL DEFAULT 0 CHECK(xp>=0), PRIMARY KEY(character_id,unit_id));
CREATE TABLE IF NOT EXISTS battle_rewards(battle_id TEXT PRIMARY KEY, character_id TEXT NOT NULL, gold INTEGER NOT NULL CHECK(gold>=0), granted_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS battle_xp_rewards(battle_id TEXT NOT NULL, unit_id TEXT NOT NULL, xp INTEGER NOT NULL CHECK(xp>=0), PRIMARY KEY(battle_id,unit_id));
DROP TRIGGER IF EXISTS grant_battle_reward;
CREATE TRIGGER grant_battle_reward AFTER INSERT ON battle_rewards BEGIN
  UPDATE characters SET wallet=wallet+NEW.gold WHERE id=NEW.character_id;
  INSERT OR IGNORE INTO economy_tx(id,character_id,kind,gold_delta,city_id,good_id,quantity,created_at)
  SELECT 'battle-reward:'||NEW.battle_id,NEW.character_id,'BATTLE_REWARD',NEW.gold,city_id,NULL,NULL,NEW.granted_at FROM characters WHERE id=NEW.character_id;
END;
DROP TRIGGER IF EXISTS grant_battle_xp;
CREATE TRIGGER grant_battle_xp AFTER INSERT ON battle_xp_rewards BEGIN
  UPDATE roster_units SET xp=xp+NEW.xp,level=1+CAST((xp+NEW.xp)/100 AS INTEGER) WHERE character_id='char-demo' AND unit_id=NEW.unit_id;
END;
`);

function seed(){
  db.prepare(`INSERT OR IGNORE INTO accounts(id) VALUES('account-demo')`).run();
  db.prepare(`INSERT OR IGNORE INTO characters VALUES('char-demo','account-demo','starter-village','IN_CITY',1000,20)`).run();
  const markets=[
    ['starter-village','rice',100,10,2,1],['starter-village','tea',100,14,3,1],
    ['harbour-city','rice',100,18,2,1],['harbour-city','tea',100,9,2,1],
    ['hill-market','rice',100,13,2,1],['hill-market','tea',100,20,3,1]
  ];
  const m=db.prepare(`INSERT OR IGNORE INTO market VALUES(?,?,?,?,?,?)`); for(const r of markets)m.run(...r);
  const roads=[
    ['ab','starter-village','harbour-city',8000],['ba','harbour-city','starter-village',8000],
    ['bc','harbour-city','hill-market',10000],['cb','hill-market','harbour-city',10000],
    ['ac','starter-village','hill-market',22000],['ca','hill-market','starter-village',22000]
  ];
  const rr=db.prepare(`INSERT OR IGNORE INTO roads VALUES(?,?,?,?)`); for(const r of roads)rr.run(...r);
  const roster=db.prepare(`INSERT OR IGNORE INTO roster_units VALUES('char-demo',?,?,1,0)`);for(const r of [['hero','主角'],['archer','弓手'],['guard','護衛']])roster.run(...r);
}
seed();

const cities=[{id:'starter-village',name:'Starter Village'},{id:'harbour-city',name:'Harbour City'},{id:'hill-market',name:'Hill Market'}];
const cargoUnits={rice:1,tea:1,cloth:2,iron:3,timber:4};
const h=x=>createHash('sha256').update(JSON.stringify(x)).digest('hex');
const reply=(res,status,body)=>{res.writeHead(status,{'content-type':'application/json; charset=utf-8','cache-control':'no-store'});res.end(JSON.stringify(body));};
const readBody=req=>new Promise((resolve,reject)=>{let s='';req.on('data',c=>s+=c);req.on('end',()=>{try{resolve(s?JSON.parse(s):{})}catch(e){reject(e)}});req.on('error',reject)});

function snapshot(){
  const c=db.prepare(`SELECT * FROM characters WHERE id='char-demo'`).get();
  const stacks=db.prepare(`SELECT good_id,quantity,cargo_units FROM cargo WHERE character_id='char-demo' AND quantity>0`).all();
  const used=stacks.reduce((n,s)=>n+s.quantity*s.cargo_units,0);
  const t=db.prepare(`SELECT * FROM travel WHERE character_id='char-demo'`).get();
  return {accountId:c.account_id,characterId:c.id,cityId:c.city_id,state:c.state,walletGold:c.wallet,cargo:{capacityUnits:c.cargo_capacity,usedUnits:used,stacks:stacks.map(s=>({goodTypeId:s.good_id,quantity:s.quantity,cargoUnitsPerItem:s.cargo_units}))},activeTravel:t?{travelId:'travel-demo',fromCityId:t.from_city,toCityId:t.to_city,routeEdgeIds:JSON.parse(t.route_json).map(x=>typeof x==='string'?x:x.edgeId),startedAt:new Date(t.started_at).toISOString(),estimatedArrivalAt:new Date(t.eta).toISOString(),status:t.status}:null};
}
function marketRow(city,good){return db.prepare(`SELECT * FROM market WHERE city_id=? AND good_id=?`).get(city,good)}
function market(city){return db.prepare(`SELECT * FROM market WHERE city_id=? ORDER BY good_id`).all(city).map(m=>({cityId:m.city_id,goodTypeId:m.good_id,stock:m.stock,referencePrice:m.ref_price,baseSpread:m.spread,version:m.version,buyPrice:m.ref_price+m.spread,sellPrice:Math.max(1,m.ref_price-m.spread)}))}
function cargoQty(g){return db.prepare(`SELECT quantity FROM cargo WHERE character_id='char-demo' AND good_id=?`).get(g)?.quantity??0}
function storage(city){return db.prepare(`SELECT good_id,quantity FROM storage WHERE character_id='char-demo' AND city_id=? AND quantity>0 ORDER BY good_id`).all(city).map(x=>({goodTypeId:x.good_id,quantity:x.quantity}))}
function transactions(){return db.prepare(`SELECT * FROM economy_tx WHERE character_id='char-demo' ORDER BY created_at DESC LIMIT 50`).all().map(t=>({id:t.id,kind:t.kind,goldDelta:t.gold_delta,cityId:t.city_id,goodTypeId:t.good_id,quantity:t.quantity,createdAt:new Date(t.created_at).toISOString()}))}
const battleRows=id=>db.prepare(`SELECT * FROM battle_units WHERE battle_id=? ORDER BY side DESC,id`).all(id);
const battleDistance=(a,b)=>Math.max(Math.abs(a.row_no-b.row_no),Math.abs(a.col_no-b.col_no));
const skillDefinitions={hero:[{id:'heavy-strike',name:'重擊',damage:32,range:2,cooldownMs:4000,type:'NORMAL',targetType:'ENEMY'}],archer:[{id:'heartseeker-arrow',name:'穿心箭',damage:24,range:7,cooldownMs:5000,type:'NORMAL',targetType:'ENEMY'},{id:'arrow-rain',name:'箭雨',damage:18,range:7,radius:1,cooldownMs:8000,type:'NORMAL',targetType:'CELL',description:'選擇落點 · 半徑 1 格 · 18 傷害'}],guard:[{id:'iron-wall',name:'鐵壁',cooldownMs:10000,durationMs:5000,reduction:.5,type:'NORMAL',targetType:'SELF',description:'所受傷害減半 · 5 秒'}]};
function grantBattleReward(id,now=Date.now()){const battle=db.prepare(`SELECT character_id FROM battles WHERE id=? AND status='VICTORY'`).get(id);if(!battle)return null;db.prepare(`INSERT OR IGNORE INTO battle_rewards VALUES(?,?,100,?)`).run(id,battle.character_id,now);db.prepare(`INSERT OR IGNORE INTO battle_xp_rewards SELECT battle_id,id,50 FROM battle_units WHERE battle_id=? AND side='PLAYER' AND alive=1`).run(id);return db.prepare(`SELECT gold,granted_at FROM battle_rewards WHERE battle_id=?`).get(id)}
function resolveBattleStatus(id,now=Date.now()){const left=db.prepare(`SELECT side,COUNT(*) count FROM battle_units WHERE battle_id=? AND alive=1 GROUP BY side`).all(id),players=left.find(x=>x.side==='PLAYER')?.count??0,enemies=left.find(x=>x.side==='ENEMY')?.count??0,status=!players?'DEFEAT':!enemies?'VICTORY':'ACTIVE';db.prepare(`UPDATE battles SET status=?,updated_at=? WHERE id=?`).run(status,now,id);if(status==='VICTORY')grantBattleReward(id,now);return status}
function advanceBattle(id,now=Date.now()){
  const battle=db.prepare(`SELECT * FROM battles WHERE id=?`).get(id);
  if(!battle||battle.status!=='ACTIVE')return;
  db.prepare(`DELETE FROM battle_status_effects WHERE battle_id=? AND expires_at<=?`).run(id,now);
  const elapsed=Math.max(0,now-battle.updated_at),steps=Math.min(20,Math.floor(elapsed/300));
  for(let step=0;step<steps;step++){
    const units=battleRows(id).filter(x=>x.alive);
    for(const unit of units){
      let target=units.find(x=>x.id===unit.target_id&&x.side!==unit.side&&x.alive);
      if(!target){const nearest=units.filter(x=>x.side!==unit.side).sort((a,b)=>battleDistance(unit,a)-battleDistance(unit,b))[0];if(nearest&&(unit.side==='ENEMY'||unit.target_id||battleDistance(unit,nearest)<=unit.attack_range)){target=nearest;db.prepare(`UPDATE battle_units SET target_id=? WHERE battle_id=? AND id=?`).run(target.id,id,unit.id)}}
      let dr=unit.dest_row,dc=unit.dest_col;
      if(target&&battleDistance(unit,target)>unit.attack_range&&dr==null&&dc==null){dr=target.row_no;dc=target.col_no}
      if(dr==null||dc==null)continue;
      const nr=unit.row_no+Math.sign(dr-unit.row_no),nc=unit.col_no+Math.sign(dc-unit.col_no);
      const occupied=units.some(x=>x.id!==unit.id&&x.row_no===nr&&x.col_no===nc);
      if(!occupied||nr!==dr||nc!==dc){db.prepare(`UPDATE battle_units SET row_no=?,col_no=? WHERE battle_id=? AND id=?`).run(nr,nc,id,unit.id);unit.row_no=nr;unit.col_no=nc}
      if(nr===dr&&nc===dc)db.prepare(`UPDATE battle_units SET dest_row=NULL,dest_col=NULL WHERE battle_id=? AND id=?`).run(id,unit.id);
    }
  }
  const units=battleRows(id).filter(x=>x.alive);
  for(const unit of units){
    const target=units.find(x=>x.id===unit.target_id&&x.side!==unit.side&&x.alive)??((unit.side==='ENEMY'||unit.target_id)?units.filter(x=>x.side!==unit.side).sort((a,b)=>battleDistance(unit,a)-battleDistance(unit,b))[0]:null);
    if(!target||battleDistance(unit,target)>unit.attack_range||now-unit.last_attack_at<unit.attack_interval)continue;
    const reduction=db.prepare(`SELECT value FROM battle_status_effects WHERE battle_id=? AND unit_id=? AND effect_id='iron-wall' AND expires_at>?`).get(id,target.id,now)?.value??0,damage=Math.max(1,Math.ceil(unit.attack_power*(1-reduction)));
    db.prepare(`UPDATE battle_units SET hp=MAX(0,hp-?),alive=CASE WHEN hp-?<=0 THEN 0 ELSE 1 END WHERE battle_id=? AND id=?`).run(damage,damage,id,target.id);
    db.prepare(`UPDATE battle_units SET last_attack_at=?,target_id=? WHERE battle_id=? AND id=?`).run(now,target.id,id,unit.id);
  }
  resolveBattleStatus(id,now);
}
function battleSnapshot(){
  const battle=db.prepare(`SELECT * FROM battles WHERE character_id='char-demo' ORDER BY created_at DESC LIMIT 1`).get();
  if(!battle)return null;
  advanceBattle(battle.id);
  const fresh=db.prepare(`SELECT * FROM battles WHERE id=?`).get(battle.id),units=battleRows(battle.id),now=Date.now(),effects=db.prepare(`SELECT * FROM battle_status_effects WHERE battle_id=? AND expires_at>?`).all(fresh.id,now),reward=fresh.status==='VICTORY'?grantBattleReward(fresh.id,now):null,roster=db.prepare(`SELECT * FROM roster_units WHERE character_id=?`).all(fresh.character_id),xpRewards=reward?db.prepare(`SELECT x.unit_id,x.xp,r.name,r.level,r.xp total_xp FROM battle_xp_rewards x JOIN roster_units r ON r.character_id=? AND r.unit_id=x.unit_id WHERE x.battle_id=? ORDER BY x.unit_id`).all(fresh.character_id,fresh.id):[];
  return{id:fresh.id,status:fresh.status,reward:reward?{gold:reward.gold,grantedAt:new Date(reward.granted_at).toISOString(),xpRewards:xpRewards.map(x=>({unitId:x.unit_id,name:x.name,xp:x.xp,level:x.level,totalXp:x.total_xp}))}:null,rows:5,columns:60,units:units.map(x=>{const progress=roster.find(r=>r.unit_id===x.id);return{id:x.id,side:x.side,name:x.name,role:x.role,level:progress?.level??1,xp:progress?.xp??0,row:x.row_no,col:x.col_no,destination:x.dest_row==null?null:{row:x.dest_row,col:x.dest_col},hp:x.hp,maxHp:x.max_hp,attack:x.attack_power,attackRange:x.attack_range,targetId:x.target_id,alive:!!x.alive,statusEffects:effects.filter(e=>e.unit_id===x.id).map(e=>({id:e.effect_id,value:e.value,expiresAt:e.expires_at,expiresInMs:Math.max(0,e.expires_at-now)})),skills:(skillDefinitions[x.id]??[]).map(s=>{const readyAt=db.prepare(`SELECT ready_at FROM battle_skill_cooldowns WHERE battle_id=? AND unit_id=? AND skill_id=?`).get(fresh.id,x.id,s.id)?.ready_at??0;return{...s,readyAt,readyInMs:Math.max(0,readyAt-now)}})}})};
}
function startBattle(env){const e=check(env);if(e)return e;return idem(env.idempotencyKey,env.payload,()=>{const s=snapshot();if(s.state!=='IN_CITY')return{status:'REJECTED',errorCode:'ERR_INVALID_STATE'};const old=db.prepare(`SELECT id FROM battles WHERE character_id='char-demo' AND status='ACTIVE'`).get();if(old)return{status:'REJECTED',errorCode:'ERR_BATTLE_ALREADY_ACTIVE'};const id=randomUUID(),now=Date.now();db.prepare(`INSERT INTO battles VALUES(?,'char-demo','ACTIVE',?,?)`).run(id,now,now);const add=db.prepare(`INSERT INTO battle_units VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`);[
  ['hero','PLAYER','主角','MELEE',2,2,120,120,18,2,900],['archer','PLAYER','弓手','RANGED',1,1,80,80,13,5,750],['guard','PLAYER','護衛','MELEE',3,1,105,105,15,2,1000],
  ['bandit-a','ENEMY','山賊甲','MELEE',1,57,65,65,9,2,1100],['bandit-b','ENEMY','山賊乙','MELEE',2,58,65,65,9,2,1100],['bandit-c','ENEMY','山賊弓手','RANGED',3,57,55,55,8,5,1200]
].forEach(([uid,side,name,role,row,col,hp,maxHp,attack,range,interval])=>add.run(id,uid,side,name,role,row,col,null,null,hp,maxHp,attack,range,interval,now,null,1));return{status:'ACCEPTED',data:{battleId:id}}})}
function battleMove(env){const e=check(env);if(e)return e;return idem(env.idempotencyKey,env.payload,()=>{const p=env.payload,b=battleSnapshot();if(!b||b.status!=='ACTIVE')return{status:'REJECTED',errorCode:'ERR_NO_ACTIVE_BATTLE'};if(!Number.isInteger(p.row)||!Number.isInteger(p.col)||p.row<0||p.row>=5||p.col<0||p.col>=60)return{status:'REJECTED',errorCode:'ERR_OUT_OF_BOUNDS'};const requested=[...new Set(Array.isArray(p.unitIds)?p.unitIds:[p.unitId].filter(Boolean))],units=b.units.filter(x=>requested.includes(x.id)&&x.side==='PLAYER'&&x.alive);if(!requested.length||units.length!==requested.length)return{status:'REJECTED',errorCode:'ERR_UNIT_NOT_CONTROLLABLE'};const blocked=new Set(b.units.filter(x=>x.alive&&!requested.includes(x.id)).map(x=>`${x.row}:${x.col}`)),available=[];for(let row=0;row<5;row++)for(let col=0;col<60;col++)if(!blocked.has(`${row}:${col}`))available.push({row,col});available.sort((a,z)=>{const ar=Math.max(Math.abs(a.row-p.row),Math.abs(a.col-p.col)),zr=Math.max(Math.abs(z.row-p.row),Math.abs(z.col-p.col));return ar-zr||(Math.abs(a.row-p.row)+Math.abs(a.col-p.col))-(Math.abs(z.row-p.row)+Math.abs(z.col-p.col))});const destinations=[],update=db.prepare(`UPDATE battle_units SET dest_row=?,dest_col=?,target_id=CASE WHEN role='RANGED' THEN target_id ELSE NULL END WHERE battle_id=? AND id=?`);for(const unit of units){const best=available.shift();if(!best)throw new Error('ERR_NO_FORMATION_SPACE');update.run(best.row,best.col,b.id,unit.id);destinations.push({unitId:unit.id,row:best.row,col:best.col})}return{status:'ACCEPTED',data:{destinations,formationCenter:{row:p.row,col:p.col}}}})}
function battleTarget(env){const e=check(env);if(e)return e;return idem(env.idempotencyKey,env.payload,()=>{const p=env.payload,b=battleSnapshot();if(!b||b.status!=='ACTIVE')return{status:'REJECTED',errorCode:'ERR_NO_ACTIVE_BATTLE'};const requested=[...new Set(Array.isArray(p.unitIds)?p.unitIds:[p.unitId].filter(Boolean))],units=b.units.filter(x=>requested.includes(x.id)&&x.side==='PLAYER'&&x.alive),target=b.units.find(x=>x.id===p.targetId&&x.side==='ENEMY'&&x.alive);if(!requested.length||units.length!==requested.length||!target)return{status:'REJECTED',errorCode:'ERR_INVALID_TARGET'};const update=db.prepare(`UPDATE battle_units SET target_id=?,dest_row=NULL,dest_col=NULL WHERE battle_id=? AND id=?`);for(const unit of units)update.run(target.id,b.id,unit.id);return{status:'ACCEPTED',data:{unitIds:units.map(x=>x.id),targetId:target.id}}})}
function battleSkill(env){
  const e=check(env);if(e)return e;const b=battleSnapshot();if(!b||b.status!=='ACTIVE')return{status:'REJECTED',errorCode:'ERR_NO_ACTIVE_BATTLE'};
  return idem(env.idempotencyKey,env.payload,()=>{
    const p=env.payload,unit=b.units.find(x=>x.id===p.unitId&&x.side==='PLAYER'&&x.alive),skill=(skillDefinitions[p.unitId]??[]).find(x=>x.id===p.skillId);if(!unit||!skill)return{status:'REJECTED',errorCode:'ERR_INVALID_SKILL_TARGET'};
    const isCell=skill.targetType==='CELL',cell=isCell&&Number.isInteger(p.row)&&Number.isInteger(p.col)&&p.row>=0&&p.row<5&&p.col>=0&&p.col<60?{row:p.row,col:p.col}:null;
    const target=skill.targetType==='SELF'?unit:skill.targetType==='ENEMY'?b.units.find(x=>x.id===p.targetId&&x.side==='ENEMY'&&x.alive):null;
    if(!isCell&&!target||isCell&&!cell)return{status:'REJECTED',errorCode:'ERR_INVALID_SKILL_TARGET'};
    const aim=cell??target;if(skill.targetType!=='SELF'&&Math.max(Math.abs(unit.row-aim.row),Math.abs(unit.col-aim.col))>skill.range)return{status:'REJECTED',errorCode:'ERR_SKILL_OUT_OF_RANGE'};
    const areaTargets=isCell?b.units.filter(x=>x.side==='ENEMY'&&x.alive&&Math.max(Math.abs(x.row-cell.row),Math.abs(x.col-cell.col))<=skill.radius):[];if(isCell&&!areaTargets.length)return{status:'REJECTED',errorCode:'ERR_NO_TARGET_IN_AREA'};
    const now=Date.now(),readyAt=db.prepare(`SELECT ready_at FROM battle_skill_cooldowns WHERE battle_id=? AND unit_id=? AND skill_id=?`).get(b.id,unit.id,skill.id)?.ready_at??0;if(now<readyAt)return{status:'REJECTED',errorCode:'ERR_SKILL_COOLDOWN',data:{readyInMs:readyAt-now}};
    let damage=0,targetHp=target?.hp??null,killed=false,hits=[];
    if(skill.targetType==='SELF')db.prepare(`INSERT INTO battle_status_effects VALUES(?,?,?,?,?) ON CONFLICT(battle_id,unit_id,effect_id) DO UPDATE SET value=excluded.value,expires_at=excluded.expires_at`).run(b.id,unit.id,skill.id,skill.reduction,now+skill.durationMs);
    else{const victims=isCell?areaTargets:[target],hit=db.prepare(`UPDATE battle_units SET hp=?,alive=? WHERE battle_id=? AND id=?`);for(const victim of victims){const after=Math.max(0,victim.hp-skill.damage),dealt=victim.hp-after;hit.run(after,after>0?1:0,b.id,victim.id);hits.push({targetId:victim.id,targetPosition:{row:victim.row,col:victim.col},damage:dealt,targetHp:after,killed:after===0});damage+=dealt}if(!isCell){targetHp=hits[0].targetHp;killed=hits[0].killed;db.prepare(`UPDATE battle_units SET target_id=? WHERE battle_id=? AND id=?`).run(target.id,b.id,unit.id)}else killed=hits.some(x=>x.killed);resolveBattleStatus(b.id,now)}
    db.prepare(`INSERT INTO battle_skill_cooldowns VALUES(?,?,?,?) ON CONFLICT(battle_id,unit_id,skill_id) DO UPDATE SET ready_at=excluded.ready_at`).run(b.id,unit.id,skill.id,now+skill.cooldownMs);
    return{status:'ACCEPTED',data:{unitId:unit.id,unitName:unit.name,targetId:target?.id??null,targetPosition:{row:aim.row,col:aim.col},skillId:skill.id,skillName:skill.name,effectId:skill.targetType==='SELF'?skill.id:null,effectDurationMs:skill.durationMs??0,damage,targetHp,killed,hits,readyAt:now+skill.cooldownMs}}
  })
}
function retreatBattle(env){const e=check(env);if(e)return e;return idem(env.idempotencyKey,env.payload,()=>{const b=battleSnapshot();if(!b||b.status!=='ACTIVE')return{status:'REJECTED',errorCode:'ERR_NO_ACTIVE_BATTLE'};db.prepare(`UPDATE battles SET status='RETREATED',updated_at=? WHERE id=?`).run(Date.now(),b.id);return{status:'ACCEPTED',data:{battleId:b.id}}})}
function openSession(){const a=db.prepare(`SELECT active_session_id FROM accounts WHERE id='account-demo'`).get();if(a?.active_session_id)db.prepare(`UPDATE sessions SET state='INVALIDATED' WHERE id=?`).run(a.active_session_id);const id=randomUUID();db.prepare(`INSERT INTO sessions VALUES(?,?,?,?)`).run(id,'account-demo','ACTIVE',Date.now());db.prepare(`UPDATE accounts SET active_session_id=? WHERE id='account-demo'`).run(id);return id}
function validSession(id){return !!db.prepare(`SELECT 1 FROM accounts a JOIN sessions s ON s.id=a.active_session_id WHERE a.id='account-demo' AND s.id=? AND s.state='ACTIVE'`).get(id)}
function idem(key,payload,fn){
  if(!key)return{status:'REJECTED',errorCode:'ERR_IDEMPOTENCY_KEY_REQUIRED'};
  const ph=h(payload),old=db.prepare(`SELECT payload_hash,result_json FROM idempo WHERE key=?`).get(key);
  if(old){if(old.payload_hash!==ph)return{status:'REJECTED',errorCode:'ERR_COMMAND_CONFLICT'};return JSON.parse(old.result_json)}
  db.exec('BEGIN IMMEDIATE');
  try{
    const r=fn();
    if(r.status!=='ACCEPTED'){db.exec('ROLLBACK');return r}
    db.prepare(`INSERT INTO idempo VALUES(?,?,?)`).run(key,ph,JSON.stringify(r));
    db.exec('COMMIT');
    return r;
  }catch(err){
    db.exec('ROLLBACK');
    return{status:'REJECTED',errorCode:err?.message||'ERR_COMMAND_FAILED'};
  }
}
function quote(good,side,requested){const s=snapshot(),m=marketRow(s.cityId,good);if(!m)throw new Error('ERR_MARKET_ITEM_NOT_FOUND');const unit=side==='BUY'?m.ref_price+m.spread:Math.max(1,m.ref_price-m.spread);const available=side==='BUY'?m.stock:cargoQty(good);const cap=side==='BUY'?Math.floor((s.cargo.capacityUnits-s.cargo.usedUnits)/(cargoUnits[good]??1)):999999;const affordable=side==='BUY'?Math.floor(s.walletGold/unit):999999;const fill=Math.max(0,Math.min(requested,available,cap,affordable));const q={quoteId:randomUUID(),cityId:s.cityId,goodTypeId:good,side,requestedQuantity:requested,fillQuantity:fill,unitPrice:unit,total:fill*unit,marketVersion:m.version};q.fingerprint=h({cityId:q.cityId,goodTypeId:q.goodTypeId,side:q.side,requestedQuantity:q.requestedQuantity,fillQuantity:q.fillQuantity,unitPrice:q.unitPrice,marketVersion:q.marketVersion});return q}
const impact=(ref,side,qty)=>Math.max(1,ref+(side==='BUY'?1:-1)*Math.ceil(qty/10));
function check(env){return validSession(env.sessionId)?null:{status:'REJECTED',errorCode:'ERR_SESSION_REPLACED'}}
function changeCargo(good,delta){const s=snapshot(),cur=cargoQty(good),next=cur+delta,cu=cargoUnits[good]??1;if(next<0)throw new Error('ERR_INSUFFICIENT_CARGO');const usedWithout=s.cargo.usedUnits-cur*cu;if(usedWithout+next*cu>s.cargo.capacityUnits)throw new Error('ERR_CARGO_CAPACITY');db.prepare(`INSERT INTO cargo VALUES('char-demo',?,?,?) ON CONFLICT(character_id,good_id) DO UPDATE SET quantity=excluded.quantity,cargo_units=excluded.cargo_units`).run(good,next,cu)}

function buy(env){const e=check(env);if(e)return e;return idem(env.idempotencyKey,env.payload,()=>{const a=env.payload.approvedQuote,s=snapshot();if(s.state!=='IN_CITY'||s.cityId!==a.cityId)return{status:'REJECTED',errorCode:'ERR_INVALID_CONTEXT'};const live=quote(a.goodTypeId,'BUY',a.requestedQuantity);if(live.fillQuantity<=0)return{status:'REJECTED',errorCode:'ERR_NO_FILL'};if(live.unitPrice>a.unitPrice)return{status:'RECONFIRM_REQUIRED',data:live};const debit=db.prepare(`UPDATE characters SET wallet=wallet-? WHERE id='char-demo' AND wallet>=?`).run(live.total,live.total);if(debit.changes!==1)throw new Error('ERR_INSUFFICIENT_GOLD');changeCargo(a.goodTypeId,live.fillQuantity);const m=marketRow(s.cityId,a.goodTypeId);const stock=db.prepare(`UPDATE market SET stock=stock-?,ref_price=?,version=version+1 WHERE city_id=? AND good_id=? AND stock>=?`).run(live.fillQuantity,impact(m.ref_price,'BUY',live.fillQuantity),s.cityId,a.goodTypeId,live.fillQuantity);if(stock.changes!==1)throw new Error('ERR_INSUFFICIENT_STOCK');const now=Date.now();db.prepare(`INSERT INTO economy_tx VALUES(?,?,?,?,?,?,?,?)`).run(randomUUID(),'char-demo','NPC_BUY',-live.total,s.cityId,a.goodTypeId,live.fillQuantity,now);db.prepare(`INSERT INTO item_trace VALUES(?,?,?,?,?,?)`).run(randomUUID(),'char-demo',a.goodTypeId,live.fillQuantity,'NPC_BUY',now);return{status:'ACCEPTED',data:{actualQuantity:live.fillQuantity,actualTotal:live.total}}})}
function sell(env){const e=check(env);if(e)return e;return idem(env.idempotencyKey,env.payload,()=>{const a=env.payload.approvedQuote,s=snapshot();if(s.state!=='IN_CITY'||s.cityId!==a.cityId)return{status:'REJECTED',errorCode:'ERR_INVALID_CONTEXT'};const live=quote(a.goodTypeId,'SELL',a.requestedQuantity);if(live.fillQuantity<=0)return{status:'REJECTED',errorCode:'ERR_NO_FILL'};if(live.unitPrice<a.unitPrice)return{status:'RECONFIRM_REQUIRED',data:live};changeCargo(a.goodTypeId,-live.fillQuantity);db.prepare(`UPDATE characters SET wallet=wallet+? WHERE id='char-demo'`).run(live.total);const m=marketRow(s.cityId,a.goodTypeId);db.prepare(`UPDATE market SET stock=stock+?,ref_price=?,version=version+1 WHERE city_id=? AND good_id=?`).run(live.fillQuantity,impact(m.ref_price,'SELL',live.fillQuantity),s.cityId,a.goodTypeId);const now=Date.now();db.prepare(`INSERT INTO economy_tx VALUES(?,?,?,?,?,?,?,?)`).run(randomUUID(),'char-demo','NPC_SELL',live.total,s.cityId,a.goodTypeId,live.fillQuantity,now);db.prepare(`INSERT INTO item_trace VALUES(?,?,?,?,?,?)`).run(randomUUID(),'char-demo',a.goodTypeId,-live.fillQuantity,'NPC_SELL',now);return{status:'ACCEPTED',data:{actualQuantity:live.fillQuantity,proceeds:live.total}}})}
function fastest(from,to){const roads=db.prepare(`SELECT * FROM roads`).all(),q=[[from,0,[]]],best=new Map([[from,0]]);while(q.length){q.sort((a,b)=>a[1]-b[1]);const [city,cost,path]=q.shift();if(city===to)return{cost,path};for(const r of roads.filter(x=>x.from_city===city)){const nc=cost+r.travel_ms;if(nc<(best.get(r.to_city)??Infinity)){best.set(r.to_city,nc);q.push([r.to_city,nc,[...path,{edgeId:r.id,roadId:r.id,fromCityId:r.from_city,toCityId:r.to_city,durationMs:r.travel_ms,startOffsetMs:0,endOffsetMs:r.travel_ms}]])}}}return null}
const routeIds=path=>path.map(x=>typeof x==='string'?x:x.edgeId);
function startTravel(env){const e=check(env);if(e)return e;return idem(env.idempotencyKey,env.payload,()=>{const s=snapshot();if(s.state!=='IN_CITY')return{status:'REJECTED',errorCode:'ERR_INVALID_STATE'};if(s.cityId===env.payload.destinationCityId)return{status:'REJECTED',errorCode:'ERR_ALREADY_THERE'};const r=fastest(s.cityId,env.payload.destinationCityId);if(!r)return{status:'REJECTED',errorCode:'ERR_NO_ROUTE'};const now=Date.now(),eta=now+r.cost;db.prepare(`INSERT OR REPLACE INTO travel VALUES('char-demo',?,?,?,?,?,'TRAVELING')`).run(s.cityId,env.payload.destinationCityId,JSON.stringify(r.path),now,eta);db.prepare(`UPDATE characters SET state='TRAVELING' WHERE id='char-demo'`).run();return{status:'ACCEPTED',data:{routeEdgeIds:routeIds(r.path),totalTravelMs:r.cost,estimatedArrivalAt:new Date(eta).toISOString()}}})}
function normalizedSegments(t){const raw=JSON.parse(t.route_json);if(raw.every(x=>typeof x==='object'))return raw;return raw.map(id=>{const r=db.prepare(`SELECT * FROM roads WHERE id=?`).get(id);return{edgeId:r.id,roadId:r.id,fromCityId:r.from_city,toCityId:r.to_city,durationMs:r.travel_ms,startOffsetMs:0,endOffsetMs:r.travel_ms}})}
function reroute(env){const e=check(env);if(e)return e;return idem(env.idempotencyKey,env.payload,()=>{const t=db.prepare(`SELECT * FROM travel WHERE character_id='char-demo' AND status='TRAVELING'`).get();if(!t)return{status:'REJECTED',errorCode:'ERR_NO_TRAVEL'};const now=Date.now();if(now>=t.eta)return{status:'REJECTED',errorCode:'ERR_ALREADY_ARRIVED'};const destination=env.payload.destinationCityId;if(!cities.some(c=>c.id===destination))return{status:'REJECTED',errorCode:'ERR_CITY_NOT_FOUND'};const segments=normalizedSegments(t);let elapsed=Math.max(0,now-t.started_at),current;for(const segment of segments){if(elapsed<segment.durationMs){current={segment,elapsed};break}elapsed-=segment.durationMs}if(!current)return{status:'REJECTED',errorCode:'ERR_ALREADY_ARRIVED'};const {segment}=current,roadId=segment.roadId??segment.edgeId,road=db.prepare(`SELECT * FROM roads WHERE id=?`).get(roadId);if(!road)throw new Error('ERR_ROUTE_CORRUPT');const start=segment.startOffsetMs??0,end=segment.endOffsetMs??road.travel_ms,ratio=segment.durationMs?current.elapsed/segment.durationMs:1,offset=Math.max(0,Math.min(road.travel_ms,Math.round(start+(end-start)*ratio)));const options=[];for(const endpoint of [{city:road.from_city,distance:offset,endOffset:0,direction:'reverse'},{city:road.to_city,distance:road.travel_ms-offset,endOffset:road.travel_ms,direction:'forward'}]){const rest=fastest(endpoint.city,destination);if(rest)options.push({cost:endpoint.distance+rest.cost,first:{edgeId:`${road.id}:${endpoint.direction}`,roadId:road.id,fromCityId:'virtual-position',toCityId:endpoint.city,durationMs:endpoint.distance,startOffsetMs:offset,endOffsetMs:endpoint.endOffset},rest:rest.path})}options.sort((a,b)=>a.cost-b.cost);const chosen=options[0];if(!chosen)return{status:'REJECTED',errorCode:'ERR_NO_ROUTE'};const path=chosen.first.durationMs>0?[chosen.first,...chosen.rest]:chosen.rest,eta=now+chosen.cost;db.prepare(`UPDATE travel SET from_city=?,to_city=?,route_json=?,started_at=?,eta=?,status='TRAVELING' WHERE character_id='char-demo'`).run('virtual-position',destination,JSON.stringify(path),now,eta);return{status:'ACCEPTED',data:{routeEdgeIds:routeIds(path),totalTravelMs:chosen.cost,estimatedArrivalAt:new Date(eta).toISOString(),origin:'VIRTUAL_POSITION'}}})}
function resolveArrival(env){const e=check(env);if(e)return e;return idem(env.idempotencyKey,env.payload,()=>{const t=db.prepare(`SELECT * FROM travel WHERE character_id='char-demo'`).get();if(!t)return{status:'REJECTED',errorCode:'ERR_NO_TRAVEL'};if(Date.now()<t.eta)return{status:'REJECTED',errorCode:'ERR_NOT_ARRIVED'};db.prepare(`UPDATE travel SET status='ARRIVED' WHERE character_id='char-demo'`).run();db.prepare(`UPDATE characters SET city_id=?,state='IN_CITY' WHERE id='char-demo'`).run(t.to_city);return{status:'ACCEPTED',data:{cityId:t.to_city}}})}
function moveStorage(env){const e=check(env);if(e)return e;return idem(env.idempotencyKey,env.payload,()=>{const s=snapshot(),p=env.payload;if(s.state!=='IN_CITY'||s.cityId!==p.cityId)return{status:'REJECTED',errorCode:'ERR_PHYSICAL_PRESENCE_REQUIRED'};if(p.quantity<=0)return{status:'REJECTED',errorCode:'ERR_INVALID_QUANTITY'};const cur=db.prepare(`SELECT quantity FROM storage WHERE character_id='char-demo' AND city_id=? AND good_id=?`).get(s.cityId,p.goodTypeId)?.quantity??0;if(p.direction==='CARGO_TO_STORAGE'){changeCargo(p.goodTypeId,-p.quantity);db.prepare(`INSERT INTO storage VALUES('char-demo',?,?,?) ON CONFLICT(character_id,city_id,good_id) DO UPDATE SET quantity=quantity+excluded.quantity`).run(s.cityId,p.goodTypeId,p.quantity)}else if(p.direction==='STORAGE_TO_CARGO'){if(cur<p.quantity)throw new Error('ERR_INSUFFICIENT_STORAGE');db.prepare(`UPDATE storage SET quantity=quantity-? WHERE character_id='char-demo' AND city_id=? AND good_id=?`).run(p.quantity,s.cityId,p.goodTypeId);changeCargo(p.goodTypeId,p.quantity)}else return{status:'REJECTED',errorCode:'ERR_INVALID_DIRECTION'};return{status:'ACCEPTED',data:{quantity:p.quantity}}})}

async function api(req,res){
  const u=new URL(req.url,'http://localhost');
  if(req.method==='GET'&&u.pathname==='/api/health')return reply(res,200,{ok:true,version:'0.11.0',phase:'P2 Battle Experience'});
  if(req.method==='GET'&&u.pathname==='/api/cities')return reply(res,200,cities);
  if(req.method==='GET'&&u.pathname==='/api/character/char-demo/snapshot')return reply(res,200,snapshot());
  if(req.method==='GET'&&u.pathname.startsWith('/api/cities/')&&u.pathname.endsWith('/market'))return reply(res,200,market(u.pathname.split('/')[3]));
  if(req.method==='GET'&&u.pathname.startsWith('/api/character/char-demo/storage/'))return reply(res,200,storage(u.pathname.split('/').at(-1)));
  if(req.method==='GET'&&u.pathname==='/api/character/char-demo/transactions')return reply(res,200,transactions());
  if(req.method==='GET'&&u.pathname==='/api/character/char-demo/battle')return reply(res,200,battleSnapshot());
  if(req.method==='POST'&&u.pathname==='/api/session/open')return reply(res,200,{sessionId:openSession()});
  if(req.method==='POST'&&u.pathname==='/api/commands/market/quote'){const b=await readBody(req);try{return reply(res,200,quote(b.goodTypeId,b.side,b.requestedQuantity))}catch(e){return reply(res,400,{errorCode:e.message})}}
  if(req.method==='POST'){const env=await readBody(req);let out;if(u.pathname==='/api/commands/market/buy')out=buy(env);else if(u.pathname==='/api/commands/market/sell')out=sell(env);else if(u.pathname==='/api/commands/travel/start')out=startTravel(env);else if(u.pathname==='/api/commands/travel/reroute')out=reroute(env);else if(u.pathname==='/api/commands/travel/resolve-arrival')out=resolveArrival(env);else if(u.pathname==='/api/commands/container/move')out=moveStorage(env);else if(u.pathname==='/api/commands/battle/start')out=startBattle(env);else if(u.pathname==='/api/commands/battle/move')out=battleMove(env);else if(u.pathname==='/api/commands/battle/target')out=battleTarget(env);else if(u.pathname==='/api/commands/battle/skill')out=battleSkill(env);else if(u.pathname==='/api/commands/battle/retreat')out=retreatBattle(env);else return false;return reply(res,200,out)}
  return false;
}
function serveStatic(req,res){let p=req.url==='/'?'/index.html':req.url;p=normalize(p).replace(/^(\.\.[/\\])+/, '');const file=join(PUBLIC_DIR,p);try{const data=readFileSync(file),ext=extname(file);const ct=ext==='.html'?'text/html; charset=utf-8':ext==='.js'?'text/javascript; charset=utf-8':ext==='.css'?'text/css; charset=utf-8':'application/octet-stream';res.writeHead(200,{'content-type':ct});res.end(data)}catch{res.writeHead(404);res.end('Not found')}}
const server=createServer(async(req,res)=>{try{if(req.url.startsWith('/api/')){const handled=await api(req,res);if(handled!==false)return;return reply(res,404,{errorCode:'ERR_NOT_FOUND'})}serveStatic(req,res)}catch(e){reply(res,500,{errorCode:'ERR_INTERNAL',message:String(e?.message??e)})}});
server.listen(PORT,'0.0.0.0',()=>console.log(`FIRST_PLAYABLE_READY http://0.0.0.0:${server.address().port}`));
