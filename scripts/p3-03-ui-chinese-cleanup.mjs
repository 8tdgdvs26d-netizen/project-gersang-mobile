import fs from 'node:fs';
import path from 'node:path';

function replaceRequired(text, from, to, label) {
  if (!text.includes(from)) throw new Error(`Missing expected source for ${label}`);
  return text.replaceAll(from, to);
}

const appPath = 'public/app.js';
let app = fs.readFileSync(appPath, 'utf8');
app = replaceRequired(app,
  "const cityName=id=>S.cities.find(x=>x.id===id)?.name||id;",
  "const cityName=id=>S.cities.find(x=>x.id===id)?.name||id;\nconst stateName=state=>({IN_CITY:'城內',IN_WORLD:'城外',TRAVELING:'旅途中'}[state]||state);",
  'stateName helper');
app = replaceRequired(app,
  '<div class="small">Combat Prototype v0.32.0</div>',
  '<div class="small">戰鬥原型 版本 0.32.0</div>',
  'prototype label');
app = replaceRequired(app,
  '<div class="small" id="state-label">${s.state}</div>',
  '<div class="small" id="state-label">${stateName(s.state)}</div>',
  'state label render');
app = replaceRequired(app,
  "if(stateLabel&&stateLabel.textContent!==S.snap.state)stateLabel.textContent=S.snap.state;",
  "if(stateLabel&&stateLabel.textContent!==stateName(S.snap.state))stateLabel.textContent=stateName(S.snap.state);",
  'state label live patch');
app = replaceRequired(app,
  '← 返回City Hub',
  '← 返回城市中心',
  'City Hub back labels');
app = replaceRequired(app,
  '買價會喺確認成交時由 Server 再檢查。',
  '買價會喺確認成交時再次檢查。',
  'Server copy');
app = replaceRequired(app,
  '買價 ${m.buyPrice} · Stock ${m.stock} · v${m.version}',
  '買價 ${m.buyPrice} · 庫存 ${m.stock}',
  'market stock/version row');
app = replaceRequired(app,
  '<div>${x.goodTypeId} × ${x.quantity}</div>',
  '<div>${goodNameFor(x.goodTypeId)} × ${x.quantity}</div>',
  'cargo stable-id display');
fs.writeFileSync(appPath, app);

const mapPath = 'public/worldmap.js';
let map = fs.readFileSync(mapPath, 'utf8');
map = replaceRequired(map,
  '<span>ETA ${new Date(t.estimatedArrivalAt).toLocaleTimeString()}</span>',
  '<span>預計到埗 ${new Date(t.estimatedArrivalAt).toLocaleTimeString()}</span>',
  'ETA label');
map = replaceRequired(map,
  '返回City Hub',
  '返回城市中心',
  'map back label');
const oldTelemetry = '<div>FPS <span id="telemetry-fps">…</span></div><div>RTT <span id="telemetry-rtt">…</span></div><div>Gap <span id="telemetry-gap">…</span></div><div>Lead <span id="telemetry-lead">…</span></div><div>Flight <span id="telemetry-inflight">…</span></div><div>Throttled <span id="telemetry-throttled">…</span></div><div>Collided <span id="telemetry-collided">…</span></div><div>Suspend <span id="telemetry-suspended">…</span></div><div>Status <span id="telemetry-status">…</span></div><div>Err <span id="telemetry-errorcode">…</span></div><div>LeadCap <span id="telemetry-leadcaphit">…</span></div><div>Frozen <span id="telemetry-capfrozen">…</span></div><div>FrozenCur <span id="telemetry-frozen-current">…</span></div><div>FrozenTot <span id="telemetry-frozen-total">…</span></div><div>FrozenPct <span id="telemetry-frozen-ratio">…</span></div><div>Correction <span id="telemetry-correction">…</span></div><div>HardResets <span id="telemetry-hardresets">…</span></div>';
const newTelemetry = '<div>幀率 <span id="telemetry-fps">…</span></div><div>延遲 <span id="telemetry-rtt">…</span></div><div>回應間隔 <span id="telemetry-gap">…</span></div><div>預測超前 <span id="telemetry-lead">…</span></div><div>請求中 <span id="telemetry-inflight">…</span></div><div>限速 <span id="telemetry-throttled">…</span></div><div>碰撞 <span id="telemetry-collided">…</span></div><div>暫停預測 <span id="telemetry-suspended">…</span></div><div>狀態 <span id="telemetry-status">…</span></div><div>錯誤 <span id="telemetry-errorcode">…</span></div><div>超前上限 <span id="telemetry-leadcaphit">…</span></div><div>凍結 <span id="telemetry-capfrozen">…</span></div><div>本次凍結 <span id="telemetry-frozen-current">…</span></div><div>累計凍結 <span id="telemetry-frozen-total">…</span></div><div>凍結比例 <span id="telemetry-frozen-ratio">…</span></div><div>修正量 <span id="telemetry-correction">…</span></div><div>強制重置 <span id="telemetry-hardresets">…</span></div>';
map = replaceRequired(map, oldTelemetry, newTelemetry, 'telemetry labels');
fs.writeFileSync(mapPath, map);

for (const file of fs.readdirSync('test').filter(x => x.endsWith('.test.mjs'))) {
  const p = path.join('test', file);
  let text = fs.readFileSync(p, 'utf8');
  const next = text.replaceAll('返回City Hub', '返回城市中心');
  if (next !== text) fs.writeFileSync(p, next);
}

const test = `import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const app=fs.readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
const map=fs.readFileSync(new URL('../public/worldmap.js',import.meta.url),'utf8');

test('P3-03 player-facing market and state labels use Chinese instead of internal codes',()=>{
  assert.match(app,/戰鬥原型 版本 0\\.32\\.0/);
  assert.match(app,/IN_CITY:'城內'/);
  assert.match(app,/IN_WORLD:'城外'/);
  assert.match(app,/TRAVELING:'旅途中'/);
  assert.match(app,/買價 \\${m\\.buyPrice} · 庫存 \\${m\\.stock}/);
  assert.doesNotMatch(app,/Stock \\${m\\.stock}/);
  assert.doesNotMatch(app,/· v\\${m\\.version}/);
  assert.doesNotMatch(app,/由 Server 再檢查/);
  assert.doesNotMatch(app,/返回City Hub/);
});

test('P3-03 cargo shows Chinese good names while stable IDs stay internal',()=>{
  assert.match(app,/goodNameFor\\(x\\.goodTypeId\\)}/);
  assert.doesNotMatch(app,/<div>\\${x\\.goodTypeId} × \\${x\\.quantity}<\\/div>/);
});

test('P3-03 map/travel diagnostic labels shown to the player are Chinese',()=>{
  assert.match(map,/預計到埗/);
  assert.match(map,/返回城市中心/);
  for(const label of ['幀率','延遲','回應間隔','預測超前','請求中','限速','碰撞','暫停預測','狀態','錯誤','超前上限','凍結','本次凍結','累計凍結','凍結比例','修正量','強制重置']) assert.match(map,new RegExp(label));
  assert.doesNotMatch(map,/返回City Hub/);
  assert.doesNotMatch(map,/>ETA /);
});
`;
fs.writeFileSync('test/ui-chinese-cleanup.test.mjs', test);
