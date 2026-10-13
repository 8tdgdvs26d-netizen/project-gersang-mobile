// VS-01 WP01-E — server copy of the EXISTING Godot combat EXP / Level rules
// for the isolated Online TEST (Hero only, approved S4 / S7). Nothing here is a
// new gameplay rule: every value mirrors godot/scripts and is checked by golden
// vectors generated from GDScript (tests/fixtures/wp01e_vectors.json).
//
//   EXP per enemy killed        CombatConfig.EXP_PER_KILL
//   enemies per encounter       EncounterContext.PLANNED_COMBAT_ENEMIES (1..3 groups)
//   World Enemy Group ids       WorldLayout.PROTOTYPE_GROUPS
//   EXP sharing                 PartyProgression: pool / survivors (Hero only: 1)
//   Level curve                 ProgressionState: leaving L needs 100 + 50 x (L - 1),
//                               several Levels per award, cap Lv100 (no EXP kept)

const E_EXP_PER_KILL = 10;
const E_ENEMIES_BY_GROUP_COUNT: { [count: number]: number } = { 1: 10, 2: 15, 3: 20 };
const E_GROUP_IDS = ["prototype_monster_01", "prototype_monster_02", "prototype_monster_03"];
const E_MAX_GROUPS = 3;
const E_START_LEVEL = 1;
const E_MAX_LEVEL = 100;
const E_EXP_BASE = 100;
const E_EXP_STEP = 50;
const E_OUTCOMES = ["victory", "retreat", "defeat"];

// Approved S3 / R-1 / MC-1 timing (server clock only).
const E_MIN_CLAIM_AGE_MS = 10000;
const E_TICKET_TTL_MS = 900000;
// Approved R-4: same-group cooldown after a server-confirmed positive EXP award.
const E_GROUP_COOLDOWN_MS = 10000;

// EXP to leave `level` (0 at the cap), as ProgressionState.required_exp.
function eRequiredExp(level: number): number {
  if (level >= E_MAX_LEVEL) return 0;
  return E_EXP_BASE + E_EXP_STEP * (Math.max(level, E_START_LEVEL) - 1);
}

// [level, exp] after gaining `amount` at `level` holding `exp`, as
// ProgressionState._gain (amounts here are at most a few hundred, so the
// MAX_EXP clamp of the offline save never applies; Schema v1 stores the
// current-Level EXP: below the requirement at Lv1-99, 0 at Lv100).
function eGain(level: number, exp: number, amount: number): number[] {
  let held = exp + amount;
  let lv = level;
  while (lv < E_MAX_LEVEL && held >= eRequiredExp(lv)) {
    held -= eRequiredExp(lv);
    lv += 1;
  }
  if (lv >= E_MAX_LEVEL) held = 0;
  return [lv, held];
}

// A valid stored Hero progression pair.
function eIsValidLevelExp(level: any, exp: any): boolean {
  if (!rulesIsInt(level) || level < E_START_LEVEL || level > E_MAX_LEVEL) return false;
  if (!rulesIsInt(exp) || exp < 0) return false;
  return level === E_MAX_LEVEL ? exp === 0 : exp < eRequiredExp(level);
}

// The enemy count of an encounter of these groups, or 0 when the list is not
// 1..3 distinct known group ids.
function eEnemyCount(groupIds: any): number {
  if (Object.prototype.toString.call(groupIds) !== "[object Array]") return 0;
  if (groupIds.length < 1 || groupIds.length > E_MAX_GROUPS) return 0;
  const seen: { [id: string]: boolean } = {};
  for (let i = 0; i < groupIds.length; i++) {
    const id = groupIds[i];
    if (typeof id !== "string" || E_GROUP_IDS.indexOf(id) < 0 || seen[id]) return 0;
    seen[id] = true;
  }
  return E_ENEMIES_BY_GROUP_COUNT[groupIds.length] || 0;
}

// The EXP a Hero-only claim earns, or -1 when the combination cannot come
// from the existing battle rules (CombatBattle: VICTORY = every enemy dead;
// DEFEAT = every friendly unit dead; RETREAT = an alive unit escaped, so at
// least one enemy is left). M1: the server bounds the claim, it does not
// prove it (approved S2).
function eClaimExp(outcome: any, kills: any, heroAlive: any, enemyCount: number): number {
  if (E_OUTCOMES.indexOf(outcome) < 0 || typeof heroAlive !== "boolean" || !rulesIsInt(kills) || kills < 0) return -1;
  if (outcome === "victory") return heroAlive && kills === enemyCount ? kills * E_EXP_PER_KILL : -1;
  if (outcome === "retreat") return heroAlive && kills < enemyCount ? kills * E_EXP_PER_KILL : -1;
  // defeat: the Hero is dead, no EXP (PartyProgression: DEFEAT awards nothing)
  return !heroAlive && kills < enemyCount ? 0 : -1;
}
