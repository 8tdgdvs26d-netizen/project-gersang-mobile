import test from 'node:test';
import assert from 'node:assert/strict';
import {CITY_DEFINITIONS} from '../public/cities.js';
import {busQuote} from '../public/bus.js';
import {WORLD_BOUNDS,OBSTACLES,PLAYER_COLLISION_RADIUS,inflateRect,pointInRect} from '../public/worldgeometry.js';

const byId=Object.fromEntries(CITY_DEFINITIONS.map(city=>[city.id,city]));
const distance=(a,b)=>Math.hypot(byId[b].coordinates.x-byId[a].coordinates.x,byId[b].coordinates.y-byId[a].coordinates.y);

test('four canonical cities occupy the approved square-map corners',()=>{
  assert.deepEqual(byId['starter-village'].coordinates,{x:220,y:220});
  assert.deepEqual(byId['hill-market'].coordinates,{x:780,y:220});
  assert.deepEqual(byId['growth-city'].coordinates,{x:220,y:780});
  assert.deepEqual(byId['harbour-city'].coordinates,{x:780,y:780});

  const xs=new Set(CITY_DEFINITIONS.map(city=>city.coordinates.x));
  const ys=new Set(CITY_DEFINITIONS.map(city=>city.coordinates.y));
  assert.deepEqual(xs,new Set([220,780]));
  assert.deepEqual(ys,new Set([220,780]));
});

test('square sides are equal and diagonals are equal and longer',()=>{
  const sides=[
    distance('starter-village','hill-market'),
    distance('starter-village','growth-city'),
    distance('hill-market','harbour-city'),
    distance('growth-city','harbour-city')
  ];
  const diagonals=[
    distance('starter-village','harbour-city'),
    distance('hill-market','growth-city')
  ];
  assert.ok(sides.every(value=>value===560));
  assert.ok(diagonals.every(value=>Math.abs(value-Math.hypot(560,560))<1e-9));
  assert.ok(diagonals[0]>sides[0]);
});

test('bus pricing and duration remain symmetric with diagonal routes costlier and longer than side routes',()=>{
  const side=busQuote('starter-village','hill-market');
  const diagonal=busQuote('starter-village','harbour-city');
  assert.equal(side.distance,560);
  assert.ok(Math.abs(diagonal.distance-Math.hypot(560,560))<1e-9);
  assert.ok(diagonal.fareGold>side.fareGold);
  assert.ok(diagonal.travelMs>side.travelMs);

  for(const from of CITY_DEFINITIONS){
    for(const to of CITY_DEFINITIONS){
      if(from.id===to.id)continue;
      const forward=busQuote(from.id,to.id),reverse=busQuote(to.id,from.id);
      assert.equal(forward.fareGold,reverse.fareGold);
      assert.equal(forward.travelMs,reverse.travelMs);
    }
  }
});

test('all approved safe exits stay in bounds, outside entry radii, and clear of collision obstacles',()=>{
  const expected={
    'starter-village':{x:220,y:292},
    'hill-market':{x:780,y:292},
    'growth-city':{x:220,y:708},
    'harbour-city':{x:780,y:708}
  };
  const inflated=OBSTACLES.map(obstacle=>inflateRect(obstacle,PLAYER_COLLISION_RADIUS));
  for(const city of CITY_DEFINITIONS){
    assert.deepEqual(city.exitPoint,expected[city.id]);
    assert.ok(city.exitPoint.x>=WORLD_BOUNDS.min&&city.exitPoint.x<=WORLD_BOUNDS.max);
    assert.ok(city.exitPoint.y>=WORLD_BOUNDS.min&&city.exitPoint.y<=WORLD_BOUNDS.max);
    assert.ok(Math.hypot(city.exitPoint.x-city.coordinates.x,city.exitPoint.y-city.coordinates.y)>city.entryRadius);
    assert.equal(inflated.some(obstacle=>pointInRect(city.exitPoint.x,city.exitPoint.y,obstacle)),false);
  }
});
