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

## V32 — 2026-09-15 — World Map & City Hub Vertical Slice

- 分類：Hong Kong Four-Region World Map & City Entry Vertical Slice
- 起點：`main` @ `39577aa06b0a8db99d3687528f61019468adf487`(即V31 merge之後)
- `package.json` 版本：`0.31.0` → `0.32.0`；health `phase`：`P2 Multi-city Warehouse Overview` → `P3 World Map & City Hub Vertical Slice`
- 新增：
  - `public/worldmap.js`：World Map(港島／九龍／新界西／新界東)、City Hub畫面、pure functions（`computeTravelPosition`、`canEnterCityHub`、`cityHubEntries`、`chooseTravelAction`、`handleCityTap`、`leaveCityHub`）。
  - `test/worldmap.test.mjs`：16個新測試。
- 修改：
  - `server.mjs`：`cities`加`region`/`coordinates`/`facilities`/`theme`（`harbour-city`→港島、`hill-market`→新界東、`starter-village`→新界西，九龍暫時未開放）；新增`GET /api/roads`（read-only，直接讀現有`roads`表）；`snapshot()`嘅`activeTravel`加`segments`欄位（reuse現有`normalizedSegments()`）；health endpoint版本/phase更新。
  - `public/app.js`：World Map取代舊「旅行」頂層入口；市場／倉庫移入City Hub（render function原封不動，只改導航入口）；頂層nav改為地圖／貨艙／戰鬥／紀錄；重用現有`travel()`/`reroute()`/`arrival()`函數。
  - `public/styles.css`：地圖/區域/City Hub樣式。
  - `package.json`、`public/index.html`：版本號同步0.32.0。
  - `test/health.test.mjs`：更新version/phase斷言。
  - `FIRST_PLAYABLE_README.md`：新增v0.32.0段落，保留全部歷史記錄。
- **不涉及**：database schema、save format、Render設定、secrets、環境變數；現有`travel`/`reroute`/`resolve-arrival`後端邏輯及市場/倉庫業務邏輯完全冇改。
- 測試結果：44（現有，內容不變除health.test.mjs版本斷言）+ 16（新增）= 60 tests passed, 0 failed。
- 存檔影響：無。
- 已知問題：暫時只有3座示範城市；九龍未有城市；銀行/傭兵店/裝備店/工廠尚未開放。
- Rollback基準：`main` 起點 `879c1022c647efc8c6aeaf6d04b2961d8d841525` / `checkpoint/v30-pre-claude`；V31基準 `39577aa06b0a8db99d3687528f61019468adf487`。

## P1-01 — 2026-09-17 — 建立真正世界玩家實體

- 分類：《萬行誌：白手 — Canonical v0.5》Phase 1 第一個開發任務。
- 起點：`main` @ `77b77a24fe97488ba8ec3d6f5df731c2cca33c17`（即V32 merge之後，同時為Canonical v0.5 Re-baseline完成後嘅CP-001基準）。
- 目標：將玩家角色由「城市節點／旅行插值標記」升級為擁有獨立、可持久化世界座標嘅玩家實體，為後續自由移動奠定地基。今次不做手機移動控制、鏡頭、碰撞、道路導航、第4城、世界怪物、Encounter，亦不改經濟、戰鬥、裝備、成長數值、Render設定或引擎。
- Database schema（additive，已獲批准）：
  - `characters`表新增兩個nullable欄位 `world_x REAL`、`world_y REAL`（同現有`equipment_inventory`欄位遷移用返同一種guarded-ALTER手法）。
  - 新角色建立（`seed()`）時直接寫入初始世界座標；旅程到埗（自動解決及`/api/commands/travel/resolve-arrival`）時更新為目的地城市座標。
  - `snapshot()`只負責「讀」：如果`world_x`/`world_y`係NULL（例如較舊存檔），會喺回傳結果入面fallback去目前城市座標，但**唔會喺讀取時寫入資料庫**——已用專屬regression test證明呢一點。
  - 唔改任何現有欄位、唔刪資料、冇DB migration script需要另外執行。
- 修改：
  - `server.mjs`：`characters`表新增欄位；`cities`常數定義提前至`seed()`之前，供初始座標使用；`snapshot()`回傳新增`worldPosition`欄位；到埗時同步更新世界座標。
  - `public/worldmap.js`：新增pure function `resolveWorldPosition(snap,citiesById,roadsById,now)`——旅行中沿用現有`computeTravelPosition`插值，非旅行時讀`snap.worldPosition`（缺少時fallback去城市座標）；`renderWorldMapHtml()`改用呢個function決定hero marker位置。
  - `CLAUDE.md`：只更新第1節「文件讀取優先次序」，將《萬行誌：白手 — Canonical v0.5》列為唯一現行標準，v0.4 Handoff Pack／800 Questions標示為已被取代嘅歷史參考；其餘章節不變。
- **不涉及**：save format結構性改動、Render設定、secrets、環境變數、`public/app.js`、`roads`／`travel`表、路線／reroute邏輯、市場／倉庫／戰鬥／裝備／成長邏輯；`package.json`版本號、health `phase`、`public/index.html`今次不改動（留待較完整Phase 1里程碑再統一處理）。
- 測試結果：60（現有，內容不變）+ 6（新增）= 66 tests passed, 0 failed。
  - `test/worldmap.test.mjs` +3：`resolveWorldPosition`喺TRAVELING／非TRAVELING／worldPosition缺失三種情況嘅pure function測試。
  - `test/world-entity.test.mjs`（新檔）+3：snapshot()初始世界座標、travel完成後世界座標更新、舊存檔NULL欄位喺snapshot()自我修復但唔寫入資料庫。
- 存檔影響：Additive schema變更，舊存檔可直接讀取，冇資料流失或需要手動migration。
- 已知限制：現有城市（starter-village／harbour-city／hill-market）同Canonical v0.5 §8定義嘅四座城市（啟步城／躍動城／商業城／開拓城）身份唔一致；呢個差距今次冇處理，需要日後獨立批准先處理。
- Rollback基準：`main` 起點 `879c1022c647efc8c6aeaf6d04b2961d8d841525` / `checkpoint/v30-pre-claude`；V32基準 `77b77a24fe97488ba8ec3d6f5df731c2cca33c17`。
