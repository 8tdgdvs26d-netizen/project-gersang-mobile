import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const app=fs.readFileSync(new URL('../public/app.js',import.meta.url),'utf8');
const map=fs.readFileSync(new URL('../public/worldmap.js',import.meta.url),'utf8');

test('P3-03 player-facing market and state labels use Chinese instead of internal codes',()=>{
  assert.ok(app.includes('戰鬥原型 版本 0.32.0'));
  assert.ok(app.includes("IN_CITY:'城內'"));
  assert.ok(app.includes("IN_WORLD:'城外'"));
  assert.ok(app.includes("TRAVELING:'旅途中'"));
  assert.ok(app.includes('買價 ${m.buyPrice} · 庫存 ${m.stock}'));
  assert.ok(!app.includes('Stock ${m.stock}'));
  assert.ok(!app.includes('· v${m.version}'));
  assert.ok(!app.includes('由 Server 再檢查'));
  assert.ok(!app.includes('返回City Hub'));
});

test('P3-03 cargo shows Chinese good names while stable IDs stay internal',()=>{
  assert.ok(app.includes('goodNameFor(x.goodTypeId)'));
  assert.ok(!app.includes('<div>${x.goodTypeId} × ${x.quantity}</div>'));
});

test('P3-03 map/travel diagnostic labels shown to the player are Chinese',()=>{
  assert.ok(map.includes('預計到埗'));
  assert.ok(map.includes('返回城市中心'));
  for(const label of ['幀率','延遲','回應間隔','預測超前','請求中','限速','碰撞','暫停預測','狀態','錯誤','超前上限','凍結','本次凍結','累計凍結','凍結比例','修正量','強制重置']) assert.ok(map.includes(label));
  assert.ok(!map.includes('返回City Hub'));
  assert.ok(!map.includes('>ETA '));
});
