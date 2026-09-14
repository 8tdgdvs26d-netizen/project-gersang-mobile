const S={sessionId:'',snap:null,cities:[],market:[],storage:[],tx:[],battle:null,selectedUnitIds:[],focusTargetId:null,battleScrollLeft:0,battlePanDragging:false,battlePanFrame:0,hitUnitIds:[],skillEffect:null,battleLog:[],tab:'market',modal:null};
async function req(path,opts={}){const r=await fetch(path,{headers:{'content-type':'application/json'},...opts});const b=await r.json();if(!r.ok)throw new Error(b.errorCode||`HTTP_${r.status}`);return b}
const post=(p,b)=>req(p,{method:'POST',body:JSON.stringify(b)});
const env=(payload,idempotencyKey=crypto.randomUUID())=>({commandId:crypto.randomUUID(),idempotencyKey,sessionId:S.sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function sendCommand(path,body){try{return await post(path,body)}catch{await wait(350);return post(path,body)}}
const command=(path,payload,key)=>sendCommand(path,env(payload,key));
const cityName=id=>S.cities.find(x=>x.id===id)?.name||id;
function toast(t){const d=document.createElement('div');d.className='toast';d.textContent=t;document.body.append(d);setTimeout(()=>d.remove(),1500)}
async function refresh(){
  S.snap=await req('/api/character/char-demo/snapshot');
  const [market,storage,tx,battle]=await Promise.all([req(`/api/cities/${S.snap.cityId}/market`),req(`/api/character/char-demo/storage/${S.snap.cityId}`),req('/api/character/char-demo/transactions'),req('/api/character/char-demo/battle')]);
  S.market=market;S.storage=storage;S.tx=tx;setBattle(battle);if(battle?.status==='ACTIVE')S.tab='battle';
  render();
}
function setBattle(next){
  if(S.battle&&next?.id===S.battle.id){for(const unit of next.units){const old=S.battle.units.find(x=>x.id===unit.id);if(old&&unit.hp<old.hp){S.hitUnitIds.push(unit.id);S.battleLog.unshift(`${unit.name} 受到 ${old.hp-unit.hp} 傷害`);}}S.battleLog=S.battleLog.slice(0,3)}
  if(S.focusTargetId&&!next?.units?.some(x=>x.id===S.focusTargetId&&x.alive))S.focusTargetId=null;
  S.battle=next;
}
function nav(t,l){return `<button class="${S.tab===t?'active':''}" data-tab="${t}">${l}</button>`}
function render(){
  const s=S.snap;if(!s)return;
  const oldScroll=document.querySelector('.battle-scroll');if(oldScroll)S.battleScrollLeft=oldScroll.scrollLeft;
  const activeBattle=S.tab==='battle'&&S.battle?.status==='ACTIVE';
  const tabs=activeBattle?'':`<div class="tabs">${nav('market','市場')}${nav('cargo','貨艙')}${nav('storage','倉庫')}${nav('travel','旅行')}${nav('battle','戰鬥')}${nav('history','紀錄')}</div>`;
  document.querySelector('#app').innerHTML=`<div class="shell ${activeBattle?'combat-shell':''}"><section class="card top"><div><div class="small">Combat Prototype v0.7.4</div><div class="city">${cityName(s.cityId)}</div><div class="small">${s.state}</div></div><div class="money">💰 ${s.walletGold}</div></section>${tabs}${view()}</div>`;
  document.querySelectorAll('[data-tab]').forEach(x=>x.onclick=()=>{S.tab=x.dataset.tab;render()});wire();setupBattlePan();if(S.hitUnitIds.length)setTimeout(()=>S.hitUnitIds=[],400);if(S.modal)showModal();
}
function view(){
  if(S.tab==='market')return `<section class="card"><b>城市市場</b><div class="small">Quote 唔鎖價，Confirm 時 Server 會重驗。</div>${S.market.map(m=>`<div class="row"><div><div class="good">${m.goodTypeId}</div><div class="prices">買 ${m.buyPrice} / 賣 ${m.sellPrice} · Stock ${m.stock} · v${m.version}</div></div><input class="qty" data-q="${m.goodTypeId}" type="number" min="1" value="1"><div class="actions"><button class="btn" data-buy="${m.goodTypeId}">買</button><button class="btn alt" data-sell="${m.goodTypeId}">賣</button></div></div>`).join('')}</section>`;
  if(S.tab==='cargo')return `<section class="card"><b>Cargo</b><div class="metric"><div><span class="small">Used</span><b>${S.snap.cargo.usedUnits}</b></div><div><span class="small">Capacity</span><b>${S.snap.cargo.capacityUnits}</b></div></div>${S.snap.cargo.stacks.map(x=>`<div class="row"><div>${x.goodTypeId} × ${x.quantity}</div><span></span><button class="btn alt" data-store="${x.goodTypeId}">入倉1</button></div>`).join('')||"<p class='small'>Cargo 空。</p>"}</section>`;
  if(S.tab==='storage')return `<section class="card"><b>${cityName(S.snap.cityId)} 倉庫</b>${S.storage.map(x=>`<div class="row"><div>${x.goodTypeId} × ${x.quantity}</div><span></span><button class="btn" data-withdraw="${x.goodTypeId}">拎1</button></div>`).join('')||"<p class='small'>倉庫空。</p>"}</section>`;
  if(S.tab==='travel'){
    const t=S.snap.activeTravel;
    if(S.snap.state==='TRAVELING'&&t){const a=new Date(t.startedAt).getTime(),e=new Date(t.estimatedArrivalAt).getTime(),p=Math.max(0,Math.min(1,(Date.now()-a)/(e-a)));return `<section class="card"><b>旅行中</b><p>${cityName(t.fromCityId)} → ${cityName(t.toCityId)}</p><div class="track"><div class="fill" style="width:${p*100}%"></div></div><p class="small">ETA ${new Date(t.estimatedArrivalAt).toLocaleTimeString()}</p><button class="btn" id="arrive">檢查到埗</button><div class="reroute"><div class="small">途中改道（由目前實際位置重新計路程）</div>${S.cities.filter(c=>c.id!==t.toCityId).map(c=>`<button class="btn alt" data-reroute="${c.id}">${c.name}</button>`).join('')}</div></section>`}
    return `<section class="card"><b>旅行地圖</b>${S.cities.filter(c=>c.id!==S.snap.cityId).map(c=>`<div class="row"><div>${c.name}</div><span></span><button class="btn" data-travel="${c.id}">出發</button></div>`).join('')}</section>`;
  }
  if(S.tab==='battle')return battleView();
  return `<section class="card"><b>交易紀錄</b>${S.tx.map(t=>`<div class="row"><div>${t.kind}<div class="small">${t.goodTypeId||''} ${t.quantity||''} · ${cityName(t.cityId)}</div></div><span></span><b>${t.goldDelta>0?'+':''}${t.goldDelta}</b></div>`).join('')||"<p class='small'>未有交易。</p>"}</section>`;
}
function battleView(){
  const b=S.battle;
  if(!b||b.status!=='ACTIVE')return `<section class="card battle-card"><b>5 × 60 戰場</b><p class="small">P1：直接控制我方單位、指定移動、鎖定敵人、自動普攻。</p>${b?`<div class="result ${b.status.toLowerCase()}">${b.status}</div>`:''}<button class="btn" id="start-battle">開始山賊戰</button></section>`;
  S.selectedUnitIds=S.selectedUnitIds.filter(id=>b.units.some(x=>x.id===id&&x.alive));
  const selected=b.units.filter(x=>S.selectedUnitIds.includes(x.id)&&x.alive);let cells='';
  for(let row=0;row<b.rows;row++)for(let col=0;col<b.columns;col++){
    const u=b.units.find(x=>x.alive&&x.row===row&&x.col===col),effect=S.skillEffect?.row===row&&S.skillEffect?.col===col,classes=['battle-cell'];
    if(u)classes.push(u.side==='PLAYER'?'friendly':'enemy');if(u&&S.selectedUnitIds.includes(u.id))classes.push('selected');if(u&&selected.some(x=>x.targetId===u.id))classes.push('targeted');if(u&&S.hitUnitIds.includes(u.id))classes.push('hit');
    if(effect)classes.push('skill-impact');
    cells+=`<button class="${classes.join(' ')}" data-row="${row}" data-col="${col}" ${u?`data-unit="${u.id}"`:''} title="${u?`${u.name} ${u.hp}/${u.maxHp}`:`${row+1},${col+1}`}">${u?`${u.role==='RANGED'?'🏹':u.side==='PLAYER'?'⚔️':'👺'}<span>${u.hp}</span>`:''}${effect?`<strong class="floating-damage">-${S.skillEffect.damage}</strong>`:''}</button>`;
  }
  const enemies=b.units.filter(x=>x.side==='ENEMY'&&x.alive),inferredTarget=selected.map(x=>x.targetId).find(id=>enemies.some(e=>e.id===id));
  if(!enemies.some(x=>x.id===S.focusTargetId))S.focusTargetId=inferredTarget||null;
  const targets=enemies.map(x=>`<button class="target-chip ${S.focusTargetId===x.id?'locked':''}" data-target-unit="${x.id}"><span>👺 ${x.name}</span><small>${x.hp}/${x.maxHp} HP</small></button>`).join('');
  const selectedLabel=selected.length?`已選 ${selected.length} 名：${selected.map(x=>x.name).join('、')}｜遠攻可邊行邊射`:'先點選藍色我方單位';
  const hero=selected.find(x=>x.id==='hero'),skill=hero?.skills?.find(x=>x.id==='heavy-strike'),skillTarget=hero&&b.units.find(x=>x.id===S.focusTargetId&&x.alive),skillDistance=skillTarget?Math.max(Math.abs(hero.row-skillTarget.row),Math.abs(hero.col-skillTarget.col)):Infinity;
  const skillText=!hero?'選擇主角使用技能':skill.readyInMs>0?`重擊冷卻 ${(skill.readyInMs/1000).toFixed(1)}s`:!skillTarget?'先鎖定敵人':skillDistance>skill.range?`目標太遠（需 ${skill.range} 格內）`:'重擊 · 32 傷害';
  const skillDisabled=!hero||!skillTarget||skill.readyInMs>0||skillDistance>skill.range;
  const cooling=skill?.readyInMs>0,cooldownPercent=cooling?Math.min(100,skill.readyInMs/skill.cooldownMs*100):0,skillButtonText=cooling?`${(skill.readyInMs/1000).toFixed(1)}s`:'重擊';
  return `<section class="card battle-card"><div class="battle-head"><div><b>山賊戰 · ${b.status}</b><div class="small">${selectedLabel}</div></div><button class="btn danger" id="retreat">撤退</button></div><div class="battle-legend"><span>🔵 我方</span><span>🔴 敵方</span><span>棋子下方數字＝HP</span></div><div class="battle-log">${S.battleLog.map(x=>`<div>⚔️ ${x}</div>`).join('')||'<div>等待首次交鋒…</div>'}</div><div class="battle-pan-wrap"><span>我方</span><input id="battle-pan" class="battle-pan" type="range" min="0" max="1000" value="0" aria-label="移動戰場畫面"><span>敵方</span></div><div class="battle-scroll"><div class="battle-grid">${cells}</div></div><div class="battle-controls"><div class="battle-targets"><div class="small">快速鎖定敵人</div>${targets}</div><div class="unit-controls"><button class="btn alt" id="select-all">全選我方</button><button class="btn alt" id="clear-selection">清除選擇</button><span class="small">點我方棋子可加選／取消</span></div><div class="skill-bar"><span class="skill-icon">💥</span><div><b>普通技能</b><div class="small">${skillText}</div></div><button class="btn skill-btn ${cooling?'cooling':''}" style="--cooldown:${cooldownPercent}%" data-skill-unit="hero" data-skill-id="heavy-strike" ${skillDisabled?'disabled':''}><span>${skillButtonText}</span></button></div></div></section>`;
}
function qty(g){return Math.max(1,Number(document.querySelector(`[data-q="${g}"]`)?.value||1))}
function wire(){
  document.querySelectorAll('[data-buy]').forEach(b=>b.onclick=()=>openQuote(b.dataset.buy,'BUY',qty(b.dataset.buy)));document.querySelectorAll('[data-sell]').forEach(b=>b.onclick=()=>openQuote(b.dataset.sell,'SELL',qty(b.dataset.sell)));document.querySelectorAll('[data-store]').forEach(b=>b.onclick=()=>move('CARGO_TO_STORAGE',b.dataset.store));document.querySelectorAll('[data-withdraw]').forEach(b=>b.onclick=()=>move('STORAGE_TO_CARGO',b.dataset.withdraw));document.querySelectorAll('[data-travel]').forEach(b=>b.onclick=()=>travel(b.dataset.travel));document.querySelectorAll('[data-reroute]').forEach(b=>b.onclick=()=>reroute(b.dataset.reroute));document.querySelector('#arrive')?.addEventListener('click',arrival);document.querySelector('#start-battle')?.addEventListener('click',startBattle);document.querySelector('#retreat')?.addEventListener('click',retreatBattle);document.querySelector('#select-all')?.addEventListener('click',selectAllUnits);document.querySelector('#clear-selection')?.addEventListener('click',clearSelection);document.querySelectorAll('.battle-cell').forEach(c=>c.onclick=()=>battleTap(c));document.querySelectorAll('[data-target-unit]').forEach(b=>b.onclick=()=>targetEnemy(b.dataset.targetUnit));document.querySelectorAll('[data-skill-unit]').forEach(b=>b.onclick=()=>useSkill(b.dataset.skillUnit,b.dataset.skillId));document.querySelector('#battle-pan')?.addEventListener('input',panBattle);
}
async function openQuote(goodTypeId,side,requestedQuantity){S.modal={quote:await post('/api/commands/market/quote',{characterId:'char-demo',goodTypeId,side,requestedQuantity}),re:false,key:crypto.randomUUID()};showModal()}
function showModal(){document.querySelector('.modalbg')?.remove();const q=S.modal.quote,d=document.createElement('div');d.className='modalbg';d.innerHTML=`<div class="modal"><div class="small">${S.modal.re?'價格已變，請重新確認':'Confirm Quote'}</div><h2>${q.side} ${q.goodTypeId}</h2><p>數量 <b>${q.fillQuantity}</b> · 單價 <b>${q.unitPrice}</b> · Total <b>${q.total}</b></p><div class="actions"><button class="btn" id="ok">Confirm</button><button class="btn alt" id="cancel">取消</button></div></div>`;document.body.append(d);d.querySelector('#cancel').onclick=()=>{S.modal=null;d.remove()};d.querySelector('#ok').onclick=confirm}
async function confirm(){const q=S.modal.quote,key=S.modal.key,path=q.side==='BUY'?'/api/commands/market/buy':'/api/commands/market/sell',r=await command(path,{approvedQuote:q},key);if(r.status==='RECONFIRM_REQUIRED'){S.modal={quote:r.data,re:true,key};showModal();toast('市場價格有變');return}if(r.status==='REJECTED'){toast(r.errorCode);return}S.modal=null;document.querySelector('.modalbg')?.remove();toast(q.side==='BUY'?'買入成功':'賣出成功');await refresh()}
async function move(direction,goodTypeId){const r=await command('/api/commands/container/move',{direction,cityId:S.snap.cityId,goodTypeId,quantity:1});if(r.status==='REJECTED')return toast(r.errorCode);toast('完成');await refresh()}
async function travel(destinationCityId){const r=await command('/api/commands/travel/start',{destinationCityId});if(r.status==='REJECTED')return toast(r.errorCode);S.tab='travel';toast('已出發');await refresh()}
async function reroute(destinationCityId){const r=await command('/api/commands/travel/reroute',{destinationCityId});if(r.status==='REJECTED')return toast(r.errorCode);toast(`已改道去 ${cityName(destinationCityId)}`);await refresh()}
async function arrival(){const r=await command('/api/commands/travel/resolve-arrival',{});if(r.status==='REJECTED')return toast(r.errorCode==='ERR_NOT_ARRIVED'?'仲未到埗':r.errorCode);S.tab='market';toast('已到埗');await refresh()}
async function startBattle(){const r=await command('/api/commands/battle/start',{});if(r.status==='REJECTED')return toast(r.errorCode);S.selectedUnitIds=['hero'];S.focusTargetId=null;S.battleScrollLeft=0;S.battleLog=[];toast('戰鬥開始');await refresh()}
async function retreatBattle(){const r=await command('/api/commands/battle/retreat',{});if(r.status==='REJECTED')return toast(r.errorCode);S.selectedUnitIds=[];S.focusTargetId=null;toast('已撤退');await refresh()}
function selectAllUnits(){S.selectedUnitIds=S.battle?.units.filter(x=>x.side==='PLAYER'&&x.alive).map(x=>x.id)||[];render()}
function clearSelection(){S.selectedUnitIds=[];render()}
async function battleTap(cell){
  const unit=S.battle?.units.find(x=>x.id===cell.dataset.unit);
  if(unit?.side==='PLAYER'){S.selectedUnitIds=S.selectedUnitIds.includes(unit.id)?S.selectedUnitIds.filter(id=>id!==unit.id):[...S.selectedUnitIds,unit.id];render();return}
  if(!S.selectedUnitIds.length)return toast('請先選擇我方單位');
  const assisted=unit?.side==='ENEMY'?unit:nearestEnemy(Number(cell.dataset.row),Number(cell.dataset.col));
  if(assisted)return targetEnemy(assisted.id);
  const r=await command('/api/commands/battle/move',{unitIds:S.selectedUnitIds,row:Number(cell.dataset.row),col:Number(cell.dataset.col)});if(r.status==='REJECTED')return toast(r.errorCode);toast(S.selectedUnitIds.length>1?`${S.selectedUnitIds.length} 名單位編隊移動`:'移動指令已落');await refresh();
}
function nearestEnemy(row,col){
  return S.battle?.units.filter(x=>x.side==='ENEMY'&&x.alive).map(x=>({unit:x,distance:Math.hypot((x.col-col)*18,(x.row-row)*42)})).filter(x=>x.distance<=46).sort((a,b)=>a.distance-b.distance)[0]?.unit||null;
}
async function targetEnemy(targetId){
  if(!S.selectedUnitIds.length)return toast('請先選擇我方單位');
  const r=await command('/api/commands/battle/target',{unitIds:S.selectedUnitIds,targetId});if(r.status==='REJECTED')return toast(r.errorCode);S.focusTargetId=targetId;toast(`${S.selectedUnitIds.length} 名單位已集火`);await refresh();
}
async function useSkill(unitId,skillId){
  const targetId=S.focusTargetId;if(!targetId)return toast('請先鎖定敵人');
  const r=await command('/api/commands/battle/skill',{unitId,skillId,targetId});if(r.status==='REJECTED'){if(r.errorCode==='ERR_INVALID_SKILL_TARGET'){S.focusTargetId=null;await refresh()}const message={ERR_SKILL_OUT_OF_RANGE:'目標超出技能範圍',ERR_SKILL_COOLDOWN:'技能冷卻中',ERR_INVALID_SKILL_TARGET:'目標已失效，請重新鎖定'}[r.errorCode]||'技能使用失敗';return toast(message)}S.skillEffect={...r.data.targetPosition,damage:r.data.damage};S.battleLog.unshift(`主角施放重擊，造成 ${r.data.damage} 傷害`);S.battleLog=S.battleLog.slice(0,3);toast(`重擊！造成 ${r.data.damage} 傷害`);await refresh();setTimeout(()=>{S.skillEffect=null;if(S.tab==='battle')render()},720);
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
async function boot(){const s=await post('/api/session/open',{accountId:'account-demo'});S.sessionId=s.sessionId;S.cities=await req('/api/cities');await refresh();setInterval(async()=>{if(S.tab==='battle'&&S.battle?.status==='ACTIVE')try{setBattle(await req('/api/character/char-demo/battle'));if(!S.battlePanDragging)render()}catch{}},600)}
boot().catch(e=>document.querySelector('#app').innerHTML=`<pre style="padding:20px;color:white">${e.stack||e}</pre>`);
