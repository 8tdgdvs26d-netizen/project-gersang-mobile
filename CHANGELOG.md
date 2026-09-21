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

## P1-03 — 2026-09-18 — Camera Follow 鏡頭跟隨 Prototype

- 分類：《萬行誌：白手 — Canonical v0.5》Phase 1 第三個開發任務。
- 起點：`main` @ `988addcd498158f4a75d988c49717231d6255fae`（即P1-02 merge之後）。
- 目標：喺P1-02自由世界移動之上，加入最小、可靠嘅Camera Follow Prototype，令玩家移動時畫面合理跟住角色，唔再依賴整張固定世界地圖視角。鏡頭純屬client presentation層，唔改任何server-authoritative位置、`IN_WORLD` state machine或movement protocol。
- 技術方案（經Charlie批准）：Dynamic SVG `viewBox`（唔用`<g transform>`）——World Map嘅`<svg>`根元素`viewBox`屬性由固定字串`"0 0 1000 1000"`改為每次由玩家目前位置即場計算。世界內容（城市、道路、hero marker）繼續用返世界座標畫，一個字都冇改；淨係「畫面顯示緊邊部分」會變。呢個做法令現有`svgPointFromEvent()`（P1-02移動輸入嘅螢幕座標→世界座標轉換）自動繼續正確運作，唔使額外改動。
- Camera Prototype Parameters（非正式規格，只供Prototype試玩）：
  - World bounds暫定`0..1000`——**Server（`server.mjs`嘅`WORLD_BOUNDS`）同Client（`public/worldmap.js`嘅`WORLD_BOUNDS`）各自保存相同數值，需要人手保持同步，並非真正single source of truth**（兩者係獨立JS運行環境，冇辦法直接share一個常數；今次冇建立新shared config架構）。
  - Camera viewport暫定`400×400`世界單位（`CAMERA_VIEWPORT_SIZE`），正方形，同`.world-map`固定正方形render box配合。
  - Clamp保證鏡頭視窗永遠喺世界邊界之內（`camX>=0`、`camY>=0`、`camX+width<=1000`、`camY+height<=1000`），唔會顯示世界外空白。
- Camera update節奏：唔新增任何新polling loop或animation engine，直接搭現有3個已經會更新hero marker位置嘅位置——`renderWorldMapHtml()`本身（tab切換／refresh／手勢完結）、`updateTravelProgress()`嘅250ms旅行插值、`sendWorldMove`嘅accepted movement response callback。三處都reuse同一個exported helper（`computeCameraViewBox`+`viewBoxAttr`），冇喺唔同地方各自複製clamp公式。
- Reload/reconnect：鏡頭純粹由`state.snap.worldPosition`即場計算，唔係獨立persist嘅狀態，reload後第一次render自動重建正確鏡頭，唔需要額外邏輯。
- Mobile viewport最小修正（經Charlie批准）：`.world-map`由固定`width:760px;height:760px`（大過螢幕、要靠`.map-scroll`原生scroll先睇晒）改為`width:100%;height:auto;aspect-ratio:1/1`，令個SVG自動填滿實際可見container闊度並保持正方形，等鏡頭中心同玩家喺螢幕上實際見到嘅中心一致。`.shell`／`.card`／`.map-scroll`／HUD／nav／導航完全冇改，冇重做layout。
- 修改：
  - `public/worldmap.js`：新增exported `WORLD_BOUNDS`、`CAMERA_VIEWPORT_SIZE`常數、`computeCameraViewBox(position,viewportSize,bounds)`、`viewBoxAttr(box)`兩個pure function；`renderWorldMapHtml()`嘅`<svg viewBox="...">`改用呢啲function即場計算（reuse已有嘅`heroPosition`變數）。
  - `public/app.js`：`updateTravelProgress()`同`sendWorldMove`嘅accepted response callback，喺依家已有嘅`.hero-marker` cx/cy patch旁邊，加多一行用`computeCameraViewBox`+`viewBoxAttr`更新SVG嘅`viewBox`。
  - `public/styles.css`：`.world-map`改用responsive `width:100%;height:auto;aspect-ratio:1/1`。
- **不涉及**：`server.mjs`、Database schema／存檔格式、movement protocol、`IN_WORLD` state machine、碰撞、道路導航、城市實體入口、第4座城市、世界怪物、汽車交通、經濟／戰鬥／裝備／傭兵／成長、zoom／pinch、minimap、正式joystick、正式map navigation、Render設定、引擎轉換。
- 新增5個test（`test/worldmap.test.mjs`）：`computeCameraViewBox`跟隨玩家中心、低邊clamp、高邊clamp、viewport size固定唔變、`renderWorldMapHtml`實際使用dynamic viewBox（唔再係固定"0 0 1000 1000"）。
- 測試結果：79（現有，內容不變）+ 5（新增）= 84 tests passed, 0 failed。
- 存檔影響：無。
- 已知、已披露嘅風險：
  - Drag期間鏡頭同時郁動嘅回饋圈（「邊拖邊郁鏡頭」）喺真手機上實際手感未經測試，需要真機驗證。
  - 依家3座demo城市分散喺1000×1000世界唔同角落，400×400鏡頭視窗大部分時間只會見到0或1座城市——刻意接受嘅Prototype取捨（今次明確Not-In-Scope唔做minimap），留返Playtest評估。
  - iPhone portrait下鏡頭同SVG container嘅responsive行為未經真機驗證。
- Rollback基準：`main` 起點 `879c1022c647efc8c6aeaf6d04b2961d8d841525` / `checkpoint/v30-pre-claude`；P1-02基準 `988addcd498158f4a75d988c49717231d6255fae`。

### P1-03 Review round 2（修正功能回歸：Camera Follow只限IN_WORLD，經Charlie批准）

- **問題**：Code review發現一個未被tests覆蓋嘅功能回歸——`renderWorldMapHtml()`原本喺任何state都用400×400 camera-follow viewBox，但3座demo城市（starter-village 220,150／hill-market 780,150／harbour-city 500,820）分散喺1000×1000世界唔同角落，喺`IN_CITY`同`TRAVELING`state，除咗玩家目前身處嗰座城市，其他城市會完全跌出400×400鏡頭範圍之外，變成睇唔到亦撳唔到——但現有`travel/start`（IN_CITY撳另一座城市出發）同reroute（TRAVELING期間中途撳其他城市改道）呢兩個P1-01/P1-02已有嘅功能，正正需要玩家可以睇到同撳到其他城市。加上P1-02嘅`touch-action:none`令原生map pan唔再係可用嘅替代導航手段，令呢兩個現有功能實際上變成不可達——屬功能回歸。
- **修正**：Camera Follow只喺`state.snap.state==='IN_WORLD'`先啟用400×400 viewBox；`IN_CITY`同`TRAVELING`一律保持完整`0 0 1000 1000`世界viewBox，確保現有city-to-city travel／reroute嘅目的地城市喺呢兩個state下仍然完全可見同可撳。`world/move`第一次成功（`IN_CITY`→`IN_WORLD`）嘅accepted response之後，先切入400×400 camera-follow viewBox。`TRAVELING`期間嘅hero marker插值（`updateTravelProgress()`）繼續每250ms更新marker位置，但唔再patch viewBox——viewBox喺呢個state保持full-world唔變。Reload/reconnect：`IN_WORLD`用persisted `worldPosition`重建camera；`IN_CITY`／`TRAVELING`重建返full-world viewBox。
- 冇新增map pan、camera toggle、minimap、zoom、city selector、navigation UI，亦冇改`server.mjs`。
- 修改：
  - `public/worldmap.js`：`renderWorldMapHtml()`加`state.snap.state==='IN_WORLD'`判斷，唔係就用full-world viewBox。
  - `public/app.js`：`updateTravelProgress()`移除咗喺TRAVELING插值期間patch viewBox嗰一段（只保留hero marker cx/cy patch）；`sendWorldMove`嘅accepted response callback唔使改——佢本身淨係喺state變成`IN_WORLD`嗰刻先觸發，邏輯上已經啱。
  - `test/worldmap.test.mjs`：原有嘅camera-follow render測試改用`IN_WORLD` snap；新增2個test明確證明`IN_CITY`同`TRAVELING`都保持`0 0 1000 1000`並且所有城市喺HTML入面`data-city`都齊全可撳。
- 測試結果：84（round 1，其中1個test因為呢個修正而更新描述及snap.state，內容邏輯正確反映新行為）+ 2（新增）= 86 tests passed, 0 failed；現有city-tap／travel／reroute相關test完全冇削弱。
- Rollback基準：同上。

## P1-04 — 2026-09-18 — Bounds + Collision / Obstacles Prototype

- 分類：《萬行誌：白手 — Canonical v0.5》Phase 1 第四個開發任務（GitHub Issue #10）。
- 起點：`main` @ `8c703388c72fe12b3a36956c3a9d1b4a704c7cb9`（即P1-03 merge之後）。
- 目標：喺P1-02自由世界移動之上，加入第一個Server-authoritative嘅障礙物碰撞Prototype，證明世界空間可以有玩家郁唔過去嘅地方。今次係Prototype，障礙物位置／大小／數量未鎖死。
- Shared geometry module（經Charlie修正批准，取代原本「Server／Client各自複製一份」嘅方案）：
  - 新增`public/worldgeometry.js`——一個DOM-free、Node同browser都可以直接`import`嘅shared module，集中保存`WORLD_BOUNDS`、`PLAYER_COLLISION_RADIUS`、`OBSTACLES`、`inflateRect`、`segmentIntersectsRect`（swept segment-vs-axis-aligned-rectangle，Liang-Barsky parametric clipping）、`pointInRect`。
  - `server.mjs`直接`import`呢個module做碰撞判定；`public/worldmap.js`直接`import`同一個module做障礙物render，唔再自己維護一份`WORLD_BOUNDS`副本。`public`目錄本身已經由`server.mjs`static serve，冇加新static route。
  - 呢個係將`WORLD_BOUNDS`由P1-03「Server/Client各自複製、人手同步」嘅做法，改做真正single source of truth；今次冇建立大型config framework，純粹一個檔案幾個pure function／常數。
- 碰撞方案（經Charlie批准）：Swept segment-vs-rectangle（唔係只check endpoint）——由`current`去bounds-safe candidate嘅整條移動路徑做intersection test，保證「起點同終點都喺障礙物外，但移動路徑穿過薄障礙物」嘅情況都會判定碰撞（`MAX_WORLD_STEP`=60可能大過障礙物闊度，endpoint-only會漏判）。
- Player Collision Radius（Prototype Parameter，經Charlie批准）：`PLAYER_COLLISION_RADIUS`=14，對齊現有hero marker嘅視覺SVG半徑（`r="14"`）。呢個半徑淨係用嚟inflate障礙物矩形做碰撞判定，`WORLD_BOUNDS`維持玩家中心座標`0..1000`唔變，冇改做`14..986`。
- 障礙物位置（Prototype提案，未鎖死）：兩個軸對齊矩形——`ridge-a`（世界座標`700,400`至`720,550`）、`ridge-b`（`550,400`至`620,470`）。兩者連同inflate之後嘅範圍都刻意避開三座城市座標同出生點（starter-village／hill-market／harbour-city），已有專屬regression test覆蓋。
- Movement順序（同Charlie批准嘅一致）：驗證state/payload → 計算target方向 → `MAX_WORLD_STEP`clamp → `WORLD_BOUNDS`clamp（bounds-safe candidate）→ 由`current`去candidate做swept obstacle collision → 撞到就位置不變、揸唔到就寫入candidate。冇physics engine、冇pathfinding。
- Collision response：`status`仍然`ACCEPTED`、response新增`data.collided`（boolean）、撞到時`worldPosition`維持`current`不變，唔做clamp-to-edge、唔做sliding。
- 零位移唔可以觸發state transition（修正咗P1-02遺留嘅一個bug，經Charlie發現）：原本`moveWorld()`嘅DB UPDATE無論任何情況都寫`state='IN_WORLD'`，連throttled（零位移）個case都會錯誤咁將`IN_CITY`轉做`IN_WORLD`。今次修正為：只有實際產生非零位移嘅移動（`nextX/nextY`同`current`唔同）先會寫入資料庫同轉`IN_WORLD`；throttled同collision-blocked兩種零位移情況，依家都會保持原本嘅state同position完全不變。
- Legacy存檔相容性（經Charlie要求，語義喺Review round 2修正）：唔假設「之後嘅write有驗證所以DB一定合法」——P1-04新增障礙物之前已經存在嘅`worldPosition`存檔，理論上可能已經跌咗入新障礙物（inflate之後）嘅範圍。處理方式（escape-only）：如果`current`本身已經喺某個inflated障礙物範圍內，嗰個障礙物只有喺candidate**仍然喺同一個障礙物內**先會擋（唔容許喺牆內自由行走或者逐步穿越成幅牆）；candidate實際離開咗嗰個障礙物先算合法escape。其他障礙物仍然照常swept check（由外面進入／穿越任何障礙物繼續會被擋）。冇自動migration、冇reset存檔、冇改DB schema。
- 修改：
  - `server.mjs`：`import`新shared module；移除本地`WORLD_BOUNDS`定義；`moveWorld()`重寫，加入swept obstacle collision、zero-displacement狀態修正、legacy escape-only邏輯、response新增`collided`欄位。
  - `public/worldmap.js`：`import`shared module嘅`WORLD_BOUNDS`／`OBSTACLES`（re-export俾`app.js`繼續用），移除自己嘅重複定義；`renderWorldMapHtml()`加返障礙物SVG `<rect class="map-obstacle">`，純render唔做碰撞判定。
  - `public/app.js`：`sendWorldMove`嘅accepted response callback，`r.data.collided===true`時call現有`toast()`做輕量Prototype回饋。
  - `public/styles.css`：新增`.map-obstacle`最小樣式（填色＋邊框），冇改動任何現有規則、layout、zoom或minimap。
- **不涉及**：道路、城市實體入口、世界怪物、動態障礙物、NPC/單位碰撞、sliding、bouncing、clamp-to-edge、pathfinding/A*、physics engine、Database schema／存檔格式migration、Travel／Reroute邏輯、minimap、zoom、正式joystick、Render設定、引擎轉換。
- 新增22個test：
  - `test/worldgeometry.test.mjs`（新檔）+10：`WORLD_BOUNDS`/`PLAYER_COLLISION_RADIUS`/`OBSTACLES`形狀同數值、`inflateRect`、`pointInRect`邊界inclusive語義、`segmentIntersectsRect`——完全miss、薄障礙物穿越（兩端都喺外面）、endpoint入障礙物、靠近但無touch、邊界grazing、退化零長度segment、平行且喺外面。
  - `test/world-collision.test.mjs`（新檔）+9：城市／出生點全部outside inflated障礙物、endpoint-inside碰撞、thin-wall swept碰撞（兩端都喺外面）、碰撞會正常消耗移動間隔（同其他move一樣update `lastWorldMoveAt`）但唔會永久卡死——等正常interval過咗之後仍然可以繼續合法移動、真正合法位移先`IN_CITY`→`IN_WORLD`、throttled零位移唔轉`IN_WORLD`、legacy已經喺障礙物內可以安全郁出嚟、郁出嚟之後由外面再入返去仍然會被擋、world bounds clamp同碰撞check並存正常運作。
  - `test/worldmap.test.mjs`+3：`worldmap.js`嘅`OBSTACLES`同shared module係同一個array instance（冇複製）、`renderWorldMapHtml`用shared data render每一個障礙物、client render唔做碰撞判定（hero marker喺障礙物內都照樣畫）。
- 測試結果：86（現有，內容不變）+ 22（新增）= 108 tests passed, 0 failed。
- 存檔影響：無新schema；沿用P1-01嘅additive `world_x`/`world_y`。障礙物純粹係code常數，唔存喺database。
- 已知限制／風險：
  - 障礙物位置／大小純屬Prototype提案，冇經過真正嘅世界設計評估，日後極可能需要重新調整。
  - Legacy escape-only邏輯只保證「郁得出」，唔保證揀最短／最自然嘅逃脫路線——如果玩家一次過落喺兩個障礙物重疊嘅範圍（今次冇出現，但理論上可能），行為未經測試。
  - 障礙物視覺樣式（`.map-obstacle`）未經真機／真人Playtest外觀確認。
  - `collided`嘅toast文案未經Charlie正式批准字眼，只係Prototype暫定訊息。
- Rollback基準：`main` 起點 `879c1022c647efc8c6aeaf6d04b2961d8d841525` / `checkpoint/v30-pre-claude`；P1-03基準 `8c703388c72fe12b3a36956c3a9d1b4a704c7cb9`。

### P1-04 Review round 1（修正Client blocking bug，經Charlie發現同批准）

- **問題**：Charlie喺Merge Gate審查發現，`public/app.js`嘅`sendWorldMove`accepted response callback，無論`r.data.state`係咩，都直接將SVG `viewBox`改做400×400 camera-follow。P1-04本身已經令collision同throttled兩種零位移case保持原state（`IN_CITY`唔會轉`IN_WORLD`），但呢個client callback完全冇理會`state`，令Server明明仲係`IN_CITY`，畫面就已經切咗做400×400 camera，重新引入咗P1-03 Review round 2先修正過嘅「其他城市跌出鏡頭範圍、travel/reroute撳唔到」問題。
- **修正**：
  - `public/worldmap.js`新增exported pure function `resolveMapViewBox(state,position,viewportSize,bounds)`——`state==='IN_WORLD'`且有position先用`computeCameraViewBox`，其他一律用full-world viewBox。`renderWorldMapHtml()`改用呢個function（行為完全不變，純粹抽出重用）。
  - `public/app.js`嘅`sendWorldMove`callback改用同一個`resolveMapViewBox(r.data.state,r.data.worldPosition,...)`，唔再自己call`computeCameraViewBox`。因為呢個helper本身就會按`state`揀返啱嘅viewBox，就算async movement response喺`pointerup`嘅`render()`之後先返嚟都唔會再錯誤覆蓋——唔需要額外加sequencing/lock邏輯。
  - Server collision邏輯今次冇改。
- **文件／test描述修正**：原本test/CHANGELOG形容「碰撞之後move ability唔被consume」唔準確——實際上collision-blocked move同其他move一樣會update`lastWorldMoveAt`，即係會正常消耗`MOVEMENT_MIN_INTERVAL_MS`（120ms）移動間隔。`test/world-collision.test.mjs`嗰個test改名並加多一個assertion，直接證明「碰撞後立即再send確實會被throttled」，然後先證明「等正常interval之後仍然可以繼續合法移動，冇永久卡死」——依家test同描述準確反映實際行為。
- 新增4個test（`test/worldmap.test.mjs`）：`resolveMapViewBox`喺`IN_WORLD`／`IN_CITY`（模擬collision或throttled零位移response仍然帶position）／`TRAVELING`／`IN_WORLD`但冇position四種情況嘅pure function測試。
- 測試結果：108（round 1，其中1個test改名並加強assertion，內容邏輯正確反映實際行為）+ 4（新增）= 112 tests passed, 0 failed。
- Branch名偏離（`claude/clever-gauss-ayt5ff`取代原定`claude/p1-04-bounds-collision-obstacles`）今次Charlie已接受，冇重開PR。
- Rollback基準：同上。

### P1-04 Review round 2（修正legacy escape-only語義，經Charlie發現同批准）

- **問題**：Charlie發現`server.mjs`嘅`segmentBlocked()`原本實作，喺`current`已經喺某個inflated障礙物內嗰陣，會**完全skip**嗰個障礙物嘅intersection check——結果變成legacy玩家一旦出生／落喺牆內，可以喺牆內自由行走，甚至逐步移動穿過成幅牆，先由另一邊離開。呢個同已批准嘅語義「容許由障礙物內向外逃離」唔一致：正確語義應該係「淨係真正離開咗嗰個障礙物先算合法」，唔係「喺牆內乜都得」。
- **修正**：`segmentBlocked(x1,y1,x2,y2)`依家對每個障礙物獨立判斷——如果`current`喺呢個障礙物內，改為檢查candidate（`x2,y2`）係咪**仍然**喺同一個障礙物內：仍然喺入面就阻擋（保持`current`不變），真正離開咗先當合法escape。如果`current`本身喺障礙物外，維持原有嘅normal swept `segmentIntersectsRect`檢查唔變。其他障礙物一律獨立照常檢查，冇改動。
- 冇做：migration、teleport out、pathfinding、sliding、nearest-exit calculation、physics redesign——純粹一行判斷邏輯修正。
- 新增1個test（`test/world-collision.test.mjs`）：legacy已經喺障礙物內，candidate都仍然喺同一障礙物內嘅move會被擋（`collided:true`、position/state不變）——用嚟直接證明「喺牆內唔可以自由行走」，同原有「郁出嚟先算escape」、「escape之後由外面再入返去會被擋」兩個test互補，三個test合埋完整覆蓋escape-only語義。
- 測試結果：112（round 1，內容不變）+ 1（新增）= 113 tests passed, 0 failed。
- Rollback基準：同上。

## P1-05 — 2026-09-18 — Roads Non-Constraining Prototype（Test-only）

- 分類：《萬行誌：白手 — Canonical v0.5》Phase 1 第五個開發任務（GitHub Issue #12）。
- 起點：`main` @ `1bc45a609f97c348b57dfebab0ae14e8b1a52a8a`（即P1-04 merge之後）。
- 目標：驗證「道路存在，但道路唔係軌道」——玩家自由世界移動必須完全唔受`roads`資料限制，可以沿路行、離開道路、橫越道路、喺冇道路連接嘅方向自由移動，淨係受World Bounds、P1-04 Obstacles、P1-02 movement step/throttle限制。
- **Coding前research結論（經Charlie批准方向：test-only + documentation，零功能code change）**：詳細閱讀同grep`server.mjs`、`public/worldmap.js`、`public/app.js`、P1-04 collision code之後確認，`world/move`（`moveWorld()`）由頭到尾冇任何`roads`table查詢、冇road lookup、冇route依賴——`roads`只喺`fastest()`（`travel/start`用）、`normalizedSegments()`（travel segments用）、`GET /api/roads`（純display）呢幾處出現，同`moveWorld()`完全獨立。Client端`public/app.js`嘅pointer movement（`svgPointFromEvent`、`setupWorldMovePointer`、`moveWorld()`、`sendWorldMove`）同樣冇讀取`S.roads`。P1-04嘅Obstacle collision（`OBSTACLES`、`segmentBlocked()`）同`roads`table係兩個完全獨立資料源，冇任何交叉引用。**即係話P1-05想驗證嘅原則喺現有代碼已經100%成立**，唔係刻意解耦設計，而係自由移動同碰撞邏輯從未讀過road資料。缺口純粹係測試覆蓋——冇一個現有test直接證明「road→off-road」、「off-road→off-road」、「cross-road」呢啲情況。
- 修改：
  - 新增`test/world-roads-non-constraining.test.mjs`（新檔，8個server HTTP regression test，用`ac`道路——starter-village{220,150}至hill-market{780,150}，兩端y座標一樣所以成條路係`y=150`、`x:220..780`嘅水平線，喺遠離兩個P1-04 obstacle嘅`x=400`區域測試）：test region冇同任何obstacle重疊嘅setup sanity check、`GET /api/roads`確認`ac`路徑同座標、road→off-road（`(400,150)`郁去`(400,50)`，因`MAX_WORLD_STEP`clamp實際落喺`(400,90)`）、off-road→off-road（`(50,50)`↔`(90,50)`）、cross-road（`(400,100)`郁去`(400,200)`，因clamp實際落喺`(400,160)`，途中確實穿越咗`y=150`嗰條路，`collided:false`）、道路上落點本身唔會觸發collision、P1-04 obstacle collision喺呢個改動之後依然正常擋（regression confirm）、`MAX_WORLD_STEP`移動step clamp喺road走廊附近同樣唔受road影響、正常clamp做單一60單位step（呢個唔係真正嘅`WORLD_BOUNDS`邊界clamp——真正嘅world bounds邊界clamp regression coverage已經存在喺`test/world-movement.test.mjs`同`test/world-collision.test.mjs`）。
  - `CHANGELOG.md`（本段）。
  - **`server.mjs`、`public/app.js`、`public/worldmap.js`、`public/worldgeometry.js`、`public/styles.css`、DB schema／存檔格式、Travel/Reroute實作——一個字都冇改**，`git diff`可以直接核實。
- **不涉及**：道路加速／減速、道路成本／體力、道路自動導航、Pathfinding/A*、auto-walk、道路磁吸／snap-to-road、waypoint、minimap路線規劃、道路危險度／encounter frequency modifier、正式城市入口、第4座城市、世界怪物／Encounter、P1-04障礙物幾何／位置（完全冇改）、經濟／戰鬥／裝備／傭兵／成長、Database schema／存檔格式、Travel/Reroute規格、正式joystick、Render設定、引擎轉換。
- 測試結果：113（現有，內容完全不變）+ 8（新增）= 121 tests passed, 0 failed。既有Travel/Reroute相關test（`test/world-movement.test.mjs`、`test/worldmap.test.mjs`、`test/world-entity.test.mjs`、`test/hardening.test.mjs`、`test/battle.test.mjs`）全部未經修改，一齊跑證明零回歸。
- 存檔影響：無。
- 已知風險：手指喺road視覺線上滑動時嘅觸感／視覺回饋純屬UX感受問題，未經真機驗證，明確留返P1-07實機驗收處理，今次唔提前處理。
- Rollback基準：P1-05正式rollback base = `main` @ `1bc45a609f97c348b57dfebab0ae14e8b1a52a8a`（即P1-04 merge之後嘅main）。更舊歷史checkpoint reference（唔係P1-05 rollback base）：`879c1022c647efc8c6aeaf6d04b2961d8d841525` / `checkpoint/v30-pre-claude`。

## P1-06 — 2026-09-18 — Position Save / Reload Robustness（Test-only）

- 分類：《萬行誌：白手 — Canonical v0.5》Phase 1 第六個開發任務（GitHub Issue #14）。
- 起點：`main` @ `7e9addd98bb316babd40c557fb2d44ad04832b51`（即P1-05 merge之後）。
- 目標：核實並補強「世界位置儲存／重新載入（Save/Reload）」嘅可靠性——證明accepted non-zero move持久保存、`IN_WORLD`喺reload/reconnect之後唔會無故變返`IN_CITY`、zero-displacement（throttled/collision/same-position）唔製造假state transition或假寫入、legacy NULL fallback保持read-only、Travel arrival後`city_id`/`state`/`world_x/world_y`一致、以及一項工程層面嘅硬指標——**真正嘅server process重啟**（kill再用同一個SQLite DB file重新開）之後，已accepted嘅position/state仍然存在。今次屬工程可靠性驗證，唔係實機Playtest（留返P1-07）。
- **Coding前research結論（經Charlie批准方向：test-only + documentation，零production code change）**：詳細閱讀`server.mjs`（`seed()`、`snapshot()`、`moveWorld()`、`resolveArrival()`、`arrivalWorldColumns()`、`openSession()`/`validSession()`、`idem()`）、`public/app.js`（`boot()`、`refresh()`、`sendWorldMove`）、`public/worldmap.js`（`resolveWorldPosition()`）之後確認：
  - Accepted non-zero move喺`idem()`嘅`BEGIN IMMEDIATE`/`COMMIT`交易入面同步寫入`characters.world_x/world_y/state`，response返之前DB已經commit，冇「ACCEPTED但DB未寫」嘅窗口。
  - `snapshot()`單一data source（直接讀`characters`表），`IN_WORLD`同`world_x/world_y`喺同一個UPDATE statement一齊寫，享有相同durability。
  - `snapshot()`開頭有一個**獨立、P1-01/P1-02已批准**嘅auto-arrival-resolve write（travel到埗自動resolve）——呢個唔係「legacy NULL fallback」嗰個機制，兩者要分開睇；legacy NULL fallback（`worldPosition=c.world_x!=null...`嗰句）本身已經由現有`test/world-entity.test.mjs`直接DB驗證係read-only。
  - collision/throttle/same-position三種情況，code層面`if(moved)`guard令UPDATE完全唔執行，但現有test淨係經HTTP snapshot驗證數值冇變，未有直接DB層面實證「literally冇write」。
  - `resolveArrival()`同`snapshot()`嘅auto-resolve都用同一個`arrivalWorldColumns()`喺單一UPDATE入面一齊寫`city_id`/`state`/`world_x`/`world_y`，冇分階段寫嘅不一致窗口。
  - Client端已grep確認`public/`目錄完全冇用`localStorage`/`sessionStorage`/`indexedDB`；`boot()`→`refresh()`每次reload都完整攞一個新`snapshot()`直接assign去`S.snap`，冇merge、冇「保留舊城市marker」邏輯，`sendWorldMove`嘅DOM patch用嘅係server response返嚟嘅數值，唔係client自己估。**即係話P1-06想驗證嘅不變量喺現有架構已經全部成立**，缺口純粹係測試覆蓋（尤其係「真正server process重啟」呢一項，之前完全冇覆蓋）。
- 修改：
  - 新增`test/world-persistence.test.mjs`（新檔，6個test）：
    1. `IN_WORLD`位置喺自成一體（唔靠其他test執行順序）嘅fixture之下，捱得過兩次獨立fresh snapshot re-fetch。
    2. Throttle：第一個move accepted並確立`lastWorldMoveAt`，緊接住第二個move真正被throttled，並用獨立`DatabaseSync`直接讀`characters`表，證明第二個command **literally冇令world_x/world_y/state有任何額外改動**。
    3. Collision：move入inflated obstacle，`ACCEPTED`+`collided:true`，直接DB讀確認冇任何額外改動。
    4. Same-position：target同current完全一樣，`ACCEPTED`+`collided:false`，直接DB讀確認冇任何額外改動。
    5. Travel arrival之後，額外做多一次獨立fresh snapshot request（模擬reload-after-arrival），確認`cityId`/`state`/`worldPosition`三者仍然一致對應destination城市座標。
    6. **真正OS-level process restart**：獨立temp dir/DB，spawn child A、legal move accepted、**kill child A並用`proc.once('exit',...)`確實等到真正exit事件**、用完全相同`DB_PATH`重新spawn child B、開一個全新session（確認同restart前唔同）、fetch fresh snapshot，證明`worldPosition`同`state='IN_WORLD'`喺真正process重啟之後依然存在。呢個test純粹用返現有child-process-per-DB-file harness pattern嘅重複spawn/kill能力，**零production code改動**。
  - `CHANGELOG.md`（本段）。
  - **`server.mjs`、`public/app.js`、`public/worldmap.js`、`public/worldgeometry.js`、DB schema/migration、session/account architecture、Travel/Reroute實作——一個字都冇改**，`git diff`可以直接核實。
- **實作過程中發現同修正嘅test harness bug（唔涉及production code）**：撰寫真正process restart test初版時，`killAndWaitForRealExit`helper錯誤咁用`child.exitCode!==null`嚟判斷「已經exit」——但Node.js對於**被signal（例如`SIGTERM`，即`child.kill()`嘅default行為）終止**嘅process，`exitCode`會永遠保持`null`（要睇`signalCode`先知道），令個assertion同埋`finally`區塊嘅defensive cleanup call誤以為process未死，喺一個「exit event已經過咗」嘅child process上面重新註冊`.once('exit',...)`監聽器，永遠等唔到嗰個已經錯過咗嘅event，令個test卡死。修正方式：喺`spawnServer()`spawn個process嗰刻就即刻attach一個`.once('exit',...)`監聽器set一個plain flag（`child.hasExited`），`killAndWaitForRealExit`同assertion都改用呢個flag，唔再睇`exitCode`。**呢個純粹係test helper本身嘅bug（本session撰寫、未commit過嘅新代碼），唔涉及`server.mjs`或任何production code**，喺完成commit之前已經修正並確認6個test全部通過。
- **不涉及**：正式城市physical entry/exit、第4座城市、world monsters、roads新功能、auto-save UI/save slot/manual save/cloud save、account system redesign、多角色存檔、跨裝置同步、offline mode、background sync、大型reconnect architecture、multiplayer persistence、DB schema redesign/migration framework、Redis/external DB/cloud DB migration、經濟/戰鬥/裝備/傭兵/成長、Travel/Reroute gameplay規格、正式joystick/gesture UX、Render config、引擎轉換。
- 測試結果：121（現有，內容完全不變）+ 6（新增）= 127 tests passed, 0 failed。
- 存檔影響：無。
- 已發現嘅真正persistence bug：**冇**。所有已批准嘅不變量（accepted move持久化、`IN_WORLD`持久化、zero-displacement冇write、legacy NULL fallback read-only、Travel arrival一致性、真正process restart之後position/state仍存在、client冇覆寫風險）經code reading同新regression test全部證實成立。
- 已知限制／留返P1-07：Client reload flow（`boot()`/`refresh()`冇localStorage、每次完整覆蓋`S.snap`）淨係得code-reading結論記錄喺呢度，冇辦法自動化test（呢個codebase一直冇用jsdom測DOM/client state層面嘅嘢）；真實瀏覽器reload（撳返轉頁面掣、Safari背景/前景切換、iOS記憶體壓力下嘅tab reload）嘅實際行為、觸控手勢中途reload嘅UX感受，明確留返P1-07 iPhone實機驗收。
- Rollback基準：P1-06正式rollback base = `main` @ `7e9addd98bb316babd40c557fb2d44ad04832b51`（即P1-05 merge之後嘅main）。更舊歷史checkpoint reference（唔係P1-06 rollback base）：`879c1022c647efc8c6aeaf6d04b2961d8d841525` / `checkpoint/v30-pre-claude`。

## P1-07A — 2026-09-18 — Mobile Control & Camera Fix

- 分類：《萬行誌：白手 — Canonical v0.5》Phase 1 真機驗收後嘅blocking UX remediation（GitHub Issue #16）。P1-07第一輪iPhone真機驗收判定FAIL/Blocking，今次修正Charlie回報嘅4個blocking問題：觸控移動唔自然、進入自由移動後畫面放大冇得縮返全圖、移動卡頓、速度過快。**唔係新增世界玩法**。
- 起點：`main` @ `38d9433df51857521bb023392a27d76b332be057`（即P1-06 merge之後）。
- **卡頓根因**（research確認，見PR）：`sendWorldMove`原本一收到response即刻`setAttribute`硬跳（完全冇smoothing）；`MAX_WORLD_STEP=60`相對於400×400鏡頭範圍太大，每次跳動都好明顯；client（150ms）同server（120ms）兩層throttle唔同步，偶爾出現「郁唔到」嘅零位移response；camera viewBox同position一齊硬跳，冇任何transition。「入咗自由移動就縮唔返全圖」係結構性缺口——`resolveMapViewBox()`淨係睇`state`，`IN_WORLD`即刻硬切400×400，**完全冇UI俾玩家自己切返full map**。
- **方案（經Charlie批准嘅UX決定）**：Virtual Joystick（固定左下角，`radius=52`／`deadzone=10`／360°方向／強度控速）**正式取代**IN_WORLD舊SVG direct-drag，唔會兩套movement input同時active；Joystick淨係計算「方向+強度」，用返一模一樣嘅`/api/commands/world/move`endpoint（`{targetX,targetY}`，一個字冇改）；`requestAnimationFrame`根據**delta-time**（唔係fixed per-frame factor）令character（80ms）同camera（120ms）smoothing，display永遠淨係向最新`serverPosition`easing，唔會predict/extrapolate，所以唔會有「穿牆再被拉返」嘅情況（collision-blocked response嘅`serverPosition`維持原地不變，display就自然平滑咁停喺嗰度）；速度降低純粹用client-only嘅`JOYSTICK_STEP_DISTANCE=18`（細過`MAX_WORLD_STEP`），**`server.mjs`今次一個字都冇改**；新增`S.mapView`（`'follow'`|`'full'`）純client-only camera模式，右上角按鈕切換，Full Map係inspection-only（進入時disable joystick movement，唔可以控制角色，切返Follow先恢復），`mapView`永遠唔會send去server。
- 修改：
  - 新增`public/movement.js`（新檔，DOM-free pure function）：`computeJoystickInput`（方向+強度，deadzone/magnitude計算）、`clampJoystickKnob`（knob視覺clamp）、`computeJoystickTarget`（由`serverPosition`計算小步target，永遠唔會由client預測位置計算）、`easeTowards`（delta-time based exponential smoothing，frame-rate independent，composable）、`isMovementAllowed`／`shouldSendJoystickMove`（Full Map disable movement intent嘅純邏輯gate）。
  - `public/worldmap.js`：新增`resolveEffectiveViewBox(mapView,state,position,viewportSize,bounds)`（additive，**`resolveMapViewBox()`本身一個字冇改**，`mapView==='full'`強制full-world box）；`renderWorldMapHtml()`改用呢個function，並加返joystick DOM（`#joystick-base`/`#joystick-knob`，TRAVELING或Full Map時attach`joystick-disabled`class）同Follow/Full Map切換按鈕（`#map-view-toggle`）。
  - `public/app.js`：移除`setupWorldMovePointer`/`svgPointFromEvent`/舊`moveWorld()`（drag-to-move完全retire）；`sendWorldMove`改做**data-only**（淨係更新`S.snap`，唔再直接碰DOM）；新增`setupJoystick()`（pointer capture、deadzone、`pointerup`/`pointercancel`/`onlostpointercapture`即刻歸零歸零停止）、`tickMovementFrame()`（單一`requestAnimationFrame`loop，每幀用`easeTowards`smoothing character position同camera box，IN_WORLD先smoothing、其餘state直接snap，先call`shouldSendJoystickMove`先決定使唔使send）、`toggleMapView()`；`S`新增`mapView:'follow'`。
  - `public/styles.css`：`.map-scroll`加`position:relative`；新增`.joystick`/`.joystick-disabled`/`.joystick-knob`/`.map-view-toggle`（純CSS，冇改任何現有規則）。
  - `CHANGELOG.md`（本段）。
  - **`server.mjs`、`public/worldgeometry.js`、DB schema/persistence、API contract、movement state machine——一個字都冇改**，`git diff --stat`可核實。
- **真機smoke test**（用headless Chromium + iPhone viewport size模擬，pointer事件驅動joystick）：確認joystick拖動確實driving真實`/world/move`command（hero marker由starter-village座標移動）、放手後位置穩定（500ms後幾乎冇再郁，冇「放手繼續自己行」）、Full Map toggle正確顯示成個世界並將joystick視覺dim（`joystick-disabled`）、Full Map入面試拖joystick角色完全冇郁（movement確實被block）、切返Follow正常。（呢個屬engineering-level smoke test，唔代表真機Acceptance Gate已經通過——見下）。
- **不涉及**：Physical city entry/exit（Phase 2）、第4座城市、world monsters/Encounter、roads speed bonus/penalty、stamina/terrain movement cost、pathfinding/A*/auto-walk/waypoint、minimap路線規劃、pinch-to-zoom、rotate camera、新account/save/DB schema、network architecture redesign、multiplayer sync、battle/economy/mercenary/equipment/growth、engine switch、Render config change、`server.mjs`嘅`MAX_WORLD_STEP`（維持60，冇改）。
- 新增31個test：
  - `test/movement.test.mjs`（新檔）+22：`computeJoystickInput`（deadzone inclusive boundary、zero-vector唔會除0、magnitude 0→1線性ramp、超出radius clamp做1、direction unit vector）、`clampJoystickKnob`（radius之內不變、超出clamp、zero vector）、`computeJoystickTarget`（inactive回傳null、full/half magnitude步距、永遠由serverPosition計算唔係獨立predict）、`easeTowards`（dt=0冇變化、大dt收斂去target、smoothingMs<=0即刻snap、**delta-time獨立性**：兩個細step等於一個大step，composability數學驗證）、`isMovementAllowed`/`shouldSendJoystickMove`（Full Map disable movement intent嘅純邏輯）。
  - `test/worldmap.test.mjs`+9：`resolveEffectiveViewBox`（full強制full-world、follow维持現有camera-follow行為唔變、IN_CITY兩者一致）、`renderWorldMapHtml`嘅mapView預設值backward-compatible、full強制viewBox、toggle按鈕文案、joystick disabled class喺Full Map／TRAVELING時正確出現。
- 測試結果：127（現有，內容完全不變）+ 31（新增）= **158 tests passed, 0 failed**。
- 存檔影響：無。
- 已知限制／真機Acceptance Gate（**Merge後仍未代表P1-07正式pass**，需要Charlie重新用iPhone驗收）：
  - `JOYSTICK_RADIUS`/`JOYSTICK_DEADZONE`/`JOYSTICK_STEP_DISTANCE`/`CHARACTER_SMOOTHING_MS`/`CAMERA_SMOOTHING_MS`全部係Prototype Parameter，真機test後好可能需要再調。
  - 搖桿方向自然度、放手即停嘅真實觸感、速度是否仍然過快、移動視覺是否仍然一格格跳、camera跟隨會唔會暈、Full Map/Follow切換嘅實際手感、obstacle/boundary真機行為、reload後位置——全部要Charlie親身用iPhone驗證，engineering層自動測試通過**唔代表**P1-07正式pass。
- Rollback基準：P1-07A正式rollback base = `main` @ `38d9433df51857521bb023392a27d76b332be057`（即P1-06 merge之後嘅main）。更舊歷史checkpoint reference（唔係P1-07A rollback base）：`879c1022c647efc8c6aeaf6d04b2961d8d841525` / `checkpoint/v30-pre-claude`。

### P1-07A Review round 1（修正client/server throttle timing衝突，經Charlie發現同批准）

- **問題**：`public/movement.js`嘅`JOYSTICK_SEND_INTERVAL_MS`原本設做100ms，但`server.mjs`嘅`MOVEMENT_MIN_INTERVAL_MS`係120ms——client理想情況下send得比server throttle窗口更頻密。持續按住joystick嘅情況下，會形成`accepted movement`→`throttled zero-move`→`accepted movement`→`throttled...`交替出現，令真正authoritative position大約每兩次send（約200ms+）先更新一次——直接同P1-07A本身想解決嘅「雙重throttle導致卡頓」呢個目標衝突。
- **修正**：`JOYSTICK_SEND_INTERVAL_MS`由100ms改做**140ms**（server 120ms + 20ms buffer），確保正常joystick cadence唔會撞正server throttle窗口。純一個數值修正，`server.mjs`/`MOVEMENT_MIN_INTERVAL_MS`/API contract一個字冇改。
- 新增1個regression test（`test/movement.test.mjs`）：明確assert`JOYSTICK_SEND_INTERVAL_MS`大過server嘅`MOVEMENT_MIN_INTERVAL_MS`（120ms，因為冇export/import唔到，test入面手動keep in sync並註明），同鎖定目前批准嘅140ms數值。
- 測試結果：158（round 1，內容不變）+ 1（新增）= 159 tests passed, 0 failed。
- Rollback基準：同上。

## P1-07 Movement Failure Diagnostic Hotfix — 2026-09-18

- 分類：P1-07A merge後，Charlie提供iPhone真機screen recording，回報「joystick knob正常跟手、Follow/Full Map正常、camera/UI整體順暢，但角色完全冇world movement」，判定為blocking bug。今次係**純diagnostic hotfix**，唔係修正。
- 起點：`main` @ `fefb11876a233fe2948a9a59a327cb31d8ba311c`（即P1-07A merge之後）。
- **Read-only diagnosis結論（見PR對話記錄，經Charlie批准診斷方向後先開始coding）**：
  - **⚠️ Root cause至今仍未證實。** 冇辦法喺呢個sandbox環境攞到Charlie實機測試嗰刻嘅network trace，`server.mjs`本身又完全冇任何request log（`api()`成個function一行`console.log`都冇），所以事後冇辦法追溯查證真正發生咗咩事。
  - 但code reading搵到一個**已確認、獨立於root cause**嘅defect：`public/app.js`嘅`sendWorldMove`喺`r.status==='REJECTED'`嗰陣只係`return`，冇任何toast／console輸出；`command()`兩次retry都失敗時嘅exception亦冇被catch住，會變成silent unhandled rejection。呢兩層合埋，代表**無論伺服器真正REJECTED原因係咩（`ERR_SESSION_REPLACED`/`ERR_INVALID_STATE`/`ERR_BATTLE_SETTLEMENT_REQUIRED`/`ERR_INVALID_WORLD_TARGET`等等），定係request根本send唔出／逾時，UI表現都會係『joystick同camera正常、角色完全唔郁、乜提示都冇』——同Charlie觀察到嘅現象完全吻合**。
  - **明確冇假設`ERR_BATTLE_SETTLEMENT_REQUIRED`（pending loot）就係root cause**——只係列做其中一個未證實嘅candidate，唔係結論。
- **今次改動（純diagnostic visibility，唔改任何movement/throttle/collision/state machine邏輯）**：
  - `public/movement.js`：新增pure helper `describeWorldMoveError(errorCode)`——將`server.mjs`嘅`moveWorld()`已知REJECTED errorCode（`ERR_SESSION_REPLACED`/`ERR_INVALID_STATE`/`ERR_BATTLE_SETTLEMENT_REQUIRED`/`ERR_INVALID_WORLD_TARGET`/`ERR_IDEMPOTENCY_KEY_REQUIRED`/`ERR_COMMAND_CONFLICT`）映射做可讀訊息；未映射嘅errorCode**原樣保留**（唔會顯示做「未知錯誤」咁隱藏咗真正代碼）。純display-only，唔改任何行為判斷。
  - `public/app.js`：`sendWorldMove`嘅`command()`call改用`try/catch`包住（呢個`try/catch`寫喺`sendWorldMove`自己個callback入面，唔係`asyncqueue.js`，`createCoalescingSender`本身一個字冇改）：
    - `REJECTED`：`console.warn`記錄`r.errorCode`，並用`toast(describeWorldMoveError(r.errorCode))`顯示可讀訊息。
    - `command()`拋exception（網絡／伺服器錯誤，兩次retry都失敗之後）：`console.error`記錄完整error，`toast`顯示fallback訊息（帶埋`err.message`如果有）。
    - **唔再有silent failure／unhandled rejection**——兩條路徑而家一定會喺畫面度顯示返嘢。
  - `CHANGELOG.md`（本段）。
  - **`server.mjs`、API contract、DB schema、movement state machine、`pendingLootSettlement()`、`public/asyncqueue.js`、joystick參數（radius/deadzone/step distance）、smoothing參數、throttle（`JOYSTICK_SEND_INTERVAL_MS`/`MOVEMENT_MIN_INTERVAL_MS`）、collision邏輯——一個字都冇改**，`git diff --stat`可核實。
- 新增3個test（`test/movement.test.mjs`）：
  1. 每個已知errorCode都映射到獨立、可讀、非原始code嘅訊息（`ERR_SESSION_REPLACED`/`ERR_INVALID_STATE`/`ERR_BATTLE_SETTLEMENT_REQUIRED`/`ERR_INVALID_WORLD_TARGET`/`ERR_IDEMPOTENCY_KEY_REQUIRED`/`ERR_COMMAND_CONFLICT`，六個訊息互不相同）。
  2. 未映射嘅errorCode（例如未來新增嘅代碼）原樣返回，唔會俾一個generic「未知錯誤」字串遮住真正代碼。
  3. `errorCode`缺失（`undefined`/`null`）都會有non-empty fallback訊息，唔會顯示空白。
- **不涉及**：修正真正movement bug本身（因為root cause未證實）、`server.mjs`任何邏輯、pending loot settlement流程、joystick/smoothing/throttle任何數值、collision邏輯、schema、API contract。
- 測試結果：159（現有，內容完全不變）+ 3（新增）= **162 tests passed, 0 failed**。
- 存檔影響：無。
- **下一步**：呢個hotfix merge之後，Charlie下次喺iPhone重試joystick移動，畫面出現嘅toast／Safari console嘅`console.warn`/`console.error`會直接顯示真正errorCode或exception內容，到時先可以針對真正root cause提交正式修正計劃。
- Rollback基準：本次hotfix rollback base = `main` @ `fefb11876a233fe2948a9a59a327cb31d8ba311c`（即P1-07A merge之後嘅main）。更舊歷史checkpoint reference（唔係本次rollback base）：`879c1022c647efc8c6aeaf6d04b2961d8d841525` / `checkpoint/v30-pre-claude`。

## P1-07B — 2026-09-18 — Continuous Visual Movement + Server Reconciliation

- 分類：《萬行誌：白手 — Canonical v0.5》Phase 1 第二輪真機驗收後嘅blocking UX remediation（GitHub Issue #19）。P1-07A+diagnostic hotfix部署後，Charlie第二輪iPhone真機錄影確認joystick同Follow/Full Map已經正常driving`/world/move`，但角色移動同camera追蹤仍然明顯「卡卡下」（velocity pulsing），diagnostic toast冇見任何rejection/network error。今次修正嘅係movement presentation model本身，**唔係新增玩法**。
- 起點：`main` @ `5705955a90cb11b25de63bca0ac22b2da49f736f`（即P1-07 Diagnostic Hotfix merge之後）。

### Pulsing根因（read-only research確認，有數得計）

`sendWorldMove`每`JOYSTICK_SEND_INTERVAL_MS=140ms`先攞到一次server response，而`JOYSTICK_STEP_DISTANCE=18`細過`MAX_WORLD_STEP=60`，即係每次accepted response都令`serverPosition`**離散跳18px**。P1-07A用`easeTowards`exponential easing（character 80ms／camera 120ms）追呢個離散target：用`factor=1-exp(-dt/smoothingMs)`計，穩定狀態下character嘅視覺誤差喺每個140ms週期入面喺~3.8px同~21.8px之間擺動（速度比約5.7倍），camera（用緊獨立、追住同一組離散`serverPos`嘅easing鏈）誤差擺動幅度仲大（~26.1px峰值）而且相位唔同步——兩條獨立exponential easing各自追住同一條離散階梯，形成issue講嘅「加速→追近→再跳前→再追」pulsing，同「camera第二層拖尾」。

### 方案（經Charlie批准嘅修正版UX決定）

- 新增client-only**連續predicted position**：joystick held時，每個animation frame（唔止每140ms send嗰刻）都根據方向＋強度＋dt連續前進，唔再淨係喺離散server snapshot之間做exponential easing。
- **速度直接由現有常數推導**：`predictionVelocity = JOYSTICK_STEP_DISTANCE / JOYSTICK_SEND_INTERVAL_MS`（18/140 px/ms），唔新增獨立speed常數，確保視覺速度長遠同server真實批准速度一致，唔會漂移。
- 新增**`MAX_PREDICTION_LEAD=36px`**：predicted position最多可以領先最新confirmed serverPosition 36px，到頂就停止local prediction（等server追上），**呢個係正常expected lead，唔係error，唔會被主動拉返**——一般successful、非collided嘅response（`collided=false`、`state`正常）完全唔做backward reconciliation，只俾server逐步追近prediction，避免重新製造forward/backward sawtooth。
- **Reconciliation淨係喺特定觸發先做**：`REJECTED`／network或command exception（呢兩種仲會即刻`predictionSuspended=true`令prediction停止再前進，等下次成功send先resume）、以及divergence自然超出`MAX_PREDICTION_LEAD`。Divergence≤36px用`RECONCILE_SMOOTHING_MS=40ms`溫和修正，36~54px（`RECONCILE_HARD_RESET_DISTANCE=54`＝3×`JOYSTICK_STEP_DISTANCE`）用`RECONCILE_STRONG_SMOOTHING_MS=40ms`（獨立可調常數，暫時同上）較快修正，>54px或者非`IN_WORLD`／`refresh()`（reload/travel/settlement等）觸發即刻hard reset，唔做動畫。
- **Collision/boundary**：新增`clampPredictedStep()`／`isStepBlocked()`，直接reuse`public/worldgeometry.js`嘅`pointInRect`/`segmentIntersectsRect`primitives（同`server.mjs`一樣嘅`OBSTACLES.map(inflateRect)`），逐字mirror`server.mjs`嘅`segmentBlocked()`escape-only語義同「bounds clamp先、collision check後、blocked就企定唔郁」嘅all-or-nothing順序。因為prediction本身已經用緊同server一樣嘅規則clamp住，正常撞牆嗰陣predicted本身就已經停喺接近server真正會拒絕嘅位置，唔會出現「肉眼穿牆好深先被拉返」。**呢個純粹係presentation-only clamp，只會比server更嚴唔會更鬆，真正collision權威永遠喺`server.mjs`**。
- **Camera改跟`predictedPosition`**（renderPosition），移除獨立嘅120ms camera easing——Camera同character而家共用同一個已經連續嘅position，唔再各自追住離散target，消除咗「第二層拖尾」。
- **Release即停**：`pointerup`/`pointercancel`/`onlostpointercapture`已有嘅`reset()`令`joystickActive=false`，prediction下一frame即刻唔再前進，冇任何慣性/滑行。
- **Full Map保持inspection-only**：`isMovementAllowed`/`shouldSendJoystickMove`呢兩個現有pure helper完全冇改，繼續同時gate住prediction advance同server send。
- **`IN_CITY`stale label**：根因係頂部狀態標籤淨係喺`render()`成個HTML重建嗰刻寫一次，但`sendWorldMove`（P1-07A刻意設計）改`S.snap.state`喺記憶體入面唔call`render()`，令標籤停留喺舊字。最小修正：加`id="state-label"`，喺`tickMovementFrame()`（同`.hero-marker`/`.world-map`一樣嘅presentation patch位置）每frame檢查、有變就update textContent，唔做full render。

### 改動

- `public/movement.js`：新增Prototype Parameters `MAX_PREDICTION_LEAD=36`、`RECONCILE_SMOOTHING_MS=40`、`RECONCILE_STRONG_SMOOTHING_MS=40`、`RECONCILE_HARD_RESET_DISTANCE=54`；新增pure helper `predictionVelocity()`、`isStepBlocked()`、`clampPredictedStep()`、`advancePredictedPosition()`、`reconciliationSmoothingMs()`；**移除**`CHARACTER_SMOOTHING_MS`／`CAMERA_SMOOTHING_MS`（被新model完全取代，全repo已冇任何地方使用，屬dead code清理，唔係未經批准改動）。
- `public/app.js`：`tickMovementFrame()`重寫（prediction advance + lead cap + reconciliation banding + camera改source + state-label patch）；`sendWorldMove`喺REJECTED/exception分支加`predictionSuspended=true`、ACCEPTED成功分支清返false；`refresh()`加`predictionResetPending=true`；`render()`嘅狀態標籤加`id="state-label"`；joystick input（`computeJoystickInput`/`clampJoystickKnob`）、send target計算（`computeJoystickTarget`，仍然由`serverPos`計，唔係predicted）、send interval（140ms）、joystick radius/deadzone——全部**一個字冇改**。
- `CHANGELOG.md`（本段）。
- **`server.mjs`、`public/worldmap.js`、`public/worldgeometry.js`、`public/styles.css`、DB schema/persistence、API contract、movement state machine、physical city entry——一個字都冇改**，`git diff --stat`可核實（只有`public/app.js`、`public/movement.js`、`test/movement.test.mjs`三個檔）。

### 真機smoke test

用headless Chromium + iPhone viewport模擬持續按住joystick 1.8秒，逐frame取樣hero marker位置：每個~16ms樣本嘅位移穩定喺1.7~3.6px範圍（連續細步，冇離散大跳），同P1-07A舊model「一次跳18px再exponential衰減」嘅pattern明顯唔同。放手後50ms同350ms嘅位置完全一致（即刻停、冇滑行）。狀態標籤正確顯示`IN_WORLD`（唔再stale）。另外確認Full Map入面拖joystick，class帶`joystick-disabled`且角色位置完全唔變，切返Follow正常。（呢個屬engineering-level smoke test，**唔代表P1-07B/P1-07正式pass**，仍然需要Charlie iPhone真機驗收。）

### 測試

新增22個test（`test/movement.test.mjs`）：`predictionVelocity`數值推導、4個Prototype Parameter鎖定值、`isStepBlocked`/`clampPredictedStep`同`test/world-collision.test.mjs`一樣嘅obstacle fixture做parity驗證（包括escape-only legacy語義）、`advancePredictedPosition`嘅lead cap邊界（含inclusive boundary）同「lead係相對serverPosition量度，唔係相對原點」、`reconciliationSmoothingMs`三檔邊界（含兩個inclusive boundary）同自訂threshold參數化驗證。

- 測試結果：162（現有，內容完全不變）+ 22（新增）= **184 tests passed, 0 failed**。
- 存檔影響：無。
- 已知限制／真機Acceptance Gate（**Merge後仍未代表P1-07正式pass**）：`MAX_PREDICTION_LEAD`/`RECONCILE_SMOOTHING_MS`/`RECONCILE_STRONG_SMOOTHING_MS`/`RECONCILE_HARD_RESET_DISTANCE`全部係Prototype Parameter，真機test後可能需要再調（尤其`RECONCILE_STRONG_SMOOTHING_MS`目前同`RECONCILE_SMOOTHING_MS`數值一樣，只係獨立tunable，未必代表已經係最佳分野）。真機連續移動手感、camera同步、collision修正是否突兀、release即停手感——全部要Charlie親身iPhone驗證。
- Rollback基準：P1-07B正式rollback base = `main` @ `5705955a90cb11b25de63bca0ac22b2da49f736f`（即P1-07 Diagnostic Hotfix merge之後嘅main）。更舊歷史checkpoint reference（唔係P1-07B rollback base）：`879c1022c647efc8c6aeaf6d04b2961d8d841525` / `checkpoint/v30-pre-claude`。

### P1-07B Merge Gate review（修正collision reconciliation漏洞，經Charlie發現同批准）

- **問題**：`sendWorldMove`原本淨係喺`REJECTED`／network exception先set`predictionSuspended=true`；`ACCEPTED`response（包括`collided:true`）一律set返`predictionSuspended=false`，冇觸發reconciliation，違反咗Plan本身「collision/server correction要觸發reconciliation」嘅原則。根因：client prediction用per-frame細步曲線前進，`server.mjs`嘅`moveWorld()`就由authoritative`serverPosition`一次過對住requested target做swept segment check——快速轉向／貼障礙物嗰陣，兩者可能短暫出現唔同結果；如果server已經回`collided:true`，client理應停止繼續prediction直到lead cap先停，而唔係將個flag清返做false當正常move處理。
- **修正**：`public/movement.js`新增pure helper`shouldSuspendAfterAccepted(response)`——`collided:true`返`true`（suspend），`collided:false`（包括throttled但非collided）返`false`（resume）。`public/app.js`嘅`sendWorldMove`ACCEPTED分支改用呢個helper決定`predictionSuspended`，取代原本直接set`false`。純一個決策邏輯修正，`server.mjs`/API/schema/collision geometry/joystick參數/prediction lead cap/reconciliation thresholds/camera source——一個字冇改。
- 新增4個regression test（`test/movement.test.mjs`）：`collided:true`嘅ACCEPTED response令prediction suspend、正常`collided:false`嘅ACCEPTED response令prediction resume（唔會停留喺suspended）、單純throttled（零位移但非collided）唔算collision唔會suspend、缺失response data唔會拋錯預設唔suspend。
- 測試結果：184（round前，內容不變）+ 4（新增）= 188 tests passed, 0 failed。
- Rollback基準：同上。

## P1-07C — 2026-09-18 — Mobile Movement Telemetry（diagnostic-only）

- 分類：《萬行誌：白手 — Canonical v0.5》Phase 1真機診斷工具（GitHub Issue #21）。P1-07B已merge並喺Render live，但Charlie最新iPhone真機測試主觀上覺得角色移動仲係「卡卡地」，甚至覺得第一個版本（P1-07A）反而更順。新假設：FPS可能正常，但真實網絡RTT/response gap可能令prediction不斷撞`MAX_PREDICTION_LEAD=36px`，形成「行一下→撞cap停→server追上→再行」嘅肉眼stutter。**呢個未證實**，所以P1-07C**唔修movement，純粹量度**——建立一個只供真機驗收用嘅debug overlay，等Charlie可以用iPhone screen recording同步攞客觀數據。
- 起點：`main` @ `bdf539b3b96e99ba835affcbc205b37c078610ef`（即P1-07B merge之後）。
- **設計原則**：telemetry純粹read-only觀察現有movement path，唔會逆向影響任何movement/joystick/prediction/reconciliation/camera行為。所有telemetry math/formatting放喺**全新`public/telemetry.js`**，`public/movement.js`、`public/asyncqueue.js`、`server.mjs`、`public/worldgeometry.js`——**一個字都冇改，`git diff`零行**（比「話冇改」更強嘅證明：直接`git diff public/movement.js public/asyncqueue.js server.mjs public/worldgeometry.js`輸出空白）。`public/app.js`嘅改動經覆核確認**只有新增行，冇修改任何一行existing code**（`git diff`入面淨係`+`，冇`-`）。
- 改動：
  - **新增`public/telemetry.js`**：`nextFpsEma()`（reuse`movement.js`現有`easeTowards`做delta-time EMA，唔新增第二套smoothing算法）、`predictionLeadDistance()`（Euclidean distance）、`nextMoveTiming()`（RTT+response gap嘅**單一共用function**，ACCEPTED/REJECTED/ERROR三條path全部call同一個，確保timing邏輯一致）、`formatMs()`/`formatFlag()`/`formatLeadReadout()`（display formatting）。新常數`TELEMETRY_FPS_SMOOTHING_MS=500`、`TELEMETRY_OVERLAY_PATCH_INTERVAL_MS=100`——同movement嘅Prototype Parameter完全分開，唔會混淆。
  - `public/app.js`：
    - `sendWorldMove`嘅callback最開頭（`try`之前）攞`startedAt=performance.now()`——呢個先至係真正network command開始（`createCoalescingSender`如果`inFlight`時只會`pending=target;return`，唔會invoke callback，所以呢個位置天然排除咗queue wait time，**唔需要改`asyncqueue.js`**）。
    - 三個completion path（ERROR catch／REJECTED／ACCEPTED）都call同一個新helper`recordMoveTelemetry()`，內部用返`nextMoveTiming()`。ERROR/REJECTED時**明確set`throttled:null`／`collided:null`**，避免overlay殘留返上一個ACCEPTED response嘅舊值。
    - 輕量shadow flag`telemetryMoveInFlight`（callback開始=true，三個出口都=false），唔碰`asyncqueue.js`個internal`inFlight`。
    - `tickMovementFrame()`尾巴（喺existing send區塊之後，純新增行）：`telemetryFpsEma`每frame用`nextFpsEma`更新；`patchTelemetryOverlay()`每frame call，但內部自己throttle最多每`TELEMETRY_OVERLAY_PATCH_INTERVAL_MS=100ms`先真正寫DOM一次（FPS/lead本身仍然每frame即時計，淨係DOM write throttle，避免debug UI自己拖低要量度嗰個FPS）。
  - `public/worldmap.js`：`renderWorldMapHtml()`加返telemetry overlay嘅靜態HTML shell（同joystick/toggle並列，一次性、additive；每個數據點一個固定`id`，`app.js`嘅`tickMovementFrame`逐個patch textContent，唔做full render，同`#state-label`P1-07B已有嘅pattern一致）。
  - `public/styles.css`：新增`.telemetry-overlay`一條規則（`position:absolute;bottom:14px;right:10px;pointer-events:none;`）——右下角，離joystick（左下）同Follow/Full Map toggle（右上）都夠遠，`pointer-events:none`確保唔會食touch。
  - `CHANGELOG.md`（本段）。
- **顯示數據**（右下角overlay）：FPS、Move RTT、Response gap、Prediction lead（`31.4 / 36px`格式）、In flight、Throttled、Collided、Prediction suspended、最新response status（ACCEPTED/REJECTED/ERROR）、最新errorCode。
- **真機smoke test**：headless Chromium + iPhone viewport確認overlay正確顯示（computed `pointer-events:none`）、持續按住joystick時telemetry數值正常更新（FPS 60、RTT個位數ms、response gap~151ms貼近140ms送出間隔、lead維持喺個位數px、status ACCEPTED）、放手後角色停低行為完全冇受telemetry影響、overlay正中央嗰點`elementFromPoint`確認實際俾joystick／地圖接收唔到overlay本身（`pointer-events:none`真正生效，唔止CSS聲明）。
- **不涉及**：任何movement UX修正、`JOYSTICK_STEP_DISTANCE`、`JOYSTICK_SEND_INTERVAL_MS`、`MAX_PREDICTION_LEAD`、reconciliation thresholds/smoothing、camera behavior、`server.mjs`、API contract、schema/state machine、collision、`asyncqueue.js`嘅queue/coalescing semantics、retry/batching/websocket/transport optimization。
- 測試：
  - 新增`test/telemetry.test.mjs`（21個DOM-free pure test）：`TELEMETRY_FPS_SMOOTHING_MS`/`TELEMETRY_OVERLAY_PATCH_INTERVAL_MS`鎖定值、`nextFpsEma`（null previous即刻snap去第一個讀數、`dt=0`唔會除0、穩定dt下會converge、單一壞frame淨係nudge唔會snap）、`predictionLeadDistance`（3-4-5直角三角形fixture、對稱性）、`nextMoveTiming`（RTT計算、第一次response gap係null、第二次開始正確計差、三條path用完全同一個function保證一致）、`formatMs`/`formatFlag`/`formatLeadReadout`（null placeholder、rounding、Issue #21原本example嘅格式）。
  - `test/worldmap.test.mjs`加2個新test：overlay shell含晒10個documented data-point id、overlay純additive（joystick/toggle markup完全唔受影響，overlay喺佢哋之後先加）。
- 測試結果：188（現有，內容完全不變）+ 21（新增）= **209 tests passed, 0 failed**。
- 存檔影響：無。
- **重要**：P1-07C完成**唔代表P1-07 pass**，純粹診斷證據收集。呢個phase嘅目的係等Charlie跟Issue #21嘅三段式protocol（穩定Wi-Fi／較弱Wi-Fi／4G-5G，各10秒×3次）錄screen recording，等下一輪根據實際FPS/RTT/response gap/prediction lead數據，先判斷真正瓶頸係咩，先至提交針對性修正Plan。
- Rollback基準：P1-07C正式rollback base = `main` @ `bdf539b3b96e99ba835affcbc205b37c078610ef`（即P1-07B merge之後嘅main）。更舊歷史checkpoint reference（唔係P1-07C rollback base）：`879c1022c647efc8c6aeaf6d04b2961d8d841525` / `checkpoint/v30-pre-claude`。

### P1-07C Merge Gate review（修正FPS telemetry被movement dt cap污染，經Charlie發現同批准）

- **問題**：原本FPS EMA直接reuse movement嘅`dt`（`tickMovementFrame`嗰句`const dt=lastFrameTime?Math.min(now-lastFrameTime,100):16`）——呢個`Math.min(...,100)`係movement smoothing/prediction先需要嘅cap，但套用到FPS量度上會令真實250ms嘅rendering stall被誤報做~100ms（~10fps）而唔係真正嘅~4fps，削弱咗P1-07C本身「用嚟區分rendering問題vs network問題」嘅診斷目的。
- **修正**：`public/telemetry.js`新增pure helper`nextTelemetryFrameDelta(previousTimestamp,now)`——回傳原始、冇cap嘅frame間距（第一frame冇previous timestamp就回傳`null`）。`public/app.js`新增獨立state`telemetryLastFrameTimestamp`，FPS EMA改用呢個獨立、唔受movement dt cap影響嘅raw delta計算；movement本身嘅`dt`/`lastFrameTime`邏輯（第327行）**一個字冇改**。
- 新增6個regression test（`test/telemetry.test.mjs`）：第一frame回傳`null`（唔會捏造dt）、250ms真實間距原樣回傳（唔變100ms）、500ms真實間距原樣回傳（唔變100ms）、正常~16ms frame唔受影響、餵入raw 250ms stall嘅FPS EMA明確比錯誤capped-at-100ms嘅結果更低（反映真正~4fps方向）、500ms stall嘅FPS EMA明確比250ms stall更低（反映~2fps方向）。
- 其餘telemetry（RTT／response gap／in-flight／lead／throttled／collided／status／errorCode／100ms overlay DOM throttle）全部**冇改**。`movement.js`/`asyncqueue.js`/`server.mjs`/`worldgeometry.js`/movement參數/camera/prediction/reconciliation/network behavior——一個字都冇改。
- 測試結果：209（round前，內容不變）+ 6（新增）= 215 tests passed, 0 failed。
- Rollback基準：同上。

## P1-07D — 2026-09-18 — Latency-Decoupled Movement（Decouple Movement from HTTP Response Cadence）

- 分類：《萬行誌：白手 — Canonical v0.5》Phase 1移動系統（GitHub Issue #23）。P1-07C真機telemetry證實咗根本原因：單一in-flight HTTP round-trip（RTT約389–716ms真機觀察值）加上server端固定`MAX_WORLD_STEP=60`嘅per-call位移上限，令authoritative confirmation cadence被RTT綁死，client-side prediction（受`MAX_PREDICTION_LEAD=36px`封頂）周期性撞頂凍結，形成「行一下→停→追→再行」嘅肉眼stutter。呢個phase經過**7輪Architecture Gate review**（v2→v4.4，逐輪由Charlie具體數學/場景反例把關）先至batch approve，核心方向定名**C2：elapsed-time authoritative allowance / earned movement**。
- 起點：`main` @ `96d789ce63bdc9e832130bbbb4d65f9caf0a3f16`（即P1-07C merge之後）。Pre-risk checkpoint：`checkpoint/p1-07d-pre-transport`（同一SHA，維持不變）。
- **設計原則**：保留absolute-target API（`{targetX,targetY}`）完全不變、`public/asyncqueue.js`單一in-flight/coalescing機制**零改動**、DB schema唔改、`JOYSTICK_RADIUS`/`JOYSTICK_DEADZONE`等既有joystick UX參數唔改、Full Map inspection-only唔改、physical city entry依然係Phase 2（呢個phase冇夾帶）。
- **Server side（`server.mjs`）**：`moveWorld()`將flat常數`MAX_WORLD_STEP=60`退役，換成elapsed-time-scaled allowance：`allowance = MOVE_SPEED_RATE * min(now-lastWorldMoveAt, MOVE_CATCHUP_CAP_MS)`（`MOVE_SPEED_RATE`/`MOVE_CATCHUP_CAP_MS`由`public/movement.js`import，避免client/server drift）。`MOVE_CATCHUP_CAP_MS=1000ms`（Prototype Parameter，未鎖定：對比800/1000/1500ms喺真機RTT範圍下嘅margin、collision風險、idle-burst風險後嘅工程判斷，非數據直接推導）。**明確、準確嘅安全invariant**（取代任何「speed ceiling」／「長期平均速度封死」類overclaim）：`displacement <= MOVE_SPEED_RATE * min(elapsedSinceLastNonThrottledAttempt, MOVE_CATCHUP_CAP_MS)`——呢個bound只係關於單一command嘅最大位移，**證明唔到**actual joystick held duration、任意wall-clock window嘅平均速度、或者idle時間冇被轉化做burst credit（呢個係喺absolute-target API零payload改動嘅前提下，結構性冇得完全避免嘅Prototype trade-off，已喺code comment同呢個entry明確承認）。Throttle（`MOVEMENT_MIN_INTERVAL_MS=120`）、collision（`segmentBlocked`）、bounds clamp、idempotency（`idem()`）全部**一個字冇改**。加咗technical debt comment：`lastWorldMoveAt`依然係process-global，single-character prototype可接受，但multi-character/multiplayer之前必須改做per-character。
- **Client side（`public/movement.js`新增pure helpers**，全部DOM-free、直接unit test**）**：
  - `integrateInputPosition`：純一frame input積分，冇lead cap、冇bleed，供`earnedPosition`（request truth累積）專用，同presentation用嘅`advancePredictedPosition`完全分家（避免任何預設參數嘅presentation correction污染request truth）。
  - `advancePredictedPosition`：內部改用`integrateInputPosition`做forward step；forward-freeze由Euclidean distance改做**方向性投影**（`ahead`沿input方向），令predicted喺大額合法grant後「落後」server時唔會被誤判做「太前」而凍結；新增**lateral bleed-off**（每frame主動拉近垂直於行進方向嘅divergence），確保呢個保護唔會變成無限期放寬。
  - `movementDivergence`：predicted/server嘅signed `ahead`/`lateral`分解。
  - `catchUpDebtAfterGrant`/`nextCatchUpDebt`：喺ACCEPTED非collided grant嗰刻，只credit沿intent方向嘅**非負ahead分量**（唔包括任何lateral分量，避免一個混雜grant嘅lateral部份被誤當合法catch-up context去masking真正嘅lateral divergence——具體反例已寫做test），俾一個persistent（跨方向改變都保留，唔會被reprojection破壞）嘅lateral安全額度；追返/release/collision/rejected/error/reset一律清零。
  - `clampEarnedTarget`：request target永遠喺線段`[serverPosition,earnedPosition]`上，唔會超越`earnedPosition`（積分終點）。
  - `nextEarnedPosition`：`earnedPosition`嘅per-frame更新，**同character state完全脫鉤**（唔理IN_CITY定IN_WORLD），解決咗一個Architecture Gate揪出嘅嚴重bug：舊設計將`earnedPosition`reset條件同`state==='IN_WORLD'`綁埋一齊，令IN_CITY嗰陣永遠send唔到非零target，形成死鎖，IN_CITY→IN_WORLD第一步永遠發生唔到。
  - `idleSettlePosition`：joystick冇active input嗰陣嘅presentation reconciliation——任何remaining divergence（唔理幾大）都平滑ease返去server truth，永遠唔hard reset，解決咗release後≤36px嘅divergence會永久卡住唔被reconcile嘅漏洞。
  - `nextGenerationAnchor`：用**anchor**（唔係逐frame比較）偵測方向（15°門檻，dot product）同magnitude（0.15絕對值差門檻）嘅有意義改變，兩者任何一項超門檻都令movement generation遞增——anchor-relative設計確保漸進、累積嘅轉向/magnitude drift（每步都細過門檻）最終一定會被偵測到，唔會逃過previous-frame比較嘅盲點。
  - `guardStaleGeneration`：包裝network call function，喺實際invoke之前check bound generation係咪仲係current——一旦release或者有意義嘅方向/magnitude改變令generation過時，即使呢個target已經被`asyncqueue.js`嘅coalescing機制queue咗做`pending`，都會喺真正打去server**之前**被drop，唔會誤送一個已經被玩家放棄嘅intent去server。Production（`app.js`）同test使用完全同一個function，唔存在兩套邏輯。
- **Client side（`public/app.js`）**：`sendWorldMove`重寫，`generation`（純client-side metadata，**唔會**出現喺實際`/world/move` API payload）連同target一齊傳入，透過`guardStaleGeneration`喺送出前drop已過時嘅pending target；response返嚟後亦獨立check staleness——stale response嘅`S.snap.worldPosition`**永遠更新**（authoritative truth必須接受，唔可以假裝冇發生過），但**唔會**建立`catchUpDebt`、**唔會**強制set/clear`predictionSuspended`、**唔會**彈toast（避免對一個玩家已經放棄咗嘅方向做出視覺修正或者誤導性提示）。`tickMovementFrame`嘅reconciliation gate重構做三分支（suspended：collision/rejected/error，沿用原有strong/hard-reset規則；idle：`idleSettlePosition`；active：`movementDivergence`+`catchUpDebt`嘅ahead/lateral gate）——非suspended觸發嘅reconciliation（太進取或者lateral超額）**永遠只ease，唔hard reset**，只有predictionSuspended（路徑已證實錯咗）先保留hard reset。`earnedPosition`/`movementGeneration`/`catchUpDebt`三個新state，喺同一個frame內、獨立於`predictedPosition`嘅resync分支之外update，確保IN_CITY嗰陣一樣正常累積。Send區塊改用`clampEarnedTarget`代替固定`JOYSTICK_STEP_DISTANCE`嘅`computeJoystickTarget`。
- **不涉及**：`public/asyncqueue.js`（零改動）、API payload shape（依然得`{targetX,targetY}`）、DB schema、joystick UX參數（`JOYSTICK_RADIUS`/`JOYSTICK_DEADZONE`/`JOYSTICK_SEND_INTERVAL_MS`）、`MAX_PREDICTION_LEAD`數值本身（36px不變，改嘅係個check點樣量）、Full Map/城市/戰鬥/市場/旅程邏輯、physical city entry（依然Phase 2）。
- **測試**：
  - `test/world-movement.test.mjs`：teleport-prevention test明確改寫（原本斷言`distance<=60.0001`，改做`distance<=MOVE_SPEED_RATE*MOVE_CATCHUP_CAP_MS`——保護精神不變，只係將flat常數換成elapsed-time-bounded公式，原因已喺test comment同呢個entry講明）；新增短elapsed對照test、400/500/700ms cadence持續catch-up test（證明steady-state throughput貼近`MOVE_SPEED_RATE`，唔再受flat cap clip）、cap boundary test（單command最大grant貼近128.6px）、beyond-cap test（超過`MOVE_CATCHUP_CAP_MS`嘅idle gap唔會攞到更多allowance，證明cap係硬上限）。
  - `test/world-collision.test.mjs`/`test/world-persistence.test.mjs`/`test/world-roads-non-constraining.test.mjs`：既有test嘅`wait()`調整（部份原本假設flat 60px cap喺短wait下都全額granted，而家改用`MOVE_CATCHUP_CAP_MS+100`確保足夠elapsed allowance）——呢啲係timing setup嘅機械性調整，**唔係assertion內容嘅減弱**（斷言本身要驗證嘅collision/road/persistence行為完全不變）；`world-roads-non-constraining.test.mjs`兩個原本假設flat-60px-clamp嘅test（`road -> off-road`、`cross-road`）因為新allowance下請求距離會被full grant而唔再clamp，明確改寫做斷言完整位移（保留「路冇特殊處理」嘅測試意圖）；`MAX_WORLD_STEP movement clamp`test改名做`the elapsed-time movement allowance clamp`，斷言改用`MOVE_SPEED_RATE*MOVE_CATCHUP_CAP_MS`計算出嚟嘅確定值（等夠耐令allowance飽和喺cap，令斷言唔受timing jitter影響）；`world-collision.test.mjs`新增一個長segment collision test，證明`segmentBlocked`喺新allowance下嘅較大距離（>60px，舊cap以上）依然正確保護。
  - `test/movement.test.mjs`：新增`integrateInputPosition`/`movementDivergence`/`catchUpDebtAfterGrant`（連同ahead-only vs Euclidean具體反例）/`nextCatchUpDebt`/`clampEarnedTarget`/`nextEarnedPosition`（連同IN_CITY bootstrap state-independence test）/`idleSettlePosition`（連同5/20/35px收斂test）/`nextGenerationAnchor`（連同0/45/90/180°×D=20/36/54/90 simulation table、漸進方向/magnitude drift、press/release）/`guardStaleGeneration`（用**真正、未改動**嘅`createCoalescingSender`做production-shaped sender test，證明實際network call count分別，唔止數值比較）全套regression test；`advancePredictedPosition`新增directional forward-freeze同lateral bleed-off嘅regression test。
- 測試結果：215（既有，除上面明確列出嘅timing/assertion改動外內容不變）+ 55（新增）= **270 tests passed, 0 failed**。連續run兩次確認timing tolerance冇flaky。
- 存檔影響：無（`world_x`/`world_y`/`state`欄位同格式完全不變）。
- **重要**：完成Coding、merge main只代表engineering測試通過，**唔代表P1-07 PASS**——呢個仲需要Charlie自己真iPhone驗收（stable Wi-Fi／weak Wi-Fi／cellular，各10秒×3次，配合P1-07C telemetry overlay），先可以正式sign off P1-07同進入Phase 1 Gate。
- Rollback基準：`main` @ `96d789ce63bdc9e832130bbbb4d65f9caf0a3f16` / `checkpoint/p1-07d-pre-transport`。

### P1-07D Merge Gate review（修正input-event → next-RAF race，經Charlie喺PR #24發現同批准）

- **問題**：`movementGeneration`/`generationAnchorInput`原本淨係喺`tickMovementFrame`（每個`requestAnimationFrame`一次）入面透過`nextGenerationAnchor`更新，但`joystickInput`本身係喺pointer event handler（`pointermove`/`pointerup`等）**同步**改動嘅。兩者之間有一個真實race window：如果A request in-flight、B已經queue咗做`pending`（generation都係5），玩家喺呢一刻release/轉向/大幅度變magnitude，`joystickInput`即刻改咗,但`movementGeneration`要等下一個RAF先會由5變6——如果A啱啱好喺呢個window（RAF之前）resolve,`createCoalescingSender`嘅`finally`會即刻dequeue同send B,而`guardStaleGeneration`檢查嗰刻見到`B.generation(5)===currentGeneration(5)`（仲未bump），B會被錯誤咁真正send去server，完全違反v4.3/v4.4批准嘅「stale pending必須喺network call之前被drop」設計。
- **修正**：`public/movement.js`新增pure function`applyMovementIntent(state,nextInput)`——純input/output，將`nextGenerationAnchor`嘅判斷、`movementGeneration`嘅bump、`generationAnchorInput`嘅更新同`joystickInput`本身嘅更新合併做**一個原子操作**。`public/app.js`加一個薄嘅同步wrapper（同名`applyMovementIntent`，內部call movement.js嘅pure function並寫返module state），成為**唯一**改動`joystickInput`嘅路徑——`updateJoystickFromEvent`（pointermove/pointerdown）、`setupJoystick`嘅`reset`（pointerup/pointercancel/lostpointercapture）、`toggleMapView`（Full Map強制release）全部經呢一個path,喺event發生嗰一刻**同步**更新generation,唔再等RAF。`refresh()`設`predictionResetPending=true`嗰一行,亦加返同一個「同步即刻bump」（呢個係另一種會取消movement intent嘅path,同樣有race風險）。`tickMovementFrame`嘅generation-bump邏輯完全移除（避免double bump，亦都因為由event handler嗰邊嘅同步更新已經足夠、更正確）。
- 新增7個regression test（`test/movement.test.mjs`）：`applyMovementIntent`本身嘅3個pure-function test（方向改變bump、tremor唔bump、release必bump）；4個**真正race regression test**（Case A release race、Case B方向change race、Case C magnitude change race、Case D micro tremor對照）——全部**唔模擬任何RAF/tick**,input change同A resolve之間完全冇插入一個frame,用返**真正、未改動**嘅`createCoalescingSender`同`guardStaleGeneration`（同production一樣嘅wrapping方式）,用network call count（1 vs 2）證明真正side effect,唔係mock判斷。
- **Comment correction**：`server.mjs`嘅invariant comment入面「a modified client could sustain the same long-run average speed as an honest one...it cannot exceed that average speed」呢句已刪除——呢個係v4.4已經明確撤回嘅overclaim（server本身冇任何機制證明或者bound長期平均速度）。改寫做明確講：single-command burst bound係**唯一**喺度嘅guarantee，冇任何long-run-average-speed guarantee，一個scripted client重複以接近`MOVE_CATCHUP_CAP_MS`嘅間距發command,可以每次都攞盡single-command allowance,呢個加埋落去等於乜嘢,呢份comment**冇**做任何聲稱或者bound。
- 測試結果：270（round前，內容不變）+ 7（新增）= 277 tests passed, 0 failed（連續run兩次確認冇flaky）。
- Changed files：`public/movement.js`、`public/app.js`、`server.mjs`、`test/movement.test.mjs`——冇碰其他file。
- Rollback基準：同上。

### P1-07D Merge Gate review 第二輪（refresh()嘅invalidation仍然遲咗一步；2個文件措辭修正，經Charlie喺PR #24發現同批准）

- **問題**：上一輪修正將`movementGeneration`嘅bump放咗喺`refresh()`入面,但實際位置喺`S.snap=await req(...)`**之後**——即係話hard-resync嘅invalidation要等snapshot request真正resolve咗先發生,唔係`refresh()`一開始就同步失效。Exact race:generation G,A movement request in-flight,B pending喺generation G;呢個時候call`refresh()`,snapshot request開始但未resolve,`movementGeneration`仍然係G;如果A呢個時候resolve,`createCoalescingSender`嘅`finally`會dequeue B,`guardStaleGeneration`見到`B.generation===currentGeneration`（都係G,仲未bump）,B會被錯誝咁真正send去server；之後snapshot先返嚟,generation先變成G+1——太遲。
- **修正**：`public/movement.js`新增pure function`invalidateMovementGeneration(state)`——`applyMovementIntent`嘅hard-resync對應版本,無條件bump generation(唔使anchor比較,因為resync本身就係要令任何之前嘅intent完全失效)。`public/app.js`嘅`refresh()`重寫成:`predictionResetPending=true;invalidateMovementGeneration();`兩句擺晒喺**成個function嘅第一句**,即係喺`S.snap=await req(...)`**之前**——確保hard-resync嘅invalidation喺`refresh()`啱啱開始嗰一刻就已經同步生效,唔使等snapshot response。
- 新增2個regression test:`invalidateMovementGeneration`本身嘅pure-function test;**Race Case E**——完全模擬production嘅實際pattern(`invalidateMovementGeneration()`喺一個未resolve嘅async operation之前call,呢個async operation刻意keep住唔resolve,期間A resolve）,用返**真正**嘅`invalidateMovementGeneration`(唔係手動`currentGeneration++`),證明B都係喺network call之前被drop(`callCount`停喺1)。
- **文件修正**:`server.mjs`嘅invariant comment刪除「reflect the distance genuinely earned during that delay」呢句——「genuinely earned」依然係overclaim(server證明唔到actual held duration),改做純粹描述「a displacement proportional to that delay」，唔再暗示個allowance反映緊「真正賺到」嘅距離。CHANGELOG上一輪嘅「新增8個regression test」數錯咗(實際3個`applyMovementIntent`+4個race case=7,總數270+7=277,同呢個entry其他地方寫嘅277一致)——已經改返做7。
- 測試結果：277（round前）+ 2（新增）= **279 tests passed, 0 failed**（連續run兩次確認冇flaky）。
- Changed files：`public/movement.js`、`public/app.js`、`server.mjs`、`test/movement.test.mjs`、`CHANGELOG.md`——冇碰其他file。
- Rollback基準：同上。

## P2-06 — 2026-09-20 — Bus Persistence / Retry / Reconnect Hardening

- 分類：《萬行誌：白手》Phase 2（GitHub repo `8tdgdvs26d-netizen/project-gersang-mobile`）。目的唔係新增玩法，係證明就算reload、斷線重連、request timeout、重送command、server restart，或者arrival resolution重複執行，巴士旅程都唔會重複扣錢、重複建立旅程、留低stale travel，或者被exploit車費/位置。先經Read-only Audit（列出`server.mjs`嘅`idem()`/`startBus()`/`resolveArrival()`/`snapshot()`實際行為，搵出2個genuine gap）交俾Charlie/ChatGPT review，批准連兩項clarification先至Coding。
- 起點：`main` @ `902773e7c70116e8ef7d41415f1597d3ee13f799`（P2-05 merge之後）。Baseline測試：**322 tests passed, 0 failed**（checkout main後親自跑，同Charlie已知CI結果一致，唔係假設）。
- **Charlie Clarification 1 — activeTravel 唔delete DB row**：`travel`表持久history（`ARRIVED` row永久保留作debug evidence），但`snapshot()`向client回傳嘅`activeTravel`而家**只有`travel.status==='TRAVELING'`先返non-null**，否則`null`——persistent DB history同active client journey分開。
- **Charlie Clarification 2 — test baseline**：Coding前實際`npm test`記錄baseline（322/0），唔假設任何數字。
- **`server.mjs`改動（4項，Charlie逐項批准嘅最小實作）**：
  1. `resolveArrival()`加`t.status!=='TRAVELING'`guard——已ARRIVED嘅journey唔會再被resolve，回傳`ERR_NO_TRAVEL`，唔會產生第二次side effect（之前純粹靠「重複寫入相同數值」嘅巧合安全，而家改做明確state guard）。
  2. `snapshot()`嘅auto-arrival（`resolveDueArrival()`）用SQLite `SAVEPOINT`（`arrival_resolution`）包住travel/characters兩個UPDATE，令TRAVELING→ARRIVED同character TRAVELING→IN_CITY/city_id/world position變成atomic。用SAVEPOINT而唔係`BEGIN IMMEDIATE`，係因為呢個function亦會喺已經開咗`idem()`自己transaction嘅internal caller（`buy`/`sell`/`startBus`/`moveWorld`/`enterCity`/`exitCity`/`moveStorage`）入面被call到——SAVEPOINT可以安全nest入`idem()`嘅transaction（merge埋一齊commit/rollback），亦可以喺top-level GET snapshot（冇外層transaction）獨立運作，滿足「唔可以同`idem()`起nested transaction」嘅要求。
  3. `snapshot()`嘅`activeTravel`改做`t&&t.status==='TRAVELING'?{...}:null`——實現Clarification 1。DB schema／travel table結構完全冇改。
  4. `public/app.js`嘅`updateTravelProgress()`：hero marker更新加`S.snap.state==='TRAVELING'&&S.snap.activeTravel`guard（雙層保護：server唔再暴露completed journey做activeTravel，client亦唔會俾stale/inconsistent data透過travel animation郁到hero position）——修正咗一個已確認bug：舊code冇呢個guard，任何行過至少一程巴士嘅角色，之後每次喺World Map tab都會俾`updateTravelProgress`（每250ms）將hero marker強制拉返去上一程目的地，同`tickMovementFrame`嘅正常render打架。
- **舊test更新（1個，因為Clarification 1令舊assertion過時，唔係weaken）**：`test/battle.test.mjs`「travel blocks challenges and snapshot automatically completes an overdue journey」原本斷言`snap.activeTravel.status==='ARRIVED'`，改做`snap.activeTravel===null`——同一個test仍然驗證緊「arrival自動完成」，只係依照新spec更新返個assertion本身。
- **新增`test/bus-persistence.test.mjs`（16個test）**：涵蓋Charlie要求嘅A-N全部項目——同key重試N次淨扣一次（A）、lost-response retry模擬（B）、已TRAVELING時唔同key攞唔到第二程（C）、旅途中reload journey/ETA/wallet保持一致（D）、reading snapshot多次resolve arrival淨一次、冇duplicate transaction（G）、explicit resolveArrival喺已auto-resolve之後rejected/no-op（H）、arrival後`activeTravel===null`（I）、DB travel row保留status ARRIVED（J）、pending battle settlement擋巴士、0 debit（K）、TRAVELING期間world movement被拒（L）、new session令舊session retry唔到（M）、insufficient funds 0 debit（N），加埋兩個race test（snapshot→explicit / explicit→snapshot兩種次序都收斂去同一個最終state：IN_CITY、正確城市、wallet不變、BUS_FARE count=1、`activeTravel:null`、DB `status='ARRIVED'`），同兩個真正OS-level server restart test（E：旅途中restart journey survive；F：ETA已過但未resolve就restart，第一次post-restart snapshot安全resolve一次），restart pattern直接重用`test/world-persistence.test.mjs`已驗證嘅`spawnServer`/`killAndWaitForRealExit`寫法。
- **不涉及**：城市座標／正方形四角地圖layout（P2-08先處理）、`safeExit`重整、巴士票價、70%時間比例、reroute（依然鎖死）、movement feel（`MAX_PREDICTION_LEAD=50`/prediction/reconciliation/collision/camera，一個字冇改）、economy expansion、DB schema（0改動）、Phase 3。
- 測試結果：322（baseline，內容除上面明確列出嘅1句assertion更新外完全不變）+ 16（新增）= **338 tests passed, 0 failed**。
- 存檔影響：無schema變動；`travel`表既有row結構不變，只係`resolveArrival`/`snapshot`嘅讀寫邏輯更嚴謹。
- Rollback基準：`main` @ `902773e7c70116e8ef7d41415f1597d3ee13f799`。

## P2-07 — 2026-09-20 — City Marker Entry Interaction

- 分類：《萬行誌：白手》Phase 2 physical-device acceptance（P2-07）發現嘅UX問題修正。目的：將「撳城市黃色圓形／城市名」變成正式嘅入城interaction，取代原本喺地圖下面獨立嘅「已抵達：XX城／進入XX城」按鈕；同時修正Follow Screen行路時城市資訊stale嘅問題。
- 起點：`main` @ `67f091f3cd95ab2dc6a889010c146f1712b942c5`（P2-06 merge之後）。Baseline測試：**338 tests passed, 0 failed**（checkout main後親自跑，唔假設數字）。
- 先做Read-only Audit先批准coding：追蹤到stale-city bug嘅精確root cause——`travelStatusHtml()`（獨立按鈕嘅來源）淨係喺`render()`重建成個`#app` innerHTML嗰陣先重新計算，但玩家行路時`sendWorldMove`嘅ACCEPTED response（`app.js`）淨係update`S.snap.worldPosition`，從來冇call`render()`；`tickMovementFrame`每幀都跑,但淨係直接patch hero marker/camera/telemetry嘅DOM attribute,冇touch過`travelStatusHtml`所在嗰嚿DOM。切去Full Map「睇落work」純粹係`toggleMapView()`尾段啱啱好call咗一次`render()`嘅side effect,唔係Full Map有咩專門嘅live-refresh機制。
- **`public/worldmap.js`改動**：
  - `chooseTravelAction(snapshot,targetCityId,cities)`加返一個新分支——`snapshot.state==='IN_WORLD'`且`isWithinCityEntry(snapshot.worldPosition,cities.find(c=>c.id===targetCityId))`（同server.mjs嘅`enterCity()`一模一樣嘅公式，`public/cities.js`shared primitive）為true時，return`'enter'`；`'start'`/`'reroute'`繼續永遠唔會被return（P2-05鎖死原封不動）。
  - `handleCityTap(cityId,{snap,cities,travel,reroute,enter})`加`action==='enter'`分支，call`enter(cityId)`。
  - `travelStatusHtml()`移除咗IN_WORLD-near-city嗰個分支（「已抵達：XX城」+`data-enter-city`按鈕），冇replacement text/button——city marker本身（SVG入面嘅`<g data-city>`）就係新嘅入城interaction。`cityEntryCandidate()`保留export（仲有自己嘅pure-function test），只係唔再喺呢度被call。
- **`public/app.js`改動**：`wire()`嗰句`[data-city]`嘅handler改傳`cities:S.cities`同`enter:enterCity`落去`handleCityTap`；移除咗依家已經冇對應button嘅`[data-enter-city]`wiring（dead code cleanup，唔屬於獨立重構——係直接跟住`travelStatusHtml`嗰個button被移除嘅結果）。
- **點解可以喺唔加`render()`嘅情況下解決stale-city問題**：`wire()`嘅`el.onclick=()=>handleCityTap(el.dataset.city,{snap:S.snap,...})`係一個arrow function,`S.snap`喺**撳落去嗰一刻**先讀,唔係喺`wire()`執行嗰刻捕獲——`S.snap.worldPosition`本身一直都俾`sendWorldMove`嘅response keep住即時更新,所以撳marker嗰一刻攞到嘅一定係最新資料,完全唔需要為咗呢個interaction而喺movement loop（`tickMovementFrame`/`sendWorldMove`）加任何`render()`或者periodic full DOM rebuild。
- **不涉及**：`server.mjs`嘅`enterCity()`邏輯（一個字冇改，繼續係authoritative嘅唯一驗證來源）、DB schema、城市座標、`entryRadius`、`safeExit`、巴士票價/時長/persistence邏輯、reroute lock、movement speed/`MAX_PREDICTION_LEAD`/prediction/reconciliation/`moveSequence`/collision/camera/joystick行為、地圖layout（正方形四角redesign留返P2-08）。
- **Tests**：
  - `test/worldmap.test.mjs`：更新原有兩個`handleCityTap`test（IN_CITY／TRAVELING撳城市marker）多加`enter`callback嘅斷言；新增7個P2-07 requirement test——IN_WORLD入radius內撳中該城市準確入城一次、圓形同城市名共用同一個`[data-city]`節點、撳隔籬城唔會入錯城、離晒所有城市撳邊個都冇反應、Follow/Full Map兩邊用**同一個**唔理`mapView`嘅pure function（結構上證明咗規則一致，唔使分開實作）、**stale-city regression test**（唔render、純粹update`snap.worldPosition`模擬「行咗去City B」,再撳City B marker,證明入到——直接對應真機見到嗰個bug嘅scenario）、確認`data-enter-city`／「已抵達」呢啲字眼完全冇再出現。
  - `test/city-entry.test.mjs`：原本斷言`data-enter-city`一定要存在嗰個test拆做兩個——`cityEntryCandidate`純function嘅行為（保留，佢依然有效，只係冇再駁落button）；同一個新test明確斷言`data-enter-city`喺近/遠任何情況下都唔再出現。其餘全部server-side test（enter/exit/idempotency/pending-loot/remote-entry-rejection）**完全冇改**，因為`server.mjs`一個字都冇動過。
- 測試結果：338（baseline，內容除上面明確列出嘅2個既有test更新外完全不變）+ 8（新增，7個喺worldmap.test.mjs＋1個喺city-entry.test.mjs因拆分test淨增加嘅一個）= **346 tests passed, 0 failed**。
- 存檔影響：無。
- Rollback基準：`main` @ `67f091f3cd95ab2dc6a889010c146f1712b942c5`。

## P2-07 City Hub Navigation — 2026-09-20 — City Hub 成為 IN_CITY 嘅預設畫面

- 分類：Charlie真機驗收P2-07 marker entry之後發現嘅更闊UX問題修正。P2-07（上一節）只解決咗「點樣入城」（marker取代舊button），但入城之後嘅畫面仍然係World Map+獨立、client-only嘅「進入城市」button（`data-enter-hub`），要再撳多一步先睇到City Hub——同marker取代嘅嗰個button係完全唔同嘅code path，P2-07嗰次審批冇涵蓋。先做read-only「P2-07 City Hub / World Navigation Architecture Audit」（逐一trace `S.tab`／server `state`／`refresh()`／`enterCity`／`exitCity`／`travelStatusHtml`／`canEnterCityHub`嘅實際行為），確認根本原因：`S.tab`（client-only導航變數，預設`'map'`）同server嘅`state`完全冇綁定，冇任何自動路徑會喺轉入`IN_CITY`嗰刻將`S.tab`設做`'hub'`。交俾Charlie/ChatGPT review，批准落實。
- 起點：`main` @ `fe552e2e96ef150570119c1d02eb80f89dc08ec1`（P2-07 marker entry merge之後）。Baseline測試：**346 tests passed, 0 failed**（checkout main後親自跑，唔假設數字）。
- **權威UX規則**：`IN_CITY`代表角色已經physically喺城入面，所以**City Hub係IN_CITY嘅預設／主要畫面**，唔應該再存在「IN_CITY → World Map →「進入城市」→ City Hub」呢條多餘流程。
- **`public/worldmap.js`改動**：
  - 新增純function `shouldShowCityHubOnStateChange(previousState,nextState)`——`previousState!=='IN_CITY'&&nextState==='IN_CITY'`先至`true`。淨係喺「啱啱轉入IN_CITY」嗰個edge先觸發，`IN_CITY→IN_CITY`嘅普通refresh（買賣、入倉、睇巴士報價）唔會被強制拉返去hub。
  - `travelStatusHtml()`嘅IN_CITY分支由「目前所在：XX城」+`data-enter-hub`「進入城市」button，改做「XX城 · 地圖查看中」+`data-back-hub`「返回City Hub」button——冇晒「進入城市」字眼／`data-enter-hub`；由於呢個分支而家淨係經由City Hub主動撳「查看地圖」先會睇到（唔再係IN_CITY嘅預設畫面），語意上係「已經喺城入面，睇緊地圖」，唔係「未入到城」。
  - `cityHubEntries()`／`renderCityHubHtml()`加多一粒常駐tile「查看地圖」（`action:'view-map'`，`data-view-map`），純client-side，同「離開城市」tile分開，一定`available:true`。
- **`public/app.js`改動**：
  - `refresh()`喺attach新snapshot之前，用`const previousState=S.snap?.state`記低轉變前個值；攞到新snapshot之後，`if(shouldShowCityHubOnStateChange(previousState,S.snap.state))S.tab='hub'`——涵蓋初始load（`S.snap`起始為`null`）、marker入城（IN_WORLD→IN_CITY）、巴士到埗（TRAVELING→IN_CITY，包括`resolveDueArrival()`喺reload嗰刻先自動resolve嘅情況）、reload時authoritative snapshot已經係IN_CITY，四種情況都會直接落hub；已有嘅`battle`auto-tab-switch邏輯喺呢句之後執行，優先權不變。
  - `wire()`移除咗已經冇對應button嘅`[data-enter-hub]`wiring（dead code，跟住`travelStatusHtml`個button被移除嘅結果）；加`[data-view-map]`wiring（`S.tab='map';render()`，純client tab flip，冇任何server call）。
  - **清理`data-hub-leave`嘅雙重綁定**：Audit發現咗一個pre-existing、同今次主要問題獨立嘅code smell——`wire()`同一個`[data-hub-leave]`element綁咗兩次click handler（一個`addEventListener`純tab flip、一個`.onclick=exitCity`真正server exit call），撳一下會觸發兩個handler（功能上冇壞，但多咗一次冗餘中途render）。而家移除咗嗰個冗餘`addEventListener`，`data-hub-leave`淨低`.onclick=exitCity`一個handler。
- **點解World Map可以留低做IN_CITY嘅optional inspection，而唔會變返Charlie明確拒絕嘅「World Map係去City Hub必經之路」（Option B）**：`resolveMapViewBox`／`resolveEffectiveViewBox`（`worldmap.js`，一個字冇改）早已令IN_CITY睇地圖鎖定full-world viewBox（唔follow camera）；joystick亦早已因為`state!=='IN_WORLD'`而disabled（`worldmap.js`，一個字冇改）——「淨睇唔可以郁」呢個特性本身已經現成、已有test覆蓋，今次淨係加咗「點樣入去嗰個畫面」（由City Hub主動撳「查看地圖」）同「點樣返去」（`data-back-hub`，同market/storage/bus用緊嗰個機制一致）嘅client-only路徑，冇新增任何假裝已經離開城市嘅邏輯，state全程維持`IN_CITY`。
- **不涉及**：`server.mjs`（一個字冇改，`enterCity`/`exitCity`/`snapshot`/`resolveDueArrival`嘅server-side驗證同語意完全不變）、DB schema、`movement.js`、`MAX_PREDICTION_LEAD`、`moveSequence`、prediction/reconciliation、collision、camera數學、城市座標、`entryRadius`、`safeExit`、巴士票價/車程/persistence/reroute lock、地圖layout（P2-08）。
- **既有test更新（1個，因為新tile令舊assertion過時，唔係weaken）**：`test/worldmap.test.mjs`「cityHubEntries returns two city services, a universal bus stop, four unavailable tiles, and leave」原本斷言`entries.length===8`／`available&&action!=='leave'`嘅數量`===3`，因為新加咗常駐`view-map`tile，改做`entries.length===9`／`===4`，並加多一句斷言`view-map`tile存在剛好一次；`unavailable`／`leave`數量嘅斷言完全不變。
- **新增test（13個，全部喺`test/worldmap.test.mjs`）**：`shouldShowCityHubOnStateChange`純function覆蓋要求1-7、18（未有snapshot／IN_WORLD／TRAVELING轉入IN_CITY一律`true`；IN_CITY→IN_CITY、IN_CITY→IN_WORLD、IN_WORLD→IN_WORLD、TRAVELING→TRAVELING一律`false`）；`cityHubEntries`／`renderCityHubHtml`包含`查看地圖`tile同`data-view-map`hook；IN_CITY嘅`renderWorldMapHtml`確認`data-enter-hub`／「進入城市」完全冇再出現、確認`data-back-hub`／「返回City Hub」存在、joystick依然disabled（沿用已有斷言模式）；兩個source-level regression test直接讀`public/app.js`源碼——確認`[data-hub-leave]`selector淨係出現一次（鎖住雙重綁定嘅fix，防止回歸）、確認`data-view-map`嘅handler係純client tab switch（冇`command(`/`post(`/`fetch(`/`await`）而且`data-enter-hub`完全冇留低任何痕跡。
- **Marker entry／remote entry／bus persistence全部保持不變**：`handleCityTap`／`chooseTravelAction`／`enterCity`／`exitCity`／`server.mjs`一個字冇改，`test/city-entry.test.mjs`同`test/bus-persistence.test.mjs`原封不動，全部繼續喺完整suite入面green。
- 測試結果：346（baseline，內容除上面明確列出嘅1句assertion更新外完全不變）+ 13（新增）= **359 tests passed, 0 failed**。
- 存檔影響：無。
- Rollback基準：`main` @ `fe552e2e96ef150570119c1d02eb80f89dc08ec1`。

## Phase 2 Closeout — 2026-09-21 — Health Metadata 更新（Issue #30 Gate PASS 後嘅純文件收尾）

- 分類：Phase 2「四城實體進出及坐車交通」（Issue #30）已經由Charlie完成完整真iPhone驗收（四城進出、離城、坐車、reload全部PASS），Phase 2 Final Gate = PASS。落實checkpoint／backup之前，先修正一個Gate audit發現嘅遺留metadata缺口：`/api/health`嘅`phase`欄位由Phase 2開發期間一直冇更新，仍然寫住Phase 1嘅字眼。呢個純粹係文件/metadata修正，**唔改任何gameplay行為**。
- 起點：`main` @ `3c8b941ba24fea8a041b39a959ae138aafa632f7`（P2-07 City Hub Navigation merge之後）。Baseline測試：**359 tests passed, 0 failed**（checkout main後親自跑，唔假設數字）。
- **`server.mjs`改動**：`/api/health`嘅`phase`欄位由`'Phase 1 Free World Movement'`改做`'Phase 2 Four-City Entry & Bus Transport'`；`version`欄位（`'0.32.0'`）不變。除呢一個字串常數之外，`/api/health`嘅其他部分（`ok:true`、路由本身）同成個`api()`函數嘅其餘部分完全冇改。
- **`test/health.test.mjs`改動**：對應斷言由`assert.equal(body.phase,'Phase 1 Free World Movement')`改做`assert.equal(body.phase,'Phase 2 Four-City Entry & Bus Transport')`——同步更新，唔係weaken，斷言驗證嘅嘢（health endpoint正確回報phase）完全不變。
- **不涉及**：movement、joystick、camera、collision、cities、城市座標、entry/exit邏輯、巴士/交通邏輯、economy、DB schema、地圖layout（正方形四角redesign留返之後）、任何Phase 3+功能。`git diff --stat`確認呢次改動範圍僅限`server.mjs`（1行）、`test/health.test.mjs`（1行）、`CHANGELOG.md`。
- 測試結果：359（baseline，內容除上面明確列出嘅1句assertion更新外完全不變）= **359 tests passed, 0 failed**（呢次冇新增test，純粹更新現有斷言嘅期望值）。
- 存檔影響：無。
- Rollback基準：`main` @ `3c8b941ba24fea8a041b39a959ae138aafa632f7`。

## P4-02 — 2026-09-21 — First World Monster → Encounter → Battle Handoff

- 分類：《萬行誌：白手》Phase 4（World Monster & Encounter）第一個垂直切片。先做咗一個read-only嘅「P4-01 World Monster & Encounter Impact Audit」（確認咗世界入面完全未有任何monster/encounter概念、`moveWorld()`係唯一authoritative移動入口、`segmentBlocked()`係目前唯一嘅碰撞系統、`startBattle()`從來冇改過`characters.state`），交俾GPT Review批准之後先落實今次呢個P4-02 Coding Order：一隻固定世界怪物（`world-bandit-1`／「遊蕩山賊」）、行到佢個範圍會觸發現有`bandit-patrol`戰鬥、消耗一次性、唔respawn。**明確唔做**：AI／巡邏、loot table、稀有度/陣營/boss邏輯、程序生成、天氣、aggro樹、怪物經濟、數值scaling——呢啲全部留返之後嘅Phase 4任務。
- 起點：`main` @ `03cde3a869a06463c4d03124a3a7fd50c3e932d5`（Phase 3收尾PR #53 merge之後）。Baseline測試：**381 tests passed, 0 failed**（checkout main後親自跑，唔假設數字）。
- **新增 `public/worldmonsters.js`**：`WORLD_MONSTER_DEFINITIONS`（frozen array，跟`public/cities.js`一模一樣嘅pattern），目前只有一隻`world-bandit-1`（等級1、位置`{x:500,y:220}`、`encounterRadius:40`、連去現有`bandit-patrol`戰鬥模板、`active:true`）；`segmentEntersEncounterRadius(fromPosition,toPosition,monster)`——標準嘅swept-circle（closest-point-on-segment）檢測，唔係淨係check終點距離：單一次accepted移動有可能由範圍外行入再行返出範圍外（tunnelling），淨check終點會漏咗呢種情況。DOM-free，server.mjs（Node）同瀏覽器client共用同一份，永遠唔會drift。
- **`server.mjs`改動**：
  - 新增additive schema `world_monster_encounters(character_id,monster_id,battle_id,triggered_at)`，`PRIMARY KEY(character_id,monster_id)`——呢條primary key本身就係「淨可以消耗一次」嘅唯一保證，唔需要respawn timestamp或者spawn scheduler。
  - 新增`battleIsActive(characterId)`（同現有`pendingLootSettlement()`一樣嘅shape，check緊`battles.status='ACTIVE'`）同`availableWorldMonsters(characterId)`（回傳仲未消耗嘅怪物，`encounterId`刻意唔包含喺俾client嘅shape入面，防止client自己諗個`encounterId`出嚟trigger戰鬥）。`snapshot()`加多一個additive欄位`worldMonsters`。
  - 將原本`startBattle()`入面實際起battle/battle_meta/battle_units/formation/mobility嘅邏輯抽出成`createBattleCore(encounter,requested,deployments)`——一個純internal、冇route、冇`idem()`嘅primitive，行為同原本一模一樣。`startBattle()`本身嘅`IN_CITY`precondition、team/deployment驗證**完全冇改**，只係將起battle嗰段call返`createBattleCore()`；**刻意冇**將precondition鬆做`IN_CITY||IN_WORLD`（Coding Order明確指出呢個係exploitable backdoor）。世界怪物嗰邊由`moveWorld()`直接call`createBattleCore()`，用固定嘅預設隊伍（hero/archer/guard，同`startBattle()`冇supply deployments時一樣嘅default），**冇**開新嘅public route俾client自己指定`monsterId`/`encounterId`。
  - `moveWorld()`：喺原有`characters.world_x/world_y`嘅UPDATE之後，用accepted嘅移動線段（`current → {nextX,nextY}`，**唔係**原本request嘅target）check`segmentEntersEncounterRadius`——呢個設計本身已經確保咗「被牆擋咗嘅移動唔會憑住個被拒絕嘅original target觸發encounter」，因為collided嘅移動`nextX/nextY===current`，變成一個zero-length segment，淨係做緊current position嘅point check。撞到就攞`createBattleCore()`起battle，`INSERT OR IGNORE`寫一行`world_monster_encounters`（exactly-once保證），成個過程同position update一齊喺`moveWorld()`原有嗰個`idem()`transaction入面，一Atomic commit or rollback，冇nested`idem()`，冇額外`SAVEPOINT`。ACCEPTED response additive加`encounterTriggered`/`battleId`/`monsterId`。
  - 加咗`battleIsActive()`guard去`moveWorld()`（ACTIVE戰鬥期間world movement完全鎖死，position原封不動）同`enterCity()`（防止玩家用「入城」逃走一場世界觸發嘅戰鬥——因為世界encounter完全唔會改`characters.state`，`state`會一直留喺`IN_WORLD`，冇呢個guard就可以喺打緊嘅時候直接入城）。兩個都係新增`ERR_BATTLE_ACTIVE`錯誤碼。明確**冇**擴去`buy`/`sell`/`startBus`/`exitCity`/storage/equipment等其他IN_CITY指令——呢啲pre-existing嘅active-battle硬化缺口記做技術債，唔喺呢次scope之內。
- **`public/worldmap.js`改動**：`renderWorldMapHtml()`加咗一個新嘅`.map-monster`／`[data-monster]`marker，源頭淨係嚟自`state.snap.worldMonsters`（server已經filter好嘅「仲有效」清單）——怪物俾人消耗之後淨係喺下次snapshot refresh先會消失，唔存在任何client-local嘅移除邏輯。原型級美術（一個紅色圓形+名），冇動畫，冇aggro range視覺化。
- **`public/app.js`改動**：`sendWorldMove()`response handling加一句——如果`r.data.encounterTriggered`，就即刻`predictionSuspended=true`並`await refresh()`，唔理呢個generation係咪`stale`（battle已經真係起咗，同generation staleness冇關係）；重用現有`refresh()`入面已經有嘅`battle?.status==='ACTIVE'`auto-tab-switch機制，**冇**喺client自己重新砌一份battle state。
- **`public/styles.css`改動**：加`.map-monster`嘅circle/text樣式（紅色圓形），對齊現有`.map-city`/`hero-marker`樣式pattern。
- **不涉及**：`public/movement.js`（`MOVEMENT_MIN_INTERVAL_MS`、`MOVE_SPEED_RATE`、`MOVE_CATCHUP_CAP_MS`一個字冇改）、`public/worldgeometry.js`（碰撞常數/障礙物幾何原封不動）、`public/cities.js`（城市座標/entry radius冇改）、`public/bus.js`、`public/goods.js`、`public/marketpricing.js`、任何戰鬥傷害/速度/技能/獎勵數值、DB schema以外嘅其他table。
- **新增`test/world-encounter.test.mjs`（10個新test，覆蓋Coding Order嘅P4-02-A至P4-02-K）**：data contract shape（A）、trigger之前snapshot列出怪物、`encounterId`刻意唔俾client（B）、segment完全喺範圍外唔trigger、怪物依然available（C）、segment tunnel穿過範圍**一定**trigger、exactly one ACTIVE battle、exactly one`world_monster_encounters`row、trigger完怪物即刻由`worldMonsters`清單消失（D/E）、ACTIVE battle期間world movement鎖死、position原封不動（F）、ACTIVE battle期間city/enter一樣被擋，即使位置本身符合入城條件（G）、同一個idempotencyKey重試唔會起第二場戰鬥，唔同key嘅重試同樣唔會（H）、**喺battle仍然ACTIVE、`characters.state`仍然`IN_WORLD`嗰陣**（撤退之前）重複snapshot/battle讀取完全穩定——battle id唔變、冇第二場battle、冇第二條`world_monster_encounters`row、position唔變（I，GPT Review round 1修正：原本I測試緊嘅係RETREATED之後嘅穩定性，唔係Coding Order要求嘅ACTIVE-battle reload/reconnect穩定性，而家I改咗做喺K撤退之前執行，先至真係驗證緊嗰個invariant）、撤退之後ACTIVE battle結束，world movement解鎖返（K）、現有嘅manual`/battle/start`路線完全冇變——IN_CITY一樣work，IN_WORLD一樣`ERR_INVALID_STATE`（J，直接證明冇偷偷將precondition鬆做`IN_CITY||IN_WORLD`）。
- **Playwright真瀏覽器smoke test**（喺呢個sandbox環境入面用真server+真headless Chromium做嘅，唔係產品Render，亦唔係Charlie嘅真iPhone驗收）：確認咗Full Map畫面真係render到個紅色「遊蕩山賊」marker、用真實HTTP command觸發encounter之後reload page真係自動彈去Battle tab、3v3單位正確顯示。發現一個同呢次改動完全無關嘅pre-existing cosmetic 404（瀏覽器自動attempt攞`/favicon.ico`，`index.html`本身從來冇declare過favicon）——唔屬於P4-02嘅regression，如實記錄喺度。
- 測試結果：381（baseline，內容完全不變）+ 10（新增）= **391 tests passed, 0 failed**。
- 存檔影響：新增一張additive table（`world_monster_encounters`），冇改動任何現有table嘅結構；`characters`表一個字冇改。
- Rollback基準：`main` @ `03cde3a869a06463c4d03124a3a7fd50c3e932d5`。
