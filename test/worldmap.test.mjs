import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {
  canEnterCityHub,
  cityHubEntries,
  leaveCityHub,
  chooseTravelAction,
  handleCityTap,
  computeTravelPosition,
  indexById,
  regionMeta,
  renderWorldMapHtml,
  resolveWorldPosition,
  computeCameraViewBox,
  resolveMapViewBox,
  resolveEffectiveViewBox,
  WORLD_BOUNDS,
  OBSTACLES,
  CAMERA_VIEWPORT_SIZE
} from '../public/worldmap.js';
import {OBSTACLES as GEOMETRY_OBSTACLES} from '../public/worldgeometry.js';

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

test('existing city ids and display names are unchanged',async()=>{
  const cities=await request('/api/cities');
  const byId=indexById(cities);
  assert.equal(byId['starter-village']?.name,'Starter Village');
  assert.equal(byId['harbour-city']?.name,'Harbour City');
  assert.equal(byId['hill-market']?.name,'Hill Market');
  assert.equal(cities.length,3);
});

test('GET /api/roads matches the roads table used by travel routing',async()=>{
  const roads=await request('/api/roads');
  const direct=roads.find(r=>r.fromCityId==='starter-village'&&r.toCityId==='harbour-city');
  assert.ok(direct,'expected a direct road from starter-village to harbour-city');
  const started=await post('/api/commands/travel/start',envelope('worldmap-roads-check',{destinationCityId:'harbour-city'}));
  assert.equal(started.status,'ACCEPTED');
  assert.equal(started.data.totalTravelMs,direct.durationMs);
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

test('cityHubEntries returns exactly 2 available, 4 unavailable, and 1 leave entry',async()=>{
  const cities=await request('/api/cities');
  const city=cities.find(c=>c.id==='starter-village');
  const entries=cityHubEntries(city?.facilities);
  assert.equal(entries.length,7);
  assert.equal(entries.filter(e=>e.available&&e.action!=='leave').length,2);
  assert.equal(entries.filter(e=>!e.available).length,4);
  assert.equal(entries.filter(e=>e.action==='leave').length,1);
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

test('selecting a map city calls the existing travel/start command',()=>{
  const calls={start:[],reroute:[]};
  const travel=id=>calls.start.push(id);
  const reroute=id=>calls.reroute.push(id);
  handleCityTap('harbour-city',{snap:{state:'IN_CITY',cityId:'starter-village'},travel,reroute});
  assert.deepEqual(calls.start,['harbour-city']);
  assert.deepEqual(calls.reroute,[]);
});

test('selecting a different city mid-journey calls the existing travel/reroute command',()=>{
  const calls={start:[],reroute:[]};
  const travel=id=>calls.start.push(id);
  const reroute=id=>calls.reroute.push(id);
  handleCityTap('hill-market',{snap:{state:'TRAVELING',cityId:'starter-village',activeTravel:{toCityId:'harbour-city'}},travel,reroute});
  assert.deepEqual(calls.reroute,['hill-market']);
  assert.deepEqual(calls.start,[]);
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
