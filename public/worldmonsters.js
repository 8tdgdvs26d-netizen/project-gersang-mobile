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
    // (500,220): midpoint((460,220),(540,220)) === (500,220). Horizontal, on the same y as the
    // original spot, so it stays exactly as far from every city entryRadius (all >=240px away) and
    // every OBSTACLES rect (both start at y=400, i.e. 180px further down) as the original static
    // position did — see test/world-monster-patrol.test.mjs for the automated data-validation proof
    // (P4-03A-C/D), not eyeballed. 80px leg at a slow, deliberately unhurried patrol pace.
    patrolA: Object.freeze({x: 460, y: 220}),
    patrolB: Object.freeze({x: 540, y: 220}),
    // px/ms. 80px leg / 0.02 = 4000ms one-way, 8000ms full A->B->A cycle — slow enough that ordinary
    // request/HTTP latency (single-digit to low-double-digit ms in this environment) only ever moves
    // the monster a fraction of a pixel between "read live position" and "act on it", so tests that
    // react to a freshly observed live position (see P4-03A-G/H) never need to guess or sleep.
    patrolSpeed: 0.02,
    // Fixed content constant, not a runtime timestamp — patrolPositionAt(monster, now) is then a pure
    // function of `now` alone with no other state, so it is exactly reproducible after any reload or
    // server restart with zero persistence (see P4-03 Audit §3).
    patrolAnchorAt: 0,
    encounterRadius: 40,
    active: true
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
