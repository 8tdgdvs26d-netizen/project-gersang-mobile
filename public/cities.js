// Phase 2 city data contract (P2-02) — shared, DOM-free world content.
//
// Stable ids are save/API keys and must not be renamed. Coordinates, entry radii and exit points
// are Prototype Parameters: P2-03 will consume them for server-authoritative physical entry/exit,
// and Playtest may tune the numeric values without changing the save contract.

export const CITY_DEFINITIONS=Object.freeze([
  Object.freeze({
    id:'starter-village',
    name:'啟步城',
    region:'NT_WEST',
    coordinates:Object.freeze({x:220,y:220}),
    entryRadius:48,
    exitPoint:Object.freeze({x:220,y:292}),
    facilities:Object.freeze(['MARKET','STORAGE']),
    theme:'starter'
  }),
  Object.freeze({
    id:'harbour-city',
    name:'商業城',
    region:'HK_ISLAND',
    coordinates:Object.freeze({x:780,y:780}),
    entryRadius:48,
    exitPoint:Object.freeze({x:780,y:708}),
    facilities:Object.freeze(['MARKET','STORAGE']),
    theme:'harbour'
  }),
  Object.freeze({
    id:'hill-market',
    name:'開拓城',
    region:'NT_EAST',
    coordinates:Object.freeze({x:780,y:220}),
    entryRadius:48,
    exitPoint:Object.freeze({x:780,y:292}),
    facilities:Object.freeze(['MARKET','STORAGE']),
    theme:'frontier'
  }),
  Object.freeze({
    id:'growth-city',
    name:'躍動城',
    region:'HK_ISLAND',
    coordinates:Object.freeze({x:220,y:780}),
    entryRadius:48,
    exitPoint:Object.freeze({x:220,y:708}),
    // Phase 3 P3-01 opens the fourth city's economy for the six-good trading slice.
    facilities:Object.freeze(['MARKET','STORAGE']),
    theme:'growth'
  })
]);

// P2-03 shares the same pure proximity rule between map presentation and server validation.
// The server remains authoritative; the client only uses this to offer an explicit action.
export function isWithinCityEntry(position,city){
  if(!position||!city?.coordinates||!Number.isFinite(city.entryRadius))return false;
  if(!Number.isFinite(position.x)||!Number.isFinite(position.y))return false;
  return Math.hypot(position.x-city.coordinates.x,position.y-city.coordinates.y)<=city.entryRadius;
}
