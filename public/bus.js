import {CITY_DEFINITIONS} from './cities.js';

// P2-05 Prototype Parameters — deliberately centralised for iPhone balance playtests.
// They describe a virtual walking reference only; roads remain non-constraining world visuals.
export const BUS_WALK_MS_PER_WORLD_UNIT=25;
export const BUS_TIME_RATIO=0.7;
export const BUS_FARE_BASE_GOLD=12;
export const BUS_FARE_PER_100_WORLD_UNITS=3;

export function busQuote(fromCityId,toCityId,cities=CITY_DEFINITIONS){
  const from=cities.find(city=>city.id===fromCityId),to=cities.find(city=>city.id===toCityId);
  if(!from||!to||from.id===to.id)return null;
  const distance=Math.hypot(to.coordinates.x-from.coordinates.x,to.coordinates.y-from.coordinates.y);
  const walkingMs=Math.round(distance*BUS_WALK_MS_PER_WORLD_UNIT);
  const travelMs=Math.round(walkingMs*BUS_TIME_RATIO);
  const fareGold=BUS_FARE_BASE_GOLD+Math.ceil(distance/100)*BUS_FARE_PER_100_WORLD_UNITS;
  return {transportMode:'BUS',fromCityId:from.id,toCityId:to.id,distance,walkingMs,travelMs,fareGold,routeEdgeId:`bus:${from.id}:${to.id}`};
}
