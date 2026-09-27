extends RefCounted

## Test-side reference model of the approved T03 prototype rule, written
## independently of MarketRules (plain integer maths for small test values):
## every 10% stock deviation from target moves the price ~5% the other way,
## clamped to 50%..200% of the baseline, then the 105% / 95% spread.
## Older tests use it where prices now depend on stock.

const TARGET := 100


static func dynamic_reference(baseline: int, stock: int, target: int = TARGET) -> int:
	var ratio_bp: int = mini(stock * 10000 / target, 30000)
	var raw: int = (baseline * (1000000 + (10000 - ratio_bp) * 50) + 500000) / 1000000
	var low: int = (baseline * 50 + 99) / 100
	var high: int = baseline * 2
	return maxi(clampi(raw, low, high), 2)


static func buy(baseline: int, stock: int, target: int = TARGET) -> int:
	return (dynamic_reference(baseline, stock, target) * 105 + 99) / 100


static func buyback(baseline: int, stock: int, target: int = TARGET) -> int:
	return dynamic_reference(baseline, stock, target) * 95 / 100
