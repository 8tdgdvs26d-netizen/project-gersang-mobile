class_name MarketRecovery
extends RefCounted

## Market recovery / restock (T04): the single authoritative implementation.
## Every STEP_MS of market time, each city x good stock moves STOCK_PER_STEP
## unit toward its target stock and stops exactly at the target. Only stock
## changes; the dynamic price follows from stock through MarketRules.
##
## The market keeps its own timeline, anchored at `anchor_ms` (the market time
## up to which recovery has been applied). Advancing moves the anchor forward
## by whole steps only, so the remainder of a partial step is kept, whether the
## game ran live, skipped frames or was closed. Player trades never touch the
## anchor. The caller passes the current time (from TimeSource); this script
## never reads a clock itself.

## PROTOTYPE PARAMETERS — not formal balance values.
const STEP_MS := 12000
const STOCK_PER_STEP := 1
## At most this much elapsed market time is counted at once (30 minutes);
## anything longer is ignored.
const MAX_ELAPSED_MS := 1800000
## No anchor yet (new session, a pre-T04 save or an invalid saved value).
const UNSET := -1
## Largest anchor that still round-trips exactly through the JSON save.
const MAX_ANCHOR_MS := 9007199254740992
const SAVED_KEYS := ["anchor_ms"]

var anchor_ms := UNSET


func is_anchored() -> bool:
	return anchor_ms != UNSET


func to_dict() -> Dictionary:
	return {"anchor_ms": anchor_ms}


## Rebuilds from saved data. Anything missing or malformed gives an unanchored
## recovery (it is anchored at the next advance without any recovery), so a
## bad timestamp can never create, remove or reverse stock.
static func from_dict(data: Variant) -> MarketRecovery:
	var recovery := MarketRecovery.new()
	if typeof(data) == TYPE_DICTIONARY and data.size() == SAVED_KEYS.size() and data.has("anchor_ms"):
		recovery.anchor_ms = _valid_anchor(data["anchor_ms"])
	return recovery


## Whole recovery steps in `elapsed_ms` of market time (0 for a negative or
## non-integer interval), counting at most MAX_ELAPSED_MS.
static func steps_for(elapsed_ms: Variant) -> int:
	if typeof(elapsed_ms) != TYPE_INT or elapsed_ms <= 0:
		return 0
	return mini(elapsed_ms, MAX_ELAPSED_MS) / STEP_MS


## Applies all recovery due between the anchor and `now_ms` to `market`.
## An unanchored or future anchor (clock moved back) is set to now and applies
## nothing. Returns {"steps": whole steps applied, "changed": stock changed}.
func advance(market: MarketState, now_ms: Variant) -> Dictionary:
	if market == null or typeof(now_ms) != TYPE_INT or now_ms < 0 or now_ms > MAX_ANCHOR_MS:
		return {"steps": 0, "changed": false}
	if not is_anchored() or anchor_ms > now_ms:
		anchor_ms = now_ms
		return {"steps": 0, "changed": false}
	var elapsed: int = now_ms - anchor_ms
	if elapsed > MAX_ELAPSED_MS:
		# Time beyond the cap is dropped; the kept window starts at now - cap.
		anchor_ms = now_ms - MAX_ELAPSED_MS
		elapsed = MAX_ELAPSED_MS
	var steps := steps_for(elapsed)
	if steps == 0:
		return {"steps": 0, "changed": false}
	anchor_ms += steps * STEP_MS
	return {"steps": steps, "changed": market.recover_toward_target(steps * STOCK_PER_STEP)}


static func _valid_anchor(value: Variant) -> int:
	if typeof(value) == TYPE_INT and value >= 0 and value <= MAX_ANCHOR_MS:
		return value
	if typeof(value) == TYPE_FLOAT and is_finite(value) and value == floorf(value) \
		and value >= 0.0 and value <= float(MAX_ANCHOR_MS):
		return int(value)
	return UNSET
