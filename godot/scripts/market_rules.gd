class_name MarketRules
extends RefCounted

## Prototype spread rules that turn a reference price into the prices players
## see. NPC sell price (player buys) = ceil(reference x 1.05); NPC buyback price
## (player sells) = floor(reference x 0.95). These are prototype parameters,
## not a formal balance. Integer maths is used on purpose: in floating point
## 80 x 1.05 is 84.00000000000001, which would wrongly round up to 85.

const BUY_PERCENT := 105
const BUYBACK_PERCENT := 95
## Smallest reference price whose buyback is still a positive integer.
const MIN_REFERENCE_PRICE := 2


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
