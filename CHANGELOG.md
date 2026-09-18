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
