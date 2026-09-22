import {goodNameFor} from './goods.js';
import {canEnterCityHub,leaveCityHub,shouldShowCityHubOnStateChange,handleCityTap,renderWorldMapHtml,renderCityHubHtml,computeTravelPosition,indexById,resolveEffectiveViewBox,viewBoxAttr,CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS,OBSTACLES} from './worldmap.js';
import {PLAYER_COLLISION_RADIUS,inflateRect} from './worldgeometry.js';
import {busQuote} from './bus.js';
import {computeJoystickInput,clampJoystickKnob,easeTowards,shouldSendJoystickMove,describeWorldMoveError,predictionVelocity,advancePredictedPosition,clampPredictedStep,reconciliationSmoothingMs,shouldSuspendAfterAccepted,JOYSTICK_RADIUS,JOYSTICK_DEADZONE,JOYSTICK_SEND_INTERVAL_MS,MAX_PREDICTION_LEAD,movementDivergence,catchUpDebtAfterGrant,nextCatchUpDebt,clampEarnedTarget,nextEarnedPosition,idleSettlePosition,applyContinuousMovementIntent as computeNextMovementIntent,invalidateMovementGeneration as computeInvalidatedMovementGeneration,guardStaleGeneration,MOVE_CATCHUP_CAP_MS} from './movement.js';
// P1-07C — Mobile Movement Telemetry (diagnostic-only, Issue #21). Read-only instrumentation of
// the existing movement path above; nothing in this import or the code that uses it changes any
// movement/joystick/prediction/reconciliation/camera behavior.
import {nextFpsEma,nextTelemetryFrameDelta,predictionLeadDistance,nextMoveTiming,formatMs,formatFlag,formatLeadReadout,TELEMETRY_OVERLAY_PATCH_INTERVAL_MS,isNearLeadCap,isCapFrozenFrame,nextCapFrozenStreakMs,capFrozenRatio,formatPercent,formatPx,formatCount} from './telemetry.js';
// P4-03A — cosmetic-only: WORLD_MONSTER_DEFINITIONS/patrolPositionAt are the same shared, DOM-free
// content module server.mjs imports (already the established pattern — public/bus.js already
// imports CITY_DEFINITIONS from ./cities.js directly into the client bundle the same way). The
// client only ever uses these to interpolate a smooth on-screen position for a monster the SERVER
// has already told it (via S.snap.worldMonsters) still exists — it never decides existence,
// consumption, or encounter outcomes, which stay 100% server-authoritative (see tickMovementFrame's
// monster-marker patch below).
import {WORLD_MONSTER_DEFINITIONS,patrolPositionAt} from './worldmonsters.js';
// P1-07B: same INFLATED_OBSTACLES construction as server.mjs's own (OBSTACLES.map(inflateRect)) —
// used only as a presentation-only prediction clamp (see clampPredictedStep), never as the real
// collision authority, which remains server.mjs's own segmentBlocked() over the same primitives.
const INFLATED_OBSTACLES=OBSTACLES.map(r=>inflateRect(r,PLAYER_COLLISION_RADIUS));
const PREDICTION_VELOCITY=predictionVelocity();
const S={sessionId:'',snap:null,cities:[],roads:[],encounters:[],roster:[],equipment:[],deploymentUnitIds:null,deploymentPositions:{},deploymentSelectedUnitId:'hero',market:[],marketMode:'BUY',storage:[],storages:{},tx:[],battle:null,selectedUnitIds:[],focusTargetId:null,armedSkill:null,battleScrollLeft:0,battlePanDragging:false,battlePanFrame:0,hitUnitIds:[],skillEffects:[],battleLog:[],seenEnemyCastIds:[],tab:'map',modal:null,mapView:'follow'};
async function req(path,opts={}){const r=await fetch(path,{headers:{'content-type':'application/json'},...opts});const b=await r.json();if(!r.ok)throw new Error(b.errorCode||`HTTP_${r.status}`);return b}
const post=(p,b)=>req(p,{method:'POST',body:JSON.stringify(b)});
const env=(payload,idempotencyKey=crypto.randomUUID())=>({commandId:crypto.randomUUID(),idempotencyKey,sessionId:S.sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function sendCommand(path,body){try{return await post(path,body)}catch{await wait(350);return post(path,body)}}
const command=(path,payload,key)=>sendCommand(path,env(payload,key));
const cityName=id=>S.cities.find(x=>x.id===id)?.name||id;
const stateName=state=>({IN_CITY:'城內',IN_WORLD:'城外',TRAVELING:'旅途中'}[state]||state);
const coord=(row,col)=>`R${row+1} C${col+1}`;
const deploymentPresets={balanced:{hero:[2,3],archer:[1,1],guard:[3,2]},forward:{hero:[2,5],archer:[1,3],guard:[3,4]},rear:{hero:[2,1],archer:[1,0],guard:[3,1]}};
function ensureDeployment(){const team=S.deploymentUnitIds||[],used=new Set();for(const id of team){let p=S.deploymentPositions[id],key=p&&`${p.row}:${p.col}`;if(!p||p.row<0||p.row>=5||p.col<0||p.col>=6||used.has(key)){const preset=deploymentPresets.balanced[id]||[2,2],open=[];for(let row=0;row<5;row++)for(let col=0;col<6;col++)if(!used.has(`${row}:${col}`))open.push({row,col});p=open.sort((a,b)=>Math.max(Math.abs(a.row-preset[0]),Math.abs(a.col-preset[1]))-Math.max(Math.abs(b.row-preset[0]),Math.abs(b.col-preset[1])))[0];S.deploymentPositions[id]=p;key=`${p.row}:${p.col}`}used.add(key)}for(const id of Object.keys(S.deploymentPositions))if(!team.includes(id))delete S.deploymentPositions[id];if(!team.includes(S.deploymentSelectedUnitId))S.deploymentSelectedUnitId=team[0]||null}
function toast(t){const d=document.createElement('div');d.className='toast';d.textContent=t;document.body.append(d);setTimeout(()=>d.remove(),1500)}
function invalidateMovementGeneration(){
  const next=computeInvalidatedMovementGeneration({movementGeneration,generationAnchorInput});
  movementGeneration=next.movementGeneration;
  generationAnchorInput=next.generationAnchorInput;
}
// P4-03A — best-effort offset between the server's clock and this device's own Date.now(), so
// tickMovementFrame's cosmetic monster-patrol interpolation can approximate "the server's current
// time" without assuming the player's device clock is anywhere close to it (unlike ordinary network
// latency, a device clock can be off by minutes/hours). Recomputed on every refresh() from the
// snapshot's own serverNowMs — never itself sent anywhere or used to decide any game logic.
//
// P4-03A Merge Gate fix — "Account for Snapshot Transit Time": serverNowMs is captured on the
// SERVER before the HTTP response travels back to the client, so comparing it against the client's
// receipt time (Date.now() right after the request resolves) silently bakes the ENTIRE one-way
// response transit time into what's treated as clock skew. At this monster's patrol speed
// (0.02px/ms), a 2000ms response delay alone would already read back as ~40px of spurious lag — the
// full encounterRadius — enough to visibly show the player colliding with the monster on screen while
// the authoritative server position is actually elsewhere (never a real encounter, since that's
// always decided server-side from the server's own live Date.now(), but a misleading, avoidable
// visual glitch). Fix: capture requestStartedAt immediately before sending the request and
// responseReceivedAt immediately after it resolves, and estimate the client instant the server's
// timestamp corresponds to as the request's MIDPOINT — requestStartedAt + (responseReceivedAt -
// requestStartedAt)/2 — the standard symmetric-latency approximation (assumes the outbound and return
// legs took about the same time, not provable, but far better than attributing 100% of the round trip
// to one direction). Pure, exported so the arithmetic itself (not just its wiring into refresh()) can
// be tested directly. Deliberately NOT a clock-sync subsystem: no historical RTT averaging, no
// NTP-style multi-sample estimation — a single request's midpoint per refresh(), nothing more.
export function computeServerTimeOffset(serverNowMs,requestStartedAt,responseReceivedAt){
  if(!Number.isFinite(serverNowMs)||!Number.isFinite(requestStartedAt)||!Number.isFinite(responseReceivedAt)||responseReceivedAt<requestStartedAt)return 0;
  const midpointClientTime=requestStartedAt+(responseReceivedAt-requestStartedAt)/2;
  return serverNowMs-midpointClientTime;
}
let serverTimeOffset=0;
async function refresh(){
  // P1-07D Merge Gate review: invalidate BEFORE the first await below, not after the snapshot
  // response returns — a refresh() is itself a hard resync (S.snap is about to be replaced
  // wholesale), so any movement request already pending under the pre-refresh generation must
  // already be stale the INSTANT refresh() starts, not once its own snapshot request happens to
  // resolve. Invalidating only after that first await would leave the exact same race window
  // applyMovementIntent was built to close for joystick input — a pending target could dequeue and
  // reach the network while this snapshot request is itself still in flight.
  predictionResetPending=true;
  invalidateMovementGeneration();
  // P2-07 City Hub Navigation: capture the state BEFORE it is overwritten below, so we can tell a
  // just-happened physical entry (marker walk-in, bus arrival, or a fresh/reloaded client whose
  // S.snap was null) apart from an ordinary in-city refresh (buying, selling, storage move) that
  // must not yank the player out of whatever city screen they were already on.
  const previousState=S.snap?.state;
  // P4-03A Merge Gate fix — requestStartedAt/responseReceivedAt bracket the snapshot request itself
  // (not any of the Promise.all() calls further below), so their midpoint approximates the client
  // instant serverNowMs actually corresponds to, rather than attributing the whole one-way response
  // transit time to clock skew (see computeServerTimeOffset's own comment). Recomputed wholesale on
  // every refresh() (never incrementally adjusted) so it can never drift further off over time.
  const requestStartedAt=Date.now();
  S.snap=await req('/api/character/char-demo/snapshot');
  const responseReceivedAt=Date.now();
  serverTimeOffset=computeServerTimeOffset(S.snap.serverNowMs,requestStartedAt,responseReceivedAt);
  if(shouldShowCityHubOnStateChange(previousState,S.snap.state))S.tab='hub';
  // P1-07B: a full refresh() replaces S.snap wholesale (e.g. after travel/arrival/settlement) —
  // whatever the client was predicting before this is no longer trustworthy, so force a hard
  // reset of the predicted position to the fresh authoritative one on the next animation frame.
  const [market,storageList,tx,battle,roster,equipment]=await Promise.all([req(`/api/cities/${S.snap.cityId}/market`),req('/api/character/char-demo/storage'),req('/api/character/char-demo/transactions'),req('/api/character/char-demo/battle'),req('/api/character/char-demo/roster'),req('/api/character/char-demo/equipment')]);
  S.market=market;S.storages=Object.fromEntries(storageList.map(x=>[x.cityId,x.goods]));S.storage=S.storages[S.snap.cityId]||[];S.tx=tx;S.roster=roster;S.equipment=equipment;if(S.deploymentUnitIds===null)S.deploymentUnitIds=roster.map(x=>x.id);ensureDeployment();setBattle(battle);if(battle?.status==='ACTIVE'||battle?.reward?.settlementRequired)S.tab='battle';
  render();
}
function setBattle(next){
  if(S.battle&&next?.id===S.battle.id){for(const unit of next.units){const old=S.battle.units.find(x=>x.id===unit.id);if(old&&unit.hp<old.hp){S.hitUnitIds.push(unit.id);S.battleLog.unshift(`${unit.name} 受到 ${old.hp-unit.hp} 傷害`);}}S.battleLog=S.battleLog.slice(0,3)}
  for(const cast of next?.enemyCasts||[])if(!S.seenEnemyCastIds.includes(cast.id)){S.seenEnemyCastIds.push(cast.id);S.battleLog.unshift(`⚠️ ${cast.skillName}鎖定 ${coord(cast.row,cast.col)}，立即離開紅色範圍！`)}S.battleLog=S.battleLog.slice(0,3);
  if(S.focusTargetId&&!next?.units?.some(x=>x.id===S.focusTargetId&&x.alive))S.focusTargetId=null;
  S.battle=next;
}
function nav(t,l){return `<button class="${S.tab===t?'active':''}" data-tab="${t}">${l}</button>`}
function render(){
  const s=S.snap;if(!s)return;
  const oldScroll=document.querySelector('.battle-scroll');if(oldScroll)S.battleScrollLeft=oldScroll.scrollLeft;
  const combatLocked=S.tab==='battle'&&(S.battle?.status==='ACTIVE'||S.battle?.reward?.settlementRequired);
  const tabs=combatLocked?'':`<div class="tabs">${nav('map','地圖')}${nav('cargo','貨艙')}${nav('battle','戰鬥')}${nav('history','紀錄')}</div>`;
  document.querySelector('#app').innerHTML=`<div class="shell ${combatLocked?'combat-shell':''}"><section class="card top"><div><div class="small">戰鬥原型 版本 0.32.0</div><div class="city">${cityName(s.cityId)}</div><div class="small" id="state-label">${stateName(s.state)}</div></div><div class="money">💰 ${s.walletGold}</div></section>${tabs}${view()}</div>`;
  document.querySelectorAll('[data-tab]').forEach(x=>x.onclick=()=>{S.tab=x.dataset.tab;render()});wire();setupBattlePan();setupJoystick();if(S.hitUnitIds.length)setTimeout(()=>S.hitUnitIds=[],400);if(S.modal)showModal();
}
function view(){
  if(['hub','market','storage','bus'].includes(S.tab)&&!canEnterCityHub(S.snap,S.snap.cityId))S.tab='map';
  if(S.tab==='map')return renderWorldMapHtml({snap:S.snap,cities:S.cities,roads:S.roads,mapView:S.mapView});
  if(S.tab==='hub')return renderCityHubHtml({snap:S.snap,cities:S.cities});
  if(S.tab==='bus'){
    const back=`<button class="btn alt" data-back-hub="1">← 返回城市中心</button>`;
    const routes=S.cities.filter(city=>city.id!==S.snap.cityId).map(city=>{const quote=busQuote(S.snap.cityId,city.id,S.cities);return `<article class="city-storage current"><div class="city-storage-head"><div><b>🚌 ${city.name}</b><small>車程約 ${(quote.travelMs/1000).toFixed(1)} 秒 · 步行參考 ${Math.round(quote.walkingMs/1000)} 秒</small></div><span>💰 ${quote.fareGold}</span></div><button class="btn" data-bus-destination="${city.id}">確認坐車</button></article>`}).join('');
    return `<section class="card">${back}<b>巴士站</b><p class="small">按距離收費；巴士車程為同等步行參考時間 70%。上車後不可改道。</p><div class="city-storage-list">${routes}</div></section>`;
  }
  if(S.tab==='market'){
    const back=`<button class="btn alt" data-back-hub="1">← 返回城市中心</button>`;
    const buy=S.marketMode==='BUY',switcher=`<div class="market-switch"><button class="${buy?'active':''}" data-market-mode="BUY">買入</button><button class="${buy?'':'active'}" data-market-mode="SELL">賣出</button></div>`;
    if(buy)return `<section class="card">${back}<b>城市市場</b>${switcher}<div class="small">買價會喺確認成交時再次檢查。</div>${S.market.map(m=>`<div class="row"><div><div class="good">${goodNameFor(m.goodTypeId)}</div><div class="prices">買價 ${m.buyPrice} · 庫存 ${m.stock}</div></div><input class="qty" data-q="${m.goodTypeId}" type="number" min="1" value="1"><button class="btn" data-buy="${m.goodTypeId}">買入</button></div>`).join('')}</section>`;
    const goods=S.snap.cargo.stacks.map(stack=>{const m=S.market.find(x=>x.goodTypeId===stack.goodTypeId);return `<div class="row"><div><div class="good">${goodNameFor(stack.goodTypeId)} × ${stack.quantity}</div><div class="prices">收購價 ${m?.sellPrice??'-'}／件</div></div><input class="qty" data-q="${stack.goodTypeId}" type="number" min="1" max="${stack.quantity}" value="1"><button class="btn alt" data-sell="${stack.goodTypeId}">賣出</button></div>`}).join('');
    const gear=S.equipment.filter(item=>item.ownerUnitId||item.storageCityId===S.snap.cityId).map(item=>`<div class="market-equipment"><div><b>${item.slot==='WEAPON'?'🗡️':'🔸'} ${item.name}</b><small>${item.ownerUnitId?`${S.roster.find(x=>x.id===item.ownerUnitId)?.name}背包${item.equippedUnitId?' · 使用中':''}`:`${cityName(item.storageCityId)} 倉庫`} · 本城收購價 💰 ${item.sellPrice}</small></div><button class="btn alt" data-equipment-sell="${item.id}">賣出</button></div>`).join('');
    return `<section class="card">${back}<b>城市市場</b>${switcher}<div class="small">不同城市會用不同價錢收購裝備。</div><div class="sell-group"><b>貨物</b>${goods||'<p class="small">貨艙冇可出售貨物。</p>'}</div><div class="sell-group"><b>裝備</b>${gear||'<p class="small">目前城市冇可出售裝備。</p>'}</div></section>`;
  }
  if(S.tab==='cargo'){
    const goods=S.snap.cargo.stacks.map(x=>`<div class="row"><div>${goodNameFor(x.goodTypeId)} × ${x.quantity}</div><span></span><button class="btn alt" data-store="${x.goodTypeId}">入倉1</button></div>`).join('')||"<p class='small'>貨艙目前冇商品。</p>";
    const backpacks=S.roster.map(unit=>{const items=S.equipment.filter(item=>item.ownerUnitId===unit.id),content=items.map(item=>{const equipped=item.equippedUnitId===unit.id,transfers=S.roster.filter(x=>x.id!==unit.id).map(x=>`<button data-transfer-item="${item.id}" data-transfer-unit="${x.id}">→ ${x.name}</button>`).join('');return `<div class="backpack-item"><div><b>${item.slot==='WEAPON'?'🗡️':'🔸'} ${item.name}</b><small>${item.attackBonus?`攻擊 +${item.attackBonus}`:`HP +${item.hpBonus}`} · ${equipped?'使用中':'背包內'}</small></div><div class="asset-actions"><button class="btn ${equipped?'danger':'alt'}" ${equipped?`data-unequip-item="${item.id}"`:`data-equip-item="${item.id}"`} data-equip-unit="${unit.id}">${equipped?'卸下':'裝備'}</button><button data-store-equipment="${item.id}">入倉</button>${transfers}</div></div>`}).join('')||'<p class="small">背包係空嘅</p>';return `<article class="unit-backpack"><div class="backpack-head"><b>🎒 ${unit.name}背包</b><span>HP ${unit.maxHp} · 攻 ${unit.attack}</span></div>${content}</article>`}).join('');
    return `<section class="card"><b>貨艙與角色背包</b><div class="metric"><div><span class="small">貨艙已用</span><b>${S.snap.cargo.usedUnits}</b></div><div><span class="small">貨艙容量</span><b>${S.snap.cargo.capacityUnits}</b></div></div><div class="cargo-goods">${goods}</div><div class="backpack-section"><div class="equipment-head"><b>裝備背包</b><small>每名角色獨立持有及裝備</small></div>${backpacks}</div></section>`;
  }
  if(S.tab==='storage'){
    const back=`<button class="btn alt" data-back-hub="1">← 返回城市中心</button>`;
    const cities=S.cities.map(city=>{const local=S.snap.state==='IN_CITY'&&city.id===S.snap.cityId,goods=(S.storages[city.id]||[]).map(x=>`<div class="row"><div>${goodNameFor(x.goodTypeId)} × ${x.quantity}</div><span></span><button class="btn ${local?'':'alt'}" ${local?`data-withdraw="${x.goodTypeId}"`:'disabled'}>${local?'拎1':'需到達'}</button></div>`).join('')||"<p class='small'>冇存放貨物。</p>",gear=S.equipment.filter(item=>item.storageCityId===city.id).map(item=>`<div class="storage-equipment"><div><b>${item.slot==='WEAPON'?'🗡️':'🔸'} ${item.name}</b><small>${item.attackBonus?`攻擊 +${item.attackBonus}`:`HP +${item.hpBonus}`}</small></div><div class="asset-actions">${local?S.roster.map(unit=>`<button data-withdraw-equipment="${item.id}" data-withdraw-unit="${unit.id}">→ ${unit.name}背包</button>`).join(''):'<button disabled>需親身到達</button>'}</div></div>`).join('')||'<p class="small">冇存放裝備。</p>';return `<article class="city-storage ${local?'current':'remote'}"><div class="city-storage-head"><div><b>${cityName(city.id)} 倉庫</b><small>${local?'📍 目前所在城市 · 可以提取':'🔒 遠端查看 · 不可提取或交易'}</small></div><span>${local?'當前':'只讀'}</span></div><div class="storage-group"><b>貨物</b>${goods}</div><div class="storage-group"><b>裝備</b>${gear}</div></article>`}).join('');
    return `<section class="card">${back}<b>全城市倉庫</b><p class="small">可以查看各地資產；必須親身到達該城市先可提取或交易。</p><div class="city-storage-list">${cities}</div></section>`;
  }
  if(S.tab==='battle')return battleView();
  return `<section class="card"><b>交易紀錄</b>${S.tx.map(t=>`<div class="row"><div>${t.kind}<div class="small">${t.goodTypeId||''} ${t.quantity||''} · ${cityName(t.cityId)}</div></div><span></span><b>${t.goldDelta>0?'+':''}${t.goldDelta}</b></div>`).join('')||"<p class='small'>未有交易。</p>"}</section>`;
}
function battleView(){
  const b=S.battle;
  if(!b||b.status!=='ACTIVE'){
    ensureDeployment();
    const label={VICTORY:'勝利',DEFEAT:'戰敗',RETREATED:'已撤退'}[b?.status]||b?.status||'',xp=b?.reward?.xpRewards?.map(x=>`<div class="xp-row"><span>${x.name} <small>Lv.${x.level}</small></span><b>+${x.xp} EXP</b><small>總 EXP ${x.totalXp}</small></div>`).join('')||'',team=S.deploymentUnitIds||[],role={MELEE:'近戰',RANGED:'遠攻'},loot=b?.reward?.loot,pendingLoot=!!b?.reward?.settlementRequired;
    const lootPanel=loot?`<div class="loot-drop ${loot.status.toLowerCase()}"><b>🎁 ${loot.name}</b><small>${loot.attackBonus?`攻擊 +${loot.attackBonus}`:`HP +${loot.hpBonus}`} · ${loot.slot==='WEAPON'?'武器':'飾物'}</small>${pendingLoot?`<p>選擇由邊名角色帶走；放棄後戰利品會消失。</p><div class="loot-actions backpack-choice">${S.roster.map(unit=>`<button class="btn" data-settle-loot="KEEP" data-owner-unit="${unit.id}">帶走 → ${unit.name}</button>`).join('')}<button class="btn danger discard-loot" data-settle-loot="DISCARD">放棄</button></div>`:`<strong>${loot.status==='KEEP'?'✓ 已帶走並放入角色背包':'已放棄此戰利品'}</strong>`}</div>`:'';
    if(pendingLoot)return `<section class="card battle-card result-card settlement-screen"><div class="settlement-title"><span>戰鬥結束 · 戰後結算</span><b>${b.encounter?.name||'戰鬥'}</b></div><div class="result ${b.status.toLowerCase()}">${label}</div><div class="battle-reward"><span>戰利金</span><b>💰 +${b.reward.gold}</b><small>已存入錢包及交易紀錄</small>${lootPanel}${xp?`<div class="xp-list">${xp}</div>`:''}</div><div class="settlement-lock">🔒 尚未離開戰場<br><small>必須處理戰利品，先會返回城市介面。</small></div></section>`;
    const roster=S.roster.map(x=>{const picked=team.includes(x.id),required=x.id==='hero',skills=x.skills.map(s=>s.name).join('、')||'未有主動技能';return `<button class="roster-card ${picked?'picked':''} ${required?'required':''}" data-deploy-unit="${x.id}" aria-pressed="${picked}"><span class="roster-check">${required?'◆':picked?'✓':'＋'}</span><b>${x.name} · Lv.${x.level}${required?' · 必須出戰':''}</b><small>${role[x.role]}｜EXP ${x.xpIntoLevel}/100</small><span>HP ${x.maxHp} · 攻 ${x.attack} · 射程 ${x.attackRange} · 敏捷 ${x.agility}</span><small>移動 ${(x.moveIntervalMs/1000).toFixed(2)}s／格 · 普攻 ${(x.attackIntervalMs/1000).toFixed(2)}s／次</small><small>技能：${skills}</small></button>`}).join('');
    let deploymentCells='';for(let row=0;row<5;row++)for(let col=0;col<6;col++){const unitId=team.find(id=>S.deploymentPositions[id]?.row===row&&S.deploymentPositions[id]?.col===col),unit=S.roster.find(x=>x.id===unitId);deploymentCells+=`<button class="deployment-cell ${unitId?'occupied':''} ${S.deploymentSelectedUnitId===unitId?'selected':''}" data-deployment-row="${row}" data-deployment-col="${col}" ${unitId?`data-deployment-unit="${unitId}"`:''}>${unit?`<b>${unit.role==='RANGED'?'🏹':'⚔️'}</b><small>${unit.name}</small>`:''}</button>`}
    const deploymentSummary=team.map(id=>{const unit=S.roster.find(x=>x.id===id),p=S.deploymentPositions[id];return `<span>${unit?.name} ${coord(p.row,p.col)}</span>`}).join('');
    const encounters=S.encounters.map(x=>`<article class="encounter-card ${x.difficulty==='精英'?'elite':''}"><div><b>${x.name}</b><span>${x.difficulty} · 建議 Lv.${x.recommendedLevel}</span></div><div class="encounter-meta"><span>👺 ${x.enemyCount}</span><span>💰 ${x.rewardGold}</span><span>EXP ${x.rewardXp}/人</span></div><button class="btn ${x.difficulty==='精英'?'danger':''}" data-start-encounter="${x.id}" ${team.includes('hero')&&!pendingLoot&&S.snap.state==='IN_CITY'?'':'disabled'}>挑戰</button></article>`).join('');
    return `<section class="card battle-card result-card"><b>隊伍編成與關卡</b><p class="small">主角必須出戰；另外自由選擇最多兩名隊友。</p>${S.snap.state!=='IN_CITY'?'<div class="team-warning">🚶 旅行中不能開始戰鬥；到埗後會自動解鎖。</div>':''}${b?`<div class="last-result"><span>${b.encounter?.name||'戰鬥'}</span><div class="result ${b.status.toLowerCase()}">${label}</div>${b.reward?`<div class="battle-reward"><span>戰利金</span><b>💰 +${b.reward.gold}</b><small>已存入錢包及交易紀錄</small>${lootPanel}${xp?`<div class="xp-list">${xp}</div>`:''}</div>`:''}</div>`:''}${pendingLoot?'<div class="settlement-warning">完成戰利品選擇後，先可以再戰或旅行。</div>':''}<div class="roster-head"><b>出戰隊伍</b><span>${team.length}/3</span></div><div class="roster-list">${roster}</div>${team.includes('hero')?'':'<div class="team-warning">主角必須出戰</div>'}<div class="deployment-head"><div><b>戰前部署區</b><small>保留上下及前後陣位；入攻距時彈性拆陣</small></div><div class="deployment-presets"><button data-deployment-preset="balanced">均衡</button><button data-deployment-preset="forward">前壓</button><button data-deployment-preset="rear">後排</button></div></div><div class="deployment-grid">${deploymentCells}</div><div class="deployment-summary">${deploymentSummary}</div><div class="encounter-list">${encounters}</div></section>`
  }
  S.selectedUnitIds=S.selectedUnitIds.filter(id=>b.units.some(x=>x.id===id&&x.alive));
  const selected=b.units.filter(x=>S.selectedUnitIds.includes(x.id)&&x.alive),destinations=b.units.filter(x=>x.side==='PLAYER'&&x.alive&&x.destination);let cells='';
  for(let row=0;row<b.rows;row++)for(let col=0;col<b.columns;col++){
    const u=b.units.find(x=>x.alive&&x.row===row&&x.col===col),arrivals=destinations.filter(x=>x.destination.row===row&&x.destination.col===col),effects=S.skillEffects.filter(x=>x.row===row&&x.col===col),iceWall=b.iceWalls?.some(w=>col>=w.startCol&&col<=w.endCol),enemyCast=b.enemyCasts?.find(x=>Math.max(Math.abs(row-x.row),Math.abs(col-x.col))<=x.radius),classes=['battle-cell'];
    if(u)classes.push(u.side==='PLAYER'?'friendly':'enemy');if(u&&S.selectedUnitIds.includes(u.id))classes.push('selected');if(u&&selected.some(x=>x.targetId===u.id))classes.push('targeted');if(u&&S.hitUnitIds.includes(u.id))classes.push('hit');if(u?.holding)classes.push('holding');if(u?.statusEffects?.some(x=>x.id==='iron-wall'))classes.push('iron-wall');if(u?.slowed)classes.push('slowed');if(u?.actionState==='FROZEN')classes.push('frozen');if(u?.actionState==='PAUSED')classes.push('paused');
    if(arrivals.length)classes.push('destination');if(effects.length)classes.push('skill-impact');if(iceWall)classes.push('ice-wall-cell');if(enemyCast)classes.push('danger-zone');if(S.armedSkill)classes.push('skill-aim-cell');
    const title=u?`${u.name} ${u.hp}/${u.maxHp} · 敏捷 ${u.agility} · ${coord(row,col)}`:arrivals.length?`${arrivals.map(x=>x.name).join('、')}目的地 · ${coord(row,col)}`:coord(row,col);
    cells+=`<button class="${classes.join(' ')}" data-row="${row}" data-col="${col}" ${u?`data-unit="${u.id}"`:''} title="${title}">${enemyCast&&!u?'<i class="danger-marker">!</i>':''}${iceWall&&!u?'<i class="ice-wall-marker">🧊</i>':''}${u?`${u.role==='RANGED'?'🏹':u.side==='PLAYER'?'⚔️':'👺'}<span>${u.hp}</span>${u.holding?'<em class="hold-marker">⏸</em>':''}`:''}${arrivals.length?`<em class="destination-marker">⚑</em>`:''}${effects.map(effect=>`<strong class="floating-damage">-${effect.damage}</strong>`).join('')}</button>`;
  }
  const enemies=b.units.filter(x=>x.side==='ENEMY'&&x.alive),inferredTarget=selected.map(x=>x.targetId).find(id=>enemies.some(e=>e.id===id));
  if(!enemies.some(x=>x.id===S.focusTargetId))S.focusTargetId=inferredTarget||null;
  const targets=enemies.map(x=>`<button class="target-chip ${S.focusTargetId===x.id?'locked':''}" data-target-unit="${x.id}"><span>👺 ${x.name}</span><small>${x.hp}/${x.maxHp} HP</small></button>`).join('');
  const selectedLabel=selected.length?`已選 ${selected.length} 名：${selected.map(x=>`${x.name}${x.holding?'（守位）':''} Lv.${x.level}（敏 ${x.agility}）`).join('、')}｜遠攻可邊行邊射`:'先點選藍色我方單位';
  const actionLabels={IDLE:'待命',MOVING:'移動',ADVANCING:'行軍交戰',CHASING:'追擊',ATTACKING:'攻擊',MOVING_ATTACKING:'邊行邊射',HOLDING:'守位',FROZEN:'凍結',PAUSED:'暫停'};
  const movementReadout=selected.length?selected.map(x=>`<span class="unit-route"><strong>${x.name}</strong> <em>${actionLabels[x.actionState]||x.actionState}${x.slowed?' · 緩速':''}</em> · ${coord(x.row,x.col)} ${x.destination?`<b>→ ${coord(x.destination.row,x.destination.col)}</b>`:'<small>· 原地</small>'}</span>`).join(''):'<span class="small">選擇我方角色後顯示行動、位置與目的地</span>';
  if(S.armedSkill&&!selected.some(x=>x.id===S.armedSkill.unitId))S.armedSkill=null;
  const skillTarget=b.units.find(x=>x.id===S.focusTargetId&&x.alive),skillBars=selected.flatMap(unit=>(unit.skills||[]).map(skill=>{
    const needsEnemy=skill.targetType==='ENEMY',distance=skillTarget?Math.max(Math.abs(unit.row-skillTarget.row),Math.abs(unit.col-skillTarget.col)):Infinity,cooling=skill.readyInMs>0,used=!!skill.used,armed=S.armedSkill?.unitId===unit.id&&S.armedSkill?.skillId===skill.id,disabled=used||cooling||(needsEnemy&&(!skillTarget||distance>skill.range));
    const activeEffect=unit.statusEffects?.find(x=>x.id===(skill.effectId??skill.id)),text=used?'本場已使用 · 下一場戰鬥恢復':cooling?`${activeEffect?`${skill.name}生效 ${(activeEffect.expiresInMs/1000).toFixed(1)}s｜`:''}冷卻 ${(skill.readyInMs/1000).toFixed(1)}s`:armed?'瞄準中：點選戰場落點':needsEnemy?(!skillTarget?'先鎖定敵人':distance>skill.range?`目標太遠（需 ${skill.range} 格內）`:skill.description||`${skill.name} · ${skill.damage} 傷害 · ${skill.range} 格`):skill.description;
    const cooldownPercent=cooling?Math.min(100,skill.readyInMs/skill.cooldownMs*100):0,buttonText=used?'已使用':cooling?`${(skill.readyInMs/1000).toFixed(1)}s`:armed?'取消':skill.targetType==='CELL'?'選落點':skill.name;
    return `<div class="skill-bar ${armed?'armed':''} ${['SPECIAL','ULTIMATE'].includes(skill.type)?'special':''}"><span class="skill-icon">${skill.type==='ULTIMATE'?'🌩️':skill.requiresRune?'⚡':unit.role==='RANGED'?'🏹':'💥'}</span><div><b>${unit.name} · ${skill.name}</b><div class="small">${text}</div></div><button class="btn skill-btn ${cooling?'cooling':''}" style="--cooldown:${cooldownPercent}%" data-skill-unit="${unit.id}" data-skill-id="${skill.id}" ${disabled?'disabled':''}><span>${skill.requiresRune&&!cooling&&!used?'畫符':buttonText}</span></button></div>`;
  })).join('')||'<div class="skill-empty small">所選角色暫時未有主動技能</div>';
  const skillOrder=(b.skillOrders||[]).map(x=>`<div class="skill-order">🚶 ${b.units.find(u=>u.id===x.unitId)?.name||'單位'}正前往 ${coord(x.row,x.col)}，到達射程後自動施放冰牆</div>`).join(''),castWarning=(b.enemyCasts||[]).map(x=>`<div class="cast-warning">⚠️ <b>${x.skillName}</b> · ${coord(x.row,x.col)} · ${(x.remainingMs/1000).toFixed(1)} 秒後命中 · 傷害 ${x.damage}</div>`).join('')||(b.bossNextCastInMs!=null?`<div class="boss-cycle">頭目下一次技能：約 ${(b.bossNextCastInMs/1000).toFixed(1)} 秒</div>`:''),pauseWarning=b.globalPause?`<div class="global-pause">⏸ 大絕畫符中 · 全戰場暫停 ${(b.globalPause.remainingMs/1000).toFixed(1)}s</div>`:'';
  return `<section class="card battle-card"><div class="battle-head"><div><b>${b.encounter?.name||'戰鬥'} · ${b.status}</b><div class="small">${b.encounter?.difficulty||''}｜${selectedLabel}</div></div><button class="btn danger" id="retreat">撤退</button></div><div class="battle-legend"><span>🔵 我方</span><span>🔴 敵方</span><span>⚑ 隊形目的地</span><span>⏸ 守位</span><span>保持上下＋前後陣位 · 攻擊目標優先</span><span>R＝行 · C＝列</span></div><div class="movement-readout">${movementReadout}</div><div class="battle-log">${S.battleLog.map(x=>`<div>⚔️ ${x}</div>`).join('')||'<div>等待首次交鋒…</div>'}</div>${pauseWarning}${skillOrder}${castWarning}<div class="battle-pan-wrap"><span>我方</span><input id="battle-pan" class="battle-pan" type="range" min="0" max="1000" value="0" aria-label="移動戰場畫面"><span>敵方</span></div><div class="battle-scroll"><div class="battle-grid">${cells}</div></div><div class="battle-controls"><div class="battle-targets"><div class="small">快速鎖定敵人</div>${targets}</div><div class="unit-controls"><button class="btn alt" id="select-all">全選我方</button><button class="btn hold-btn" id="hold-position" ${selected.length?'':'disabled'}>⏸ 守住原位</button><button class="btn alt" id="clear-selection">清除選擇</button><span class="small">新移動／攻擊命令會解除守位</span></div><div class="skill-stack">${skillBars}</div></div></section>`;
}
function qty(g){return Math.max(1,Number(document.querySelector(`[data-q="${g}"]`)?.value||1))}
function wire(){
  // P2-07 Decision 2: the separate "進入XX城" [data-enter-city] button no longer exists (removed
  // from worldmap.js's travelStatusHtml) — [data-city] below (the city marker itself) is now the
  // only wiring that calls enterCity().
  // P2-07 City Hub Navigation: [data-hub-leave] has exactly one handler (below, .onclick=exitCity)
  // — the real server-authoritative exit command, which itself sets S.tab via leaveCityHub().tab.
  // Do not add a second addEventListener for it here; a prior version double-fired (an
  // addEventListener doing a client-only tab flip, PLUS this .onclick calling exitCity), which
  // produced a redundant intermediate render on every single tap.
  document.querySelectorAll('[data-market-mode]').forEach(b=>b.onclick=()=>{S.marketMode=b.dataset.marketMode;render()});document.querySelectorAll('[data-buy]').forEach(b=>b.onclick=()=>openQuote(b.dataset.buy,'BUY',qty(b.dataset.buy)));document.querySelectorAll('[data-sell]').forEach(b=>b.onclick=()=>openQuote(b.dataset.sell,'SELL',qty(b.dataset.sell)));document.querySelectorAll('[data-equipment-sell]').forEach(b=>b.onclick=()=>openEquipmentQuote(b.dataset.equipmentSell));document.querySelectorAll('[data-store]').forEach(b=>b.onclick=()=>move('CARGO_TO_STORAGE',b.dataset.store));document.querySelectorAll('[data-withdraw]').forEach(b=>b.onclick=()=>move('STORAGE_TO_CARGO',b.dataset.withdraw));document.querySelectorAll('[data-store-equipment]').forEach(b=>b.onclick=()=>storeEquipment(b.dataset.storeEquipment));document.querySelectorAll('[data-withdraw-equipment]').forEach(b=>b.onclick=()=>withdrawEquipment(b.dataset.withdrawEquipment,b.dataset.withdrawUnit));document.querySelectorAll('[data-transfer-item]').forEach(b=>b.onclick=()=>transferEquipment(b.dataset.transferItem,b.dataset.transferUnit));document.querySelectorAll('[data-city]').forEach(el=>el.onclick=()=>handleCityTap(el.dataset.city,{snap:S.snap,cities:S.cities,travel,reroute,enter:enterCity}));document.querySelector('#arrive')?.addEventListener('click',arrival);document.querySelectorAll('[data-hub-enter]').forEach(b=>b.onclick=()=>{S.tab=b.dataset.hubEnter;render()});document.querySelector('[data-view-map]')?.addEventListener('click',()=>{S.tab='map';render()});document.querySelectorAll('[data-back-hub]').forEach(b=>b.onclick=()=>{S.tab='hub';render()});document.querySelectorAll('[data-settle-loot]').forEach(b=>b.onclick=()=>settleLoot(b.dataset.settleLoot,b.dataset.ownerUnit));document.querySelectorAll('[data-equip-item]').forEach(b=>b.onclick=()=>equip(b.dataset.equipItem,b.dataset.equipUnit));document.querySelectorAll('[data-unequip-item]').forEach(b=>b.onclick=()=>unequip(b.dataset.unequipItem,b.dataset.equipUnit));document.querySelectorAll('[data-deploy-unit]').forEach(b=>b.onclick=()=>toggleDeploymentUnit(b.dataset.deployUnit));document.querySelectorAll('[data-deployment-row]').forEach(b=>b.onclick=()=>deploymentTap(Number(b.dataset.deploymentRow),Number(b.dataset.deploymentCol),b.dataset.deploymentUnit));document.querySelectorAll('[data-deployment-preset]').forEach(b=>b.onclick=()=>setDeploymentPreset(b.dataset.deploymentPreset));document.querySelectorAll('[data-start-encounter]').forEach(b=>b.onclick=()=>startBattle(b.dataset.startEncounter));document.querySelector('#retreat')?.addEventListener('click',retreatBattle);document.querySelector('#select-all')?.addEventListener('click',selectAllUnits);document.querySelector('#hold-position')?.addEventListener('click',holdPosition);document.querySelector('#clear-selection')?.addEventListener('click',clearSelection);document.querySelectorAll('.battle-cell').forEach(c=>c.onclick=()=>battleTap(c));document.querySelectorAll('[data-target-unit]').forEach(b=>b.onclick=()=>targetEnemy(b.dataset.targetUnit));document.querySelectorAll('[data-skill-unit]').forEach(b=>b.onclick=()=>useSkill(b.dataset.skillUnit,b.dataset.skillId));document.querySelector('#battle-pan')?.addEventListener('input',panBattle);document.querySelector('#map-view-toggle')?.addEventListener('click',toggleMapView);
  document.querySelectorAll('[data-hub-leave]').forEach(b=>b.onclick=exitCity);
  document.querySelectorAll('[data-bus-destination]').forEach(b=>b.onclick=()=>openBusConfirm(b.dataset.busDestination));
}
function toggleMapView(){S.mapView=S.mapView==='follow'?'full':'follow';if(S.mapView==='full'){joystickActive=false;applyMovementIntent({active:false,dirX:0,dirY:0,magnitude:0})}render()}
async function settleLoot(decision,ownerUnitId){const battleId=S.battle?.id;if(!battleId)return;const r=await command('/api/commands/battle/settle-loot',{battleId,decision,...(ownerUnitId?{ownerUnitId}:{})});if(r.status==='REJECTED')return toast(r.errorCode);const owner=S.roster.find(x=>x.id===ownerUnitId)?.name;toast(decision==='KEEP'?`戰利品已放入${owner}背包`:'已放棄戰利品');await refresh()}
async function equip(itemId,unitId){const r=await command('/api/commands/equipment/equip',{itemId,unitId});if(r.status==='REJECTED')return toast('裝備失敗');toast('裝備完成，能力已更新');await refresh()}
async function unequip(itemId,unitId){const r=await command('/api/commands/equipment/unequip',{itemId,unitId});if(r.status==='REJECTED')return toast('卸下失敗');toast('裝備已放回角色背包');await refresh()}
async function transferEquipment(itemId,toUnitId){const r=await command('/api/commands/equipment/transfer',{itemId,toUnitId});if(r.status==='REJECTED')return toast(r.errorCode);toast(`已轉交畀${S.roster.find(x=>x.id===toUnitId)?.name}`);await refresh()}
async function storeEquipment(itemId){const r=await command('/api/commands/equipment/store',{itemId,cityId:S.snap.cityId});if(r.status==='REJECTED')return toast(r.errorCode);toast(`裝備已存入${cityName(S.snap.cityId)}倉庫`);await refresh()}
async function withdrawEquipment(itemId,toUnitId){const r=await command('/api/commands/equipment/withdraw',{itemId,cityId:S.snap.cityId,toUnitId});if(r.status==='REJECTED')return toast(r.errorCode);toast(`裝備已交畀${S.roster.find(x=>x.id===toUnitId)?.name}`);await refresh()}
async function openQuote(goodTypeId,side,requestedQuantity){S.modal={quote:await post('/api/commands/market/quote',{characterId:'char-demo',goodTypeId,side,requestedQuantity}),re:false,key:crypto.randomUUID()};showModal()}
async function openEquipmentQuote(itemId){S.modal={quote:await post('/api/commands/market/equipment-quote',{itemId}),re:false,key:crypto.randomUUID()};showModal()}
function showModal(){document.querySelector('.modalbg')?.remove();const q=S.modal.quote,d=document.createElement('div');d.className='modalbg';const bus=S.modal.kind==='BUS';d.innerHTML=bus?`<div class="modal"><div class="small">巴士車費確認</div><h2>🚌 前往 ${cityName(q.toCityId)}</h2><p>車費 <b>💰 ${q.fareGold}</b> · 車程約 <b>${(q.travelMs/1000).toFixed(1)} 秒</b></p><div class="actions"><button class="btn" id="ok">確認上車</button><button class="btn alt" id="cancel">取消</button></div></div>`:`<div class="modal"><div class="small">${S.modal.re?'價格已變，請重新確認':'Confirm Quote'}</div><h2>${q.side==='BUY'?'買入':'賣出'} ${q.itemName||q.goodTypeId}</h2><p>數量 <b>${q.fillQuantity}</b> · 單價 <b>${q.unitPrice}</b> · Total <b>${q.total}</b></p><div class="actions"><button class="btn" id="ok">確認成交</button><button class="btn alt" id="cancel">取消</button></div></div>`;document.body.append(d);d.querySelector('#cancel').onclick=()=>{S.modal=null;d.remove()};d.querySelector('#ok').onclick=confirm}
async function confirm(){const q=S.modal.quote,key=S.modal.key;if(S.modal.kind==='BUS'){const r=await command('/api/commands/transport/bus/start',{destinationCityId:q.toCityId},key);if(r.status==='REJECTED')return toast(r.errorCode==='ERR_INSUFFICIENT_GOLD'?'金幣不足，未能上車':r.errorCode);S.modal=null;document.querySelector('.modalbg')?.remove();S.tab='map';toast(`已上車前往 ${cityName(q.toCityId)}`);return refresh()}const path=q.kind==='EQUIPMENT'?'/api/commands/market/equipment-sell':q.side==='BUY'?'/api/commands/market/buy':'/api/commands/market/sell',r=await command(path,{approvedQuote:q},key);if(r.status==='RECONFIRM_REQUIRED'){S.modal={quote:r.data,re:true,key};showModal();toast('市場價格有變');return}if(r.status==='REJECTED'){toast(r.errorCode);return}S.modal=null;document.querySelector('.modalbg')?.remove();toast(q.side==='BUY'?'買入成功':'賣出成功');await refresh()}
async function move(direction,goodTypeId){const r=await command('/api/commands/container/move',{direction,cityId:S.snap.cityId,goodTypeId,quantity:1});if(r.status==='REJECTED')return toast(r.errorCode);toast('完成');await refresh()}
async function enterCity(destinationCityId){const r=await command('/api/commands/city/enter',{destinationCityId});if(r.status==='REJECTED')return toast(r.errorCode==='ERR_CITY_ENTRY_OUT_OF_RANGE'?'未到城市入口':r.errorCode);toast(`已進入${cityName(destinationCityId)}`);await refresh()}
async function exitCity(){const r=await command('/api/commands/city/exit',{});if(r.status==='REJECTED')return toast(r.errorCode);S.tab=leaveCityHub().tab;toast('已離開城市');await refresh()}
function openBusConfirm(destinationCityId){const quote=busQuote(S.snap.cityId,destinationCityId,S.cities);if(!quote)return;S.modal={kind:'BUS',quote,key:crypto.randomUUID()};showModal()}
async function travel(destinationCityId){const r=await command('/api/commands/travel/start',{destinationCityId});if(r.status==='REJECTED')return toast(r.errorCode==='ERR_BATTLE_SETTLEMENT_REQUIRED'?'請先完成戰利品結算':r.errorCode);S.tab='map';toast('已出發');await refresh()}
async function reroute(destinationCityId){const r=await command('/api/commands/travel/reroute',{destinationCityId});if(r.status==='REJECTED')return toast(r.errorCode);toast(`已改道去 ${cityName(destinationCityId)}`);await refresh()}
async function arrival(){const r=await command('/api/commands/travel/resolve-arrival',{});if(r.status==='REJECTED')return toast(r.errorCode==='ERR_NOT_ARRIVED'?'仲未到埗':r.errorCode);S.tab='map';toast('已到埗');await refresh()}
function toggleDeploymentUnit(unitId){const team=S.deploymentUnitIds||[];if(unitId==='hero'){S.deploymentSelectedUnitId='hero';toast('主角必須出戰 · 已選作部署');return render()}S.deploymentUnitIds=team.includes(unitId)?team.filter(id=>id!==unitId):team.length<3?[...team,unitId]:team;if(team.length===3&&!team.includes(unitId))toast('Prototype 隊伍上限為 3 人');ensureDeployment();render()}
function deploymentTap(row,col,unitId){if(unitId){S.deploymentSelectedUnitId=unitId;return render()}if(!S.deploymentSelectedUnitId)return toast('先點部署區內一名角色');S.deploymentPositions[S.deploymentSelectedUnitId]={row,col};render()}
function setDeploymentPreset(name){const preset=deploymentPresets[name];if(!preset)return;for(const id of S.deploymentUnitIds||[]){const [row,col]=preset[id];S.deploymentPositions[id]={row,col}}ensureDeployment();toast({balanced:'均衡陣',forward:'前壓陣',rear:'後排陣'}[name]);render()}
async function startBattle(encounterId='bandit-patrol'){const team=S.deploymentUnitIds||[];if(!team.length)return toast('請先選擇出戰角色');ensureDeployment();const deployments=team.map(unitId=>({unitId,...S.deploymentPositions[unitId]})),r=await command('/api/commands/battle/start',{encounterId,unitIds:team,deployments});if(r.status==='REJECTED'){const message={ERR_BATTLE_SETTLEMENT_REQUIRED:'請先完成戰利品結算',ERR_INVALID_STATE:'旅行中不能開始戰鬥'}[r.errorCode]||r.errorCode;return toast(message)}S.selectedUnitIds=[team[0]];S.focusTargetId=null;S.armedSkill=null;S.battleScrollLeft=0;S.battleLog=[];toast(`${S.encounters.find(x=>x.id===encounterId)?.name||'戰鬥'}開始 · ${team.length} 人出戰`);await refresh()}
async function retreatBattle(){const r=await command('/api/commands/battle/retreat',{});if(r.status==='REJECTED')return toast(r.errorCode);S.selectedUnitIds=[];S.focusTargetId=null;S.armedSkill=null;toast('已撤退');await refresh()}
function selectAllUnits(){S.selectedUnitIds=S.battle?.units.filter(x=>x.side==='PLAYER'&&x.alive).map(x=>x.id)||[];render()}
async function holdPosition(){if(!S.selectedUnitIds.length)return;const count=S.selectedUnitIds.length,r=await command('/api/commands/battle/hold',{unitIds:S.selectedUnitIds});if(r.status==='REJECTED')return toast(r.errorCode);S.selectedUnitIds=[];toast(`${count} 名單位守住原位`);await refresh()}
function clearSelection(){S.selectedUnitIds=[];render()}
async function battleTap(cell){
  if(S.armedSkill)return castCellSkill(Number(cell.dataset.row),Number(cell.dataset.col));
  const unit=S.battle?.units.find(x=>x.id===cell.dataset.unit);
  if(unit?.side==='PLAYER'){S.selectedUnitIds=S.selectedUnitIds.includes(unit.id)?S.selectedUnitIds.filter(id=>id!==unit.id):[...S.selectedUnitIds,unit.id];render();return}
  if(!S.selectedUnitIds.length)return toast('請先選擇我方單位');
  const assisted=unit?.side==='ENEMY'?unit:nearestEnemy(Number(cell.dataset.row),Number(cell.dataset.col));
  if(assisted)return targetEnemy(assisted.id);
  const row=Number(cell.dataset.row),col=Number(cell.dataset.col),count=S.selectedUnitIds.length,r=await command('/api/commands/battle/move',{unitIds:S.selectedUnitIds,row,col});if(r.status==='REJECTED')return toast(r.errorCode);S.selectedUnitIds=[];toast(count>1?`${count} 名編隊移動 → ${coord(row,col)}`:`移動目的地 → ${coord(row,col)}`);await refresh();
}
function nearestEnemy(row,col){
  return S.battle?.units.filter(x=>x.side==='ENEMY'&&x.alive).map(x=>({unit:x,distance:Math.hypot((x.col-col)*18,(x.row-row)*42)})).filter(x=>x.distance<=46).sort((a,b)=>a.distance-b.distance)[0]?.unit||null;
}
async function targetEnemy(targetId){
  if(!S.selectedUnitIds.length)return toast('請先選擇我方單位');
  const count=S.selectedUnitIds.length,r=await command('/api/commands/battle/target',{unitIds:S.selectedUnitIds,targetId});if(r.status==='REJECTED')return toast(r.errorCode);S.focusTargetId=targetId;S.selectedUnitIds=[];toast(`${count} 名單位已鎖定攻擊`);await refresh();
}
async function useSkill(unitId,skillId){
  const unit=S.battle?.units.find(x=>x.id===unitId),skill=unit?.skills?.find(x=>x.id===skillId);if(skill?.targetType==='CELL'){S.armedSkill=S.armedSkill?.unitId===unitId&&S.armedSkill?.skillId===skillId?null:{unitId,skillId};render();return}const targetId=skill?.targetType==='SELF'?unitId:S.focusTargetId;if(!targetId)return toast('請先鎖定敵人');
  if(skill?.requiresRune){if(skill.type==='ULTIMATE'){const pause=await command('/api/commands/battle/global-pause',{unitId,action:'BEGIN'});if(pause.status==='REJECTED')return toast('未能暫停戰場')}return openRunePad(unitId,skillId,targetId,skill)}
  await castTargetSkill(unitId,skillId,targetId);
}
async function castTargetSkill(unitId,skillId,targetId,rune){
  const r=await command('/api/commands/battle/skill',{unitId,skillId,targetId,...(rune?{rune}:{})});if(r.status==='REJECTED'){if(r.errorCode==='ERR_INVALID_SKILL_TARGET'){S.focusTargetId=null;await refresh()}const message={ERR_SKILL_OUT_OF_RANGE:'目標超出技能範圍',ERR_SKILL_COOLDOWN:'技能冷卻中',ERR_INVALID_SKILL_TARGET:'目標已失效，請重新鎖定',ERR_INVALID_RUNE:'符號不正確'}[r.errorCode]||'技能使用失敗';toast(message);return r}if(r.data.damage)S.skillEffects=r.data.hits?.length?r.data.hits.filter(x=>x.damage).map(x=>({...x.targetPosition,damage:x.damage})):[{...r.data.targetPosition,damage:r.data.damage}];const resultText=r.data.resultText;S.battleLog.unshift(`${r.data.unitName}施放${r.data.skillName}，${resultText}`);S.battleLog=S.battleLog.slice(0,3);toast(`${r.data.skillName}！${resultText}`);await refresh();if(r.data.damage)setTimeout(()=>{S.skillEffects=[];if(S.tab==='battle')render()},720);return r;
}
function openRunePad(unitId,skillId,targetId,skill){
  const rune=skill.requiresRune,isUltimate=skill.type==='ULTIMATE',symbol=rune==='O'?'O':'Z';document.querySelector('.rune-bg')?.remove();const d=document.createElement('div');d.className='rune-bg';d.innerHTML=`<div class="rune-modal"><div><b>${isUltimate?'🌩️ 天雷陣':'⚡ 雷擊符'}</b><p class="small">一筆畫出 ${symbol}。${isUltimate?'畫符期間全戰場暫停，12 秒後自動恢復。':'畫符期間戰鬥照常進行。'}</p></div><canvas class="rune-pad" width="600" height="360"></canvas><div class="rune-status">按住畫板開始畫符</div><div class="actions"><button class="btn alt" data-rune-clear>重畫</button><button class="btn danger" data-rune-cancel>取消</button></div></div>`;document.body.append(d);const canvas=d.querySelector('canvas'),ctx=canvas.getContext('2d'),status=d.querySelector('.rune-status');let points=[],drawing=false;
  const guide=()=>{ctx.clearRect(0,0,600,360);ctx.save();ctx.setLineDash([12,12]);ctx.strokeStyle='#6d6555';ctx.lineWidth=12;ctx.beginPath();if(rune==='O')ctx.ellipse(300,180,190,115,0,0,Math.PI*2);else{ctx.moveTo(100,75);ctx.lineTo(500,75);ctx.lineTo(100,285);ctx.lineTo(500,285)}ctx.stroke();ctx.restore()};guide();
  const point=e=>{const r=canvas.getBoundingClientRect();return{x:(e.clientX-r.left)/r.width*600,y:(e.clientY-r.top)/r.height*360}};
  canvas.onpointerdown=e=>{drawing=true;points=[point(e)];canvas.setPointerCapture(e.pointerId);guide();ctx.strokeStyle='#ffd66b';ctx.lineWidth=14;ctx.lineCap='round';ctx.lineJoin='round';ctx.beginPath();ctx.moveTo(points[0].x,points[0].y);status.textContent='畫符中…'};
  canvas.onpointermove=e=>{if(!drawing)return;const p=point(e);points.push(p);ctx.lineTo(p.x,p.y);ctx.stroke()};
  canvas.onpointerup=async()=>{if(!drawing)return;drawing=false;const first=points[0],last=points.at(-1),xs=points.map(p=>p.x),ys=points.map(p=>p.y),topRight=points.findIndex(p=>p.x>390&&p.y<150),bottomLeft=points.findIndex((p,i)=>i>topRight&&p.x<240&&p.y>210),closed=Math.hypot(first.x-last.x,first.y-last.y)<110,valid=rune==='O'?points.length>=12&&Math.max(...xs)-Math.min(...xs)>280&&Math.max(...ys)-Math.min(...ys)>170&&closed:points.length>=8&&first.x<220&&first.y<150&&topRight>0&&bottomLeft>topRight&&last.x>390&&last.y>210;if(!valid){status.textContent=`未認到 ${symbol} 符，撳「重畫」再試`;status.className='rune-status invalid';return}status.textContent='畫符成功！';status.className='rune-status valid';d.remove();const result=await castTargetSkill(unitId,skillId,targetId,rune);if(isUltimate&&result?.status==='REJECTED')await command('/api/commands/battle/global-pause',{unitId,action:'END'})};
  d.querySelector('[data-rune-clear]').onclick=()=>{points=[];status.textContent='按住畫板重新畫符';status.className='rune-status';guide()};d.querySelector('[data-rune-cancel]').onclick=async()=>{d.remove();if(isUltimate)await command('/api/commands/battle/global-pause',{unitId,action:'END'})};
}
async function castCellSkill(row,col){
  const armed=S.armedSkill;if(!armed)return;const r=await command('/api/commands/battle/skill',{unitId:armed.unitId,skillId:armed.skillId,row,col});if(r.status==='REJECTED'){const message={ERR_SKILL_OUT_OF_RANGE:'落點超出技能射程',ERR_SKILL_COOLDOWN:'技能冷卻中',ERR_NO_TARGET_IN_AREA:'範圍內沒有敵人',ERR_INVALID_SKILL_TARGET:'無效落點',ERR_NO_SKILL_APPROACH_CELL:'沒有可到達的施法位置'}[r.errorCode]||'技能使用失敗';return toast(message)}S.armedSkill=null;if(r.data.queued){S.battleLog.unshift(`${r.data.unitName}${r.data.resultText}`);S.battleLog=S.battleLog.slice(0,3);toast(`${r.data.unitName}正前往施法位置`);await refresh();return}S.skillEffects=(r.data.hits||[]).filter(x=>x.damage).map(x=>({...x.targetPosition,damage:x.damage}));S.battleLog.unshift(`${r.data.unitName}施放${r.data.skillName}，${r.data.resultText}`);S.battleLog=S.battleLog.slice(0,3);toast(`${r.data.skillName}！${r.data.resultText}`);await refresh();setTimeout(()=>{S.skillEffects=[];if(S.tab==='battle')render()},720);
}
function setupBattlePan(){
  const scroll=document.querySelector('.battle-scroll'),pan=document.querySelector('#battle-pan');if(!scroll||!pan)return;
  scroll.scrollLeft=S.battleScrollLeft;
  const syncPan=()=>{S.battleScrollLeft=scroll.scrollLeft;if(!S.battlePanDragging){const max=scroll.scrollWidth-scroll.clientWidth;pan.value=max?String(Math.round(scroll.scrollLeft/max*1000)):'0'}};
  const start=()=>{S.battlePanDragging=true};
  const finish=()=>{S.battlePanDragging=false;syncPan()};
  syncPan();scroll.addEventListener('scroll',syncPan,{passive:true});pan.addEventListener('pointerdown',start,{passive:true});pan.addEventListener('touchstart',start,{passive:true});pan.addEventListener('change',finish);pan.addEventListener('pointerup',finish,{passive:true});pan.addEventListener('touchend',finish,{passive:true});
}
function panBattle(event){
  const scroll=document.querySelector('.battle-scroll');if(!scroll)return;S.battlePanDragging=true;
  const value=Number(event.target.value);cancelAnimationFrame(S.battlePanFrame);S.battlePanFrame=requestAnimationFrame(()=>{const max=scroll.scrollWidth-scroll.clientWidth;S.battleScrollLeft=max*value/1000;scroll.scrollLeft=S.battleScrollLeft});
}
let travelArrivalRefreshing=false;
function updateTravelProgress(){
  const fill=document.querySelector('#travel-fill');
  if(fill){const start=Number(fill.dataset.start),end=Number(fill.dataset.end),span=end-start,p=span>0?Math.max(0,Math.min(1,(Date.now()-start)/span)):1;fill.style.width=`${p*100}%`;const label=document.querySelector('#travel-progress-pct');if(label)label.textContent=`${Math.round(p*100)}%`;if(p>=1&&!travelArrivalRefreshing){travelArrivalRefreshing=true;refresh().finally(()=>{travelArrivalRefreshing=false})}}
  // P2-06 — Charlie Clarification 1: client-side defense in depth. Even though the server now nulls
  // activeTravel once a journey is ARRIVED, travel animation must never be able to drive the hero
  // marker unless the snapshot itself says the player is currently TRAVELING — a non-TRAVELING state
  // (stale/inconsistent data, a race during reload) must never let a leftover/old activeTravel move
  // the marker.
  const hero=document.querySelector('.hero-marker');
  if(hero&&S.snap?.state==='TRAVELING'&&S.snap.activeTravel){
    const pos=computeTravelPosition(S.snap.activeTravel.segments,indexById(S.cities),indexById(S.roads),S.snap.activeTravel.startedAt,Date.now());
    if(pos){hero.setAttribute('cx',pos.x);hero.setAttribute('cy',pos.y)}
  }
}
// P1-07C — Mobile Movement Telemetry (diagnostic-only, Issue #21) state. Read-only observation of
// the existing movement path: nothing here is ever fed back into movement/prediction/
// reconciliation/camera — see telemetry.js for the pure math/formatting.
let telemetryFpsEma=null,telemetryLastFrameTimestamp=null,telemetryLastOverlayPatchAt=0,telemetryMoveInFlightCount=0,telemetryLastCompletedAt=null,telemetryLastRttMs=null,telemetryLastResponseGapMs=null,telemetryLastStatus=null,telemetryLastErrorCode=null,telemetryLastThrottled=null,telemetryLastCollided=null;
// P1-07 Root Cause Measurement Test — additional read-only observation state (Issue #23 follow-up).
// Same rule as the P1-07C state above: nothing here is ever read back by movement/prediction/
// reconciliation/network code — only patchTelemetryOverlay and the tail of tickMovementFrame below
// read/write these.
let telemetryCapFrozenCurrentMs=0,telemetryCapFrozenTotalMs=0,telemetryActiveMovementTotalMs=0,telemetryHardResetCount=0,telemetryLastCorrectionDistance=null,telemetryLastCapFrozen=false;
// Single call site for all three /world/move completion paths (ACCEPTED, REJECTED, a thrown
// network/command exception) so RTT/response-gap timing is computed identically every time — see
// P1-07C Merge Gate direction. throttled/collided are explicitly nulled on REJECTED/ERROR so the
// overlay never shows a stale value left over from a previous ACCEPTED response.
function recordMoveTelemetry({status,errorCode,throttled,collided,startedAt}){
  const timing=nextMoveTiming(startedAt,performance.now(),telemetryLastCompletedAt);
  telemetryLastRttMs=timing.rttMs;telemetryLastResponseGapMs=timing.responseGapMs;telemetryLastCompletedAt=timing.completedAt;
  telemetryLastStatus=status;telemetryLastErrorCode=errorCode;telemetryLastThrottled=throttled;telemetryLastCollided=collided;
}
// P1-07C: FPS/lead are computed every frame (see tickMovementFrame); only this DOM write is
// throttled to TELEMETRY_OVERLAY_PATCH_INTERVAL_MS, so the debug overlay itself doesn't add
// measurable DOM load to the FPS it's trying to measure — per P1-07C Merge Gate direction §3.
function patchTelemetryOverlay(now,leadPx){
  if(now-telemetryLastOverlayPatchAt<TELEMETRY_OVERLAY_PATCH_INTERVAL_MS)return;
  telemetryLastOverlayPatchAt=now;
  const set=(id,text)=>{const el=document.querySelector(id);if(el)el.textContent=text};
  set('#telemetry-fps',telemetryFpsEma==null?'…':String(Math.round(telemetryFpsEma)));
  set('#telemetry-rtt',formatMs(telemetryLastRttMs));
  set('#telemetry-gap',formatMs(telemetryLastResponseGapMs));
  set('#telemetry-lead',formatLeadReadout(leadPx,MAX_PREDICTION_LEAD));
  set('#telemetry-inflight',formatFlag(telemetryMoveInFlightCount>0));
  set('#telemetry-throttled',formatFlag(telemetryLastThrottled));
  set('#telemetry-collided',formatFlag(telemetryLastCollided));
  set('#telemetry-suspended',formatFlag(predictionSuspended));
  set('#telemetry-status',telemetryLastStatus||'…');
  set('#telemetry-errorcode',telemetryLastErrorCode||'–');
  // P1-07 Root Cause Measurement Test — same throttled-DOM-write pattern as the P1-07C fields
  // above; the underlying counters are still updated every frame/response (see tickMovementFrame
  // and sendWorldMove), only this overlay write is throttled.
  set('#telemetry-leadcaphit',formatFlag(isNearLeadCap(leadPx,MAX_PREDICTION_LEAD)));
  set('#telemetry-capfrozen',formatFlag(telemetryLastCapFrozen));
  set('#telemetry-frozen-current',formatMs(telemetryCapFrozenCurrentMs));
  set('#telemetry-frozen-total',formatMs(telemetryCapFrozenTotalMs));
  set('#telemetry-frozen-ratio',formatPercent(capFrozenRatio(telemetryCapFrozenTotalMs,telemetryActiveMovementTotalMs)));
  set('#telemetry-correction',formatPx(telemetryLastCorrectionDistance));
  set('#telemetry-hardresets',formatCount(telemetryHardResetCount));
}
// P1-07A: sendWorldMove is data-only — it updates the authoritative S.snap and nothing else.
// All on-screen presentation (hero marker position, camera viewBox) is owned exclusively by
// tickMovementFrame()'s requestAnimationFrame loop below. This keeps "what we ask the server for"
// and "what we show on screen" cleanly separated, per P1-07A's server-authoritative requirement.
//
// P1-07 Movement Failure Diagnostic Hotfix — a real-device report found joystick input and
// camera/UI working normally while the character never actually moved, with zero on-screen
// indication of why. This hotfix makes failures visible (REJECTED errorCode, or a network/command
// exception) — it does not change server behavior, retry behavior, or any movement/throttle/
// collision logic.
//
// P1-07B — REJECTED and a network/command exception also set predictionSuspended=true, so
// tickMovementFrame stops advancing the predicted position further ahead while something is
// actually wrong (rather than just capping its lead, which is for normal latency, not failure).
// A fresh successful, non-collided (ACCEPTED, collided:false) response clears it again. See
// tickMovementFrame for how this combines with reconciliation.
//
// P1-07B Merge Gate review — an ACCEPTED response with collided:true also suspends prediction.
// Client prediction sweeps in small per-frame steps; server.mjs's moveWorld() sweeps in one shot
// from the authoritative serverPosition to the requested target. On a fast turn right against an
// obstacle these two sweeps can briefly disagree, so once the server has actually said collided,
// prediction must stop advancing (not just cap its lead) until reconciliation — driven by the
// same collided:true — has pulled it back in line, exactly like the REJECTED/exception case.
// P1-07D — Latency-Decoupled Movement (Issue #23). `generation` travels alongside the target as
// pure client-side metadata (never part of the actual /world/move payload below — the API shape is
// unchanged) so a pending, coalesced target that only gets dequeued after its movement intent has
// gone stale (release, or a meaningful direction/magnitude change — see nextGenerationAnchor) is
// dropped by guardStaleGeneration BEFORE ever reaching the network. Production and the test suite
// call this exact same guardStaleGeneration export — never a hand-duplicated copy of the same check.
const networkMoveCall=({x,y,moveSequence})=>command('/api/commands/world/move',{targetX:x,targetY:y,moveSequence});
const guardedMoveCall=guardStaleGeneration(networkMoveCall,()=>movementGeneration);
let movementRequestSequence=0,latestCompletedMovementSequence=0;
// P4-02 Merge Gate fix — pure, DOM/network-free extraction of the order-independent decision the
// completion-reorder race fix depends on: does this world command response mean the server already
// has an ACTIVE battle, regardless of which of two in-flight requests it belongs to or what order
// their HTTP completions arrive in? Exported so the race (see sendWorldMove's own comment below, and
// P4-02-M/N) can be exercised directly and deterministically, without needing a DOM/fetch environment.
//
// P4-03B — renamed from battleAlreadyActiveFromMoveResponse: the response shape this checks
// (status/data.encounterTriggered/errorCode) is identical for /api/commands/world/move AND the new
// /api/commands/world/heartbeat (see server.mjs's worldHeartbeat()/moveWorld()), and the logic itself
// never referenced anything move-specific — reused as-is by sendWorldHeartbeat below, not
// re-implemented.
export function battleAlreadyActiveFromWorldResponse(r){
  if(!r)return false;
  return r.status==='ACCEPTED'?r.data?.encounterTriggered===true:r.errorCode==='ERR_BATTLE_ACTIVE';
}
const sendWorldMove=async(target)=>{
  const requestSequence=++movementRequestSequence;
  const{generation}=target;
  // P1-07C: startedAt is taken at the true start of the network command (this callback only ever
  // runs once createCoalescingSender actually dequeues it — see Plan §2), never at enqueue time.
  const startedAt=performance.now();
  telemetryMoveInFlightCount++;
  let outcome;
  try{
    outcome=await guardedMoveCall({...target,moveSequence:requestSequence}); // server also orders parallel commands by this sequence
  }catch(err){
    console.error('sendWorldMove: command() threw (network or server exception)',err);
    // This request DID reach the network (guardedMoveCall only throws from inside networkMoveCall);
    // it may still have gone stale WHILE genuinely in flight — a different check from
    // guardStaleGeneration's pre-send one, deciding whether THIS error should drive UI feedback.
    const stale=generation!==movementGeneration;
    if(!stale){
      toast(`移動指令失敗：${err?.message||'網絡或伺服器錯誤'}`);
      predictionSuspended=true;
    }
    recordMoveTelemetry({status:'ERROR',errorCode:err?.message||null,throttled:null,collided:null,startedAt});
    telemetryMoveInFlightCount=Math.max(0,telemetryMoveInFlightCount-1);
    return;
  }
  if(outcome.dropped){
    // Never reached the network — no RTT occurred, so telemetry is deliberately left untouched
    // rather than fabricating a completed-request data point.
    telemetryMoveInFlightCount=Math.max(0,telemetryMoveInFlightCount-1);
    return;
  }
  const r=outcome.result;
  // P4-02 Merge Gate fix — a response reporting the server already has an ACTIVE battle (either this
  // very request just triggered one, or a DIFFERENT in-flight request already did and this one simply
  // bounced off the server's battleIsActive() guard) must resync the client no matter what order the
  // HTTP completions happen to arrive in. Checked BEFORE the completion-order discard below on
  // purpose: that guard exists to stop an OLDER response's own worldPosition from rolling presentation
  // truth backwards, but refresh() here fetches fresh authoritative state directly rather than trusting
  // this response's payload, so bypassing that guard here can never itself cause a rollback. Without
  // this, the following race was possible — request A genuinely triggers an encounter, a later request
  // B's ERR_BATTLE_ACTIVE response completes FIRST (bumping the completion-order counter), then A's own
  // encounterTriggered:true response arrives and gets silently discarded by that same counter check,
  // leaving the client stuck on the World Map with no battle showing until a manual reload — even
  // though the server has an ACTIVE battle the whole time. Also deliberately not gated on `stale`
  // (generation): the battle is real server-side either way, same rationale as encounterTriggered
  // already had before this fix.
  //
  // P4-02 Final Merge Gate fix — this branch must also advance the completion watermark itself
  // (never move it backwards, hence Math.max): once ANY response has confirmed the server already
  // has an ACTIVE battle, an older, ordinary ACCEPTED response for some earlier request C (still
  // in flight when the encounter triggered, completing only now) must never be allowed to pass the
  // completion-order discard below and re-apply its own stale worldPosition/predictionSuspended/
  // catchUpDebt over the just-resynced Battle presentation state. Without this, that discard's
  // `requestSequence<latestCompletedMovementSequence` check could still let C through if C's own
  // sequence happens to be higher than whatever the watermark last was.
  if(battleAlreadyActiveFromWorldResponse(r)){
    latestCompletedMovementSequence=Math.max(latestCompletedMovementSequence,requestSequence);
    predictionSuspended=true;
    await refresh();
    recordMoveTelemetry({status:r.status,errorCode:r.status==='REJECTED'?r.errorCode:null,throttled:r.data?.throttled??null,collided:r.data?.collided??null,startedAt});
    telemetryMoveInFlightCount=Math.max(0,telemetryMoveInFlightCount-1);
    return;
  }
  // Parallel transport: server rejects stale arrival order using moveSequence, while this completion
  // guard prevents an older HTTP completion from rolling client presentation truth backwards.
  if(requestSequence<latestCompletedMovementSequence){telemetryMoveInFlightCount=Math.max(0,telemetryMoveInFlightCount-1);return}
  latestCompletedMovementSequence=requestSequence;
  const stale=generation!==movementGeneration;
  if(r.status==='REJECTED'){
    if(!stale){
      console.warn('sendWorldMove: REJECTED',r.errorCode);
      toast(describeWorldMoveError(r.errorCode));
      predictionSuspended=true;
    }
    // Stale REJECTED: REJECTED never changes worldPosition, so there is no truth to accept, and a
    // toast about an already-abandoned direction would only confuse the player.
    recordMoveTelemetry({status:'REJECTED',errorCode:r.errorCode,throttled:null,collided:null,startedAt});
    telemetryMoveInFlightCount=Math.max(0,telemetryMoveInFlightCount-1);
    return;
  }
  // P1-07 Root Cause Measurement Test — correctionDistance: the gap between what the client was
  // showing (predictedPosition) and the truth that just arrived, captured at the exact moment truth
  // updates (read-only; does not affect the assignment on the next line or anything after it).
  telemetryLastCorrectionDistance=Math.hypot(predictedPosition.x-r.data.worldPosition.x,predictedPosition.y-r.data.worldPosition.y);
  S.snap.worldPosition=r.data.worldPosition;S.snap.state=r.data.state; // always accepted as truth,
                                                                         // stale or not (P1-07D v4.1)
  if(r.data.collided&&!stale)toast('撞到障礙物'); // a stale collision toast would describe a
                                                    // direction the player has already left
  if(!stale){
    predictionSuspended=shouldSuspendAfterAccepted(r.data);
    if(!predictionSuspended)catchUpDebt=catchUpDebtAfterGrant(predictedPosition,r.data.worldPosition,joystickInput.active?joystickInput:null);
    // stale: predictionSuspended and catchUpDebt are both left completely untouched by this response
  }
  recordMoveTelemetry({status:'ACCEPTED',errorCode:null,throttled:r.data.throttled,collided:r.data.collided,startedAt});
  telemetryMoveInFlightCount=Math.max(0,telemetryMoveInFlightCount-1);
};

// P4-03B — client-triggered idle-world liveness poll. The server decides EVERYTHING about whether an
// encounter happened (time, monster position, swept geometry, battle creation, consumption — see
// evaluateWorldMonsterExposure's own comment in server.mjs); this call is purely the trigger that
// makes that evaluation happen while the player isn't otherwise sending any world command (a
// stationary player never calls world/move at all — see tickMovementFrame's own gating). Payload is
// deliberately {} — the client never supplies player position, monster identity, or any timestamp.
// `worldHeartbeatInFlight` guards against a slow response (network retry, etc.) still being in flight
// when the next 1000ms tick fires — never more than one heartbeat request outstanding at once.
let worldHeartbeatInFlight=false;
async function sendWorldHeartbeat(){
  if(worldHeartbeatInFlight)return;
  worldHeartbeatInFlight=true;
  try{
    const r=await command('/api/commands/world/heartbeat',{});
    // Same resync rule as sendWorldMove's own battleAlreadyActiveFromWorldResponse check: either this
    // heartbeat itself just triggered an encounter, or the server already has an ACTIVE battle from
    // some other in-flight request — either way, refresh() fetches fresh authoritative state (never
    // trusts this response's payload beyond the trigger signal) and the existing refresh()/render()
    // path naturally transitions to the Battle UI (see refresh()'s own battle?.status==='ACTIVE' tab
    // switch).
    if(battleAlreadyActiveFromWorldResponse(r))await refresh();
  }catch(err){
    // Best-effort: a failed heartbeat (network hiccup, etc.) is silently retried by the next 1000ms
    // tick — no toast, no prediction suspension, since (unlike a rejected player-initiated move) there
    // is no player action or on-screen prediction this failure needs to explain.
    console.error('sendWorldHeartbeat: command() threw (network or server exception)',err);
  }finally{
    worldHeartbeatInFlight=false;
  }
}

// Virtual joystick (P1-07A) — fixed bottom-left, replaces the old SVG direct-drag-to-move input.
// Only one movement input mechanism is ever active: the joystick is the sole driver of free
// world movement now.
let joystickActive=false,joystickPointerId=null,joystickInput={active:false,dirX:0,dirY:0,magnitude:0};
// P1-07D Merge Gate review — the SINGLE synchronous path every joystickInput-changing event must go
// through (pointerdown/pointermove/pointerup/pointercancel/lostpointercapture, plus toggleMapView's
// forced release above). Applies movement.js's pure computeNextMovementIntent (exported as
// applyMovementIntent) and writes its result straight into module state, atomically, at the moment
// the input itself changes — never deferred to the next tickMovementFrame/RAF. See that function's
// own comment for the exact race this closes.
function applyMovementIntent(nextInput){
  const next=computeNextMovementIntent({joystickInput,movementGeneration,generationAnchorInput},nextInput);
  joystickInput=next.joystickInput;
  movementGeneration=next.movementGeneration;
  generationAnchorInput=next.generationAnchorInput;
}
function updateJoystickFromEvent(event,centerX,centerY,knob){
  const dx=event.clientX-centerX,dy=event.clientY-centerY;
  const knobOffset=clampJoystickKnob(dx,dy,JOYSTICK_RADIUS);
  if(knob)knob.style.transform=`translate(${knobOffset.x}px,${knobOffset.y}px)`;
  applyMovementIntent(computeJoystickInput(dx,dy,JOYSTICK_RADIUS,JOYSTICK_DEADZONE));
}
function setupJoystick(){
  const base=document.querySelector('#joystick-base');
  const knob=document.querySelector('#joystick-knob');
  const reset=()=>{joystickActive=false;joystickPointerId=null;applyMovementIntent({active:false,dirX:0,dirY:0,magnitude:0});if(knob)knob.style.transform='translate(0px,0px)'};
  reset();
  if(!base||base.classList.contains('joystick-disabled'))return;
  base.onpointerdown=event=>{
    event.preventDefault();
    joystickActive=true;joystickPointerId=event.pointerId;
    base.setPointerCapture(event.pointerId);
    const rect=base.getBoundingClientRect(),centerX=rect.left+rect.width/2,centerY=rect.top+rect.height/2;
    updateJoystickFromEvent(event,centerX,centerY,knob);
    base.onpointermove=moveEvent=>{if(!joystickActive||moveEvent.pointerId!==joystickPointerId)return;moveEvent.preventDefault();updateJoystickFromEvent(moveEvent,centerX,centerY,knob)};
    const stop=stopEvent=>{if(stopEvent&&stopEvent.pointerId!==undefined&&stopEvent.pointerId!==joystickPointerId)return;reset()};
    base.onpointerup=stop;base.onpointercancel=stop;base.onlostpointercapture=stop;
  };
}

// P1-07B — Continuous Visual Movement + Server Reconciliation. `predictedPosition` advances
// continuously every frame while the joystick is held, capped at MAX_PREDICTION_LEAD ahead of the
// last confirmed serverPosition along the current input direction (normal expected lead). Both the
// hero marker and the camera render from this single continuous position.
//
// P1-07D — Latency-Decoupled Movement (Issue #23) extends the reconciliation gate to a three-way
// split (see the tickMovementFrame body below): `predictionSuspended` (collision/rejected/error —
// the predicted path is known wrong, strong/hard-reset rules unchanged from P1-07B); idle/no active
// input (any leftover divergence, however it arose, eases smoothly toward truth — see
// idleSettlePosition, never a hard reset); active hold (signed ahead/lateral divergence — see
// movementDivergence — with `catchUpDebt` giving a temporary, direction-anchor-persistent lateral
// allowance after a legitimate large elapsed-time-scaled server grant, so a direction change right
// after such a grant is never mistaken for dangerous lateral drift). A non-suspended trigger (too
// far ahead, or lateral divergence beyond its budget) always eases, never hard-resets — only a
// genuinely known-wrong predicted path (predictionSuspended) may still snap.
//
// `earnedPosition` is a SEPARATE, parallel accumulator (see nextEarnedPosition) driving what gets
// *requested* from the server — deliberately independent of predictedPosition/character-state, so
// it can accumulate a genuine first non-zero target even while still IN_CITY (P1-07D v4.2 Blocker
// 1). `movementGeneration`/`generationAnchorInput` track movement intent epochs (press/release/a
// meaningful direction-or-magnitude change, measured against a persisted anchor so gradual drift is
// still eventually detected — see nextGenerationAnchor) so a request that goes stale before its
// response lands is handled without corrupting reconciliation for the CURRENT intent (see
// sendWorldMove above).
let predictedPosition=null,predictionSuspended=false,predictionResetPending=false,lastFrameTime=0,lastJoystickSendAt=0,
    earnedPosition=null,wasJoystickActiveLastFrame=false,catchUpDebt=0,movementGeneration=0,generationAnchorInput=null;
function tickMovementFrame(now){
  requestAnimationFrame(tickMovementFrame);
  const dt=lastFrameTime?Math.min(now-lastFrameTime,100):16;
  lastFrameTime=now;
  // P4-03A — cosmetic monster-patrol marker smoothing. Deliberately BEFORE the IN_WORLD-only early
  // return below: the World Map is also viewable while IN_CITY (P2-07's "查看地圖"/data-view-map),
  // and patrol motion has nothing to do with the player's own movement state. Gated purely on its
  // own conditions — S.tab==='map', and only monsters the server's own S.snap.worldMonsters still
  // lists (a consumed monster simply stops appearing there on the next refresh(), so this loop
  // naturally stops finding/patching it, never any client-side removal logic). `now` here is rAF's
  // own high-res timestamp, not epoch time — Date.now() is called explicitly for this, same as every
  // other Date.now()-based read in this file. No network request, no full render().
  if(S.tab==='map')for(const monster of S.snap?.worldMonsters||[]){
    const definition=WORLD_MONSTER_DEFINITIONS.find(x=>x.id===monster.id);
    if(!definition)continue;
    const approxServerNow=Date.now()+serverTimeOffset;
    const position=patrolPositionAt(definition,approxServerNow);
    if(!position)continue;
    const node=document.querySelector(`[data-monster="${monster.id}"]`);
    if(!node)continue;
    const circle=node.querySelector('circle'),label=node.querySelector('text');
    if(circle){circle.setAttribute('cx',position.x);circle.setAttribute('cy',position.y)}
    if(label){label.setAttribute('x',position.x);label.setAttribute('y',position.y+34)}
  }
  if(!S.snap||S.snap.state!=='IN_WORLD')return;
  const serverPos=S.snap.worldPosition;
  if(!serverPos)return;
  const notYetInWorld=S.snap.state!=='IN_WORLD',resetPending=predictionResetPending;
  // P1-07D Merge Gate review: movementGeneration/generationAnchorInput are NOT bumped here anymore
  // — they're already up to date by the time this runs, updated synchronously at the moment
  // joystickInput itself changed (applyMovementIntent) or a resync was requested (refresh(), right
  // where predictionResetPending is set). Bumping again from a per-frame snapshot here would either
  // double-bump an already-applied change or, worse, be the very race this fix closes (see
  // applyMovementIntent's comment in movement.js).

  if(!predictedPosition)predictedPosition={...serverPos};
  // P1-07 Root Cause Measurement Test — captured BEFORE the branch tree below runs/mutates
  // predictedPosition, against the SAME serverPos it will still be compared to after: read-only,
  // reuses movement.js's own movementDivergence (never a hand-duplicated formula). null when there
  // is no active input to project an "ahead" direction onto (movementDivergence's own fallback).
  const telemetryAheadBefore=joystickInput.active?movementDivergence(predictedPosition,serverPos,joystickInput).ahead:null;
  const telemetryActiveThisFrame=joystickInput.active&&!notYetInWorld&&!resetPending&&!predictionSuspended;
  if(notYetInWorld||resetPending){
    predictedPosition={...serverPos};
    predictionSuspended=false;
  }else if(predictionSuspended){
    const d=Math.hypot(predictedPosition.x-serverPos.x,predictedPosition.y-serverPos.y);
    const smoothingMs=reconciliationSmoothingMs(d);
    // P1-07 Root Cause Measurement Test — hardResetCount: counts this exact, unmodified condition
    // (smoothingMs===null, i.e. distance>RECONCILE_HARD_RESET_DISTANCE) firing; the branch below is
    // untouched, still does exactly what it did before this counter existed.
    if(smoothingMs===null)telemetryHardResetCount++;
    predictedPosition=smoothingMs===null?{...serverPos}:{x:easeTowards(predictedPosition.x,serverPos.x,dt,smoothingMs),y:easeTowards(predictedPosition.y,serverPos.y,dt,smoothingMs)};
  }else if(!joystickInput.active){
    predictedPosition=idleSettlePosition(predictedPosition,serverPos,dt);
  }else{
    const divergence=movementDivergence(predictedPosition,serverPos,joystickInput);
    const dangerousAhead=divergence.ahead>MAX_PREDICTION_LEAD;
    const dangerousLateral=divergence.lateral>MAX_PREDICTION_LEAD+catchUpDebt;
    if(dangerousAhead||dangerousLateral){
      const bandDistance=dangerousAhead?Math.hypot(predictedPosition.x-serverPos.x,predictedPosition.y-serverPos.y):divergence.lateral;
      const smoothingMs=reconciliationSmoothingMs(bandDistance,MAX_PREDICTION_LEAD,Infinity);
      predictedPosition={x:easeTowards(predictedPosition.x,serverPos.x,dt,smoothingMs),y:easeTowards(predictedPosition.y,serverPos.y,dt,smoothingMs)};
    }else if(joystickActive&&shouldSendJoystickMove(S.mapView,joystickInput.active)){
      const candidate=advancePredictedPosition(predictedPosition,serverPos,joystickInput,dt,PREDICTION_VELOCITY,MAX_PREDICTION_LEAD);
      predictedPosition=clampPredictedStep(predictedPosition,candidate,WORLD_BOUNDS,INFLATED_OBSTACLES);
    }
  }
  // P1-07 Root Cause Measurement Test — captured AFTER the branch tree above has fully settled
  // predictedPosition for this frame, against the SAME serverPos as telemetryAheadBefore, so the
  // difference is purely "how much forward progress happened this frame" — an outcome measurement,
  // never a proxy from proximity alone. Read-only: isCapFrozenFrame only classifies; it changes
  // nothing above.
  const telemetryAheadAfter=joystickInput.active?movementDivergence(predictedPosition,serverPos,joystickInput).ahead:null;
  const telemetryCapFrozenThisFrame=isCapFrozenFrame({active:telemetryActiveThisFrame,aheadBefore:telemetryAheadBefore,aheadAfter:telemetryAheadAfter,maxLead:MAX_PREDICTION_LEAD});
  telemetryCapFrozenCurrentMs=nextCapFrozenStreakMs(telemetryCapFrozenCurrentMs,telemetryCapFrozenThisFrame,dt);
  if(telemetryCapFrozenThisFrame)telemetryCapFrozenTotalMs+=dt;
  if(telemetryActiveThisFrame)telemetryActiveMovementTotalMs+=dt;
  telemetryLastCapFrozen=telemetryCapFrozenThisFrame;
  const distanceForDebt=Math.hypot(predictedPosition.x-serverPos.x,predictedPosition.y-serverPos.y);
  catchUpDebt=nextCatchUpDebt(catchUpDebt,distanceForDebt,MAX_PREDICTION_LEAD,predictionSuspended||!joystickInput.active||notYetInWorld||resetPending);

  if(!earnedPosition)earnedPosition={...serverPos};
  earnedPosition=nextEarnedPosition(earnedPosition,serverPos,joystickInput,wasJoystickActiveLastFrame,dt,PREDICTION_VELOCITY,resetPending||predictionSuspended);
  wasJoystickActiveLastFrame=joystickInput.active;

  if(resetPending)predictionResetPending=false;

  const hero=document.querySelector('.hero-marker');
  if(hero){hero.setAttribute('cx',predictedPosition.x);hero.setAttribute('cy',predictedPosition.y)}
  const stateLabel=document.querySelector('#state-label');
  if(stateLabel&&stateLabel.textContent!==stateName(S.snap.state))stateLabel.textContent=stateName(S.snap.state);
  const camera=resolveEffectiveViewBox(S.mapView,S.snap.state,predictedPosition,CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS);
  const svg=document.querySelector('.world-map');
  if(svg)svg.setAttribute('viewBox',viewBoxAttr(camera));
  if(joystickActive&&shouldSendJoystickMove(S.mapView,joystickInput.active)&&now-lastJoystickSendAt>=JOYSTICK_SEND_INTERVAL_MS){
    lastJoystickSendAt=now;
    const target=clampEarnedTarget(earnedPosition,serverPos,MOVE_CATCHUP_CAP_MS,PREDICTION_VELOCITY);
    if(target)sendWorldMove({...target,generation:movementGeneration});
  }
  // P1-07C — diagnostic-only tail: reads predictedPosition/serverPos that the movement logic
  // above already settled this frame, never writes back to them. FPS/lead are computed every
  // frame; only the overlay DOM write is throttled (see patchTelemetryOverlay).
  //
  // P1-07C Merge Gate review — FPS must use its own raw, uncapped frame delta, never movement's
  // `dt` above (which is clamped to 100ms for smoothing/prediction purposes — a real 250ms
  // rendering stall would otherwise read back as only ~100ms/~10fps instead of the true ~4fps,
  // defeating telemetry's whole purpose of telling rendering stalls apart from network gaps).
  // Movement's own dt/lastFrameTime logic above is completely untouched.
  const rawTelemetryDt=nextTelemetryFrameDelta(telemetryLastFrameTimestamp,now);
  telemetryLastFrameTimestamp=now;
  if(rawTelemetryDt!=null)telemetryFpsEma=nextFpsEma(telemetryFpsEma,rawTelemetryDt);
  patchTelemetryOverlay(now,predictionLeadDistance(predictedPosition,serverPos));
}
async function boot(){const s=await post('/api/session/open',{accountId:'account-demo'});S.sessionId=s.sessionId;[S.cities,S.roads,S.encounters]=await Promise.all([req('/api/cities'),req('/api/roads'),req('/api/battle/encounters')]);await refresh();setInterval(updateTravelProgress,250);setInterval(async()=>{if(S.tab==='battle'&&S.battle?.status==='ACTIVE')try{const next=await req('/api/character/char-demo/battle'),ended=next?.status!=='ACTIVE';setBattle(next);if(ended)await refresh();else if(!S.battlePanDragging)render()}catch{}},600);
  // P4-03B — same "one eternal setInterval + internal gate" style as the two intervals above (never
  // dynamically created/destroyed on tab/state changes). Only actually sends a request while every
  // condition holds: viewing the World Map tab, authoritatively IN_WORLD (excludes IN_CITY/TRAVELING),
  // the document is visible (battery/network — server-side fairness comes from the bounded lookback
  // regardless, see boundedExposureFromTime in server.mjs), and no battle is currently ACTIVE.
  setInterval(()=>{if(S.tab==='map'&&S.snap?.state==='IN_WORLD'&&document.visibilityState==='visible'&&S.battle?.status!=='ACTIVE')sendWorldHeartbeat()},1000);
  requestAnimationFrame(tickMovementFrame)}
// P4-02 Merge Gate fix — guarded so this module can be safely `import`ed in a Node test (to exercise
// battleAlreadyActiveFromWorldResponse above) without auto-booting a real app instance against a
// nonexistent DOM/server. In every real browser load, `document` always exists, so this is identical
// to the previous unconditional boot() call — zero behavior change for actual players.
if(typeof document!=='undefined')boot().catch(e=>document.querySelector('#app').innerHTML=`<pre style="padding:20px;color:white">${e.stack||e}</pre>`);
