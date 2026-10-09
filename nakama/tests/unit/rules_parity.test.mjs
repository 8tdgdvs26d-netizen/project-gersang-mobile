// The TypeScript port must reproduce the GDScript rules exactly
// (fixtures/rules_vectors.json is generated from godot/scripts).
import test from "node:test";
import assert from "node:assert/strict";
import { loadModule, fixtures } from "./harness.mjs";

const m = loadModule();

test("dynamic reference price matches MarketRules.dynamic_reference", () => {
  assert.ok(fixtures.dynamic_reference.length > 1000);
  for (const [baseline, stock, target, expected] of fixtures.dynamic_reference) {
    assert.equal(m.rulesDynamicReference(baseline, stock, target), expected, `${baseline}/${stock}/${target}`);
  }
});

test("buy / buyback spread matches MarketRules", () => {
  for (const [reference, buy, buyback] of fixtures.spread) {
    assert.equal(m.rulesBuyPrice(reference), buy, `buy ${reference}`);
    assert.equal(m.rulesBuybackPrice(reference), buyback, `buyback ${reference}`);
  }
});

test("recovery steps match MarketRecovery.steps_for", () => {
  for (const [elapsed, steps] of fixtures.recovery_steps) {
    assert.equal(m.rulesRecoverySteps(elapsed), steps, `elapsed ${elapsed}`);
  }
});

test("recovery advance matches MarketRecovery.advance on a drained market", () => {
  const p = m.progressCreateDefault();
  p.market.A.test_good_01.current_stock -= 60;
  p.market.B.test_good_06.current_stock += 40;
  for (const row of fixtures.recovery_advance) {
    const steps = m.progressAdvanceRecovery(p, row.now_ms);
    assert.equal(steps, row.steps, `steps at ${row.now_ms}`);
    assert.equal(p.market_recovery_anchor_ms, row.anchor_ms, `anchor at ${row.now_ms}`);
    assert.equal(p.market.A.test_good_01.current_stock, row.stock_A_01);
    assert.equal(p.market.B.test_good_06.current_stock, row.stock_B_06);
  }
});

test("trade sequence matches TradeService.buy / sell order for order", () => {
  const p = m.progressCreateDefault();
  assert.equal(p.money, fixtures.starting_money);
  assert.equal(m.rulesMaxCapacity(p.character.strength), fixtures.capacity_default);
  for (const [i, row] of fixtures.trade_sequence.entries()) {
    const d = m.tradeDecide(p, { action: row.action, city_id: row.city_id, good_id: row.good_id, quantity: row.quantity });
    const label = `#${i} ${row.action} ${row.city_id} ${row.good_id} x${row.quantity}`;
    assert.equal(d.status === "applied", row.success, `${label} success`);
    assert.equal(d.reason, row.reason, `${label} reason`);
    assert.equal(d.total, row.total, `${label} total`);
    assert.equal(d.unit_price, row.unit_price, `${label} unit price`);
    assert.equal(p.money, row.money_after, `${label} money`);
    assert.equal(p.backpack[row.good_id] || 0, row.carried_after, `${label} carried`);
    assert.equal(m.progressUsedCapacity(p), row.used_capacity_after, `${label} capacity`);
    if (row.stock_after >= 0) assert.equal(p.market[row.city_id][row.good_id].current_stock, row.stock_after, `${label} stock`);
  }
});

test("market stock limit matches TradeService (insufficient_market_stock)", () => {
  const p = m.progressCreateDefault();
  p.market.A.test_good_02.current_stock -= 95;
  assert.ok(fixtures.trade_sequence_low_stock.some((r) => r.reason === "insufficient_market_stock"));
  for (const [i, row] of fixtures.trade_sequence_low_stock.entries()) {
    const d = m.tradeDecide(p, { action: "buy", city_id: "A", good_id: "test_good_02", quantity: row.quantity });
    assert.equal(d.status === "applied", row.success, `#${i} success`);
    assert.equal(d.reason, row.reason, `#${i} reason`);
    assert.equal(d.total, row.total, `#${i} total`);
    assert.equal(p.money, row.money_after, `#${i} money`);
    assert.equal(p.market.A.test_good_02.current_stock, row.stock_after, `#${i} stock`);
  }
});

test("integer division stays exact near 2^53", () => {
  const big = 9007199254740991;
  assert.equal(m.rulesDiv(big, 1), big);
  assert.equal(m.rulesDiv(big, 10), 900719925474099);
  assert.equal(m.rulesDiv(big - 1, 3), 3002399751580330);
});
