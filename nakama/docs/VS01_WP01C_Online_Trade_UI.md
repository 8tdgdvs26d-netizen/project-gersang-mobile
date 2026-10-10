# VS-01 WP01-C — Online Trade UI Integration: Evidence

- Repository: `8tdgdvs26d-netizen/project-gersang-mobile`
- Branch: `claude/vs01-wp01c-online-trade-ui` (own worktree, from `main`)
- Base `main`: `335c584b2b815080ac2254f906b9c7ae6d6693dd` (PR #135 S01 merged)
- **Code under test:** `979016069befa8d12d97e493a403e9941ada97ea`. This is the
  PR #136 review-round-1 fix, on top of `2e66638` and `1855bea`. The commit
  after it changes only this document.
- Approval: Charlie approved the WP01-C Blueprint and the bounded
  implementation on 2026-10-10.
- Mac: Godot 4.7.2.stable, Node 24.21.0, Docker Desktop, Nakama 3.25.0,
  PostgreSQL 16 (local only). Recorded 2026-10-10.

## Preflight

| Item | Result |
|---|---|
| `main` | `335c584b2b815080ac2254f906b9c7ae6d6693dd`, clean tree |
| Open PRs | none |
| CI on `main` | Node/npm CI green (there is no Godot CI) |
| CP-008 | present in the Checkpoint Index; unchanged |
| Development Save SHA-256 | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` (as expected) |

## UI audit (before)

| Piece | Finding |
|---|---|
| `city_hub.gd` / `city_hub.tscn` | A pure view. It emits `buy_requested` / `sell_requested` / `leave_requested` and shows what it is given (`show_market`, `show_money`, `show_cargo_summary`, `show_trade_feedback`). It holds no trade rules and no save access. |
| `main.gd` | Connects those signals to the OFFLINE `TradeService` and writes the result through `SaveStore`. This is the only place the hub meets a trade service. |
| `OnlineTradeAdapter` / `OnlineProgressClient` | Present since WP01-B / S01. They are server-confirmed and monotonic, and keep pending orders in RAM only. No UI used them yet. |
| Online / offline separation | The contract isolation test forbids gameplay scripts from referencing the online layer. |

**Decision.** A separate **Online TEST mode** scene reuses the existing
`city_hub.tscn` unchanged, and a small controller connects the hub's signals
to `OnlineTradeAdapter` instead of `TradeService`. This is minimal: `main.gd`,
`main.tscn`, the offline `TradeService`, `SaveStore` and the save schema are
NOT touched, so online data cannot reach the offline save by construction.
The only change to a shared UI file is one additive method,
`CityHub.show_feedback_text()`. It shows a ready-made line for states that are
neither a success nor a rule failure, such as "not confirmed". No STOP
condition applies: no Canonical or gameplay rule changes, Session Policy A and
the backend contract are unchanged, there is no save schema change, and the
architecture is not altered.

## What was built

- **A. Isolated Online TEST mode:** `godot/scenes/online_trade_test_mode.tscn`.
  A banner reads 「ONLINE TEST 模式・本機測試伺服器 / 交易由伺服器確認；不會寫入本機遊戲存檔」.
  The mode is opened only by its own scene or launcher, not from the game.
- **B. Local test account sign-in:** an email and password are pre-filled with
  a random disposable `@myrial.test` account. The server is 127.0.0.1:17350
  (or `--online-host` / `--online-port`).
- **C. Session begin:** 「開始遊戲 Session」 calls `vs01_session_begin` through the
  adapter.
- **D. Existing market UI:** `test_good_01` shows server prices, stock and
  holdings in the normal market rows. Buy 1, Buy 10, Sell 1 and Sell 10 use
  the hub's own buttons. The other goods are shown disabled (no server data),
  and only the Market tab is visible. A / B city switch buttons are provided.
- **E. Server-confirmed state:** money, the cargo summary, holdings, prices and
  the trade feedback come only from the server receipt or a server read. A
  rule rejection by the server (e.g. 「金錢不足」) is shown with the hub's
  existing text. 「重新讀取」 performs a fresh server read.
- **F. Not-confirmed states:**
  - Lost answer → 「結果未確認（可能已成功或未成功），請重試核實」. The full
    status line explains that the screen still shows the last
    server-confirmed values and that the trade may or may not have
    happened. 「未確定交易：N 單」 is shown. 「重試未確定」 resends with
    the SAME idempotency key.
  - Superseded → 「已被其他裝置接管，交易未送出」. Trading is locked and
    「重新接管」 is offered.
  - Rate limited, stale and rejected states each have their own text.
  - No double submit: while an order is in flight every trade button is
    disabled, and a second tap is ignored.

## PR #136 review round 1 (fix `979016069befa8d12d97e493a403e9941ada97ea`)

1. **Uncertain ≠ not applied.** The earlier wording (「金錢及貨物未有更改」 /
   「未有更改」) could tell the player that a trade did not happen, when the
   server may have committed it before the answer was lost (the live test does
   exactly this). The new texts are:
   - status line: 「網絡中斷：未能確認交易結果。畫面仍顯示上次伺服器確認的數值；交易可能已成功或未成功，請按「重試未確定」以原指令重試／核實。」
   - market row: 「結果未確認（可能已成功或未成功），請重試核實」

   Neither implies a rollback or that server balances are unchanged. The UI
   test asserts both texts.
2. **Actions during an in-flight request / sign-out.** Before the fix:
   - Refresh, session begin, sign-in and city switch could overlap an awaited
     trade.
   - `sign_out()` cleared `_busy`. A continuation of the old trade could then
     unlock a newer order and write its old result onto the new view. In the
     shipped code the continuation usually never resumed, because the
     replaced adapter (RefCounted) was freed, but that protection was
     accidental.

   **Fix, in `online_trade_test_mode.gd` only:**
   - Every awaited action (sign-in, begin / reclaim, refresh, retry, trade)
     takes the same one-request lock.
   - Refresh, Begin, Sign-in, Retry and the city buttons are disabled while a
     request is in flight, and the functions refuse locally (`busy`), sending
     nothing.
   - Sign-out (also through 「離開城市」) stays available, and raises a view
     epoch. A request started under an older epoch finishes without touching
     the view and without releasing the lock.

   `OnlineProgressClient` and `OnlineTradeAdapter` are unchanged, so S01
   semantics are preserved; the client still marks such answers stale.

   **Deterministic test** (`verify_vs01_wp01c_online_trade_ui`, now 65
   checks):
   - With an order in flight, refresh, begin and city switch are refused and
     their buttons are locked.
   - Leave mid-order, then sign in with a second account and begin, then start
     a new order. The FIRST account's order then answers. The test holds the
     old adapter so this answer really arrives.
   - Result: the new order stays locked (no double submit). The new view shows
     no old feedback, status or values. The new order then confirms normally.
   - The same is checked for a refresh answered after sign-out.
   - On the previous controller, 10 of these checks FAIL; on the fix all pass.

## Changed files

| File | Change |
|---|---|
| `godot/scripts/online_trade_test_mode.gd` | new: controller (sign-in, session, trade, refresh, retry, reclaim, city switch, sign-out; status panel) |
| `godot/scenes/online_trade_test_mode.tscn` | new: controller + an instance of the existing `city_hub.tscn` |
| `godot/scripts/city_hub.gd` | +`show_feedback_text(text)` (additive, 7 lines) |
| `godot/tests/verify_vs01_wp01c_online_trade_ui.gd` | new: offline UI integration test (65 checks; part of the Godot regression) |
| `godot/tests/live_vs01_wp01c_online_trade_ui.gd` | new: live UI run against the local server (23 checks) |
| `godot/tests/verify_vs01_wp01_online_contract.gd` | the isolation exemption list includes `online_trade_test_mode.gd` (an online-layer file) |
| `nakama/scripts/run_live_tests.sh` | runs the live UI test (strict marker check) |
| `nakama/scripts/run_online_trade_ui.sh` | new: launcher for hands-on testing (local stack + isolated HOME) |
| `nakama/docs/VS01_WP01C_Online_Trade_UI.md` | this document |

No server, contract, save, `main.gd`, `main.tscn` or offline-service file
changed.

## Player steps (Mac, hands-on)

1. Start Docker Desktop.
2. From the repository root, run
   `GODOT=/Applications/Godot.app/Contents/MacOS/Godot nakama/scripts/run_online_trade_ui.sh`.
   This builds the server, starts the local stack, and opens the window with
   an isolated `user://`.
3. Click 「登入本機測試帳號」 (a disposable account is pre-filled).
4. Click 「開始遊戲 Session」. The A 城 market opens with 金錢 10000.
5. On 測試商品一, click 「買入 10」. Expect 「已買入 10 件測試商品一，支付 840」,
   金錢 9160 and 持有 10.
6. Click 「B 城」, then 「賣出 10」. Expect 「已賣出 10 件…收入 1140」, 金錢 10300
   and 持有 0.
7. Click 「重新讀取」. The values stay the same.
8. Optional checks:
   - Stop Docker during a trade: 「未能確認結果」 appears, with no success
     shown. Restart Docker, then click 「重試未確定」.
   - Sign in with the same account in a second window and begin a session
     there: the first window shows 「已被其他裝置接管」.
9. Click 「離開城市」 to sign out. Close the window. To stop the stack, run
   `docker compose -f nakama/docker-compose.yml stop` (never `down -v`).

## Screenshots

Captured on the final code with the real scene against the local server
(720x1280; not committed):

1. login
2. market at A, session begun
3. after Buy 10
4. after Sell 10 at B
5. network loss: not confirmed, 1 pending
6. after retry

## Test results (all with isolated `user://` and disposable local accounts)

Re-run in full on `979016069befa8d12d97e493a403e9941ada97ea` after the PR #136
review fix, with identical counts except the UI test (51 → 65 checks).

| Suite | Result |
|---|---|
| Node/npm (root, Node/npm CI scope, NOT Godot CI) | 508/508 |
| Nakama unit | 43/43 |
| Live stress | 14/14 |
| WP01 live probe | 47/47 |
| WP01-B online trade harness | 103/103 |
| **WP01-C live UI** (real scene, market buttons, local server) | **23/23** |
| Lossy proxy | 24 answers dropped, all resolved by retry with the same key |
| **Godot full regression** (isolated wrapper) | **69/69 PASS**, FAIL 0, 0 script / parse errors, wrapper exit 0 |
| ↳ `verify_vs01_wp01c_online_trade_ui` (UI integration) | 65 checks |
| ↳ `verify_s11_p00_core_loop_integration` (offline core loop) | 1854 checks |
| ↳ `verify_m2_09` (TimeSource rule) | 518 checks |

## Acceptance scenarios

| # | Scenario | Evidence |
|---|---|---|
| A | Buy OK | live UI: Buy 10 at A → 9160 / 10 from the receipt |
| B | Sell OK | live UI: Sell 10 at B → 10300 / 0 |
| C | Refresh consistent | live UI: after a fresh read the screen equals the server progress |
| D | Network loss: no false success | live UI via the lossy proxy: 「結果未確認（可能已成功或未成功）」; the screen keeps the last confirmed values; 1 pending. The server HAD committed, as the retry proves |
| E | Idempotency | live UI: retry returns the original receipt (replayed); goods +1 once; a second retry changes nothing; a fresh read confirms |
| F | Takeover blocks the old session | live UI: second client begins → the old device is blocked and shown 「已被其他裝置接管」; reclaim → trading works |
| G | Offline core loop unaffected | Godot full regression 69/69, including the core loop (1854 checks); `main.gd` and the save are untouched |
| H | Development Save unchanged | SHA below; each UI test also asserts it, and asserts that no save file is created |

## Development Save

| | SHA-256 | mtime | size | version |
|---|---|---|---|---|
| Before | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |
| After | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |

## Known risks / limits

- TEST mode only. It is opened by its own scene or launcher, not from the
  game menu.
- Local email test accounts only; Apple sign-in is out of scope.
- Pending orders are kept in RAM: killing the app loses the local "pending"
  note. The server stays correct; no persistence is in scope.
- The hub is scaled (0.84) to fit under the status panel. This is not a
  redesign.
- Only `test_good_01` trades online; the other goods and facilities are
  disabled in this mode.
- There is no Godot CI. The Godot results above are local runs, and CI PASS
  covers Node/npm only.
- **Mac hands-on acceptance: PENDING.** It is recorded separately; CI PASS is
  not gameplay acceptance.

## Rollback

Revert the PR's merge commit (`git revert -m 1 <merge>`). All files are new
except the following, which revert cleanly:

- the additive `show_feedback_text`;
- one line in the isolation exemption list;
- three lines in `run_live_tests.sh`.

There is no data migration and no server change, and the Development Save is
never touched.
