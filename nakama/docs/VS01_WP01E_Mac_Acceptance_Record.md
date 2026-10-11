# VS-01 WP01-E — Mac Player Acceptance: Record (2026-10-11)

**Result: PASS, confirmed by Charlie** (Charlie's own play on the Mac; Charlie
replied 「正常」 after re-login). The result is limited to the core flow below;
the items under "Not separately reported" were not stated individually.
This record does not close the VS-01 Gate.

## Environment

- Branch `claude/vs01-wp01e-combat-exp`, code as committed at `d62ce8f` / `d613ce9`
  (no code change during the session).
- Disposable Docker project `myrial-vs01-wp01e`, node 1 only (`127.0.0.1:17350`).
- Godot 4.7.2, `res://scenes/online_combat_test_mode.tscn`, every window with the
  same isolated HOME `/var/folders/bb/…/T/tmp.Mobdr2xxAv` (isolated `user://`;
  no save file was created there).
- Windows opened by Claude: 1 (launcher script, 13:15Z), 2 (13:27Z), 3 (13:31Z),
  4 (14:17Z), 5 (14:18Z), 6 (14:21Z, re-login).

## Acceptance run (account `charlie-wp01e-mac@myrial.test`, user `3023d9f5-…-061a5e287105`)

Charlie typed the email and a test password of their own choosing (not shared
with Claude).

| Step | Charlie observed (screenshots 3, 4) | Server record |
|---|---|---|
| Sign in, start session | Lv 1 (window 5) | account created; WP01 session begun |
| Battle: groups 2+3 (15) | — | 14:21:02Z receipt applied: +150, Lv 1 → 2 (50 / 150), rev 1, ticket CLAIMED |
| Battle: group 1 (10) | 「伺服器已確認：經驗 +100（Lv 2 → Lv 3）」 | 14:21:16Z receipt applied (after `too_early`, MC-1 intent DECIDED): +100, Lv 2 → 3 (0 / 200), rev 2 |
| Before closing | 「主角 Lv 3　經驗 0 / 200（伺服器確認）」 | Hero Lv 3, 0 / 200, revision 2; 2 receipts; 2 tickets CLAIMED |
| Close (⌘Q), reopen (window 6), sign in with the same email and password, start session | 「主角 Lv 3　經驗 0 / 200（伺服器確認）」, 「遊戲 Session：已開始」; Charlie: 「正常」 | 14:22:11Z new `session_begin` for the same user (previous session superseded); Hero unchanged (Lv 3, 0 / 200, revision 2); no new receipt |

EXP / Level persisted across closing and re-login; each battle was settled
exactly once (receipts = Hero revisions = 2).

## Earlier attempts in the same session (kept as evidence)

| Account | Play | Server | Outcome |
|---|---|---|---|
| `combat-b4d8a9e2de99d82b` (window 1) | 3 wins | +100, +100, +150 → Lv 3, 100 / 200, rev 3 | re-login impossible: the random pre-filled password was not known |
| `combat-dc065ed625e2b7f4` (window 2) | 3 wins | +150, +100, +100 → Lv 3, 100 / 200, rev 3 | same |
| `combat-efa3ada91b5313dd` (window 3) | 2 wins; screenshot 1 = Lv 3, 0 / 200 | +150, +100 → Lv 3, 0 / 200, rev 2 | same |
| `combat-2e68e3ae5d2c2c85` (window 4) | screenshot 2 = Lv 1 | new account, no battle | the pre-filled random email was used, so a NEW account was created (expected server behaviour) |

In every account the receipts, tickets and Hero revision agree (no duplicate
or lost EXP).

## Charlie's findings (UX; no code changed; for GPT / Charlie to decide)

1. **No sign-out button** in the TEST panel (sign-out exists only for tests).
   Closing the window (⌘Q) was used instead.
2. **The login form pre-fills a new random email and password every time**, and
   signing in creates the account silently. Re-login needs the tester to type
   and keep their own credentials; otherwise a new Lv 1 account appears.

## Not separately reported by Charlie

- Whether the result screen showed no EXP number before the server confirmed it.
- 「重新讀取」 leaving the numbers unchanged.
- Optional checks A (cooldown) and B (lost result).

## Development Save incident (not caused by the TEST windows; under investigation)

- `myrial_save.json` (real `user://`) was `59fcf77a…5531f7` (mtime 1790568901, 2052 B)
  at 13:10Z and 13:15Z; at **13:25:52Z** it became `5707b3c9…e2a083`
  (mtime 1791725152, 2826 B), unchanged since (14:22Z).
- Cause: a Godot process PID 61244 started 13:24:29Z by launchd with **no
  arguments and the normal HOME** (Project Manager / editor), which ran a
  project twice at ~13:25: logs `GODOT_LIVE_PROBE PASS` (code only in the old
  `myrial-wp01-acceptance` worktree) and then the normal game
  (`M2-09 passenger transport ready`), which writes the Development Save.
- Every Claude launch used the isolated HOME (commands logged; window 5 verified
  `HOME=/var/folders/…/tmp.Mobdr2xxAv`). Charlie: 「應該唔係」 (probably not
  opened by Charlie). The launcher of PID 61244 is not determined.
- Nothing was restored or deleted; copies of the changed save and the two logs
  are in the evidence package. No backup with SHA `59fcf77a…` was found in
  `~/Downloads` / `~/Documents`. Restoring is for Charlie / GPT to decide.
