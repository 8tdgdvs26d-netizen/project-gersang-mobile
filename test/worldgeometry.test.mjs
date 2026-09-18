import test from 'node:test';
import assert from 'node:assert/strict';
import {WORLD_BOUNDS,PLAYER_COLLISION_RADIUS,OBSTACLES,inflateRect,segmentIntersectsRect,pointInRect} from '../public/worldgeometry.js';

const rect={minX:100,minY:100,maxX:200,maxY:200};

test('worldgeometry.js exports Prototype Parameters with the expected shapes/values',()=>{
  assert.deepEqual(WORLD_BOUNDS,{min:0,max:1000});
  assert.equal(PLAYER_COLLISION_RADIUS,14);
  assert.ok(Array.isArray(OBSTACLES)&&OBSTACLES.length>0);
  for(const o of OBSTACLES){
    assert.ok(o.minX<o.maxX&&o.minY<o.maxY,`obstacle ${o.id} must have a positive width/height`);
  }
});

test('inflateRect grows every edge outward by the given radius, keeping the same id',()=>{
  assert.deepEqual(inflateRect(rect,14),{id:undefined,minX:86,minY:86,maxX:214,maxY:214});
  assert.deepEqual(inflateRect({id:'x',...rect},10),{id:'x',minX:90,minY:90,maxX:210,maxY:210});
});

test('pointInRect is inclusive of the rectangle boundary',()=>{
  assert.equal(pointInRect(150,150,rect),true);
  assert.equal(pointInRect(100,100,rect),true);
  assert.equal(pointInRect(200,200,rect),true);
  assert.equal(pointInRect(99,150,rect),false);
  assert.equal(pointInRect(150,201,rect),false);
});

test('segmentIntersectsRect: a segment that never comes near the rectangle returns false',()=>{
  assert.equal(segmentIntersectsRect(0,0,50,0,rect),false);
  assert.equal(segmentIntersectsRect(0,0,0,500,rect),false);
});

test('segmentIntersectsRect: a segment passing fully through a thin obstacle with both endpoints outside still returns true (thin-wall / swept case)',()=>{
  const thinWall={minX:145,minY:0,maxX:155,maxY:1000};
  assert.equal(segmentIntersectsRect(0,500,300,500,thinWall),true);
});

test('segmentIntersectsRect: an endpoint landing inside the rectangle returns true',()=>{
  assert.equal(segmentIntersectsRect(150,150,500,500,rect),true);
  assert.equal(segmentIntersectsRect(-500,-500,150,150,rect),true);
});

test('segmentIntersectsRect: a segment that stays close but never touches the rectangle returns false',()=>{
  assert.equal(segmentIntersectsRect(0,99,500,99,rect),false);
  assert.equal(segmentIntersectsRect(201,0,201,500,rect),false);
});

test('segmentIntersectsRect: boundary/touch semantics — a segment that only grazes the rectangle edge counts as intersecting',()=>{
  assert.equal(segmentIntersectsRect(0,100,500,100,rect),true);
  assert.equal(segmentIntersectsRect(200,0,200,500,rect),true);
});

test('segmentIntersectsRect: a degenerate zero-length segment behaves like a point-in-rect test',()=>{
  assert.equal(segmentIntersectsRect(150,150,150,150,rect),true);
  assert.equal(segmentIntersectsRect(0,0,0,0,rect),false);
});

test('segmentIntersectsRect: a segment that runs parallel to and outside a rectangle edge returns false',()=>{
  assert.equal(segmentIntersectsRect(-50,300,-50,-300,rect),false);
});
