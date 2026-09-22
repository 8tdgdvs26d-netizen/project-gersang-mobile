// Phase 4 (P4-02/P4-03A) world monster data contract — shared, DOM-free content module, mirroring
// the exact pattern already established by public/cities.js (frozen array + pure proximity
// primitive), so server.mjs (Node) and the browser client can import the same authoritative content
// and never drift. This is deliberately the smallest possible slice: just enough to detect proximity
// and hand off to the EXISTING battle layer via a fixed encounterId — no AI, no loot, no respawn, no
// scaling. See the approved P4-01/P4-03 Audits and P4-02/P4-03A Coding Orders for the full rationale
// and explicit non-goals.

export const WORLD_MONSTER_DEFINITIONS = Object.freeze([
  Object.freeze({
    id: 'world-bandit-1',
    displayName: '遊蕩山賊',
    level: 1,
    // Reuses the EXISTING server.mjs encounterDefinitions content — a world monster is a trigger
    // for a pre-existing battle template, not a second combat-content schema.
    encounterId: 'bandit-patrol',
    // P4-03A — deterministic two-point patrol, centered on the original P4-02 static spawn point
    // (500,220): midpoint((440,220),(560,220)) === (500,220). Horizontal, on the same y as the
    // original spot, so it stays exactly as far from every city entryRadius (all still comfortably
    // clear — see test/world-monster-patrol.test.mjs's P4-03A-C/D automated data-validation proof,
    // not eyeballed) and every OBSTACLES rect (both start at y=400, far below y=220) as the original
    // static position did. Widened from an initial 80px leg to 120px (P4-03A Review Fix round 1):
    // at the narrower width, the monster's own leftmost/rightmost reach (460/540) sat EXACTLY
    // encounterRadius (40px) away from the old static (500,220) reference point, which could not
    // reliably prove the encounter check had genuinely switched from a static to a dynamic center
    // (see test/world-monster-patrol.test.mjs's P4-03A-H for the differential proof this margin
    // exists to support). At 120px, patrolA/patrolB sit 60px from (500,220) — comfortably outside
    // the 40px radius with a real margin, not a coincidental boundary value.
    patrolA: Object.freeze({x: 440, y: 220}),
    patrolB: Object.freeze({x: 560, y: 220}),
    // px/ms. 120px leg / 0.02 = 6000ms one-way, 12000ms full A->B->A cycle — slow enough that
    // ordinary request/HTTP latency (single-digit to low-double-digit ms in this environment) only
    // ever moves the monster a fraction of a pixel between "read live position" and "act on it", so
    // tests that react to a freshly observed live position (see P4-03A-G) never need to guess or sleep.
    patrolSpeed: 0.02,
    // Fixed content constant, not a runtime timestamp — patrolPositionAt(monster, now) is then a pure
    // function of `now` alone with no other state, so it is exactly reproducible after any reload or
    // server restart with zero persistence (see P4-03 Audit §3).
    patrolAnchorAt: 0,
    encounterRadius: 40,
    active: true,
    // P4-03C — Aggro/Chase Prototype Parameters (see the approved P4-03C Audit/Design
    // Clarification/Coding Order — not Canonical balance numbers, subject to Playtest re-tuning).
    // aggroRadius(90) sits clearly outside encounterRadius(40) so a swept patrol/chase path always
    // has room to acquire aggro before it can possibly also satisfy the tighter encounter check in
    // the same sweep. chaseSpeed(0.08px/ms) is deliberately well under the player's own
    // MOVE_SPEED_RATE (JOYSTICK_STEP_DISTANCE/JOYSTICK_SEND_INTERVAL_MS = 18/140 ~= 0.1286px/ms, see
    // public/movement.js) — a chased player can always outrun the monster by actually moving away,
    // so reaching a city is a reward for successfully evading, not the only escape valve (see the
    // Final Design Clarification's Enter-City analysis). leashRadius(150) is measured from the fixed
    // patrolA/patrolB midpoint (the patrol route's own center), not from the monster's live chase
    // position — see chasePositionAt below and server.mjs's evaluateWorldMonsterAggroChase.
    aggroRadius: 90,
    chaseSpeed: 0.08,
    leashRadius: 150
  })
]);

// P4-03A — deterministic two-point ("triangle wave") patrol position at an arbitrary point in time.
// Pure: no Date.now() call, no DB access, no DOM, no mutable module state, no randomness — given the
// same (monster, timeMs) it always returns the same {x,y}, on both Node (server.mjs) and the browser
// (cosmetic rendering only, see public/app.js's tickMovementFrame — server authority is unaffected
// since the client only ever uses this for presentation, never to decide an encounter). Server.mjs
// is the only place this feeds into an actual game-logic decision (moveWorld()'s encounter check).
export function patrolPositionAt(monster, timeMs) {
  const { patrolA, patrolB, patrolSpeed, patrolAnchorAt } = monster || {};
  // Defensive fallback for a malformed/partial monster definition: stand still at patrolA (or, if
  // even that is missing, there is nothing sane to return). This should never trigger for any entry
  // in WORLD_MONSTER_DEFINITIONS itself — it only guards against future content mistakes.
  if (!patrolA || !Number.isFinite(patrolA.x) || !Number.isFinite(patrolA.y)) return null;
  if (!patrolB || !Number.isFinite(patrolB.x) || !Number.isFinite(patrolB.y)
    || !Number.isFinite(patrolSpeed) || patrolSpeed <= 0
    || !Number.isFinite(patrolAnchorAt) || !Number.isFinite(timeMs)) {
    return { x: patrolA.x, y: patrolA.y };
  }
  const dx = patrolB.x - patrolA.x, dy = patrolB.y - patrolA.y;
  const legDistance = Math.hypot(dx, dy);
  // Zero-length patrol (patrolA === patrolB): stationary at patrolA, not a division by zero.
  if (legDistance === 0) return { x: patrolA.x, y: patrolA.y };
  const legDurationMs = legDistance / patrolSpeed;
  const cycleDurationMs = legDurationMs * 2;
  // JavaScript's `%` can return a negative result for a negative dividend (timeMs before
  // patrolAnchorAt) — normalize into [0, cycleDurationMs) rather than let the triangle-wave math
  // below go negative.
  const rawPhase = (timeMs - patrolAnchorAt) % cycleDurationMs;
  const phase = rawPhase < 0 ? rawPhase + cycleDurationMs : rawPhase;
  // First half of the cycle: A -> B. Second half: B -> A (mirrored ratio).
  const t = phase <= legDurationMs ? phase / legDurationMs : 1 - (phase - legDurationMs) / legDurationMs;
  return { x: patrolA.x + dx * t, y: patrolA.y + dy * t };
}

// P4-03B — the actual piecewise-linear patrol path travelled during [fromTime, toTime], NOT a single
// straight line from patrolPositionAt(fromTime) to patrolPositionAt(toTime). A direct start->end
// segment is wrong whenever the interval crosses one or more patrol turnarounds (A or B): the
// triangle-wave position can legitimately end up back near where it started (see the worked example
// below), making the naive straight segment zero-length or otherwise miss the real path entirely,
// even though the monster genuinely swept through the player's position in between. Pure: no
// Date.now(), no DB, no DOM, no mutable state, no randomness — same purity contract as
// patrolPositionAt, which this function is built entirely out of.
//
// Worked example (current world-bandit-1 content): patrolA=440, patrolB=560, patrolAnchorAt=0,
// legDurationMs=6000 (120px leg / 0.02px/ms). fromTime=4500 (x=530, A->B leg), toTime=7500 (x=530
// again, now on the B->A leg, having turned around at B at t=6000):
//   patrolSegmentsBetween(monster,4500,7500) === [
//     {from:{x:530,y:220}, to:{x:560,y:220}},   // 4500 -> 6000 (A->B leg, up to the turnaround)
//     {from:{x:560,y:220}, to:{x:530,y:220}}    // 6000 -> 7500 (B->A leg, after the turnaround)
//   ]
// A direct 4500->7500 segment would be {from:{530,220},to:{530,220}} — zero-length, completely
// missing the real excursion out to B and back.
//
// Algorithm: turnarounds occur at every patrolAnchorAt + k*legDurationMs for integer k (both A and B
// are turnaround points, one legDurationMs apart — NOT one cycleDurationMs apart). Walk forward from
// the first such boundary strictly after `fromTime` (via Math.floor, correct for negative offsets
// too — mirrors patrolPositionAt's own negative-modulo handling) up to `toTime`, collecting every
// boundary timestamp in between; each consecutive pair of boundaries is then guaranteed to contain no
// turnaround, so patrolPositionAt at each boundary and a straight line between them is exact, not an
// approximation. Landing exactly on a turnaround at either end of the interval never produces a
// duplicate or a missing segment: the boundary loop starts strictly after `fromTime` (so a turnaround
// AT fromTime is only ever the interval's own start, never re-added), and the loop condition is a
// strict `<` against `toTime` (so a turnaround AT toTime is only ever the interval's own end, never
// re-added as an extra zero-length tail segment).
//
// Complexity: O(1 + floor((end-start)/legDurationMs)) segments, each one O(1) (a single
// patrolPositionAt call) — bounded linearly by how many turnarounds the interval spans, never
// unbounded/exponential. Callers are expected to additionally bound (end-start) itself via a lookback
// cap (see server.mjs's MAX_WORLD_EXPOSURE_LOOKBACK_MS) so this stays cheap even under a very stale
// watermark; this function itself is still safe (just proportionally more segments) if a caller ever
// omits that cap.
export function patrolSegmentsBetween(monster, fromTime, toTime) {
  const { patrolA, patrolB, patrolSpeed, patrolAnchorAt } = monster || {};
  if (!patrolA || !Number.isFinite(patrolA.x) || !Number.isFinite(patrolA.y)) return [];
  const fallbackPoint = { x: patrolA.x, y: patrolA.y };
  if (!patrolB || !Number.isFinite(patrolB.x) || !Number.isFinite(patrolB.y)
    || !Number.isFinite(patrolSpeed) || patrolSpeed <= 0
    || !Number.isFinite(patrolAnchorAt) || !Number.isFinite(fromTime) || !Number.isFinite(toTime)) {
    return [{ from: fallbackPoint, to: fallbackPoint }];
  }
  // Defensive: a caller-reversed (fromTime>toTime) interval still produces a valid piecewise path
  // for the normalized [start,end] range rather than crashing or silently returning nonsense.
  const start = Math.min(fromTime, toTime), end = Math.max(fromTime, toTime);
  const dx = patrolB.x - patrolA.x, dy = patrolB.y - patrolA.y;
  const legDistance = Math.hypot(dx, dy);
  // Zero-length interval, or a zero-length patrol route (patrolA===patrolB): nothing to sweep,
  // return a single degenerate point-segment — segmentEntersEncounterRadius already treats a
  // zero-length segment as a plain point-in-circle check, so callers need no special-casing.
  if (legDistance === 0 || start === end) {
    const p = patrolPositionAt(monster, start);
    return [{ from: p, to: p }];
  }
  const legDurationMs = legDistance / patrolSpeed;
  const firstK = Math.floor((start - patrolAnchorAt) / legDurationMs) + 1;
  const boundaries = [start];
  for (let k = firstK, t = patrolAnchorAt + k * legDurationMs; t < end; k++, t = patrolAnchorAt + k * legDurationMs) {
    boundaries.push(t);
  }
  boundaries.push(end);
  const segments = [];
  for (let i = 0; i < boundaries.length - 1; i++) {
    const t1 = boundaries[i], t2 = boundaries[i + 1];
    if (t2 === t1) continue;
    segments.push({ from: patrolPositionAt(monster, t1), to: patrolPositionAt(monster, t2) });
  }
  if (!segments.length) {
    const p = patrolPositionAt(monster, start);
    segments.push({ from: p, to: p });
  }
  return segments;
}

// P4-03C — CHASE position: pure anchor+speed advance toward `targetPos`, capped at reaching it
// exactly (never overshoots — the monster does not run past where the player was last seen). Same
// purity contract as patrolPositionAt/patrolSegmentsBetween (no Date.now(), no DB, no DOM, no
// mutable module state, no randomness): given the same (anchorPos, anchorAt, targetPos, chaseSpeed,
// timeMs) it always returns the same {x,y}, on both Node (server.mjs, the authoritative caller) and
// the browser (public/app.js's tickMovementFrame, cosmetic-only interpolation between polls — see
// its own comment for why the anchor triple must be transmitted, not just the live position, per the
// P4-03C Final Design Clarification's Authoritative Chase Sync analysis).
//
// Deliberately NOT built on patrolPositionAt's triangle-wave math — CHASE has a single, currently-
// live (anchorPos -> targetPos) leg, not a fixed, canonical two-point route ping-ponging forever, so
// there is no turnaround/cycle concept here at all, just a straight, distance-capped advance.
export function chasePositionAt(anchorPos, anchorAt, targetPos, chaseSpeed, timeMs) {
  if (!anchorPos || !Number.isFinite(anchorPos.x) || !Number.isFinite(anchorPos.y)) return null;
  if (!targetPos || !Number.isFinite(targetPos.x) || !Number.isFinite(targetPos.y)
    || !Number.isFinite(chaseSpeed) || chaseSpeed <= 0
    || !Number.isFinite(anchorAt) || !Number.isFinite(timeMs)) {
    return { x: anchorPos.x, y: anchorPos.y };
  }
  const dx = targetPos.x - anchorPos.x, dy = targetPos.y - anchorPos.y;
  const distance = Math.hypot(dx, dy);
  // Zero-distance target (monster already standing exactly where the player was last seen): stay
  // put, not a division by zero.
  if (distance === 0) return { x: anchorPos.x, y: anchorPos.y };
  // A `timeMs` before `anchorAt` (should never happen from a real caller, but defensive exactly like
  // patrolSegmentsBetween's own fromTime/toTime normalization) clamps to zero elapsed rather than
  // reversing direction past the anchor.
  const elapsedMs = Math.max(0, timeMs - anchorAt);
  const advance = Math.min(distance, chaseSpeed * elapsedMs);
  const ratio = advance / distance;
  return { x: anchorPos.x + dx * ratio, y: anchorPos.y + dy * ratio };
}

// Closest-point-on-segment-to-circle-center check (standard swept-circle test), NOT an endpoint-only
// distance check — a single movement step can legitimately go from outside the encounter radius,
// through it, and back outside within one accepted server displacement (tunnelling), so only
// checking the final position would let a player walk straight through a monster without ever
// triggering it. Deterministic, pure, no floating-point-order dependence beyond ordinary arithmetic.
export function segmentEntersEncounterRadius(fromPosition, toPosition, monster) {
  if (!fromPosition || !toPosition || !monster?.position || !Number.isFinite(monster.encounterRadius)) return false;
  const dx = toPosition.x - fromPosition.x, dy = toPosition.y - fromPosition.y;
  const lengthSquared = dx * dx + dy * dy;
  const cx = monster.position.x - fromPosition.x, cy = monster.position.y - fromPosition.y;
  // lengthSquared===0: no displacement at all — fall back to a plain point-in-circle check at
  // fromPosition (t would be undefined/NaN from a 0/0 division otherwise).
  const t = lengthSquared > 0 ? Math.max(0, Math.min(1, (cx * dx + cy * dy) / lengthSquared)) : 0;
  const closestX = fromPosition.x + t * dx, closestY = fromPosition.y + t * dy;
  const distance = Math.hypot(closestX - monster.position.x, closestY - monster.position.y);
  return distance <= monster.encounterRadius;
}
