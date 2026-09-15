# CHANGELOG — 巨商 / MYRIAL: UNWRITTEN

## V30 — 2026-09-15 — Claude接手前安全基準

- Commit SHA（完整）：`879c1022c647efc8c6aeaf6d04b2961d8d841525`
- 保護分支：`checkpoint/v30-pre-claude`（指向同一commit，不可改動或刪除）
- `package.json` 版本：`0.30.0`
- 測試結果：43 tests passed, 0 failed
- 存檔影響：無（此為Claude接手前唯一可還原嘅V30程式基準）
- Rollback基準：`879c1022c647efc8c6aeaf6d04b2961d8d841525` / `checkpoint/v30-pre-claude`

## V31 — 2026-09-15 — Development Safety Foundation

- 分類：開發安全基建（Development Safety Infrastructure）
- 起點：`main` @ `879c1022c647efc8c6aeaf6d04b2961d8d841525`
- `package.json` 版本：`0.30.0` → `0.31.0`
- 改動內容：
  - 新增 `CLAUDE.md`：規定文件讀取優先次序、Git安全規則、雙重確認制（Coding前批准計劃、Merge前批准成果）、範圍控制。
  - 新增 `CHANGELOG.md`（本檔）。
  - 新增 `.github/workflows/test.yml`：PR及push到main時自動執行 `npm test`（Node.js 22，`permissions: contents: read`，不使用secrets，不部署Render，不寫入repository）。
  - 新增 `test/health.test.mjs`：獨立regression test，確認 `/api/health` 回應 `ok:true`、`version:'0.31.0'`、`phase:'P2 Multi-city Warehouse Overview'`。
  - 修正 `FIRST_PLAYABLE_README.md` 過時版本標示（原顯示 `v0.5.2`），保留原有版本歷史段落，新增「Current V30 capabilities」摘要。
  - 版本文字統一更新為 `0.31.0`（`package.json`、`public/index.html`、`public/app.js`、`server.mjs` health endpoint 的 `version` 欄位）。
  - `server.mjs` health endpoint 的 `phase` 欄位原文保留：`P2 Multi-city Warehouse Overview`。
- **不涉及**：戰鬥邏輯、經濟／市場／城市／旅程／貨倉邏輯、裝備／背包／戰利品／角色成長邏輯、database schema、存檔格式、Render設定、secrets、環境變數。
- 測試結果：43（現有，內容不變）+ 1（新增health test）= 44 tests passed, 0 failed。
- 存檔影響：無。
- 已知問題：暫無。
- Rollback基準：`main` 起點 `879c1022c647efc8c6aeaf6d04b2961d8d841525` / `checkpoint/v30-pre-claude`。
