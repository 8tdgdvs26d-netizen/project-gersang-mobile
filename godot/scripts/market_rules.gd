class_name MarketRules
extends RefCounted

## Prototype pricing rules. The single authoritative dynamic-price formula
## turns a good's baseline reference price and the city's current / target
## stock into a dynamic reference price; the spread then turns that into the
## prices players see. NPC sell price (player buys) = ceil(dynamic x 1.05); NPC
## buyback price (player sells) = floor(dynamic x 0.95). These are prototype
## parameters, not a formal balance. Integer maths is used on purpose: in
## floating point 80 x 1.05 is 84.00000000000001, which would wrongly round up
## to 85.

const BUY_PERCENT := 105
const BUYBACK_PERCENT := 95
## Smallest reference price whose buyback is still a positive integer.
const MIN_REFERENCE_PRICE := 2

## PROTOTYPE PARAMETERS (T03). Price moves opposite to stock: every 1% the
## stock is below / above target moves the price 0.5% up / down, i.e. every
## 10% stock deviation is about 5% price. With stock >= 0 the highest
## reachable price is +50% (stock 0); the 200% ceiling is a safety bound. The
## floor (50%) is reached at stock = 2 x target.
const PRICE_SENSITIVITY_PERCENT := 50
const DYNAMIC_FLOOR_PERCENT := 50
const DYNAMIC_CEILING_PERCENT := 200
## Stock / target ratios are measured in basis points (1/100 of a percent),
## capped where the price would already be at the floor.
const RATIO_CAP_BP := 30000


## Dynamic reference price for one city x good. Deterministic integer maths
## (no floating point, no overflow for any value MarketState accepts):
##   ratio_bp  = floor(stock / target, 4 decimals), capped at RATIO_CAP_BP
##   factor    = 1_000_000 + (10000 - ratio_bp) x PRICE_SENSITIVITY_PERCENT  (ppm)
##   raw       = round_half_up(baseline x factor / 1_000_000)
##   result    = clamp(raw, ceil(baseline x 50%), baseline x 200%), at least MIN_REFERENCE_PRICE
## At stock == target the result is exactly the baseline. Returns 0 for
## invalid input (baseline below MIN_REFERENCE_PRICE, stock < 0, target <= 0).
@warning_ignore("integer_division")
static func dynamic_reference(baseline_reference: int, current_stock: int, target_stock: int) -> int:
	if baseline_reference < MIN_REFERENCE_PRICE or current_stock < 0 or target_stock <= 0:
		return 0
	var ratio_bp := _ratio_bp(current_stock, target_stock)
	var factor_ppm := 1000000 + (10000 - ratio_bp) * PRICE_SENSITIVITY_PERCENT
	var raw := _scale_ppm(baseline_reference, maxi(factor_ppm, 0))
	return clamp_reference(baseline_reference, raw)


## Applies the floor / ceiling to a raw dynamic reference.
@warning_ignore("integer_division")
static func clamp_reference(baseline_reference: int, raw_reference: int) -> int:
	var floor_price := (baseline_reference * DYNAMIC_FLOOR_PERCENT + 99) / 100
	var ceiling_price := baseline_reference / 100 * DYNAMIC_CEILING_PERCENT + baseline_reference % 100 * DYNAMIC_CEILING_PERCENT / 100
	return maxi(clampi(raw_reference, floor_price, ceiling_price), MIN_REFERENCE_PRICE)


## floor(stock x 10000 / target) by long division, so stock x 10000 can
## never overflow; capped at RATIO_CAP_BP.
@warning_ignore("integer_division")
static func _ratio_bp(stock: int, target: int) -> int:
	var whole := stock / target
	if whole >= RATIO_CAP_BP / 10000:
		return RATIO_CAP_BP
	var remainder := stock % target
	var ratio := whole
	for digit in range(4):
		remainder *= 10
		ratio = ratio * 10 + remainder / target
		remainder %= target
	return mini(ratio, RATIO_CAP_BP)


## round_half_up(value x factor_ppm / 1_000_000) without overflowing: the
## value is split into millions and a remainder below one million.
@warning_ignore("integer_division")
static func _scale_ppm(value: int, factor_ppm: int) -> int:
	var millions := value / 1000000
	var rest := value % 1000000
	return millions * factor_ppm + (rest * factor_ppm + 500000) / 1000000


## Price a player pays to buy one unit, or 0 for an invalid reference.
@warning_ignore("integer_division")
static func buy_price(reference_price: int) -> int:
	if reference_price < MIN_REFERENCE_PRICE:
		return 0
	return (reference_price * BUY_PERCENT + 99) / 100


## Price a player receives for selling one unit, or 0 for an invalid reference.
@warning_ignore("integer_division")
static func buyback_price(reference_price: int) -> int:
	if reference_price < MIN_REFERENCE_PRICE:
		return 0
	return reference_price * BUYBACK_PERCENT / 100
