// VS-01 WP01 — the representative buy / sell command, decided on the server.
//
// tradeDecide mirrors TradeService.buy / TradeService.sell (godot/scripts/
// trade_service.gd) check for check and in the same order, without the
// optional cost ledger. It mutates only the progress copy it is given, and
// only when the order is accepted, so a rejection changes nothing.

interface TradeRequest {
  action: string; // "buy" | "sell"
  city_id: string;
  good_id: string;
  quantity: number;
}

interface TradeDecision {
  status: string; // "applied" | "rejected"
  reason: string; // "" when applied; TradeService reason otherwise
  unit_price: number;
  total: number;
}

function tradeReject(reason: string, total: number): TradeDecision {
  return { status: "rejected", reason: reason, unit_price: 0, total: total };
}

function tradeDecide(p: TradeProgress, req: TradeRequest): TradeDecision {
  if (req.action === "buy") return tradeDecideBuy(p, req);
  if (req.action === "sell") return tradeDecideSell(p, req);
  return tradeReject("invalid_action", 0);
}

function tradeDecideBuy(p: TradeProgress, req: TradeRequest): TradeDecision {
  const quote = progressQuote(p, req.city_id, req.good_id);
  if (quote === null || quote.buy_price <= 0) return tradeReject("invalid_city_or_good", 0);
  const qty = req.quantity;
  if (!rulesIsAllowedQuantity(qty)) return tradeReject("invalid_quantity", 0);
  if (qty > quote.stock) return tradeReject("insufficient_market_stock", 0);
  // CharacterInventory.can_add
  const cost = rulesCapacityCost(req.good_id);
  const used = progressUsedCapacity(p);
  const max = rulesMaxCapacity(p.character.strength);
  if (cost <= 0 || used > max || qty > rulesDiv(max - used, cost)) return tradeReject("insufficient_cargo_space", 0);
  const unit = quote.buy_price; // locked for the whole order
  if (qty > rulesDiv(RULES_MAX_SAFE, unit)) return tradeReject("invalid_quantity", 0);
  const total = unit * qty;
  if (total > p.money) return tradeReject("insufficient_money", total);
  p.money -= total;
  p.backpack[req.good_id] = (p.backpack[req.good_id] || 0) + qty;
  p.market[req.city_id][req.good_id].current_stock -= qty;
  return { status: "applied", reason: "", unit_price: unit, total: total };
}

function tradeDecideSell(p: TradeProgress, req: TradeRequest): TradeDecision {
  const quote = progressQuote(p, req.city_id, req.good_id);
  if (quote === null || quote.buyback_price <= 0) return tradeReject("invalid_city_or_good", 0);
  const qty = req.quantity;
  if (!rulesIsAllowedQuantity(qty)) return tradeReject("invalid_quantity", 0);
  const carried = p.backpack[req.good_id] || 0;
  if (qty > carried) return tradeReject("insufficient_cargo", 0);
  const unit = quote.buyback_price; // locked for the whole order
  if (qty > rulesDiv(RULES_MAX_SAFE, unit)) return tradeReject("invalid_quantity", 0);
  const total = unit * qty;
  if (qty > RULES_MAX_SAFE - quote.stock || total > RULES_MAX_SAFE - p.money) return tradeReject("invalid_state", total);
  p.money += total;
  if (carried === qty) delete p.backpack[req.good_id];
  else p.backpack[req.good_id] = carried - qty;
  p.market[req.city_id][req.good_id].current_stock += qty;
  return { status: "applied", reason: "", unit_price: unit, total: total };
}
