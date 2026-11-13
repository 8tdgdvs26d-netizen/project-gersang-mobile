# CLAUDE.md — 《萬行誌：白手》MYRIAL: UNWRITTEN 開發安全規則

呢份文件係 Claude（或任何接手嘅 AI）喺呢個 repository 工作時必須遵守嘅穩定工作規則。每次任務都要遵守。

## 1. Source of Truth 與必讀文件

開始規劃、Implementation、Review 或 Acceptance 前，必須按以下次序核實：

1. **Charlie 最新明確決定**。
2. **最新 `MYRIAL_AI工作入口_Current`**（Google Drive）：https://docs.google.com/document/d/12s-PfPCKXl0NF1FvVqKIcnJf_zHygrvRMMQs4On-XR0/edit 。先依入口讀取「文件位置索引」「項目現況與下一步」「操作限制」「文件與記錄執行指引」。
3. **當次工作直接相關的正式 Current Canonical、System、WP、決策及驗收規格**，只讀需要的部分；若互相衝突，STOP 交 Charlie。
4. **即時 GitHub、CI、Mac、iPhone／iPad及Playtest證據** — 用來確認實作、SHA、PR、Tests及Acceptance；不得用程式碼反過來推翻Gameplay Canonical。
5. **歷史追溯（非 Current Authority）**：舊 `00_CURRENT_PROJECT_SOURCES`、2026-10-08 Consolidated Canonical／Current Status／Project Instructions v4.x／Source Index、舊完整 Art Bible、Canonical v0.5、Prototype、V30 Handoff、Handoff Pack v0.4、800 Questions及Phaser/Web資料。只在必要追溯時讀相關部分，不得復活已取代決定。

設計真相與工程真相必須分開。Design approved不代表Implemented；Tests／CI PASS不代表Stage PASS或玩家體驗PASS。若Current Sources與工程證據衝突，立即STOP，列出衝突、影響及選項，交Charlie決定，禁止靜默覆蓋。

如必要文件無法存取，而且會影響正確判斷，必須停止並要求提供，不可憑記憶或猜測繼續。

## 2. Branch 與 Git 規則

- 禁止直接修改或commit到 `main`。
- 禁止修改或刪除任何 `checkpoint/*` 或 `backup/*` branch。
- 禁止force push或重寫history。
- 所有工作必須由已核實的最新 `main` exact SHA開新branch。
- Coding完成後只可開Pull Request；未獲Charlie明確Merge批准，禁止自行merge。

## 3. 雙重確認制

1. **Coding前** — 必須有已批准的Blueprint／執行計劃。
2. **Merge前** — 必須提交PR、diff、Tests／CI及風險證據，再取得Charlie明確批准。

Coding批准不等於Merge批准；GPT Accepted亦不等於Charlie已關閉Gate。

## 4. Roles 與 STOP Conditions

- Charlie：Project Owner；最終批准方向、Canonical、Scope、重大風險、玩家體驗、PR Merge及Stage／System Gate關閉。
- GPT：Brain／Gatekeeper；負責Blueprint、Scope、優先級、重大技術方案獨立Review、Acceptance、風險及下一步。
- Claude：Engineering Technical Advisor及主要工程執行者；只在Charlie批准Scope內進行Repo Preflight、Implementation、Bug Fix、Tests、Regression／Stress、PR及Evidence整理，並可獨立審查重大技術方案或提出NO-GO。同一工作的實作者不得自行充當獨立審查者。

遇到以下情況必須STOP：
- 新Gameplay／Canonical決定或衝突；
- Scope或Roadmap需要重大改變；
- 重大Architecture選擇；
- Save Schema／Migration修改；
- 降低Acceptance Standard；
- 跨System、高風險或影響Core Loop問題；
- 無法在批准Scope內安全解決的Blocker。

## 5. 測試與 Acceptance

- 預設：Relevant Tests + Full Normal Regression + Risk-based Stress。
- 新增或改變行為必須增加regression test。
- 不可刪除、削弱或繞過斷言來製造PASS。
- CI名稱必須精確：Node／npm CI不得稱為Godot CI。
- 狀態分開記錄：Designed、Implemented、Automated Tests Passed、CI Passed、GPT Accepted、Mac Accepted、iPhone Accepted、iPad Accepted、Playtested、Player Value Verified。
- Formal Gameplay Acceptance優先使用Clean Acceptance Workspace，並保護Development Save。

## 6. 未經批准禁止改動

- **預設READ ONLY**：工具具有讀寫能力不代表已獲授權；Google Drive之前的文件重整Editor授權已完結，任何新Drive寫入須Charlie就當次工作明確批准。
- **Repo／工程另批**：文件指引對齊、Blueprint審查或P0解除不等於已批准Coding、Godot／CI、Development Save、PR／Merge、部署或裝置測試；所有操作按最新「操作限制_Current」與當次工作授權執行。
- Canonical、Gameplay Rules、Scope或Acceptance Standard。
- Database／Save Schema或Migration。
- Gameplay邏輯、經濟、戰鬥、裝備、角色成長及數值。
- `main`、Git history、checkpoints、Development Save。
- Deploy設定、secrets、credentials或環境變數。

任何Secret、API secret key、Apple credential、password、private key、token或service-role credential都不可commit入repo。

## 7. Scope與Core Loop

每項近期工作都要回答：有冇令玩家更接近「入城準備 → 買貨 → 離城自由選路 → 遇敵 → 即時戰鬥 → 獎勵／成長 → 另一城賣貨 → 改善隊伍 → 再出發」？如沒有，除必要安全／工程blocker外，不應加入Current Scope。

「將來會用」「舊版已有」「AI寫得快」「順手做埋」都不是擴大Scope的理由。

## 8. 溝通方式

與Charlie以中文／廣東話溝通。技術名詞先用中文再寫英文；縮寫首次出現寫全稱。先解釋是甚麼、重要性、玩家影響、風險、選項及驗收，不假設Charlie熟悉程式。
