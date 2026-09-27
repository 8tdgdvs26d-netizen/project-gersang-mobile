extends RefCounted

## Test-side reference model of the approved T04 prototype rule, written
## independently of MarketRecovery / MarketState: every 12 whole seconds of
## market time each stock moves one unit toward its target and stops there;
## at most 30 minutes of elapsed time count. Plain loops, one unit at a time.

const STEP_SECONDS := 12
const CAP_SECONDS := 1800


static func steps_for_ms(elapsed_ms: int) -> int:
	if elapsed_ms <= 0:
		return 0
	var seconds_counted: int = mini(elapsed_ms, CAP_SECONDS * 1000)
	var steps := 0
	while (steps + 1) * STEP_SECONDS * 1000 <= seconds_counted:
		steps += 1
	return steps


static func recovered_stock(stock: int, target: int, steps: int) -> int:
	for step in range(steps):
		if stock < target:
			stock += 1
		elif stock > target:
			stock -= 1
	return stock


## A copy of a market snapshot after `steps` recovery steps.
static func recovered_snapshot(snapshot: Dictionary, steps: int) -> Dictionary:
	var result := snapshot.duplicate(true)
	for city in result:
		for good_id in result[city]:
			var entry: Dictionary = result[city][good_id]
			entry["current_stock"] = recovered_stock(entry["current_stock"], entry["target_stock"], steps)
	return result
