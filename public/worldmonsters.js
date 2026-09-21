// Phase 4 (P4-02) world monster data contract — shared, DOM-free content module, mirroring the
// exact pattern already established by public/cities.js (frozen array + pure proximity primitive),
// so server.mjs (Node) and the browser client can import the same authoritative content and never
// drift. This is deliberately the smallest possible slice: just enough to detect proximity and hand
// off to the EXISTING battle layer via a fixed encounterId — no AI, no loot, no respawn, no scaling.
// See the approved P4-01 Audit / P4-02 Coding Order for the full rationale and explicit non-goals.

export const WORLD_MONSTER_DEFINITIONS = Object.freeze([
  Object.freeze({
    id: 'world-bandit-1',
    displayName: '遊蕩山賊',
    level: 1,
    // Reuses the EXISTING server.mjs encounterDefinitions content — a world monster is a trigger
    // for a pre-existing battle template, not a second combat-content schema.
    encounterId: 'bandit-patrol',
    position: Object.freeze({x: 500, y: 220}),
    encounterRadius: 40,
    active: true
  })
]);

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
