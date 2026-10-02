class_name GestureMatcher
extends RefCounted

## Combat C07: the Prototype Lightning (⚡) matcher. Deterministic geometry
## only (no handwriting recognition): the same stroke always gets the same
## 0-100 Match Score.
##
## Points are in the drawing area's own units: (0, 0) top-left, (1, 1)
## bottom-right of the square area that shows the guide.
##
##   1. a stroke shorter than MIN_LENGTH_RATIO of the guide (or with fewer
##      than 2 points) scores 0 (incomplete)
##   2. the stroke and the guide are both resampled to SAMPLES points evenly
##      spaced along their paths; d = the mean distance between the i-th
##      points (order matters: route, direction, position and deviation all
##      show in d; a reversed stroke lands far from the guide)
##   3. shape = 100 while d <= PERFECT_DEVIATION, then minus
##      POINTS_PER_DEVIATION per unit of extra deviation (0.01 = 5 points)
##   4. coverage = the share of the guide's resampled points within
##      COVERAGE_RADIUS of the stroke (completion)
##   5. score = floor(shape x coverage); if the stroke misses either key turn
##      (within TURN_RADIUS) it is capped at MISSED_TURN_CAP (a Fail)
## Grades: exactly 100 Perfect, 80-99 Success, 60-79 Partial, below 60 Fail.

enum Grade { PERFECT, SUCCESS, PARTIAL, FAIL }

## The guide: top-right -> middle-left -> middle-right -> bottom-left.
const GUIDE: Array[Vector2] = [Vector2(0.65, 0.08), Vector2(0.30, 0.50), Vector2(0.68, 0.50), Vector2(0.35, 0.92)]
## The guide's two key turns.
const TURNS: Array[Vector2] = [Vector2(0.30, 0.50), Vector2(0.68, 0.50)]
const SAMPLES := 32
const MIN_LENGTH_RATIO := 0.3
const PERFECT_DEVIATION := 0.04
const POINTS_PER_DEVIATION := 500.0
const COVERAGE_RADIUS := 0.08
const TURN_RADIUS := 0.10
const MISSED_TURN_CAP := 59
const SUCCESS_SCORE := 80
const PARTIAL_SCORE := 60
## A stroke shorter than this (or a single point) is not submitted at all
## (an accidental touch): the window stays open.
const MIN_SUBMIT_LENGTH := 0.05


static func score(stroke: PackedVector2Array) -> int:
	var guide := PackedVector2Array(GUIDE)
	if stroke.size() < 2 or path_length(stroke) < MIN_LENGTH_RATIO * path_length(guide):
		return 0
	var drawn := resample(stroke, SAMPLES)
	var target := resample(guide, SAMPLES)
	var deviation := 0.0
	for index in range(SAMPLES):
		deviation += drawn[index].distance_to(target[index])
	deviation /= SAMPLES
	var shape := clampf(100.0 - maxf(deviation - PERFECT_DEVIATION, 0.0) * POINTS_PER_DEVIATION, 0.0, 100.0)
	var covered := 0
	for point in target:
		if distance_to_path(point, stroke) <= COVERAGE_RADIUS:
			covered += 1
	var result := floori(shape * covered / SAMPLES)
	for turn in TURNS:
		if distance_to_path(turn, stroke) > TURN_RADIUS:
			result = mini(result, MISSED_TURN_CAP)
	return clampi(result, 0, 100)


static func grade_for(match_score: int) -> Grade:
	if match_score >= 100:
		return Grade.PERFECT
	if match_score >= SUCCESS_SCORE:
		return Grade.SUCCESS
	if match_score >= PARTIAL_SCORE:
		return Grade.PARTIAL
	return Grade.FAIL


## Whether a finished stroke counts as an attempt (not an accidental touch).
static func is_submittable(stroke: PackedVector2Array) -> bool:
	return stroke.size() >= 2 and path_length(stroke) >= MIN_SUBMIT_LENGTH


static func path_length(points: PackedVector2Array) -> float:
	var total := 0.0
	for index in range(1, points.size()):
		total += points[index - 1].distance_to(points[index])
	return total


## `count` points evenly spaced along the path (first and last included).
static func resample(points: PackedVector2Array, count: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	var total := path_length(points)
	if total <= 0.0:
		for index in range(count):
			result.append(points[0])
		return result
	var step := total / (count - 1)
	var segment := 1
	var walked := 0.0
	for index in range(count):
		var wanted := minf(step * index, total)
		while segment < points.size() - 1 and walked + points[segment - 1].distance_to(points[segment]) < wanted:
			walked += points[segment - 1].distance_to(points[segment])
			segment += 1
		var length := points[segment - 1].distance_to(points[segment])
		var t := 0.0 if length <= 0.0 else clampf((wanted - walked) / length, 0.0, 1.0)
		result.append(points[segment - 1].lerp(points[segment], t))
	return result


static func distance_to_path(point: Vector2, path: PackedVector2Array) -> float:
	if path.size() == 1:
		return point.distance_to(path[0])
	var best := INF
	for index in range(1, path.size()):
		var closest := Geometry2D.get_closest_point_to_segment(point, path[index - 1], path[index])
		best = minf(best, point.distance_to(closest))
	return best
