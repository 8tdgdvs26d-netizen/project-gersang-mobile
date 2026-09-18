// Shared world-geometry data/logic (P1-04) — DOM-free, imported by both server.mjs (Node)
// and public/worldmap.js (browser), so collision truth and obstacle rendering never drift.
// All values here are Prototype Parameters, not final balance/design specs — subject to Playtest.

export const WORLD_BOUNDS={min:0,max:1000};

// Prototype radius only, aligned to the existing hero-marker's visual SVG radius (r="14").
// Used only to inflate obstacle rectangles for collision purposes — WORLD_BOUNDS stays
// player-center-based (0..1000), not shrunk to 14..986.
export const PLAYER_COLLISION_RADIUS=14;

// Axis-aligned obstacle rectangles, in the same world-coordinate space as WORLD_BOUNDS.
// Placement is a Prototype proposal only — kept clear of every city's coordinates and the
// spawn point (starter-village).
export const OBSTACLES=[
  {id:'ridge-a',minX:700,minY:400,maxX:720,maxY:550},
  {id:'ridge-b',minX:550,minY:400,maxX:620,maxY:470}
];

export function inflateRect(rect,radius){
  return {id:rect.id,minX:rect.minX-radius,minY:rect.minY-radius,maxX:rect.maxX+radius,maxY:rect.maxY+radius};
}

export function pointInRect(x,y,rect){
  return x>=rect.minX&&x<=rect.maxX&&y>=rect.minY&&y<=rect.maxY;
}

// Swept segment-vs-axis-aligned-rectangle intersection (Liang-Barsky parametric clipping).
// Returns true whenever any point of the segment from (x1,y1) to (x2,y2) lies inside/on rect —
// including when both endpoints are outside but the segment passes through it (thin-wall case).
export function segmentIntersectsRect(x1,y1,x2,y2,rect){
  const dx=x2-x1,dy=y2-y1;
  let tMin=0,tMax=1;
  const clips=[[-dx,x1-rect.minX],[dx,rect.maxX-x1],[-dy,y1-rect.minY],[dy,rect.maxY-y1]];
  for(const [p,q] of clips){
    if(p===0){
      if(q<0)return false;
    }else{
      const r=q/p;
      if(p<0){if(r>tMax)return false;if(r>tMin)tMin=r}
      else{if(r<tMin)return false;if(r<tMax)tMax=r}
    }
  }
  return tMin<=tMax;
}
