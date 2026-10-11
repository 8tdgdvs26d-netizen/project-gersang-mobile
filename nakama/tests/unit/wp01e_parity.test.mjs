// VS-01 WP01-E: the server copy of the combat EXP / Level rules reproduces the
// GDScript rules exactly (fixtures/wp01e_vectors.json is generated from
// godot/scripts by nakama/scripts/generate_wp01e_vectors.gd).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { loadModule } from "./harness.mjs";

const m = loadModule();
const v = JSON.parse(readFileSync(fileURLToPath(new URL("../fixtures/wp01e_vectors.json", import.meta.url)), "utf8"));

test("constants match CombatConfig / EncounterContext / WorldLayout / ProgressionState", () => {
  assert.equal(m.E_EXP_PER_KILL, v.exp_per_kill);
  assert.deepEqual(Object.keys(v.enemies_by_group_count).map(Number), [1, 2, 3]);
  for (const count of [1, 2, 3]) assert.equal(m.E_ENEMIES_BY_GROUP_COUNT[count], v.enemies_by_group_count[String(count)]);
  assert.deepEqual([...m.E_GROUP_IDS], v.group_ids);
  assert.equal(m.E_MAX_LEVEL, v.max_level);
  // R-4 / S3 cooldown is the approved 10 s; it equals the Prototype respawn.
  assert.equal(m.E_GROUP_COOLDOWN_MS, 10000);
  assert.equal(v.group_respawn_ms, 10000);
});

test("Level requirement matches ProgressionState.required_exp for every Level", () => {
  assert.equal(v.required_exp.length, 102);
  for (const [level, need] of v.required_exp) assert.equal(m.eRequiredExp(level), need, `level ${level}`);
});

test("EXP gain matches ProgressionState.advance (multi-Level, cap, carry)", () => {
  assert.ok(v.gain.length > 500);
  for (const [level, held, amount, level2, held2] of v.gain) {
    assert.deepEqual([...m.eGain(level, held, amount)], [level2, held2], `${level}/${held}+${amount}`);
    assert.ok(m.eIsValidLevelExp(level2, held2), `result ${level2}/${held2} is a valid Schema v1 pair`);
  }
});

test("Hero-only settlement matches PartyProgression.apply for every possible outcome", () => {
  assert.ok(v.settlement.length > 100);
  for (const [outcome, kills, alive, enemies, level, held, awarded, level2, held2] of v.settlement) {
    const exp = m.eClaimExp(outcome, kills, alive, enemies);
    assert.equal(exp, awarded, `${outcome} kills ${kills} alive ${alive} of ${enemies}`);
    assert.deepEqual([...m.eGain(level, held, exp)], [level2, held2]);
  }
});

test("combinations the battle rules cannot produce are refused", () => {
  for (const enemies of [10, 15, 20]) {
    assert.equal(m.eClaimExp("victory", enemies - 1, true, enemies), -1, "victory needs every enemy dead");
    assert.equal(m.eClaimExp("victory", enemies, false, enemies), -1, "victory with a dead Hero");
    assert.equal(m.eClaimExp("victory", enemies + 1, true, enemies), -1, "more kills than enemies");
    assert.equal(m.eClaimExp("retreat", enemies, true, enemies), -1, "retreat with no enemy left");
    assert.equal(m.eClaimExp("retreat", 3, false, enemies), -1, "retreat needs the Hero alive");
    assert.equal(m.eClaimExp("defeat", 3, true, enemies), -1, "defeat with the Hero alive");
    assert.equal(m.eClaimExp("defeat", enemies, false, enemies), -1, "defeat with every enemy dead");
  }
  assert.equal(m.eClaimExp("victory", -1, true, 10), -1);
  assert.equal(m.eClaimExp("victory", 10.5, true, 10), -1);
  assert.equal(m.eClaimExp("victory", 10, "true", 10), -1);
  assert.equal(m.eClaimExp("win", 10, true, 10), -1);
});

test("Schema v1 stores current-Level EXP: below the requirement at Lv1-99, 0 at Lv100", () => {
  assert.ok(m.eIsValidLevelExp(1, 0));
  assert.ok(m.eIsValidLevelExp(1, 99));
  assert.ok(!m.eIsValidLevelExp(1, 100));
  assert.ok(m.eIsValidLevelExp(99, 4999));
  assert.ok(!m.eIsValidLevelExp(99, 5000));
  assert.ok(m.eIsValidLevelExp(100, 0));
  assert.ok(!m.eIsValidLevelExp(100, 1));
  assert.ok(!m.eIsValidLevelExp(0, 0));
  assert.ok(!m.eIsValidLevelExp(101, 0));
  assert.ok(!m.eIsValidLevelExp(1, -1));
  assert.ok(!m.eIsValidLevelExp(1, 1.5));
});

test("encounter groups: 1-3 distinct known ids, enemy count from the server table", () => {
  assert.equal(m.eEnemyCount(["prototype_monster_01"]), 10);
  assert.equal(m.eEnemyCount(["prototype_monster_01", "prototype_monster_03"]), 15);
  assert.equal(m.eEnemyCount(["prototype_monster_01", "prototype_monster_02", "prototype_monster_03"]), 20);
  for (const bad of [[], ["x"], ["prototype_monster_01", "prototype_monster_01"], "prototype_monster_01", null,
    ["prototype_monster_01", "prototype_monster_02", "prototype_monster_03", "prototype_monster_01"], [1]]) {
    assert.equal(m.eEnemyCount(bad), 0, JSON.stringify(bad));
  }
});
