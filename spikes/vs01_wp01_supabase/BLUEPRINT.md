# VS-01 WP01 Blueprint — Backend Provider & Authority Technical Spike

狀態：**補寫版（Retroactive write-up）— DRAFT，待 GPT Review 及 Charlie 確認**

- 補寫日期：2026-10-09
- 原始 Blueprint：Charlie 已於 2026-10-08 批准（見 `MYRIAL_Current_Project_Status_2026-10-08`），但原文喺 Google Drive 搵唔到。本文件按以下已核實來源重組，**唔係原文**；如原文日後尋回而內容有衝突，以原文及 Charlie 決定為準。
- 依據來源：`MYRIAL_Consolidated_Canonical_and_Vertical_Slice_Roadmap_2026-10-08_v1.0`（§14、§21、§22）、`MYRIAL_Current_Project_Status_2026-10-08`（A1–A14）、PR #131 及本目錄 `EVIDENCE.md`。
- Charlie 2026-10-09 決定：WP01 定位為**「後端技術可行性驗證 Gate」**。

## 1. Purpose（目的）

用一個可棄置（disposable）的 Supabase 項目，驗證 VS-01 已批准架構方向（A1–A14）嘅核心後端機制喺技術上可行，作為 A11「Provider 鎖定前必須做 Technical Spike」嘅證據：

- 正式帳號登入（A2）；
- Command-based Server Authority：Client 唔可以直接改進度（A4、A5）；
- 單一 Active Gameplay Session（A7）；
- 重複／重播保護、原子性 Money + Inventory 變更、審計紀錄（A14）；
- Godot 4.x Client 可以直接用 HTTPS 連接（A1、Godot 產品路線）。

## 2. Player Value（玩家價值）

WP01 本身**冇直接玩家可見功能**。佢嘅價值係保護將來嘅 Core Loop：

- 買貨、賣貨、戰鬥獎勵等進度由 Server 確認，唔會因斷線、重複撳、或者 Client 被改而重複發錢或者丟失；
- iPhone／iPad 同一帳號讀同一份進度（Canonical §14）嘅技術基礎；
- 及早發現 Provider 限制，避免 VS-02 經濟系統做到一半先要換後端。

## 3. Scope（範圍）

- 可棄置 Supabase schema：`spike_player_progress`、`spike_active_sessions`、`spike_command_receipts`、`spike_audit_log`，全部開 RLS；
- 兩個 `SECURITY DEFINER` RPC：開 session（lease）、執行測試 command（idempotent、原子、寫收據及審計）；
- Edge Function `command`：驗證 JWT，service-role key 只留喺 Server；
- 離線 Authority Model 及合約測試（Node）；
- Live Smoke、Live Stress、Godot Live Probe 執行器；
- 獨立 Godot HTTPS Client（`godot/spikes/`），**唔接入遊戲或 Save v14**；
- Evidence、已部署權限唯讀核對、Provider 比較（`PROVIDER_COMPARISON.md`）。

## 4. Not Doing（不做）

- 唔改 Gameplay、經濟、戰鬥、數值、Canonical；
- 唔改 Save v14、唔做 Migration、唔碰 Development Save；
- 唔建正式 Backend schema、正式帳號 UI、社交登入；
- 唔接入現有遊戲流程（`main.gd`、Domain Services）；
- 唔做共享市場、正式戰鬥驗證、正式 Reconnect 規則；
- 唔鎖定 Provider；
- 唔做 PlayFab／Firebase 實機 Spike（只做文件比較）；
- 唔改 `main`、唔 Merge PR #131。

## 5. Acceptance Criteria（驗收準則）及目前證據

| # | 準則 | 證據狀態（詳見 `EVIDENCE.md`） |
|---|---|---|
| AC1 | 玩家只可以讀自己嘅進度，唔可以直接寫 | PASS：Live Smoke「直接寫入被拒」；已部署權限核對 v3；跨帳號 `foreignRowsVisible=0` |
| AC2 | 進度只可以經 Server command 改變 | PASS：RPC 只有 service_role 可執行（v3）；Live Smoke |
| AC3 | 同一 command 重複送出只生效一次（包括並行） | PASS：Live Stress 並行重複 x20、回覆遺失重試 |
| AC4 | 多個唔同 command 並行冇遺失更新 | PASS：Live Stress 並行 x20 |
| AC5 | 被拒 command 唔改任何狀態 | PASS：Live Stress、離線模型 |
| AC6 | 單一 Active Session：搶佔被拒、Lease 過期後可以接手、舊 Session 失效 | PASS：Live Stress 兩次 run 合計 |
| AC7 | 跨帳號隔離 | PASS：`stress-1791532990918` |
| AC8 | Secret 唔入 Client、Repo、Log | PASS：合約測試；Godot client 只讀 publishable key |
| AC9 | Godot 4.x Client 可以登入、開 session、讀狀態、提交 idempotent command | PASS：Mac Godot Live Probe（`7b51b25`） |
| AC10 | 現有 Regression 無退步 | PASS：`npm test` 516/516、Godot 65/65 + 新增 9/9、Node/npm CI |
| AC11 | 有基本延遲數據 | 已收集：連續 30 次 p95 1529 ms（Mac → Supabase）；**未設合格門檻**，交 GPT 判斷 |
| AC12 | 有 Provider 比較作鎖定前參考 | 已提交 `PROVIDER_COMPARISON.md`（文件比較，唔係實機 Spike） |
| AC13 | iPhone／iPad 實機整合 | **DEFERRED（Charlie 批准延後，見 §10）** |
| AC14 | 玩家體驗驗收 | **DEFERRED（Charlie 批准延後，見 §10）** |

Live Smoke 同 Live Stress 係 Charlie 提供嘅 Mac 真實執行紀錄，冇完整原始日誌，Claude 冇獨立核實（見 `EVIDENCE.md` 來源說明）。

## 6. Required Acceptance Level（驗收等級）

- 必須：Automated Tests、Node/npm CI、Live（Mac → 可棄置 Supabase）、GPT Acceptance Review、Charlie Gate 決定。
- 延後（唔係豁免）：iPhone Accepted、iPad Accepted、Playtested、Player Value Verified。
- 狀態分開記錄：Designed ✅、Implemented（Spike）✅、Automated Tests Passed ✅、CI Passed ✅（Node/npm，唔係 Godot CI）、GPT Accepted ⏳、Mac Live ✅（Charlie 提供）、iPhone／iPad ⏸、Playtested ⏸、Player Value Verified ⏸。

## 7. Owner（負責人）

- Charlie：Gate 及 Merge 最終批准、延後決定、Provider 鎖定決定。
- GPT：Blueprint Review、Acceptance Review、風險判斷、下一步。
- Claude／Engineering：實作、測試、Evidence、文件；無權 Merge 或關 Gate。

## 8. Regression Requirements（回歸要求）

- 相關：`node --test test/vs01_supabase_spike.test.mjs`；`godot/tests/verify_vs01_spike_client.gd`。
- 完整一般回歸：`npm test`；Godot `godot/tests/run_tests.sh`。
- CI：Node/npm `test` job（**唔係 Godot CI**，repo 冇 Godot CI）。
- 改動 spike 程式後必須重跑相關測試；改動 SQL 後必須重跑已部署權限唯讀核對（v3）。

## 9. Known Risks（已知風險）

1. **service_role 多出權限**：Supabase 預設授權令 `service_role` 對 spike 表有 `MAINTAIN/TRUNCATE/REFERENCES/TRIGGER`。Charlie 已接受為 Spike 嘅已知平台差異；正式 schema 必須逐張表重新審核最小權限，唔可以沿用。
2. **Live 證據來源**：Live Smoke／Stress 冇完整原始日誌，執行 commit 未記錄（執行器由 `68d1470` 起冇改）。
3. **延遲**：p95 1529 ms 屬單次 Mac 網絡量度，未有門檻，亦未喺流動網絡量度。
4. **未驗證範圍**：真機、背景／前景切換、流動網絡斷線重連、Session 過期時嘅玩家 UX。
5. **Spike ≠ 正式架構**：測試 command 只係 `spike_item`；正式經濟、戰鬥結果驗證、市場 Aggregation 都未設計。
6. **原 Blueprint 原文缺失**：本文件屬補寫，可能同原文有出入。
7. **Provider 比較只係文件研究**：PlayFab／Firebase 冇實機驗證；成本需要以官方最新價格再核實。

## 10. Charlie 批准嘅延後項目（2026-10-09）

Charlie 已批准 WP01 以「後端技術可行性驗證 Gate」處理，並**延後**以下項目：

- iPhone／iPad 實機整合（登入、command、背景切換、斷線重連、狀態讀取）；
- 玩家體驗驗收。

**延後唔等於豁免。** 呢兩項嘅驗收責任保留，必須喺之後正式接入遊戲嘅 VS-01 Work Package（Account／Online Save／Session／Reconnect 實作）完成；最遲喺 VS-14 Real-device Candidate Acceptance 之前。屆時責任分工：Engineering 提供 build 及 Evidence，Charlie 做 iPhone／iPad 實機驗收，GPT 做 Acceptance Review。

## 11. Stress Level（壓力測試等級）

- Canonical §21：VS-01 = **Stress Full**；Canonical §22：只可以升級，唔可以自行降低。WP01 沿用 **Full**，唔降級。
- 已執行：離線模型（100 次重複、50 次連續、搶佔／過期）、Live 並行重複 x20、並行唯一 x20、連續 x30（延遲／錯誤）、回覆遺失重試、原子拒絕、Session 搶佔、Lease 過期接手、跨帳號隔離。
- 未執行：長時間 soak、多帳號同時大量並發、真機流動網絡。
- 以上已執行範圍是否足以滿足 WP01（可棄置 Spike）嘅「Full」要求，交 GPT 判斷；Claude 唔自行宣稱達標。

## 12. Gate 狀態

- WP01 Gate：**未關閉**。等候 GPT Acceptance Review 及 Charlie 決定。
- PR #131：Draft，**唔可以 Merge**，直至 Charlie 明確批准。
- Provider：**未鎖定**。
