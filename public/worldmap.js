import {WORLD_BOUNDS,OBSTACLES} from './worldgeometry.js';
import {isWithinCityEntry} from './cities.js';

const REGION_META=[
  {id:'NT_WEST',name:'新界西',x:0,y:0,w:500,h:330,open:true},
  {id:'NT_EAST',name:'新界東',x:500,y:0,w:500,h:330,open:true},
  {id:'KOWLOON',name:'九龍（未開放）',x:150,y:330,w:700,h:290,open:false},
  {id:'HK_ISLAND',name:'港島',x:100,y:620,w:800,h:380,open:true}
];

export function regionMeta(){return REGION_META}

function indexById(list){return Object.fromEntries((list||[]).map(x=>[x.id,x]))}
export {indexById};

export function canEnterCityHub(snapshot,targetCityId){
  if(!snapshot)return false;
  if(snapshot.state!=='IN_CITY')return false;
  return snapshot.cityId===targetCityId;
}

export function cityEntryCandidate(snapshot,cities){
  if(snapshot?.state!=='IN_WORLD'||!snapshot.worldPosition)return null;
  return (cities||[]).find(city=>isWithinCityEntry(snapshot.worldPosition,city))??null;
}

export function cityHubEntries(facilities){
  const list=Array.isArray(facilities)?facilities:[];
  return [
    {id:'market',label:'市場',available:list.includes('MARKET')},
    {id:'storage',label:'貨倉',available:list.includes('STORAGE')},
    {id:'bus',label:'巴士站',available:true},
    {id:'bank',label:'銀行',available:false},
    {id:'mercenary',label:'傭兵店',available:false},
    {id:'equipment',label:'裝備店',available:false},
    {id:'factory',label:'工廠',available:false},
    // P2-07 City Hub Navigation: optional, client-only inspection of the World Map while IN_CITY.
    // Never enters/exits the city — see travelStatusHtml's IN_CITY branch and shouldShowCityHubOnStateChange.
    {id:'view-map',label:'查看地圖',available:true,action:'view-map'},
    {id:'leave',label:'離開城市',available:true,action:'leave'}
  ];
}

export function leaveCityHub(){return {tab:'map'}}

// P2-07 City Hub Navigation: IN_CITY is a physical-presence server state, so City Hub is the
// primary client screen for it — a client that JUST transitioned into IN_CITY (from any other
// state, or from no prior snapshot at all, e.g. initial load) must land on Hub directly. A client
// that was ALREADY IN_CITY and merely re-fetches (buying, selling, storage move, etc.) must NOT be
// forced back to Hub — that would kick a player out of Market/Storage/Bus on every ordinary refresh.
export function shouldShowCityHubOnStateChange(previousState,nextState){
  return previousState!=='IN_CITY'&&nextState==='IN_CITY';
}

export function chooseTravelAction(snapshot,targetCityId,cities){
  // P2-05: paid transport still never starts from a map-node tap — 'start'/'reroute' are never
  // returned here, so handleCityTap's travel()/reroute() branches below stay permanently
  // unreachable from a marker tap (kept only so callers that still pass travel/reroute continue
  // to behave exactly as before: never invoked).
  //
  // P2-07: the ONLY action a city marker tap can trigger is physical entry — and only into the
  // EXACT city that was tapped, evaluated fresh against the CURRENT snapshot at tap time (never a
  // stale render). This deliberately re-checks isWithinCityEntry against targetCityId itself
  // (not "whichever city happens to be nearest") so tapping a distant city's marker while standing
  // in a different city's radius can never enter the wrong (or any) city.
  if(snapshot?.state!=='IN_WORLD'||!snapshot.worldPosition)return null;
  const city=(cities||[]).find(c=>c.id===targetCityId);
  if(!city||!isWithinCityEntry(snapshot.worldPosition,city))return null;
  return 'enter';
}

export function handleCityTap(cityId,{snap,cities,travel,reroute,enter}){
  const action=chooseTravelAction(snap,cityId,cities);
  if(action==='start')return travel(cityId);
  if(action==='reroute')return reroute(cityId);
  if(action==='enter')return enter?.(cityId);
  return null;
}

function lerp(a,b,ratio){return a+(b-a)*ratio}
function lerpCoordinates(fromCoord,toCoord,ratio){return {x:lerp(fromCoord.x,toCoord.x,ratio),y:lerp(fromCoord.y,toCoord.y,ratio)}}

function interpolateSegment(segment,ratio,citiesById,roadsById){
  if(segment.fromCityId==='virtual-position'){
    const road=roadsById[segment.roadId];
    if(!road)return null;
    const startFrac=road.durationMs?segment.startOffsetMs/road.durationMs:0;
    const endFrac=road.durationMs?segment.endOffsetMs/road.durationMs:0;
    const frac=lerp(startFrac,endFrac,ratio);
    const fromCity=citiesById[road.fromCityId],toCity=citiesById[road.toCityId];
    if(!fromCity||!toCity)return null;
    return lerpCoordinates(fromCity.coordinates,toCity.coordinates,frac);
  }
  const fromCity=citiesById[segment.fromCityId],toCity=citiesById[segment.toCityId];
  if(!fromCity||!toCity)return null;
  return lerpCoordinates(fromCity.coordinates,toCity.coordinates,ratio);
}

export function computeTravelPosition(segments,citiesById,roadsById,startedAt,now){
  if(!segments||!segments.length)return null;
  const start=new Date(startedAt).getTime();
  let elapsed=Math.max(0,now-start);
  for(let i=0;i<segments.length;i++){
    const segment=segments[i];
    const isLast=i===segments.length-1;
    if(elapsed<segment.durationMs||isLast){
      const ratio=segment.durationMs>0?Math.min(1,elapsed/segment.durationMs):1;
      return interpolateSegment(segment,ratio,citiesById,roadsById);
    }
    elapsed-=segment.durationMs;
  }
  return null;
}

function cityDisplayName(cities,id){return cities.find(c=>c.id===id)?.name||id}

function travelStatusHtml(state){
  const t=state.snap.activeTravel;
  if(state.snap.state==='TRAVELING'&&t){
    const a=new Date(t.startedAt).getTime(),e=new Date(t.estimatedArrivalAt).getTime(),p=Math.max(0,Math.min(1,(Date.now()-a)/(e-a)));
    return `<div class="map-travel-status"><p>🚌 巴士：${cityDisplayName(state.cities,t.fromCityId)} → ${cityDisplayName(state.cities,t.toCityId)}</p><div class="track"><div id="travel-fill" class="fill" data-start="${a}" data-end="${e}" style="width:${p*100}%"></div></div><div class="travel-progress"><span id="travel-progress-pct">${Math.round(p*100)}%</span><span>預計到埗 ${new Date(t.estimatedArrivalAt).toLocaleTimeString()}</span></div><button class="btn" id="arrive">檢查到埗</button><div class="small">車費已支付；行程中不可自由移動或改道。</div></div>`;
  }
  // P2-07 City Hub Navigation: IN_CITY no longer shows the World Map by default (Hub does — see
  // shouldShowCityHubOnStateChange), so this branch is now reached only via the explicit "查看地圖"
  // inspection action from City Hub. No "進入城市" — the player is already inside; this is a
  // read-only look at the map, not an unfinished entry.
  if(state.snap.state==='IN_CITY'){
    const city=state.cities.find(c=>c.id===state.snap.cityId);
    return `<div class="map-travel-status"><p>${city?.name||state.snap.cityId} · 地圖查看中</p><button class="btn" data-back-hub="1">返回城市中心</button></div>`;
  }
  // P2-07 Decision 2 — the separate "已抵達：XX城 / 進入XX城" control is intentionally removed.
  // The city marker itself (yellow circle + name, see renderWorldMapHtml's [data-city] node) is now
  // the official entry interaction — see chooseTravelAction/handleCityTap above. No replacement
  // text/button is rendered here for the IN_WORLD-near-a-city case; cityEntryCandidate() remains
  // exported (and still directly tested) as a general-purpose pure primitive, it is just no longer
  // called from here.
  return '';
}

function roadKey(fromCityId,toCityId){return [fromCityId,toCityId].sort().join('|')}

function roadsSvg(cities,roads){
  const citiesById=indexById(cities);
  const seen=new Set();
  const lines=[];
  for(const road of roads||[]){
    const from=citiesById[road.fromCityId],to=citiesById[road.toCityId];
    if(!from?.coordinates||!to?.coordinates)continue;
    const key=roadKey(road.fromCityId,road.toCityId);
    if(seen.has(key))continue;
    seen.add(key);
    lines.push(`<line class="map-road" x1="${from.coordinates.x}" y1="${from.coordinates.y}" x2="${to.coordinates.x}" y2="${to.coordinates.y}"></line>`);
  }
  return lines.join('');
}

export function resolveWorldPosition(snap,citiesById,roadsById,now){
  if(snap.state==='TRAVELING'&&snap.activeTravel?.segments)return computeTravelPosition(snap.activeTravel.segments,citiesById,roadsById,snap.activeTravel.startedAt,now);
  return snap.worldPosition??citiesById[snap.cityId]?.coordinates;
}

// WORLD_BOUNDS and OBSTACLES come from the shared public/worldgeometry.js module (P1-04),
// re-exported here so app.js can keep importing them from worldmap.js.
export {WORLD_BOUNDS,OBSTACLES};
// Camera Prototype Parameter, not a final spec — subject to Playtest tuning.
export const CAMERA_VIEWPORT_SIZE=400;

export function computeCameraViewBox(position,viewportSize,bounds){
  const half=viewportSize/2;
  const x=Math.max(bounds.min,Math.min(bounds.max-viewportSize,position.x-half));
  const y=Math.max(bounds.min,Math.min(bounds.max-viewportSize,position.y-half));
  return {x,y,width:viewportSize,height:viewportSize};
}

export function viewBoxAttr(box){return `${box.x} ${box.y} ${box.width} ${box.height}`}

// Single source of truth for "which viewBox does this state get" (P1-04 review round 1) —
// shared by renderWorldMapHtml() and app.js's sendWorldMove callback, so an async movement
// response can never force camera-follow onto a state (e.g. IN_CITY after a collision or a
// throttled zero-displacement move) that must keep the full-world view.
export function resolveMapViewBox(state,position,viewportSize,bounds){
  if(state==='IN_WORLD'&&position)return computeCameraViewBox(position,viewportSize,bounds);
  return {x:bounds.min,y:bounds.min,width:bounds.max,height:bounds.max};
}

// P1-07A: two-tier camera. 'full' is inspection-only and always shows the whole world,
// overriding whatever resolveMapViewBox() would otherwise pick for the current state — additive
// on top of resolveMapViewBox(), which stays unchanged so its existing behavior/tests hold.
export function resolveEffectiveViewBox(mapView,state,position,viewportSize,bounds){
  if(mapView==='full')return {x:bounds.min,y:bounds.min,width:bounds.max,height:bounds.max};
  return resolveMapViewBox(state,position,viewportSize,bounds);
}

export function renderWorldMapHtml(state){
  const citiesById=indexById(state.cities);
  const roadsById=indexById(state.roads||[]);
  const heroPosition=resolveWorldPosition(state.snap,citiesById,roadsById,Date.now());
  const mapView=state.mapView||'follow';
  const camera=resolveEffectiveViewBox(mapView,state.snap.state,heroPosition,CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS);
  const zones=REGION_META.map(r=>`<g class="map-region ${r.open?'':'region-locked'}"><rect x="${r.x}" y="${r.y}" width="${r.w}" height="${r.h}"></rect><text class="map-region-label" x="${r.x+r.w/2}" y="${r.y+30}">${r.name}</text></g>`).join('');
  const roads=roadsSvg(state.cities,state.roads);
  const obstacles=OBSTACLES.map(o=>`<rect class="map-obstacle" data-obstacle="${o.id}" x="${o.minX}" y="${o.minY}" width="${o.maxX-o.minX}" height="${o.maxY-o.minY}"></rect>`).join('');
  const nodes=state.cities.map(c=>`<g class="map-city" data-city="${c.id}"><circle cx="${c.coordinates.x}" cy="${c.coordinates.y}" r="26"></circle><text x="${c.coordinates.x}" y="${c.coordinates.y+44}">${c.name}</text></g>`).join('');
  // P4-02 — minimal world monster marker, mirroring the existing [data-city] node pattern. Sourced
  // only from state.snap.worldMonsters (the server's own already-filtered "still available" list):
  // a consumed monster simply stops appearing on the next snapshot refresh, never a client-local
  // removal. Prototype-level art per the approved P4-02 Coding Order — no animation, no aggro range
  // visualisation.
  const monsters=(state.snap.worldMonsters||[]).map(m=>`<g class="map-monster" data-monster="${m.id}"><circle cx="${m.position.x}" cy="${m.position.y}" r="18"></circle><text x="${m.position.x}" y="${m.position.y+34}">${m.displayName}</text></g>`).join('');
  const hero=heroPosition?`<circle class="hero-marker" cx="${heroPosition.x}" cy="${heroPosition.y}" r="14"></circle>`:'';
  // Follow View / Full Map toggle (P1-07A) — client-only presentation state, never sent to the server.
  const mapViewToggle=`<button class="btn map-view-toggle" id="map-view-toggle" type="button">${mapView==='follow'?'🗺️ 全圖':'📍 跟隨'}</button>`;
  // P2-04: leaving a city is an explicit server command; only IN_WORLD can use free movement.
  // Full Map remains inspection-only as before.
  const joystickDisabled=state.snap.state!=='IN_WORLD'||mapView==='full';
  const joystick=`<div class="joystick${joystickDisabled?' joystick-disabled':''}" id="joystick-base"><div class="joystick-knob" id="joystick-knob"></div></div>`;
  // P1-07C — Mobile Movement Telemetry (diagnostic-only, Issue #21). Static shell only: every
  // value is "…" until app.js's tickMovementFrame patches these fixed ids in place, the same
  // per-frame-patch pattern already used for #state-label/.hero-marker — never rebuilt via
  // render(). Bottom-right, pointer-events:none (see styles.css), clear of the joystick
  // (bottom-left) and the Follow/Full Map toggle (top-right).
  // P1-07 Root Cause Measurement Test — 7 more static placeholder ids, appended after the P1-07C
  // ones, patched by the same tickMovementFrame/patchTelemetryOverlay pattern above. Purely
  // additive: nothing existing above is reordered or removed.
  // P4-04B2 — 6 more static placeholder ids (telemetry-recent-*) for the Recent Movement Anomaly
  // block: the latest committed freeze event, retained for RECENT_EVENT_RETENTION_MS (5s) after it
  // ends so a real-device screenshot taken shortly afterward still shows the evidence. Same
  // patchTelemetryOverlay pattern as every other field above — purely additive, same overlay, no new
  // UI surface, no toggle needed (the overlay itself is already visible on-screen by default).
  const telemetryOverlay=`<div class="telemetry-overlay" id="telemetry-overlay" aria-hidden="true"><div>幀率 <span id="telemetry-fps">…</span></div><div>延遲 <span id="telemetry-rtt">…</span></div><div>回應間隔 <span id="telemetry-gap">…</span></div><div>預測超前 <span id="telemetry-lead">…</span></div><div>請求中 <span id="telemetry-inflight">…</span></div><div>限速 <span id="telemetry-throttled">…</span></div><div>碰撞 <span id="telemetry-collided">…</span></div><div>暫停預測 <span id="telemetry-suspended">…</span></div><div>狀態 <span id="telemetry-status">…</span></div><div>錯誤 <span id="telemetry-errorcode">…</span></div><div>超前上限 <span id="telemetry-leadcaphit">…</span></div><div>凍結 <span id="telemetry-capfrozen">…</span></div><div>本次凍結 <span id="telemetry-frozen-current">…</span></div><div>累計凍結 <span id="telemetry-frozen-total">…</span></div><div>凍結比例 <span id="telemetry-frozen-ratio">…</span></div><div>修正量 <span id="telemetry-correction">…</span></div><div>強制重置 <span id="telemetry-hardresets">…</span></div><div>最近事件-凍結 <span id="telemetry-recent-freeze">…</span></div><div>最近事件-超前 <span id="telemetry-recent-lead">…</span></div><div>最近事件-延遲 <span id="telemetry-recent-rtt">…</span></div><div>最近事件-間隔 <span id="telemetry-recent-gap">…</span></div><div>最近事件-請求中 <span id="telemetry-recent-inflight">…</span></div><div>最近事件-時間 <span id="telemetry-recent-age">…</span></div></div>`;
  return `<section class="card map-card"><b>世界地圖</b><div class="map-scroll"><svg class="world-map" viewBox="${viewBoxAttr(camera)}" preserveAspectRatio="xMidYMid meet">${zones}${roads}${obstacles}${nodes}${monsters}${hero}</svg>${mapViewToggle}${joystick}${telemetryOverlay}</div>${travelStatusHtml(state)}</section>`;
}

export function renderCityHubHtml(state){
  const city=state.cities.find(c=>c.id===state.snap.cityId);
  const tiles=cityHubEntries(city?.facilities).map(e=>{
    if(e.action==='leave')return `<button class="hub-tile hub-leave" data-hub-leave="1">🚪 ${e.label}</button>`;
    if(e.action==='view-map')return `<button class="hub-tile" data-view-map="1">🗺️ ${e.label}</button>`;
    if(!e.available)return `<button class="hub-tile hub-disabled" disabled>${e.label}<small>尚未開放</small></button>`;
    return `<button class="hub-tile" data-hub-enter="${e.id}">${e.label}</button>`;
  }).join('');
  return `<section class="card hub-card"><b>${city?.name||state.snap.cityId} · City Hub</b><div class="hub-grid">${tiles}</div></section>`;
}
