# Current Project Status 更新草稿（DRAFT — 未套用）

日期：2026-10-09。狀態：**草稿，待 GPT Review 及 Charlie 批准後，由 Charlie 套用到 Google Drive 嘅 Current Project Status**。Claude 冇修改 Drive 文件。

## 已落後嘅內容

`MYRIAL_Current_Project_Status_2026-10-08`（最後修改 2026-10-08 14:31 UTC）仍然寫：

- 「Project is intentionally PAUSED … before Backend Technical Spike / VS-01 WP01」
- 「VS-01 WP01 implementation: NOT STARTED」
- 「Latest live main SHA … 3774aef…；CI evidence UNKNOWN」

以上同 PR #131 及 2026-10-09 工作事實唔一致，應標示為**落後（STALE）**。

## 建議替換內容

### Current pause point

VS-01 WP01（後端技術可行性驗證 Gate）：已批准的 Spike 核心 Live 檢查已取得 PASS 證據，**WP01 Gate 仍待正式驗收**（GPT Acceptance Review 及 Charlie Gate 決定）。WP01 Gate **未關閉**。下一個 Work Package 未開始。

### Product / Gate state（只列有變動項目）

- Backend Technical Spike / VS-01 WP01 Blueprint：APPROVED 2026-10-08；補寫版 `spikes/vs01_wp01_supabase/BLUEPRINT.md` 待 GPT Review（原文喺 Drive 搵唔到）。
- VS-01 WP01 定位：Charlie 2026-10-09 批准為「後端技術可行性驗證 Gate」。
- VS-01 WP01 implementation：IMPLEMENTED（可棄置 Spike），PR #131 Draft，未 Merge。
- Automated Tests：PASS（`npm test` 516/516；Godot 65/65 + `verify_vs01_spike_client` 9/9）。
- CI：Node/npm CI PASS（唔係 Godot CI）。
- Mac Live（Charlie 提供）：Live Smoke 4/4 PASS；Live Stress 兩次 run 合計 8/8 PASS；Godot Live Probe PASS。
- GPT Review（2026-10-09）：接受補寫 Blueprint 基本結構及現有 Live Smoke、Live Stress、Godot Live Probe 證據；WP01 Gate 正式驗收仍待完成。
- Stress：GPT 已對 WP01 可棄置技術 Spike 嘅現有 Stress Coverage **有條件接受**（2026-10-09）。呢個接受只限 WP01 Spike；**正式 VS-01 Full Stress 尚未通過**。長時間運行（soak）、多帳號並發、Reconnect、Mobile Lifecycle（背景／前景切換、流動網絡）仍須喺後續 VS-01 Work Package 驗證。
- 安全（A14）：Rate Limiting **未完成正式驗證**；唔可以宣稱整體安全要求已達標。
- 跨帳號隔離：只驗證 REST 讀取（`foreignRowsVisible=0`）同 command（`ERR_SESSION_STALE`）兩條路徑，唔代表所有跨帳號攻擊路徑已驗證。
- iPhone／iPad 實機整合：**DEFERRED（Charlie 2026-10-09 批准）**，驗收責任保留至之後正式接入遊戲嘅 VS-01 WP，最遲 VS-14 之前。
- 玩家體驗驗收：**DEFERRED（Charlie 2026-10-09 批准）**，責任同上。
- Backend provider：仍然**未鎖定**；Supabase 係唯一有實機證據嘅候選；比較見 `PROVIDER_COMPARISON.md`。

### Latest verified engineering baseline

- `main`：`3774aefacfb92736c63034c51565aa4e675d3aeb`（無變動）。
- WP01 branch：`claude/vs01-wp01-backend-spike`，最新 SHA 以 PR #131 為準，套用前必須重新核實 GitHub。
- Supabase 可棄置項目：`myrial-vs01-spike`（只供 Spike；唔係正式 Backend）。

### Known risks（新增）

- Supabase 預設授權令 `service_role` 多出 `MAINTAIN/TRUNCATE/REFERENCES/TRIGGER`；Spike 接受，正式 schema 必須重新審核最小權限。
- Live Smoke／Stress 冇完整原始日誌。
- 延遲 p95 1529 ms（Mac，單次量度），未設門檻。

### Resume instruction

等 GPT Acceptance Review 及 Charlie 決定：(1) 是否關閉 WP01 Gate；(2) 是否 Merge PR #131；(3) 是否鎖定 Provider 或者先做 PlayFab／Firebase Spike；(4) 下一個 VS-01 Work Package。
