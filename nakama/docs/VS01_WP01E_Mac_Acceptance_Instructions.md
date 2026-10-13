# VS-01 WP01-E — Mac Player Acceptance: Instructions (for Charlie)

**Status: PREPARED, NOT PERFORMED.** Automated tests are **not** a substitute
for this hands-on check. The result is recorded separately, and only from
Charlie's own play and the server record.

## Before you start (Claude prepares everything)

- Claude starts the **disposable** test server (Docker project
  `myrial-vs01-wp01e`, its own database). It never uses the WP01–C database
  or the game's save.
- Claude opens the window with:

  ```
  COMPOSE_PROJECT_NAME=myrial-vs01-wp01e GODOT=/Applications/Godot.app/Contents/MacOS/Godot nakama/scripts/run_online_combat_ui.sh
  ```

  This runs Godot with a fresh, isolated `user://`, so your Development Save
  is not touched.
- **You only need to:** keep Docker Desktop open, play in the Godot window, and
  tell Claude what you see.

## Steps (about 5 minutes)

The blue panel is at the bottom of the window.

1. Press **「登入本機測試帳號」**. The email and password are filled in for you.
2. Press **「開始遊戲 Session」**.
   **Expect:** 「主角 Lv 1　經驗 0 / 100（伺服器確認）」.
3. Press **「戰鬥：敵群 1」**. A battle with the Hero alone against 10 enemies opens.
4. Fight and win. You can use the Gesture skill (⚡) to hit many enemies at once.
5. On the result screen, press **「返回世界」**.
   - **Expect** one of:
     - **(a) the win took under 10 seconds:** 「戰鬥結束得太快…稍後自動重新提交」. Wait about 10 seconds; it confirms by itself.
     - **(b)** 「伺服器已確認：經驗 +100（Lv 1 → Lv 2）」.
   - **Check:** the result screen showed **no EXP number** before the server
     confirmed it.
6. **Expect:** 「主角 Lv 2　經驗 0 / 150（伺服器確認）」.
7. Press **「戰鬥：敵群 2+3」** (15 enemies). Win, then press 「返回世界」.
   **Expect:** +150 EXP, which gives 「主角 Lv 3　經驗 0 / 200」.
8. Press **「重新讀取」**. The numbers stay the same.
9. Close the window. Ask Claude to open it again, sign in with the **same**
   account (Claude gives you the email and password), and press
   「開始遊戲 Session」.
   **Expect:** the same Level and EXP as before closing (read back from the
   server).

## Optional checks

| # | Check | What to do | Expect |
|---|---|---|---|
| A | Cooldown | Right after a win, press the same enemy group again | 「此敵群剛被擊敗，冷卻中…」 for about 10 s |
| B | Lost result | Close the window during 「戰鬥結束得太快…」 (before it confirms), reopen, sign in, start the session | Only the server Level / EXP; 「…只可按「放棄上一場」」; press 「放棄上一場」 then 「確認放棄」 to fight again |

## What to report to Claude

- Each step: what you saw (a screenshot if possible).
- Anything confusing, slow, or different from "Expect".
- Claude then checks the server record (receipts, Level / EXP) and writes the
  acceptance record as PASS, FAIL or PENDING, exactly as observed.
