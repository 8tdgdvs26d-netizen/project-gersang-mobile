# VS-01 WP01 — Save v14 Migration Assessment (assessment only, D6)

Status: **ASSESSMENT ONLY**. Under D6 (Charlie, 2026-10-10) this WP changes no
Save schema, writes no migration, and converts no save. Every option below
needs a separate, approved migration plan before any implementation.

## 1. Current facts (verified 2026-10-10)

- `godot/scripts/save_store.gd`: `VERSION := 14`, reads v1–v14 and migrates
  older versions **in memory**. The file becomes v14 at the **next normal
  save** (for example v8 → v9 progression, v10 allocation, v11 roster, v12
  legacy Mercenary migration, v13 carrying, v14 condition).
- Protected Development Save: `user://myrial_save.json` in the normal Godot
  user data folder (`~/Library/Application Support/Godot/app_userdata/Myrial- Unwritten/`).
  It is **version 8**, 2052 bytes, last written 2026-09-28. SHA-256
  `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7`.
- **Risk found:** starting the game normally with that user data folder loads
  the v8 save, migrates it in memory, and **rewrites it as v14** at the next
  normal save. Any Mac playtest or acceptance run must therefore use an
  isolated `user://` (for example `HOME=$(mktemp -d)`, as
  `nakama/scripts/run_godot_regression_isolated.sh` does) or a verified copy.
  WP01 tests never touch the Development Save: its hash was checked before
  and after every run.

## 2. What the server holds now (WP01)

Server contract `myrial.vs01.wp01.trade_progress` v1: money, backpack goods,
the per-player Prototype market and recovery anchor, a representative Base
STR, gameplay session and revision. It covers only a small part of Save v14.
Save v14 also has location, warehouses, cost ledger, progression, allocation,
Mercenary roster, carrying / equipment, condition and pending legacy
Mercenaries.

## 3. Options for a later approved migration plan (no decision taken)

| Option | What happens | Main risk |
|---|---|---|
| A. Fresh server start | VS accounts start from server defaults. Local saves remain development assets only (A10). | Prototype progress is not carried over (it was never formal VS progress). |
| B. One-time, server-validated import | The client uploads a v14 save once, and the server validates every section with the same strict rules before accepting it. | Client-side saves can be edited, so import is a trust hole unless capped or limited to test accounts. Needs a full server port of the v14 validators. |
| C. Developer-only import tool | A local tool imports a chosen save into a test account for QA. | Must never ship. Needs its own access control. |

A10 already says the local Save v14 is a migration / development asset, not
formal server authority. Option B conflicts with A4 (server authority) unless
it is tightly bounded, so it would need GPT architecture review.

## 4. Preconditions for any migration WP

1. Approved option and scope (Charlie). Server contract versioning rules.
2. Verified backup of the Development Save (byte copy plus SHA-256) and a
   restore exercise before any test touches a copy.
3. Clean acceptance workspace with isolated `user://`.
4. Server-side validators with parity tests against `save_store.gd` (same
   approach as the WP01 trade golden vectors).
5. Rollback: the server contract version stays readable, and imports are
   reversible per account.
