import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm,readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {
  canEnterCityHub,
  cityHubEntries,
  leaveCityHub,
  shouldShowCityHubOnStateChange,
  chooseTravelAction,
  handleCityTap,
  computeTravelPosition,
  indexById,
  regionMeta,
  renderWorldMapHtml,
  renderCityHubHtml,
  resolveWorldPosition,
  computeCameraViewBox,
  resolveMapViewBox,
  resolveEffectiveViewBox,
  WORLD_BOUNDS,
  OBSTACLES,
  CAMERA_VIEWPORT_SIZE
} from '../public/worldmap.js';
import {CITY_DEFINITIONS} from '../public/cities.js';
import {OBSTACLES as GEOMETRY_OBSTACLES,PLAYER_COLLISION_RADIUS,inflateRect,pointInRect} from '../public/worldgeometry.js';

let child,base,dir,sessionId;
const request=async(path,options={})=>{const r=await fetch(base+path,{headers:{'content-type':'application/json'},...options});return r.json()};
const post=(path,body)=>request(path,{method:'POST',body:JSON.stringify(body)});
const envelope=(key,payload)=>({commandId:crypto.randomUUID(),idempotencyKey:key,sessionId,characterId:'char-demo',clientSentAt:new Date().toISOString(),payload});

test.before(async()=>{
  dir=await mkdtemp(join(tmpdir(),'myrial-worldmap-'));
  child=spawn(process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...process.env,PORT:'0',DB_PATH:join(dir,'test.sqlite')},stdio:['ignore','pipe','inherit']});
  const line=await new Promise((resolve,reject)=>{child.stdout.on('data',b=>{const s=b.toString();if(s.includes('FIRST_PLAYABLE_READY'))resolve(s)});child.on('exit',code=>reject(new Error(`server exited ${code}`))) });
  base=`http://127.0.0.1:${line.match(/:(\d+)/)[1]}`;
  sessionId=(await post('/api/session/open',{accountId:'account-demo'})).sessionId;
});
test.after(async()=>{child?.kill();await rm(dir,{recursive:true,force:true})});

test('regions are limited to the four fixed Hong Kong districts, and Kowloon may have zero cities',async()=>{
  const cities=await request('/api/cities');
  const allowedRegionIds=regionMeta().map(r=>r.id);
  assert.deepEqual(new Set(allowedRegionIds),new Set(['HK_ISLAND','KOWLOON','NT_WEST','NT_EAST']));
  for(const city of cities)assert.ok(allowedRegionIds.includes(city.region),`${city.id} has an invalid region ${city.region}`);
  const kowloonCities=cities.filter(c=>c.region==='KOWLOON');
  assert.equal(kowloonCities.length,0);
});

test('four-city data contract preserves legacy ids and exposes approved Chinese display names',async()=>{
  const cities=await request('/api/cities');
  const byId=indexById(cities);
  assert.equal(byId['starter-village']?.name,'啟步城');
  assert.equal(byId['harbour-city']?.name,'商業城');
  assert.equal(byId['hill-market']?.name,'開拓城');
  assert.equal(byId['growth-city']?.name,'躍動城');
  assert.equal(cities.length,4);
  assert.equal(new Set(cities.map(city=>city.id)).size,4);
});

test('every city has complete physical-entry metadata and a collision-safe exit point',async()=>{
  const cities=await request('/api/cities');
  const inflatedObstacles=GEOMETRY_OBSTACLES.map(obstacle=>inflateRect(obstacle,PLAYER_COLLISION_RADIUS));
  for(const city of cities){
    assert.ok(Number.isFinite(city.coordinates?.x)&&Number.isFinite(city.coordinates?.y),`${city.id} needs coordinates`);
    assert.ok(city.coordinates.x>=WORLD_BOUNDS.min&&city.coordinates.x<=WORLD_BOUNDS.max,`${city.id} x is outside world bounds`);
    assert.ok(city.coordinates.y>=WORLD_BOUNDS.min&&city.coordinates.y<=WORLD_BOUNDS.max,`${city.id} y is outside world bounds`);
    assert.ok(Number.isFinite(city.entryRadius)&&city.entryRadius>0,`${city.id} needs a positive entry radius`);
    assert.ok(Number.isFinite(city.exitPoint?.x)&&Number.isFinite(city.exitPoint?.y),`${city.id} needs an exit point`);
    assert.ok(city.exitPoint.x>=WORLD_BOUNDS.min&&city.exitPoint.x<=WORLD_BOUNDS.max,`${city.id} exit x is outside world bounds`);
    assert.ok(city.exitPoint.y>=WORLD_BOUNDS.min&&city.exitPoint.y<=WORLD_BOUNDS.max,`${city.id} exit y is outside world bounds`);
    assert.ok(Math.hypot(city.exitPoint.x-city.coordinates.x,city.exitPoint.y-city.coordinates.y)>city.entryRadius,`${city.id} exit must be outside its entry radius`);
    assert.equal(inflatedObstacles.some(obstacle=>pointInRect(city.exitPoint.x,city.exitPoint.y,obstacle)),false,`${city.id} exit overlaps an inflated obstacle`);
  }
});

test('server city payload is sourced from the shared city contract without mutating it',async()=>{
  const cities=await request('/api/cities');
  assert.deepEqual(cities,CITY_DEFINITIONS);
  assert.ok(Object.isFrozen(CITY_DEFINITIONS));
  assert.ok(CITY_DEFINITIONS.every(city=>Object.isFrozen(city)&&Object.isFrozen(city.coordinates)&&Object.isFrozen(city.exitPoint)&&Object.isFrozen(city.facilities)));
});

test('legacy travel endpoint delegates to the paid bus service instead of free road routing',async()=>{
  const roads=await request('/api/roads');
  const direct=roads.find(r=>r.fromCityId==='starter-village'&&r.toCityId==='harbour-city');
  assert.ok(direct,'expected a direct road from starter-village to harbour-city');
  const started=await post('/api/commands/travel/start',envelope('worldmap-roads-check',{destinationCityId:'harbour-city'}));
  assert.equal(started.status,'ACCEPTED');
  assert.equal(started.data.transportMode,'BUS');
  assert.ok(started.data.fareGold>0);
  assert.notEqual(started.data.totalTravelMs,direct.durationMs);
});

test("canEnterCityHub rejects while TRAVELING regardless of city id",()=>{
  assert.equal(canEnterCityHub({state:'TRAVELING',cityId:'starter-village'},'starter-village'),false);
  assert.equal(canEnterCityHub({state:'TRAVELING',cityId:'starter-village'},'harbour-city'),false);
});

test("canEnterCityHub rejects IN_CITY when the requested city id does not match the player's current city",()=>{
  assert.equal(canEnterCityHub({state:'IN_CITY',cityId:'starter-village'},'harbour-city'),false);
});

test("canEnterCityHub allows IN_CITY when the requested city id matches the player's current city",()=>{
  assert.equal(canEnterCityHub({state:'IN_CITY',cityId:'starter-village'},'starter-village'),true);
});

test('computeTravelPosition interpolates a single-segment journey correctly',()=>{
  const citiesById={a:{id:'a',coordinates:{x:0,y:0}},b:{id:'b',coordinates:{x:100,y:0}}};
  const roadsById={};
  const segments=[{edgeId:'ab',roadId:'ab',fromCityId:'a',toCityId:'b',durationMs:1000,startOffsetMs:0,endOffsetMs:1000}];
  const startedAt=new Date(0).toISOString();
  assert.deepEqual(computeTravelPosition(segments,citiesById,roadsById,startedAt,0),{x:0,y:0});
  assert.deepEqual(computeTravelPosition(segments,citiesById,roadsById,startedAt,500),{x:50,y:0});
  assert.deepEqual(computeTravelPosition(segments,citiesById,roadsById,startedAt,1000),{x:100,y:0});
});

test('computeTravelPosition interpolates a multi-segment journey across a segment boundary',()=>{
  const citiesById={a:{id:'a',coordinates:{x:0,y:0}},b:{id:'b',coordinates:{x:100,y:0}},c:{id:'c',coordinates:{x:100,y:100}}};
  const roadsById={};
  const segments=[
    {edgeId:'ab',roadId:'ab',fromCityId:'a',toCityId:'b',durationMs:1000,startOffsetMs:0,endOffsetMs:1000},
    {edgeId:'bc',roadId:'bc',fromCityId:'b',toCityId:'c',durationMs:1000,startOffsetMs:0,endOffsetMs:1000}
  ];
  const startedAt=new Date(0).toISOString();
  assert.deepEqual(computeTravelPosition(segments,citiesById,roadsById,startedAt,999),{x:99.9,y:0});
  assert.deepEqual(computeTravelPosition(segments,citiesById,roadsById,startedAt,1000),{x:100,y:0});
  assert.deepEqual(computeTravelPosition(segments,citiesById,roadsById,startedAt,1500),{x:100,y:50});
  assert.deepEqual(computeTravelPosition(segments,citiesById,roadsById,startedAt,2000),{x:100,y:100});
});

test("computeTravelPosition resolves the reroute virtual-position segment via the underlying road's real endpoints",()=>{
  const citiesById={a:{id:'a',coordinates:{x:0,y:0}},b:{id:'b',coordinates:{x:100,y:0}}};
  const roadsById={ab:{id:'ab',fromCityId:'a',toCityId:'b',durationMs:1000}};
  const segments=[{edgeId:'ab:forward',roadId:'ab',fromCityId:'virtual-position',toCityId:'b',durationMs:700,startOffsetMs:300,endOffsetMs:1000}];
  const startedAt=new Date(0).toISOString();
  assert.deepEqual(computeTravelPosition(segments,citiesById,roadsById,startedAt,0),{x:30,y:0});
  assert.deepEqual(computeTravelPosition(segments,citiesById,roadsById,startedAt,700),{x:100,y:0});
});

test('computeTravelPosition reproduces the same position for a later "now" without client memory (reload simulation)',()=>{
  const citiesById={a:{id:'a',coordinates:{x:0,y:0}},b:{id:'b',coordinates:{x:100,y:0}},c:{id:'c',coordinates:{x:100,y:100}}};
  const roadsById={};
  const segments=[
    {edgeId:'ab',roadId:'ab',fromCityId:'a',toCityId:'b',durationMs:1000,startOffsetMs:0,endOffsetMs:1000},
    {edgeId:'bc',roadId:'bc',fromCityId:'b',toCityId:'c',durationMs:1000,startOffsetMs:0,endOffsetMs:1000}
  ];
  const startedAt=new Date(0).toISOString();
  const liveAtT1500=computeTravelPosition(segments,citiesById,roadsById,startedAt,1500);
  const reloadedAtT1500=computeTravelPosition(segments,citiesById,roadsById,startedAt,1500);
  assert.deepEqual(liveAtT1500,reloadedAtT1500);
  assert.deepEqual(reloadedAtT1500,{x:100,y:50});
});

// P2-07 City Hub Navigation added the always-available 查看地圖 (view-map) tile — entries.length and
// the available&&action!=='leave' count both grow by exactly one; the unavailable-tile and leave
// counts are untouched, so this deliberately updates (not weakens) the pre-existing assertions.
test('cityHubEntries returns two city services, a universal bus stop, a view-map tile, four unavailable tiles, and leave',async()=>{
  const cities=await request('/api/cities');
  const city=cities.find(c=>c.id==='starter-village');
  const entries=cityHubEntries(city?.facilities);
  assert.equal(entries.length,9);
  assert.equal(entries.filter(e=>e.available&&e.action!=='leave').length,4);
  assert.equal(entries.filter(e=>!e.available).length,4);
  assert.equal(entries.filter(e=>e.action==='leave').length,1);
  assert.equal(entries.filter(e=>e.action==='view-map').length,1);
});

test("cityHubEntries derives available services from the selected city's facilities metadata",()=>{
  const marketOnly=['MARKET'];
  const marketOnlyEntries=cityHubEntries(marketOnly);
  assert.equal(marketOnlyEntries.find(e=>e.id==='market').available,true);
  assert.equal(marketOnlyEntries.find(e=>e.id==='storage').available,false);
  assert.deepEqual(marketOnly,['MARKET']);

  const emptyEntries=cityHubEntries([]);
  assert.equal(emptyEntries.find(e=>e.id==='market').available,false);
  assert.equal(emptyEntries.find(e=>e.id==='storage').available,false);

  const missingEntries=cityHubEntries(undefined);
  assert.equal(missingEntries.find(e=>e.id==='market').available,false);
  assert.equal(missingEntries.find(e=>e.id==='storage').available,false);

  for(const entries of [marketOnlyEntries,emptyEntries,missingEntries]){
    assert.equal(entries.find(e=>e.action==='leave').available,true);
  }
});

test('renderWorldMapHtml renders each bidirectional road once and places roads below city nodes',()=>{
  const cities=[
    {id:'a',name:'A',coordinates:{x:0,y:0}},
    {id:'b',name:'B',coordinates:{x:100,y:0}}
  ];
  const roads=[
    {id:'ab',fromCityId:'a',toCityId:'b',durationMs:1000},
    {id:'ba',fromCityId:'b',toCityId:'a',durationMs:1000},
    {id:'missing',fromCityId:'a',toCityId:'ghost-city',durationMs:1000}
  ];
  const snap={state:'IN_CITY',cityId:'a'};
  const html=renderWorldMapHtml({snap,cities,roads});
  const roadMatches=html.match(/class="map-road"/g)||[];
  assert.equal(roadMatches.length,1);
  const firstRoadIndex=html.indexOf('class="map-road"');
  const firstCityNodeIndex=html.indexOf('class="map-city"');
  assert.ok(firstRoadIndex>=0&&firstCityNodeIndex>=0);
  assert.ok(firstRoadIndex<firstCityNodeIndex);
});

test('worldmap.js re-exports the same OBSTACLES array instance from the shared worldgeometry.js module (no duplicated copy)',()=>{
  assert.equal(OBSTACLES,GEOMETRY_OBSTACLES);
});

test('renderWorldMapHtml renders one <rect class="map-obstacle"> per shared OBSTACLES entry, using its actual bounds',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const snap={state:'IN_CITY',cityId:'a'};
  const html=renderWorldMapHtml({snap,cities,roads:[]});
  const obstacleMatches=html.match(/class="map-obstacle"/g)||[];
  assert.equal(obstacleMatches.length,OBSTACLES.length);
  for(const o of OBSTACLES){
    assert.ok(html.includes(`data-obstacle="${o.id}"`));
    assert.ok(html.includes(`x="${o.minX}" y="${o.minY}" width="${o.maxX-o.minX}" height="${o.maxY-o.minY}"`));
  }
});

test('renderWorldMapHtml performs no client-side collision logic: obstacles render even when the hero marker sits inside one',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const insideObstacle={x:(OBSTACLES[0].minX+OBSTACLES[0].maxX)/2,y:(OBSTACLES[0].minY+OBSTACLES[0].maxY)/2};
  const snap={state:'IN_WORLD',cityId:'a',worldPosition:insideObstacle};
  const html=renderWorldMapHtml({snap,cities,roads:[]});
  assert.ok(html.includes('class="hero-marker"'));
  assert.ok(html.includes('class="map-obstacle"'));
});

test('selecting a map city never starts paid transport outside City Hub (P2-07 requirement 10)',()=>{
  const calls={start:[],reroute:[],enter:[]};
  const travel=id=>calls.start.push(id);
  const reroute=id=>calls.reroute.push(id);
  const enter=id=>calls.enter.push(id);
  handleCityTap('harbour-city',{snap:{state:'IN_CITY',cityId:'starter-village'},cities:CITY_DEFINITIONS,travel,reroute,enter});
  assert.deepEqual(calls.start,[]);
  assert.deepEqual(calls.reroute,[]);
  assert.deepEqual(calls.enter,[],'P2-07 requirement 5: IN_CITY + tap a city marker must never enter — only City Hub\'s own leave/enter controls change city state while IN_CITY');
});

test('selecting a map city mid-journey never reroutes a paid bus (P2-07 requirement 11)',()=>{
  const calls={start:[],reroute:[],enter:[]};
  const travel=id=>calls.start.push(id);
  const reroute=id=>calls.reroute.push(id);
  const enter=id=>calls.enter.push(id);
  handleCityTap('hill-market',{snap:{state:'TRAVELING',cityId:'starter-village',activeTravel:{toCityId:'harbour-city'}},cities:CITY_DEFINITIONS,travel,reroute,enter});
  assert.deepEqual(calls.reroute,[]);
  assert.deepEqual(calls.start,[]);
  assert.deepEqual(calls.enter,[],'P2-07 requirement 6: TRAVELING + tap a city marker must never enter');
});

// --- P2-07: city marker is the official entry interaction (Decisions 1 & 2) ---
// All pure, DOM-free tests of chooseTravelAction/handleCityTap — the exact function app.js's
// [data-city] click handler calls, reading whatever snapshot/cities it is given at call time.

test('P2-07 requirement 1: IN_WORLD inside a city\'s own entry radius, tapping that city\'s marker, enters exactly once',()=>{
  const city=CITY_DEFINITIONS.find(c=>c.id==='starter-village');
  const calls=[];
  handleCityTap(city.id,{snap:{state:'IN_WORLD',worldPosition:{...city.coordinates}},cities:CITY_DEFINITIONS,enter:id=>calls.push(id)});
  assert.deepEqual(calls,[city.id]);
});

test('P2-07 requirement 2: the yellow circle and the city name are the same interaction target — both live inside one [data-city] node, not separate elements',()=>{
  const html=renderWorldMapHtml({snap:{state:'IN_WORLD',worldPosition:{x:0,y:0}},cities:CITY_DEFINITIONS,roads:[],mapView:'follow'});
  for(const city of CITY_DEFINITIONS){
    const match=html.match(new RegExp(`<g class="map-city" data-city="${city.id}"><circle[^>]*></circle><text[^>]*>${city.name}</text></g>`));
    assert.ok(match,`expected one [data-city="${city.id}"] <g> containing both the circle and the "${city.name}" text`);
  }
});

test('P2-07 requirement 3: standing in City A\'s radius but tapping City B\'s marker never enters any city',()=>{
  const cityA=CITY_DEFINITIONS.find(c=>c.id==='starter-village'),cityB=CITY_DEFINITIONS.find(c=>c.id==='harbour-city');
  const calls=[];
  handleCityTap(cityB.id,{snap:{state:'IN_WORLD',worldPosition:{...cityA.coordinates}},cities:CITY_DEFINITIONS,enter:id=>calls.push(id)});
  assert.deepEqual(calls,[],'tapping a distant city\'s marker while inside a different city\'s radius must never enter it');
});

test('P2-07 requirement 4: far from every city, tapping any city marker never enters',()=>{
  const calls=[];
  for(const city of CITY_DEFINITIONS)handleCityTap(city.id,{snap:{state:'IN_WORLD',worldPosition:{x:0,y:0}},cities:CITY_DEFINITIONS,enter:id=>calls.push(id)});
  assert.deepEqual(calls,[]);
});

test('P2-07 requirements 7 & 8: the entry rule is identical regardless of Follow Map or Full Map — chooseTravelAction/handleCityTap never take mapView as an input at all',()=>{
  const city=CITY_DEFINITIONS.find(c=>c.id==='hill-market');
  const followCalls=[],fullCalls=[];
  handleCityTap(city.id,{snap:{state:'IN_WORLD',worldPosition:{...city.coordinates}},cities:CITY_DEFINITIONS,enter:id=>followCalls.push(id)});
  handleCityTap(city.id,{snap:{state:'IN_WORLD',worldPosition:{...city.coordinates}},cities:CITY_DEFINITIONS,enter:id=>fullCalls.push(id)});
  assert.deepEqual(followCalls,[city.id]);
  assert.deepEqual(fullCalls,[city.id]);
  // Structural confirmation: renderWorldMapHtml renders the same [data-city] nodes in both map
  // views — the joystick is gated by mapView (joystickDisabled), city markers are not.
  const nearby={state:'IN_WORLD',worldPosition:{...city.coordinates}};
  const followHtml=renderWorldMapHtml({snap:nearby,cities:CITY_DEFINITIONS,roads:[],mapView:'follow'});
  const fullHtml=renderWorldMapHtml({snap:nearby,cities:CITY_DEFINITIONS,roads:[],mapView:'full'});
  for(const c of CITY_DEFINITIONS){
    assert.ok(followHtml.includes(`data-city="${c.id}"`),`follow map missing marker for ${c.id}`);
    assert.ok(fullHtml.includes(`data-city="${c.id}"`),`full map missing marker for ${c.id}`);
  }
});

test('P2-07 requirement 9 (stale-city regression): moving the snapshot from City A\'s vicinity to City B\'s vicinity — with no re-render in between — and then tapping City B\'s marker enters City B',()=>{
  // Mirrors production exactly: app.js's [data-city] onclick handler reads S.snap fresh at call
  // time (see wire()'s handleCityTap(...,{snap:S.snap,...})); sendWorldMove's ACCEPTED path
  // updates S.snap.worldPosition directly without ever calling render(). So a pure call here with
  // an already-updated snapshot object *is* the correct simulation of "walked to City B without
  // switching Follow/Full Map" — no DOM/render() involvement needed or introduced.
  const cityA=CITY_DEFINITIONS.find(c=>c.id==='starter-village'),cityB=CITY_DEFINITIONS.find(c=>c.id==='harbour-city');
  const snap={state:'IN_WORLD',worldPosition:{...cityA.coordinates}};
  const callsAtA=[];
  handleCityTap(cityB.id,{snap,cities:CITY_DEFINITIONS,enter:id=>callsAtA.push(id)});
  assert.deepEqual(callsAtA,[],'sanity: not yet near City B, tapping it must not enter');
  snap.worldPosition={...cityB.coordinates}; // simulates sendWorldMove's direct S.snap.worldPosition update
  const callsAtB=[];
  handleCityTap(cityB.id,{snap,cities:CITY_DEFINITIONS,enter:id=>callsAtB.push(id)});
  assert.deepEqual(callsAtB,[cityB.id],'after walking to City B (data updated, no render()), tapping City B\'s marker must enter it');
});

test('P2-07 requirement 13: the old separate "已抵達 / 進入XX城" [data-enter-city] control is no longer rendered anywhere',()=>{
  for(const city of CITY_DEFINITIONS){
    const nearby={state:'IN_WORLD',worldPosition:{...city.coordinates}};
    const html=renderWorldMapHtml({snap:nearby,cities:CITY_DEFINITIONS,roads:[],mapView:'follow'});
    assert.ok(!html.includes('data-enter-city'),`expected no data-enter-city control while near ${city.id}`);
    assert.ok(!html.includes('已抵達'),'expected the removed "已抵達" copy to be gone entirely');
  }
});

test("leaving City Hub only changes local screen state, makes no network request, and leaves the passed-in snapshot's city_id and state untouched",()=>{
  const originalFetch=globalThis.fetch;
  let fetchCalls=0;
  globalThis.fetch=()=>{fetchCalls++;throw new Error('leaveCityHub must not call fetch')};
  try{
    const snapshot={cityId:'harbour-city',state:'IN_CITY'};
    const before=JSON.parse(JSON.stringify(snapshot));
    const result=leaveCityHub(snapshot);
    assert.deepEqual(result,{tab:'map'});
    assert.deepEqual(snapshot,before);
    assert.equal(fetchCalls,0);
  }finally{
    globalThis.fetch=originalFetch;
  }
});

test('resolveWorldPosition delegates to computeTravelPosition while TRAVELING with segments',()=>{
  const citiesById={a:{id:'a',coordinates:{x:0,y:0}},b:{id:'b',coordinates:{x:100,y:0}}};
  const roadsById={};
  const segments=[{edgeId:'ab',roadId:'ab',fromCityId:'a',toCityId:'b',durationMs:1000,startOffsetMs:0,endOffsetMs:1000}];
  const snap={state:'TRAVELING',cityId:'a',worldPosition:{x:9999,y:9999},activeTravel:{segments,startedAt:new Date(0).toISOString()}};
  assert.deepEqual(resolveWorldPosition(snap,citiesById,roadsById,500),{x:50,y:0});
});

test("resolveWorldPosition returns the snapshot's persisted worldPosition when not traveling",()=>{
  const citiesById={a:{id:'a',coordinates:{x:0,y:0}}};
  const snap={state:'IN_CITY',cityId:'a',worldPosition:{x:42,y:7}};
  assert.deepEqual(resolveWorldPosition(snap,citiesById,{},Date.now()),{x:42,y:7});
});

test('resolveWorldPosition falls back to the city\'s coordinates when worldPosition is missing',()=>{
  const citiesById={a:{id:'a',coordinates:{x:220,y:150}}};
  const snap={state:'IN_CITY',cityId:'a'};
  assert.deepEqual(resolveWorldPosition(snap,citiesById,{},Date.now()),{x:220,y:150});
});

test('computeCameraViewBox centers exactly on the player position when well within bounds',()=>{
  const box=computeCameraViewBox({x:500,y:500},CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS);
  assert.deepEqual(box,{x:300,y:300,width:400,height:400});
});

test("computeCameraViewBox clamps at the world's minimum edge so the viewBox never shows area below 0",()=>{
  const box=computeCameraViewBox({x:0,y:10},CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS);
  assert.ok(box.x>=WORLD_BOUNDS.min,`expected x>=${WORLD_BOUNDS.min}, got ${box.x}`);
  assert.ok(box.y>=WORLD_BOUNDS.min,`expected y>=${WORLD_BOUNDS.min}, got ${box.y}`);
  assert.equal(box.x,0);
  assert.equal(box.y,0);
});

test("computeCameraViewBox clamps at the world's maximum edge so the viewBox never exceeds world bounds on the high side",()=>{
  const box=computeCameraViewBox({x:1000,y:990},CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS);
  assert.ok(box.x+box.width<=WORLD_BOUNDS.max,`expected x+width<=${WORLD_BOUNDS.max}, got ${box.x+box.width}`);
  assert.ok(box.y+box.height<=WORLD_BOUNDS.max,`expected y+height<=${WORLD_BOUNDS.max}, got ${box.y+box.height}`);
  assert.equal(box.x,600);
  assert.equal(box.y,600);
});

test('computeCameraViewBox always returns a fixed viewport size regardless of position',()=>{
  for(const position of [{x:0,y:0},{x:500,y:500},{x:1000,y:1000},{x:220,y:150}]){
    const box=computeCameraViewBox(position,CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS);
    assert.equal(box.width,CAMERA_VIEWPORT_SIZE);
    assert.equal(box.height,CAMERA_VIEWPORT_SIZE);
    assert.ok(box.x>=WORLD_BOUNDS.min&&box.x+box.width<=WORLD_BOUNDS.max);
    assert.ok(box.y>=WORLD_BOUNDS.min&&box.y+box.height<=WORLD_BOUNDS.max);
  }
});

test('resolveMapViewBox returns a camera-follow viewBox for IN_WORLD with a position',()=>{
  const box=resolveMapViewBox('IN_WORLD',{x:500,y:500},CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS);
  assert.deepEqual(box,computeCameraViewBox({x:500,y:500},CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS));
  assert.notDeepEqual(box,{x:WORLD_BOUNDS.min,y:WORLD_BOUNDS.min,width:WORLD_BOUNDS.max,height:WORLD_BOUNDS.max});
});

test('resolveMapViewBox returns the full-world viewBox for IN_CITY regardless of the worldPosition passed in (covers a collision-blocked or throttled zero-displacement move whose response still carries a position)',()=>{
  const box=resolveMapViewBox('IN_CITY',{x:500,y:500},CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS);
  assert.deepEqual(box,{x:WORLD_BOUNDS.min,y:WORLD_BOUNDS.min,width:WORLD_BOUNDS.max,height:WORLD_BOUNDS.max});
});

test('resolveMapViewBox returns the full-world viewBox for TRAVELING regardless of the position passed in',()=>{
  const box=resolveMapViewBox('TRAVELING',{x:500,y:500},CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS);
  assert.deepEqual(box,{x:WORLD_BOUNDS.min,y:WORLD_BOUNDS.min,width:WORLD_BOUNDS.max,height:WORLD_BOUNDS.max});
});

test('resolveMapViewBox falls back to the full-world viewBox for IN_WORLD when no position is available',()=>{
  const box=resolveMapViewBox('IN_WORLD',null,CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS);
  assert.deepEqual(box,{x:WORLD_BOUNDS.min,y:WORLD_BOUNDS.min,width:WORLD_BOUNDS.max,height:WORLD_BOUNDS.max});
});

const FULL_WORLD_BOX={x:WORLD_BOUNDS.min,y:WORLD_BOUNDS.min,width:WORLD_BOUNDS.max,height:WORLD_BOUNDS.max};

test("resolveEffectiveViewBox: 'full' map view always shows the whole world, even while IN_WORLD with a valid position (Full Map is inspection-only and overrides camera-follow)",()=>{
  const box=resolveEffectiveViewBox('full','IN_WORLD',{x:500,y:500},CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS);
  assert.deepEqual(box,FULL_WORLD_BOX);
});

test("resolveEffectiveViewBox: 'follow' map view defers to resolveMapViewBox's existing camera-follow behavior while IN_WORLD",()=>{
  const box=resolveEffectiveViewBox('follow','IN_WORLD',{x:500,y:500},CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS);
  assert.deepEqual(box,computeCameraViewBox({x:500,y:500},CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS));
  assert.notDeepEqual(box,FULL_WORLD_BOX);
});

test("resolveEffectiveViewBox: 'follow' map view still shows the full world while IN_CITY (matches resolveMapViewBox's existing non-IN_WORLD behavior, unchanged)",()=>{
  const box=resolveEffectiveViewBox('follow','IN_CITY',{x:220,y:150},CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS);
  assert.deepEqual(box,FULL_WORLD_BOX);
});

test("resolveEffectiveViewBox: 'full' map view while IN_CITY is consistent with 'follow' (both already show the full world)",()=>{
  const box=resolveEffectiveViewBox('full','IN_CITY',{x:220,y:150},CAMERA_VIEWPORT_SIZE,WORLD_BOUNDS);
  assert.deepEqual(box,FULL_WORLD_BOX);
});

test('renderWorldMapHtml uses a camera-follow 400x400 viewBox centered on the hero position while IN_WORLD',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const snap={state:'IN_WORLD',cityId:'a',worldPosition:{x:500,y:500}};
  const html=renderWorldMapHtml({snap,cities,roads:[]});
  assert.ok(html.includes('viewBox="300 300 400 400"'),`expected a camera-follow viewBox, got: ${html.match(/viewBox="[^"]*"/)}`);
  assert.ok(!html.includes('viewBox="0 0 1000 1000"'));
});

test('renderWorldMapHtml keeps the full-world 0 0 1000 1000 viewBox while IN_CITY, so other cities stay visible and reachable for travel',()=>{
  const cities=[
    {id:'starter-village',name:'A',coordinates:{x:220,y:150}},
    {id:'hill-market',name:'B',coordinates:{x:780,y:150}},
    {id:'harbour-city',name:'C',coordinates:{x:500,y:820}}
  ];
  const snap={state:'IN_CITY',cityId:'starter-village',worldPosition:{x:220,y:150}};
  const html=renderWorldMapHtml({snap,cities,roads:[]});
  assert.ok(html.includes('viewBox="0 0 1000 1000"'),`expected the full-world viewBox, got: ${html.match(/viewBox="[^"]*"/)}`);
  for(const city of cities)assert.ok(html.includes(`data-city="${city.id}"`));
});

test('renderWorldMapHtml keeps the full-world 0 0 1000 1000 viewBox while TRAVELING, so mid-journey reroute targets stay visible and reachable',()=>{
  const cities=[
    {id:'starter-village',name:'A',coordinates:{x:220,y:150}},
    {id:'hill-market',name:'B',coordinates:{x:780,y:150}},
    {id:'harbour-city',name:'C',coordinates:{x:500,y:820}}
  ];
  const segments=[{edgeId:'ab',roadId:'ab',fromCityId:'starter-village',toCityId:'hill-market',durationMs:1000,startOffsetMs:0,endOffsetMs:1000}];
  const snap={state:'TRAVELING',cityId:'starter-village',worldPosition:{x:220,y:150},activeTravel:{fromCityId:'starter-village',toCityId:'hill-market',segments,startedAt:new Date(0).toISOString(),estimatedArrivalAt:new Date(1000).toISOString()}};
  const html=renderWorldMapHtml({snap,cities,roads:[]});
  assert.ok(html.includes('viewBox="0 0 1000 1000"'),`expected the full-world viewBox, got: ${html.match(/viewBox="[^"]*"/)}`);
  for(const city of cities)assert.ok(html.includes(`data-city="${city.id}"`));
});

test('renderWorldMapHtml defaults to Follow View camera behavior when mapView is omitted (backward compatible with pre-P1-07A callers)',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const snap={state:'IN_WORLD',cityId:'a',worldPosition:{x:500,y:500}};
  const html=renderWorldMapHtml({snap,cities,roads:[]});
  assert.ok(html.includes('viewBox="300 300 400 400"'),`expected camera-follow viewBox by default, got: ${html.match(/viewBox="[^"]*"/)}`);
});

test("renderWorldMapHtml: mapView:'full' forces the full-world viewBox even while IN_WORLD",()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const snap={state:'IN_WORLD',cityId:'a',worldPosition:{x:500,y:500}};
  const html=renderWorldMapHtml({snap,cities,roads:[],mapView:'full'});
  assert.ok(html.includes('viewBox="0 0 1000 1000"'),`expected the full-world viewBox, got: ${html.match(/viewBox="[^"]*"/)}`);
});

test('renderWorldMapHtml renders the Follow/Full Map toggle button with the label matching the opposite (target) mode',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const snap={state:'IN_WORLD',cityId:'a',worldPosition:{x:500,y:500}};
  const followHtml=renderWorldMapHtml({snap,cities,roads:[],mapView:'follow'});
  assert.ok(followHtml.includes('id="map-view-toggle"'));
  assert.ok(followHtml.includes('全圖'),'while in Follow View, the button should offer to switch to Full Map');
  const fullHtml=renderWorldMapHtml({snap,cities,roads:[],mapView:'full'});
  assert.ok(fullHtml.includes('跟隨'),'while in Full Map, the button should offer to switch back to Follow View');
});

test('renderWorldMapHtml renders the joystick base, disabled while inspecting Full Map',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const snap={state:'IN_WORLD',cityId:'a',worldPosition:{x:500,y:500}};
  const followHtml=renderWorldMapHtml({snap,cities,roads:[],mapView:'follow'});
  assert.ok(followHtml.includes('id="joystick-base"'));
  assert.ok(!followHtml.includes('joystick-disabled'),'joystick must be enabled in Follow View while IN_WORLD');
  const fullHtml=renderWorldMapHtml({snap,cities,roads:[],mapView:'full'});
  assert.ok(fullHtml.includes('joystick-disabled'),'joystick must be disabled while inspecting Full Map');
});

test('renderWorldMapHtml renders the joystick disabled while TRAVELING regardless of mapView (movement is rejected server-side anyway)',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}},{id:'b',name:'B',coordinates:{x:500,y:500}}];
  const segments=[{edgeId:'ab',roadId:'ab',fromCityId:'a',toCityId:'b',durationMs:1000,startOffsetMs:0,endOffsetMs:1000}];
  const snap={state:'TRAVELING',cityId:'a',worldPosition:{x:220,y:150},activeTravel:{fromCityId:'a',toCityId:'b',segments,startedAt:new Date(0).toISOString(),estimatedArrivalAt:new Date(1000).toISOString()}};
  const html=renderWorldMapHtml({snap,cities,roads:[],mapView:'follow'});
  assert.ok(html.includes('joystick-disabled'));
});

test('renderWorldMapHtml disables the joystick while IN_CITY, so leaving must use City Hub',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const snap={state:'IN_CITY',cityId:'a',worldPosition:{x:220,y:150}};
  const html=renderWorldMapHtml({snap,cities,roads:[],mapView:'follow'});
  assert.ok(html.includes('joystick-disabled'));
});

// --- P1-07C: Mobile Movement Telemetry overlay shell (diagnostic-only, Issue #21) ---
// The overlay is a static shell here; app.js's tickMovementFrame patches its child span ids every
// frame (throttled), never rebuilding it via render(). These tests only check the shell exists
// with the expected hooks — not that it's pointer-events:none (that's a styles.css rule, verified
// by direct inspection, not a DOM-free unit test in this codebase's established convention).

test('renderWorldMapHtml renders the P1-07C telemetry overlay shell with all documented data-point ids, each starting as a placeholder',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const snap={state:'IN_WORLD',cityId:'a',worldPosition:{x:500,y:500}};
  const html=renderWorldMapHtml({snap,cities,roads:[],mapView:'follow'});
  assert.ok(html.includes('id="telemetry-overlay"'));
  for(const id of ['telemetry-fps','telemetry-rtt','telemetry-gap','telemetry-lead','telemetry-inflight','telemetry-throttled','telemetry-collided','telemetry-suspended','telemetry-status','telemetry-errorcode']){
    assert.ok(html.includes(`id="${id}"`),`expected the overlay shell to include #${id}`);
  }
});

test('renderWorldMapHtml: the telemetry overlay is purely additive — joystick and Follow/Full Map toggle markup are unaffected by its presence',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const snap={state:'IN_WORLD',cityId:'a',worldPosition:{x:500,y:500}};
  const html=renderWorldMapHtml({snap,cities,roads:[],mapView:'follow'});
  assert.ok(html.includes('id="joystick-base"'));
  assert.ok(html.includes('id="map-view-toggle"'));
  assert.ok(html.indexOf('id="telemetry-overlay"')>html.indexOf('id="joystick-base"'),'telemetry overlay should be appended after the joystick, never inserted between existing controls');
});

// --- P1-07 Root Cause Measurement Test: 7 more overlay data-point ids, purely additive to the
// existing P1-07C shell above (that test is left untouched — this only adds new coverage). ---

test('renderWorldMapHtml renders the P1-07 Root Cause Measurement Test overlay ids, appended after the existing P1-07C ones, each starting as a placeholder',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const snap={state:'IN_WORLD',cityId:'a',worldPosition:{x:500,y:500}};
  const html=renderWorldMapHtml({snap,cities,roads:[],mapView:'follow'});
  const newIds=['telemetry-leadcaphit','telemetry-capfrozen','telemetry-frozen-current','telemetry-frozen-total','telemetry-frozen-ratio','telemetry-correction','telemetry-hardresets'];
  for(const id of newIds){
    assert.ok(html.includes(`id="${id}"`),`expected the overlay shell to include #${id}`);
    assert.ok(html.indexOf(`id="${id}"`)>html.indexOf('id="telemetry-errorcode"'),`expected #${id} to be appended after the existing P1-07C ids, never inserted between them`);
  }
});

// --- P4-04B2: 6 more overlay data-point ids (Recent Movement Anomaly), purely additive to the
// existing shell above (neither earlier test is touched — this only adds new coverage). ---

test('renderWorldMapHtml renders the P4-04B2 Recent Movement Anomaly overlay ids, appended after the existing P1-07 Root Cause Measurement Test ones, each starting as a placeholder',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const snap={state:'IN_WORLD',cityId:'a',worldPosition:{x:500,y:500}};
  const html=renderWorldMapHtml({snap,cities,roads:[],mapView:'follow'});
  const newIds=['telemetry-recent-freeze','telemetry-recent-lead','telemetry-recent-rtt','telemetry-recent-gap','telemetry-recent-inflight','telemetry-recent-age'];
  for(const id of newIds){
    assert.ok(html.includes(`id="${id}"`),`expected the overlay shell to include #${id}`);
    assert.ok(html.indexOf(`id="${id}"`)>html.indexOf('id="telemetry-hardresets"'),`expected #${id} to be appended after the existing P1-07 Root Cause Measurement Test ids, never inserted between them`);
  }
});

// --- P4-04B2 Mobile Telemetry Overflow Fix — display/layout-only: a narrow-viewport 2-column
// reflow of the SAME 23 overlay fields (no field removed, no accordion, no scrolling required). The
// markup (public/worldmap.js) is unchanged this round; only public/styles.css gained a mobile media
// query, so these tests verify (1) all 23 telemetry ids still render exactly once each — nothing
// removed — and (2) the responsive layout rule itself exists in styles.css. ---

test('P4-04B2 Mobile Telemetry Overflow Fix: all 23 telemetry overlay ids — the same set from P1-07C/P1-07/P4-04B2 — still render, each exactly once, none removed',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const snap={state:'IN_WORLD',cityId:'a',worldPosition:{x:500,y:500}};
  const html=renderWorldMapHtml({snap,cities,roads:[],mapView:'follow'});
  const allIds=['telemetry-fps','telemetry-rtt','telemetry-gap','telemetry-lead','telemetry-inflight','telemetry-throttled','telemetry-collided','telemetry-suspended','telemetry-status','telemetry-errorcode','telemetry-leadcaphit','telemetry-capfrozen','telemetry-frozen-current','telemetry-frozen-total','telemetry-frozen-ratio','telemetry-correction','telemetry-hardresets','telemetry-recent-freeze','telemetry-recent-lead','telemetry-recent-rtt','telemetry-recent-gap','telemetry-recent-inflight','telemetry-recent-age'];
  assert.equal(allIds.length,23,'sanity check on the expected field count itself');
  for(const id of allIds){
    const matches=html.split(`id="${id}"`).length-1;
    assert.equal(matches,1,`expected #${id} to render exactly once, found ${matches}`);
  }
});

test('P4-04B2 Mobile Telemetry Overflow Fix: joystick and Follow/Full Map toggle controls remain present and unaffected by the overlay layout change',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const snap={state:'IN_WORLD',cityId:'a',worldPosition:{x:500,y:500}};
  const html=renderWorldMapHtml({snap,cities,roads:[],mapView:'follow'});
  assert.ok(html.includes('id="joystick-base"'));
  assert.ok(html.includes('id="joystick-knob"'));
  assert.ok(html.includes('id="map-view-toggle"'));
});

test('P4-04B2 Mobile Telemetry Overflow Fix: styles.css defines a narrow-viewport responsive 2-column grid for .telemetry-overlay, never removing the base (wider-screen) rule',async()=>{
  const css=await readFile(new URL('../public/styles.css',import.meta.url),'utf8');
  const baseRuleIndex=css.indexOf('.telemetry-overlay{');
  assert.ok(baseRuleIndex>=0,'the existing single-column base rule must still be present, unchanged, for wider screens');
  const mediaMatch=css.match(/@media\(max-width:\d+px\)\{\.telemetry-overlay\{[^}]*display:grid[^}]*\}/);
  assert.ok(mediaMatch,'expected a narrow-viewport media query switching .telemetry-overlay to a grid layout');
  assert.match(mediaMatch[0],/grid-template-columns:repeat\(2,/,'expected exactly 2 columns, not a collapse/accordion or single column');
  assert.doesNotMatch(mediaMatch[0],/overflow(?:-y)?:\s*(auto|scroll)/,'the mobile fix must not rely on internal scrolling to see the full snapshot');
});

// =====================================================================================
// P2-07 City Hub Navigation — IN_CITY must default directly to City Hub, never require a
// separate "進入城市" step from the World Map. See CHANGELOG.md P2-07 City Hub Navigation entry
// and the approved "P2-07 City Hub / World Navigation Architecture Audit" for full rationale.
// =====================================================================================

test('shouldShowCityHubOnStateChange requirement 1/4: a client with no prior snapshot (fresh/reloaded) whose authoritative state is already IN_CITY must land on Hub',()=>{
  assert.equal(shouldShowCityHubOnStateChange(undefined,'IN_CITY'),true);
  assert.equal(shouldShowCityHubOnStateChange(null,'IN_CITY'),true);
});

test('shouldShowCityHubOnStateChange requirement 2: a transition from IN_WORLD into IN_CITY (marker entry) must land on Hub',()=>{
  assert.equal(shouldShowCityHubOnStateChange('IN_WORLD','IN_CITY'),true);
});

test('shouldShowCityHubOnStateChange requirement 3: a transition from TRAVELING into IN_CITY (bus arrival) must land on Hub',()=>{
  assert.equal(shouldShowCityHubOnStateChange('TRAVELING','IN_CITY'),true);
});

test('shouldShowCityHubOnStateChange requirements 5/6/7: an ordinary IN_CITY-to-IN_CITY refresh (buying, selling, storage, bus quote, etc. while already inside) must NOT force the player back to Hub — that would eject them from Market/Storage/Bus on every unrelated refresh',()=>{
  assert.equal(shouldShowCityHubOnStateChange('IN_CITY','IN_CITY'),false);
});

test('shouldShowCityHubOnStateChange requirement 18: a transition out of IN_CITY (city exit) must not (re)force Hub — exitCity\'s own leaveCityHub() already drives the tab to the World Map',()=>{
  assert.equal(shouldShowCityHubOnStateChange('IN_CITY','IN_WORLD'),false);
});

test('shouldShowCityHubOnStateChange never fires while remaining IN_WORLD or TRAVELING across an unrelated refresh',()=>{
  assert.equal(shouldShowCityHubOnStateChange('IN_WORLD','IN_WORLD'),false);
  assert.equal(shouldShowCityHubOnStateChange('TRAVELING','TRAVELING'),false);
});

test('requirement 8: cityHubEntries includes a 查看地圖 (view map) entry, always available, distinct from the leave action',()=>{
  const entries=cityHubEntries(['MARKET','STORAGE']);
  const viewMap=entries.find(e=>e.action==='view-map');
  assert.ok(viewMap,'expected a view-map entry in cityHubEntries');
  assert.equal(viewMap.label,'查看地圖');
  assert.equal(viewMap.available,true);
  assert.notEqual(viewMap.id,'leave');
});

test('requirement 8: renderCityHubHtml renders a 查看地圖 tile with a dedicated data-view-map hook, separate from data-hub-leave',()=>{
  const state={snap:{cityId:'starter-village'},cities:[{id:'starter-village',name:'新手村',facilities:['MARKET','STORAGE']}]};
  const html=renderCityHubHtml(state);
  assert.ok(html.includes('data-view-map="1"'),'expected a data-view-map hook in the City Hub tile grid');
  assert.ok(html.includes('查看地圖'));
  assert.ok(html.includes('data-hub-leave="1"'),'the existing leave-city tile must still be present, unaffected');
});

test('requirement 9/13: while IN_CITY, renderWorldMapHtml no longer renders the old "進入城市"/data-enter-hub control at all',()=>{
  const cities=[{id:'starter-village',name:'新手村',coordinates:{x:220,y:150}}];
  const snap={state:'IN_CITY',cityId:'starter-village',worldPosition:{x:220,y:150}};
  const html=renderWorldMapHtml({snap,cities,roads:[],mapView:'follow'});
  assert.ok(!html.includes('data-enter-hub'),'the old client-only "進入城市" tab-switch control must be fully removed');
  assert.ok(!html.includes('進入城市'),'no copy anywhere should still imply the player needs to "enter" a city they are already inside');
});

test('requirement 11: while IN_CITY, the World Map inspection screen offers a 返回城市中心 control (data-back-hub) — the same client-only mechanism Market/Storage/Bus already use to return to Hub',()=>{
  const cities=[{id:'starter-village',name:'新手村',coordinates:{x:220,y:150}}];
  const snap={state:'IN_CITY',cityId:'starter-village',worldPosition:{x:220,y:150}};
  const html=renderWorldMapHtml({snap,cities,roads:[],mapView:'follow'});
  assert.ok(html.includes('data-back-hub="1"'));
  assert.ok(html.includes('返回城市中心'));
  assert.ok(html.includes('新手村'),'the inspection screen may show the current city name for context');
});

test('requirement 10: the joystick stays disabled on the IN_CITY inspection map, identical to the pre-existing IN_CITY behavior (renderWorldMapHtml disables the joystick whenever state!==IN_WORLD, unchanged by this feature)',()=>{
  const cities=[{id:'a',name:'A',coordinates:{x:220,y:150}}];
  const snap={state:'IN_CITY',cityId:'a',worldPosition:{x:220,y:150}};
  const html=renderWorldMapHtml({snap,cities,roads:[],mapView:'follow'});
  assert.ok(html.includes('joystick-disabled'));
});

test('requirement 17: public/app.js wires [data-hub-leave] to exactly ONE click handler — the real server-authoritative exitCity() — never a second client-only listener that would double-fire on a single tap',async()=>{
  const source=await readFile(new URL('../public/app.js',import.meta.url),'utf8');
  const occurrences=source.split(`'[data-hub-leave]'`).length-1;
  assert.equal(occurrences,1,`expected exactly one [data-hub-leave] selector in app.js (one wiring), found ${occurrences}`);
  assert.ok(source.includes(`document.querySelectorAll('[data-hub-leave]').forEach(b=>b.onclick=exitCity)`),'expected the sole handler to be the real exitCity() server command');
});

test('requirement 9: public/app.js wires [data-view-map] as a pure client-side tab switch — no server command, no fetch/post/await — while [data-enter-hub] no longer exists anywhere in the file',async()=>{
  const source=await readFile(new URL('../public/app.js',import.meta.url),'utf8');
  assert.ok(!source.includes('data-enter-hub'),'the removed old IN_CITY entry control must leave no trace in app.js');
  const match=source.match(/document\.querySelector\('\[data-view-map\]'\)\?\.addEventListener\('click',\(\)=>\{([^}]*)\}\);/);
  assert.ok(match,'expected a single data-view-map click handler wired via addEventListener');
  const body=match[1];
  assert.ok(body.includes(`S.tab='map'`));
  assert.ok(!/command\(|post\(|fetch\(|await /.test(body),`expected a pure client-only tab switch, found a network/async call in: ${body}`);
});
