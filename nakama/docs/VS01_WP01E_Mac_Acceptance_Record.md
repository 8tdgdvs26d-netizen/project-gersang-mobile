# VS-01 WP01-E — Mac Player Acceptance: Record (2026-10-11)

**Result: PASS, confirmed by Charlie** (Charlie's own play on the Mac; Charlie
replied 「正常」 after re-login). The result is limited to the core flow below;
the items under "Not separately reported" were not stated individually.
This record does not close the VS-01 Gate.

> **Update (documentation-only corrective, 2026-10-13):** Session 1 below is kept
> as originally recorded. The two items it lists under "Not separately reported"
> were confirmed by Charlie in **Session 2** (section at the end). The
> `GODOT_LIVE_PROBE` reading in the Development Save incident section is
> superseded by the clarification added there. The historical Development Save
> write remains a **FAIL**.

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

*(Historical status of Session 1 only; both items below were confirmed by
Charlie in Session 2, 2026-10-12 HKT — see the Session 2 section.)*

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

### Clarification of the "Cause" bullet above (2026-10-13; the original text is kept)

- **Superseded reading:** the `GODOT_LIVE_PROBE PASS` text was **not** produced at
  ~13:25 on 2026-10-11. Godot copies the previous `godot.log` to
  `godot<start-time>.log` when a run starts, so `godot2026-10-11T21.25.40.log`
  holds the log of an *earlier* run (sometime after 2026-10-09 15:47 HKT) and only
  marks the start of a new run at 13:25:40Z. One run touched the save on
  2026-10-11: it printed `Myrial: Unwritten M2-09 passenger transport ready` and the
  save was re-created at 13:25:52Z as save version 14 (it had been version 8).
- **Observed, not established as cause or actor:** a Godot process (PID 61244)
  started 13:24:29Z with no arguments, parent launchd, normal HOME. Which project it
  ran, how it was started and by whom are **not determined**; that it produced the
  13:25:40Z run is an inference, not a proven fact.
- **Disposition (Charlie, 2026-10-12):** the unapproved Development Save write is
  recorded as a permanent **historical FAIL** (the original v8 bytes were not
  recovered; the cause and any v8 data loss remain unresolved). Charlie accepted the
  v14 file (SHA-256 `5707b3c9622f1e5ceebe35a6d989a4466dabbca8818a5ad83f6b7ac475e2a083`)
  as the new baseline; it is backed up and locked with `chflags uchg` (2026-10-11).
  This is not a retroactive PASS.

## Session 2 — isolated Mac acceptance of the two remaining items (2026-10-12 HKT)

One-time isolated session approved by Charlie; 2026-10-11 16:28–16:52 UTC
(2026-10-12 00:28–00:52 HKT). Code as committed at `a12e771` (no code change).

| Item | Charlie confirmed | Server record (account `combat-74b2291250bce3c5`, user `4963adf1-…`) |
|---|---|---|
| No EXP number on the result screen before the server confirmed | **「yes」**; screenshot of the victory screen (勝利, HP bars, 返回世界; no EXP) | first win: receipt 16:29:44Z, +100, Lv 1 → 2 |
| 「重新讀取」 leaves Level / EXP unchanged | **「係 無變」** at **Lv 3, 150 / 200** | Hero Lv 3, 150 / 200, revision 4; no receipt or Hero change after 16:33:34Z |

- Four separate receipts, **+100 EXP each** (16:29:44Z, 16:31:35Z, 16:32:00Z,
  16:33:34Z), Hero revisions 1–4, each battle settled once. A fast win showed
  「戰鬥結束得太快…稍後自動重新提交」 and was confirmed automatically later.
- Isolation: fresh isolated HOME (headless probe: `user_data_dir` in scratch,
  `user://myrial_save.json` missing); the real Development Save stayed locked
  (`uchg`) with SHA, size, mtime, atime, ctime and inode identical before (16:28Z)
  and after (16:52Z); 1,297 one-second samples showed no process holding a file in
  the real save folder. Sampling cannot exclude every transient access.
- Evidence: `WP01E_Mac_Acceptance_Session2.zip`, SHA-256
  `592c34fae921806fd43200b3b47095f380a0486a8188b6bad4fb31394c213115` (reviewed by
  GPT on 2026-10-12; the Mac copy in `~/Downloads` was no longer present on
  2026-10-13).
- **Result: Mac Session 2 PASS** for this limited isolated TEST flow. The VS-01 Gate
  and WP01-E formal delivery are **not** closed; iPhone / iPad / Playtest NOT TESTED.
