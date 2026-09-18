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
- **不涉及**：破壞性存檔格式改動；只涉及已批准的additive schema change：新增nullable `world_x`/`world_y`。亦不涉及：Render設定、secrets、環境變數、`public/app.js`、`roads`／`travel`表、路線／reroute邏輯、市場／倉庫／戰鬥／裝備／成長邏輯；`package.json`版本號、health `phase`、`public/index.html`今次不改動（留待較完整Phase 1里程碑再統一處理）。
- 測試結果：60（現有，內容不變）+ 6（新增）= 66 tests passed, 0 failed。
  - `test/worldmap.test.mjs` +3：`resolveWorldPosition`喺TRAVELING／非TRAVELING／worldPosition缺失三種情況嘅pure function測試。
  - `test/world-entity.test.mjs`（新檔）+3：snapshot()初始世界座標、travel完成後世界座標更新、舊存檔NULL欄位喺snapshot()自我修復但唔寫入資料庫。
- 存檔影響：Additive schema變更，舊存檔可直接讀取，冇資料流失或需要手動migration。
- 已知限制：現有城市（starter-village／harbour-city／hill-market）同Canonical v0.5 §8定義嘅四座城市（啟步城／躍動城／商業城／開拓城）身份唔一致；呢個差距今次冇處理，需要日後獨立批准先處理。
- Rollback基準：`main` 起點 `879c1022c647efc8c6aeaf6d04b2961d8d841525` / `checkpoint/v30-pre-claude`；V32基準 `77b77a24fe97488ba8ec3d6f5df731c2cca33c17`。

## P1-02 — 2026-09-17 — 自由世界移動控制 Prototype

- 分類：《萬行誌：白手 — Canonical v0.5》Phase 1 第二個開發任務。
- 起點：`main` @ `6d49c747bbefa8598c7580d233366154bb0844ea`（即P1-01 merge之後）。
- 目標：喺P1-01已建立嘅persisted `worldPosition`地基上，加入第一個真正可以自由改變世界座標嘅移動Prototype，證明玩家可以脫離城市節點思維喺世界空間移動。今次係Prototype，Joystick／tap-to-move／drag最終方案未鎖死。
- State machine（經Charlie批准）：
  - 新增`IN_WORLD`狀態。第一次移動成功時`IN_CITY`→`IN_WORLD`；`IN_WORLD`可以繼續合法移動；`TRAVELING`期間一律拒絕移動。
  - 今次唔做`IN_WORLD`→`IN_CITY`嘅正式城市入口邏輯，留待Phase 2「四城實體進出」處理。
  - 市場、倉庫、City Hub、戰鬥、旅行等現有`state==='IN_CITY'`嘅gate**一個字都冇改**——`IN_WORLD`落嚟自然唔再滿足呢啲gate，行為完全靠現有邏輯自然生效，唔係新增檢查。
  - 已知限制：玩家一離城後，Prototype暫時冇辦法用返市場／倉庫等城市功能（`ERR_INVALID_CONTEXT`／`ERR_PHYSICAL_PRESENCE_REQUIRED`），呢個係刻意延後嘅中間狀態，非bug。
- Server-authoritative movement command（經Charlie批准）：
  - 新增`POST /api/commands/world/move`，payload為Absolute Target Position `{targetX,targetY}`。
  - Server由自己持久化嘅`world_x/world_y`出發計算實際位移，clamp單次位移（`MAX_WORLD_STEP`=60，標示為「Movement Prototype Parameter」而非Balance Parameter）、再clamp入世界邊界`0..1000`（同`public/worldmap.js`個SVG viewBox一致，單一數據來源），先寫入資料庫並回傳server最終接受嘅真實座標；client唔可以直接決定最終位置。
  - 加入Prototype級最短command間隔（`MOVEMENT_MIN_INTERVAL_MS`=120ms，記憶體變數，冇新Database table）：太密嘅command會被接受但唔會產生額外位移，防止client狂send request變相加速。
- 修改：
  - `server.mjs`：新增`moveWorld(env)`command function同`/api/commands/world/move`路由；只用返P1-01已存在嘅`world_x`/`world_y`欄位，冇新增Database schema。
  - `public/app.js`：喺World Map嘅SVG加`pointerdown`/`pointermove`/`pointerup`事件（約150ms throttle），將螢幕座標轉做世界座標後call新command；response返嚟後直接patch `.hero-marker`位置（同現有`updateTravelProgress()`手法一致），手勢完結先做完整`render()`同步UI。城市節點嘅原有tap-to-travel行為透過判斷`pointerdown`目標係咪`.map-city`嚟保留，唔受影響。
  - `public/styles.css`：`.world-map`加`cursor:grab`視覺提示。
  - `test/world-movement.test.mjs`（新檔）：9個server端regression test，覆蓋合法移動、state轉換、anti-teleport clamp、世界邊界clamp、時間節流、TRAVELING拒絕、離城後城市功能被拒、reload/reconnect一致性、無效payload拒絕。
- **不涉及**：任何新Database schema／存檔格式；鏡頭跟隨、碰撞、道路導航、城市實體入口／離城觸發、第4座城市、世界怪物／Encounter、汽車交通改造、經濟／戰鬥／裝備／傭兵／成長、Render設定、引擎轉換、正式joystick UI、大型anti-cheat／rate-limit平台、server-side movement tick。
- 測試結果：66（現有，內容不變）+ 9（新增）= 75 tests passed, 0 failed。
- 存檔影響：無新schema；沿用P1-01嘅additive `world_x`/`world_y`。
- 已知風險：
  - 冇per-秒rate limit，只有per-command最短間隔，理論上狂send短command仍可以受網絡來回時間限制下加快移動——已披露，未解決，屬殘餘風險。
  - `pointermove`同`.map-scroll`原有嘅原生scroll手勢有冇衝突，未經真機測試驗證。
  - 離城後（`IN_WORLD`）暫時冇辦法用市場／倉庫／重新入城，屬已知、刻意延後嘅限制。
- Rollback基準：`main` 起點 `879c1022c647efc8c6aeaf6d04b2961d8d841525` / `checkpoint/v30-pre-claude`；P1-01基準 `6d49c747bbefa8598c7580d233366154bb0844ea`。

### P1-02 Review round 2（Client端修正，經Charlie批准）

- **手機pointer手勢同原生scroll衝突（round 2初版，已喺round 3修正時機問題，見下）**：`.world-map`嘅`touch-action`喺`pointerdown`確認非撳中城市節點之後先set做`none`並call`event.preventDefault()`，手勢完結reset返空字串。`.map-scroll`原有嘅`touch-action:pan-x pan-y`同`overflow:auto`完全冇改，冇郁camera、map scrolling、zoom，亦冇將今次Prototype手勢鎖死做正式規格。
- **Movement request race**：新增`public/asyncqueue.js`（新檔，`createCoalescingSender`，純函數、冇DOM／fetch依賴），確保同一時間只有一個`world/move` request在途；drag期間新出現嘅pointer位置會存做「最新pending target」，前一個request完成後先send返最新嗰個，中途過時嘅target會被丟棄，唔會再有「舊target回應遲到令位置跳返轉頭」嘅可能。`public/app.js`嘅`moveWorld()`改為透過呢個wrapper發送，`server.mjs`嘅movement protocol、state machine、Database schema**完全冇改**。
- 新增4個pure function test（`test/asyncqueue.test.mjs`，新檔）：單一call即時send、in-flight期間多個call被coalesce做一個用最新target嘅follow-up call、sender永遠唔會被同時call兩次（防race核心證明）、唔重疊嘅sequential call個別照送唔會被丟棄。
- 已披露、未能自動測試嘅部分：`touch-action`／`preventDefault`喺真實觸控手勢入面嘅實際效果（同`.map-scroll`原生scroll嘅交互）屬DOM/瀏覽器行為，呢個codebase一直冇用jsdom等工具測試呢類手勢層面代碼（同現有`setupBattlePan()`等一致），所以呢部分只可以喺真機／真瀏覽器測試驗證，未自動化。
- 測試結果：75（round 1，內容不變）+ 4（新增）= 79 tests passed, 0 failed。

### P1-02 Review round 3（修正touch-action時機，經Charlie批准）

- **問題**：round 2將`touch-action:none`喺`pointerdown`事件處理器入面先set，時機太遲——瀏覽器通常喺手勢一開始就已經根據當其時嘅`touch-action`決定會唔會接管做native pan/scroll，所以就算JS喺`pointerdown`入面立即set，個手勢仍然可能已經俾瀏覽器搶咗去做native scroll，或者觸發`pointercancel`。
- **修正**：`touch-action:none`改為直接寫喺`public/styles.css`嘅`.world-map`選擇器入面，變成手勢開始前已經存在嘅靜態樣式，唔再依賴JS喺`pointerdown`之後先設定。`public/app.js`移除咗`pointerdown`入面動態set`svg.style.touchAction='none'`同`pointerup`/`pointercancel`入面reset返空字串嗰兩行——唔再需要，因為CSS由頁面load開始已經套用。`event.preventDefault()`喺`pointerdown`／`pointermove`保留做多一層保險，冇移除。
- 接受嘅Prototype限制（經批准）：喺World Map SVG上拖動，由遊戲movement手勢優先接管；原生map pan今次唔係核心，正式camera／map navigation留待後續Phase 1任務處理。
- 冇新增camera、zoom、新gesture mode、joystick、overlay system或map navigation redesign。
- 修改：`public/styles.css`（`.world-map`加`touch-action:none`）、`public/app.js`（移除動態touch-action set/reset嗰兩行，其餘手勢邏輯、request coalescing完全不變）。
- 測試結果：79（round 2，內容不變）= 79 tests passed, 0 failed（呢次純CSS/JS timing修正，冇新增test，亦冇改任何現有test）。
