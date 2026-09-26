class_name MarketPrices
extends RefCounted

## Prototype market baseline for the two active cities: the reference price of
## every good plus the starting and target stock. MarketState copies these into
## the runtime market; MarketRules turns a reference price into buy and buyback
## prices. All values are TEST VALUES, not a formal economy balance.

const INITIAL_STOCK := 100
const TARGET_STOCK := 100

const PRICES := {
	"A": {
		"test_good_01": 80,
		"test_good_02": 180,
		"test_good_03": 420,
		"test_good_04": 900,
		"test_good_05": 2100,
		"test_good_06": 3600,
	},
	"B": {
		"test_good_01": 120,
		"test_good_02": 300,
		"test_good_03": 650,
		"test_good_04": 1250,
		"test_good_05": 1700,
		"test_good_06": 4300,
	},
}


static func has_price(city_id: Variant, good_id: Variant) -> bool:
	return get_price(city_id, good_id) > 0


## Returns the baseline reference price, or 0 for unknown or reserved cities,
## unknown goods and missing or invalid entries.
static func get_price(city_id: Variant, good_id: Variant) -> int:
	if typeof(city_id) != TYPE_STRING or not city_id in WorldLayout.ACTIVE_CITY_IDS:
		return 0
	if not GoodsCatalog.has_good(good_id):
		return 0
	var price: Variant = PRICES.get(city_id, {}).get(good_id)
	if typeof(price) != TYPE_INT or price <= 0:
		return 0
	return price
