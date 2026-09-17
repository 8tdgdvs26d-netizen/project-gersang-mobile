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

export function cityHubEntries(facilities){
  const list=Array.isArray(facilities)?facilities:[];
  return [
    {id:'market',label:'市場',available:list.includes('MARKET')},
    {id:'storage',label:'貨倉',available:list.includes('STORAGE')},
    {id:'bank',label:'銀行',available:false},
    {id:'mercenary',label:'傭兵店',available:false},
    {id:'equipment',label:'裝備店',available:false},
    {id:'factory',label:'工廠',available:false},
    {id:'leave',label:'離開城市',available:true,action:'leave'}
  ];
}

export function leaveCityHub(){return {tab:'map'}}

export function chooseTravelAction(snapshot,targetCityId){
  if(!snapshot)return null;
  if(snapshot.state==='IN_CITY'){
    if(snapshot.cityId===targetCityId)return null;
    return 'start';
  }
  if(snapshot.state==='TRAVELING'){
    if(snapshot.activeTravel?.toCityId===targetCityId)return null;
    return 'reroute';
  }
  return null;
}

export function handleCityTap(cityId,{snap,travel,reroute}){
  const action=chooseTravelAction(snap,cityId);
  if(action==='start')return travel(cityId);
  if(action==='reroute')return reroute(cityId);
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
    return `<div class="map-travel-status"><p>${cityDisplayName(state.cities,t.fromCityId)} → ${cityDisplayName(state.cities,t.toCityId)}</p><div class="track"><div id="travel-fill" class="fill" data-start="${a}" data-end="${e}" style="width:${p*100}%"></div></div><div class="travel-progress"><span id="travel-progress-pct">${Math.round(p*100)}%</span><span>ETA ${new Date(t.estimatedArrivalAt).toLocaleTimeString()}</span></div><button class="btn" id="arrive">檢查到埗</button><div class="small">撳地圖上其他城市可以中途改道</div></div>`;
  }
  if(state.snap.state==='IN_CITY'){
    const city=state.cities.find(c=>c.id===state.snap.cityId);
    return `<div class="map-travel-status"><p>目前所在：${city?.name||state.snap.cityId}</p><button class="btn" data-enter-hub="${state.snap.cityId}">進入城市</button></div>`;
  }
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

export function renderWorldMapHtml(state){
  const citiesById=indexById(state.cities);
  const roadsById=indexById(state.roads||[]);
  const heroPosition=resolveWorldPosition(state.snap,citiesById,roadsById,Date.now());
  const zones=REGION_META.map(r=>`<g class="map-region ${r.open?'':'region-locked'}"><rect x="${r.x}" y="${r.y}" width="${r.w}" height="${r.h}"></rect><text class="map-region-label" x="${r.x+r.w/2}" y="${r.y+30}">${r.name}</text></g>`).join('');
  const roads=roadsSvg(state.cities,state.roads);
  const nodes=state.cities.map(c=>`<g class="map-city" data-city="${c.id}"><circle cx="${c.coordinates.x}" cy="${c.coordinates.y}" r="26"></circle><text x="${c.coordinates.x}" y="${c.coordinates.y+44}">${c.name}</text></g>`).join('');
  const hero=heroPosition?`<circle class="hero-marker" cx="${heroPosition.x}" cy="${heroPosition.y}" r="14"></circle>`:'';
  return `<section class="card map-card"><b>世界地圖</b><div class="map-scroll"><svg class="world-map" viewBox="0 0 1000 1000" preserveAspectRatio="xMidYMid meet">${zones}${roads}${nodes}${hero}</svg></div>${travelStatusHtml(state)}</section>`;
}

export function renderCityHubHtml(state){
  const city=state.cities.find(c=>c.id===state.snap.cityId);
  const tiles=cityHubEntries(city?.facilities).map(e=>{
    if(e.action==='leave')return `<button class="hub-tile hub-leave" data-hub-leave="1">🚪 ${e.label}</button>`;
    if(!e.available)return `<button class="hub-tile hub-disabled" disabled>${e.label}<small>尚未開放</small></button>`;
    return `<button class="hub-tile" data-hub-enter="${e.id}">${e.label}</button>`;
  }).join('');
  return `<section class="card hub-card"><b>${city?.name||state.snap.cityId} · City Hub</b><div class="hub-grid">${tiles}</div></section>`;
}
