import test from 'node:test';
import assert from 'node:assert/strict';
import {WORLD_MONSTER_DEFINITIONS} from '../public/worldmonsters.js';
import {WORLD_BOUNDS,OBSTACLES,PLAYER_COLLISION_RADIUS,inflateRect,pointInRect,segmentIntersectsRect} from '../public/worldgeometry.js';
import {CITY_DEFINITIONS} from '../public/cities.js';

// P4-04A — World Threat Parameter/Placement Tuning. Geometric regression proof for the approved
// P4-04A Coding Order's retuned world-bandit-1 content (patrolA/patrolB y:220->80, aggroRadius:90->110,
// leashRadius:150->280 — see public/worldmonsters.js's own P4-04A comment for the full rationale).
// This file proves the SPECIFIC geometric claims the P4-04A Design/Coding Orders rely on, using the
// actual live content and actual shared primitives — never a re-typed literal that could silently
// drift from public/worldmonsters.js if the content changes again. Covers required tests A through F
// from the approved P4-04A Coding Order §5.

const monster=WORLD_MONSTER_DEFINITIONS[0];
const patrolCenter={x:(monster.patrolA.x+monster.patrolB.x)/2,y:(monster.patrolA.y+monster.patrolB.y)/2};

// Standard closest-point-on-segment-to-point primitive (same t-clamped-projection technique already
// established by public/worldmonsters.js's segmentEntersEncounterRadius), reused below for both
// point-to-segment and (via the four-endpoint-projection method) segment-to-segment minimum distance.
function pointToSegmentDistance(px,py,x1,y1,x2,y2){
  const dx=x2-x1,dy=y2-y1,lengthSquared=dx*dx+dy*dy;
  const t=lengthSquared>0?Math.max(0,Math.min(1,((px-x1)*dx+(py-y1)*dy)/lengthSquared)):0;
  const closestX=x1+t*dx,closestY=y1+t*dy;
  return Math.hypot(px-closestX,py-closestY);
}
// Standard orientation/on-segment primitives (classic computational-geometry segment-intersection
// test — see e.g. Cormen et al.), used ONLY to detect whether two segments cross at an interior
// point, which the four-endpoint-projection distance formula below cannot by itself detect (two
// segments can cross with all four endpoints still away from the opposite segment).
function orientation(px,py,qx,qy,rx,ry){
  const val=(qy-py)*(rx-qx)-(qx-px)*(ry-qy);
  if(val===0)return 0;
  return val>0?1:2;
}
function onSegment(px,py,qx,qy,rx,ry){
  return qx<=Math.max(px,rx)&&qx>=Math.min(px,rx)&&qy<=Math.max(py,ry)&&qy>=Math.min(py,ry);
}
function segmentsIntersect(x1,y1,x2,y2,x3,y3,x4,y4){
  const o1=orientation(x1,y1,x2,y2,x3,y3),o2=orientation(x1,y1,x2,y2,x4,y4);
  const o3=orientation(x3,y3,x4,y4,x1,y1),o4=orientation(x3,y3,x4,y4,x2,y2);
  if(o1!==o2&&o3!==o4)return true;
  if(o1===0&&onSegment(x1,y1,x3,y3,x2,y2))return true;
  if(o2===0&&onSegment(x1,y1,x4,y4,x2,y2))return true;
  if(o3===0&&onSegment(x3,y3,x1,y1,x4,y4))return true;
  if(o4===0&&onSegment(x3,y3,x2,y2,x4,y4))return true;
  return false;
}
// The minimum distance between two 2D line segments is always attained either at a crossing point
// (distance 0 — checked FIRST via segmentsIntersect, since two segments can cross at an interior
// point while all four endpoints remain away from the opposite segment, which the endpoint-
// projection method below cannot detect on its own) or, when they do not cross, at one of the four
// endpoint-vs-opposite-segment closest points — a standard, well-established computational-geometry
// result.
function segmentToSegmentDistance(ax1,ay1,ax2,ay2,bx1,by1,bx2,by2){
  if(segmentsIntersect(ax1,ay1,ax2,ay2,bx1,by1,bx2,by2))return 0;
  return Math.min(
    pointToSegmentDistance(ax1,ay1,bx1,by1,bx2,by2),
    pointToSegmentDistance(ax2,ay2,bx1,by1,bx2,by2),
    pointToSegmentDistance(bx1,by1,ax1,ay1,ax2,ay2),
    pointToSegmentDistance(bx2,by2,ax1,ay1,ax2,ay2)
  );
}

// ============================================================================
// A — approved Prototype Parameter values
// ============================================================================

test('P4-04A-A: approved World Threat tuning values are present exactly as specified in the P4-04A Coding Order',()=>{
  assert.deepEqual(monster.patrolA,{x:440,y:80});
  assert.deepEqual(monster.patrolB,{x:560,y:80});
  assert.equal(monster.aggroRadius,110);
  assert.equal(monster.leashRadius,280);
  assert.equal(monster.chaseSpeed,0.08,'chaseSpeed must stay fixed — the P4-04A Design Gate found it functionally reasonable and the Coding Order requires keeping it unless proven otherwise');
  assert.equal(monster.encounterRadius,40,'encounterRadius must stay fixed — not part of the approved P4-04A change set');
});

// ============================================================================
// B — main trade route (Starter Village -> Hill Market) clearance from aggroRadius
// ============================================================================

test('P4-04A-B: the direct Starter Village -> Hill Market trade route never enters the monster\'s aggroRadius under the new patrol corridor — proven via true segment-to-segment minimum distance, not an assumed offset',()=>{
  const starterVillage=CITY_DEFINITIONS.find(c=>c.id==='starter-village');
  const hillMarket=CITY_DEFINITIONS.find(c=>c.id==='hill-market');
  assert.ok(starterVillage&&hillMarket,'sanity: both cities must exist in content');
  // The direct route as a player would actually walk it (free-form movement, see P1-05 — roads are
  // non-constraining, so the "natural" route between two cities on the same y is a straight line
  // between their coordinates, exactly what the P4-04 Micro Playtest actually drove).
  const routeFrom=starterVillage.coordinates,routeTo=hillMarket.coordinates;
  assert.equal(routeFrom.y,220);
  assert.equal(routeTo.y,220);
  const minDistance=segmentToSegmentDistance(
    routeFrom.x,routeFrom.y,routeTo.x,routeTo.y,
    monster.patrolA.x,monster.patrolA.y,monster.patrolB.x,monster.patrolB.y
  );
  assert.ok(minDistance>monster.aggroRadius,
    `the closest approach between the trade route and the patrol segment is ${minDistance}px, expected strictly greater than aggroRadius(${monster.aggroRadius}) — otherwise the route would guarantee an aggro trigger for a player simply travelling between the two cities, which is exactly the bug the P4-04 Micro Playtest found and P4-04A exists to fix`);
  // Minimum required perpendicular clearance per the approved Coding Order (~30px) — a looser sanity
  // floor, not the precise computed value above, so this stays robust to minor future patrol tuning.
  assert.ok(minDistance-monster.aggroRadius>=25,
    `clearance (${minDistance-monster.aggroRadius}px) must be a real margin, not a coincidental near-zero value — Coding Order §5B expects approximately 30px`);
});

// ============================================================================
// C — the new patrol segment stays entirely within WORLD_BOUNDS
// ============================================================================

test('P4-04A-C: the new patrol segment (the only authoritative monster position, patrolPositionAt output) stays completely within WORLD_BOUNDS — the aggro/leash circles are not required to fit inside the world, only the monster\'s own position',()=>{
  for(const point of [monster.patrolA,monster.patrolB]){
    assert.ok(point.x>=WORLD_BOUNDS.min&&point.x<=WORLD_BOUNDS.max,`patrol point x=${point.x} must be within WORLD_BOUNDS [${WORLD_BOUNDS.min},${WORLD_BOUNDS.max}]`);
    assert.ok(point.y>=WORLD_BOUNDS.min&&point.y<=WORLD_BOUNDS.max,`patrol point y=${point.y} must be within WORLD_BOUNDS [${WORLD_BOUNDS.min},${WORLD_BOUNDS.max}]`);
  }
});

// ============================================================================
// D — patrol route does not overlap any city's entryRadius
// ============================================================================

test('P4-04A-D: the new patrol route does not overlap any current city\'s entryRadius',()=>{
  for(const city of CITY_DEFINITIONS){
    const distance=pointToSegmentDistance(city.coordinates.x,city.coordinates.y,monster.patrolA.x,monster.patrolA.y,monster.patrolB.x,monster.patrolB.y);
    assert.ok(distance>city.entryRadius,
      `patrol route sits ${distance}px from ${city.id}'s coordinates, expected strictly greater than its entryRadius(${city.entryRadius}) — the patrol itself must never physically overlap a city's entry zone`);
  }
});

// ============================================================================
// E — patrol route does not enter any current inflated obstacle
// ============================================================================

test('P4-04A-E: the new patrol route does not enter any current inflated obstacle',()=>{
  const inflated=OBSTACLES.map(r=>inflateRect(r,PLAYER_COLLISION_RADIUS));
  for(const rect of inflated){
    assert.ok(!pointInRect(monster.patrolA.x,monster.patrolA.y,rect),`patrolA must not sit inside inflated obstacle ${JSON.stringify(rect)}`);
    assert.ok(!pointInRect(monster.patrolB.x,monster.patrolB.y,rect),`patrolB must not sit inside inflated obstacle ${JSON.stringify(rect)}`);
    assert.ok(!segmentIntersectsRect(monster.patrolA.x,monster.patrolA.y,monster.patrolB.x,monster.patrolB.y,rect),`the patrolA->patrolB segment must not cross inflated obstacle ${JSON.stringify(rect)}`);
  }
});

// ============================================================================
// F — City Safe Zone reachability: at least one realistic city is reachable while still CHASE
// ============================================================================

test('P4-04A-F: with leashRadius=280, at least Starter Village and Hill Market become geometrically reachable while the monster is still CHASE — CHASE -> run toward city -> enter before leash disengage is a real, reachable decision (geometry proof only; actual feel is P4-04B\'s job)',()=>{
  const starterVillage=CITY_DEFINITIONS.find(c=>c.id==='starter-village');
  const hillMarket=CITY_DEFINITIONS.find(c=>c.id==='hill-market');
  for(const city of [starterVillage,hillMarket]){
    const distanceToCenter=Math.hypot(city.coordinates.x-patrolCenter.x,city.coordinates.y-patrolCenter.y);
    const nearestEntryBoundary=distanceToCenter-city.entryRadius;
    assert.ok(nearestEntryBoundary<monster.leashRadius,
      `${city.id}'s nearest entry boundary is ${nearestEntryBoundary}px from the patrol center, expected strictly LESS than leashRadius(${monster.leashRadius}) — a point on the city's entry boundary must still be within the leash, so a chased player who reaches it is still CHASE at that moment, not already disengaged`);
  }
  // Documents (does not itself require) that the two diagonal-corner cities remain intentionally
  // beyond reach at this leashRadius — Coding Order §7/Issue 2 only requires "at least one realistic
  // current route", not universal reachability, and an unbounded leash would undermine the disengage
  // mechanic entirely.
  const harbourCity=CITY_DEFINITIONS.find(c=>c.id==='harbour-city');
  const growthCity=CITY_DEFINITIONS.find(c=>c.id==='growth-city');
  for(const city of [harbourCity,growthCity]){
    const distanceToCenter=Math.hypot(city.coordinates.x-patrolCenter.x,city.coordinates.y-patrolCenter.y);
    const nearestEntryBoundary=distanceToCenter-city.entryRadius;
    assert.ok(nearestEntryBoundary>monster.leashRadius,`${city.id} is expected to remain beyond leash reach at the current tuning (documented, not a requirement)`);
  }
});

// ============================================================================
// Cross-check — obstacle-vs-leash finding (P4-03C-I) still holds under the new leashRadius/patrol
// ============================================================================

test('P4-04A-G: obstacle-blocked CHASE remains geometrically unreachable under the new leashRadius(280)/patrol center — the P4-03C-I finding is not silently invalidated by this retune',()=>{
  const inflated=OBSTACLES.map(r=>inflateRect(r,PLAYER_COLLISION_RADIUS));
  for(const rect of inflated){
    const closestX=Math.max(rect.minX,Math.min(patrolCenter.x,rect.maxX));
    const closestY=Math.max(rect.minY,Math.min(patrolCenter.y,rect.maxY));
    const distance=Math.hypot(closestX-patrolCenter.x,closestY-patrolCenter.y);
    assert.ok(distance>monster.leashRadius,`obstacle closest point sits ${distance}px from the new patrol center, expected strictly beyond the new leashRadius(${monster.leashRadius})`);
  }
});

// ============================================================================
// Draft Review Fix — segmentToSegmentDistance must detect an interior crossing, not just rely on
// the four-endpoint-projection distances (which alone would wrongly report a nonzero minimum
// distance for two segments that cross with all four endpoints away from the opposite segment).
// ============================================================================

test('P4-04A-H: segmentToSegmentDistance returns exactly 0 for two segments crossing at an interior point (neither endpoint touches the opposite segment)',()=>{
  // A: (0,0) -> (10,0), a horizontal segment. B: (5,-5) -> (5,5), a vertical segment crossing A's
  // interior at (5,0) — none of A's or B's four endpoints lie on the opposite segment, so the plain
  // four-endpoint-projection formula alone (pre-fix) would have returned a nonzero minimum distance
  // despite the segments genuinely crossing.
  assert.equal(segmentToSegmentDistance(0,0,10,0,5,-5,5,5),0);
  // Sanity: the same two segments shifted apart (B moved to x=15, well clear of A) must NOT report 0.
  assert.ok(segmentToSegmentDistance(0,0,10,0,15,-5,15,5)>0,'two genuinely non-crossing, non-touching segments must not report a zero distance');
});
