// Phase 3 economy content contract — data only. Balance values are Prototype Parameters.
export const GOOD_DEFINITIONS=Object.freeze([
  Object.freeze({id:'rice',name:'米糧',cargoUnits:1}),
  Object.freeze({id:'tea',name:'茶葉',cargoUnits:1}),
  Object.freeze({id:'cloth',name:'布匹',cargoUnits:2}),
  Object.freeze({id:'iron',name:'鐵材',cargoUnits:3}),
  Object.freeze({id:'timber',name:'木材',cargoUnits:4}),
  Object.freeze({id:'medicine',name:'藥材',cargoUnits:1})
]);

// Four-city, six-good seed matrix. These are playtest parameters, not final balance promises.
export const MARKET_SEED=Object.freeze([
  ['starter-village','rice',120,10,2,120,6],['starter-village','tea',90,15,3,100,4],['starter-village','cloth',80,24,4,90,3],['starter-village','iron',60,34,5,80,2],['starter-village','timber',110,18,3,110,5],['starter-village','medicine',70,30,4,80,3],
  ['hill-market','rice',85,14,2,90,4],['hill-market','tea',75,21,3,80,3],['hill-market','cloth',70,29,4,80,3],['hill-market','iron',120,22,4,120,6],['hill-market','timber',95,24,3,100,4],['hill-market','medicine',115,19,3,120,6],
  ['growth-city','rice',75,17,3,85,3],['growth-city','tea',105,13,2,110,5],['growth-city','cloth',115,20,3,120,6],['growth-city','iron',70,31,5,80,3],['growth-city','timber',65,30,4,75,2],['growth-city','medicine',90,25,4,100,4],
  ['harbour-city','rice',70,20,3,80,3],['harbour-city','tea',125,9,2,125,6],['harbour-city','cloth',100,18,3,110,5],['harbour-city','iron',80,28,4,90,3],['harbour-city','timber',70,27,4,80,3],['harbour-city','medicine',75,32,5,85,3]
].map(([cityId,goodTypeId,stock,basePrice,spread,targetStock,restockRate])=>Object.freeze({cityId,goodTypeId,stock,basePrice,spread,targetStock,restockRate})));

export const cargoUnitsFor=goodId=>GOOD_DEFINITIONS.find(g=>g.id===goodId)?.cargoUnits??1;
export const goodNameFor=goodId=>GOOD_DEFINITIONS.find(g=>g.id===goodId)?.name??goodId;
