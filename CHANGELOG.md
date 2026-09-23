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
- **PR #54 Merge Gate Race Fix（Codex Review發現嘅P1 race condition，client-only修正，`server.mjs`一個字冇改）**：連續world movement時，兩個`/world/move`請求嘅response有機會亂序完成——例如request A真正觸發encounter（response帶`encounterTriggered:true`），稍後嘅request B撞落`battleIsActive()`guard攞`ERR_BATTLE_ACTIVE`但response**先**返到，而`public/app.js`原有嘅completion-order guard（`requestSequence<latestCompletedMovementSequence`）會將之後先返到、但實際上正確嘅A response當做stale嘢discard咗，令client卡喺World Map，要reload先睇到已經ACTIVE嘅battle。修正：喺`sendWorldMove()`入面新增一個純、DOM/network-free嘅`export function battleAlreadyActiveFromMoveResponse(r)`（`ACCEPTED`睇`r.data.encounterTriggered===true`，`REJECTED`睇`r.errorCode==='ERR_BATTLE_ACTIVE'`），呢個check擺喺completion-order discard**之前**執行，唔理`stale`——只要任何一個response話server已經有ACTIVE battle，就即刻`predictionSuspended=true`加`await refresh()`（重用現有`refresh()`嘅battle auto-tab-switch，唔喺client自己砌battle state），令client最終一定收斂去正確畫面，唔理兩個response嘅完成次序。連帶將`boot()`嗰句用`if(typeof document!=='undefined')`包住——純粹係令`public/app.js`可以喺Node被`import`嚟testing用（`document`喺任何真瀏覽器一定存在，行為對玩家完全冇變），唔屬於movement/battle邏輯改動。新增`test/world-encounter-client-race.test.mjs`（4個新test）：`battleAlreadyActiveFromMoveResponse`對所有response shape嘅分類、**P4-02-M**（encounter completion reorder——兩個response order對調，斷言都會force resync，仲有source-level structural check確認個gate實際上寫喺discard之前、分支入面`predictionSuspended`/`refresh()`冇俾`stale`卡住）、**P4-02-N**（單獨一個`ERR_BATTLE_ACTIVE`、冇見過原本trigger response嘅lost-response情況，一樣force resync）、同一個regression guard確認普通REJECTED（`describeWorldMoveError`）同普通stale ACCEPTED（`shouldSuspendAfterAccepted`/`catchUpDebtAfterGrant`）呢兩段完全原封不動。測試結果：391（baseline，內容完全不變）+ 4（新增）= **395 tests passed, 0 failed**（原本P4-02-A至K全部重新跑過，10個一樣PASS）。
- **PR #54 Final Merge Gate Fix（同一個completion-order invariant嘅尾位，client-only，`server.mjs`一個字冇改）**：上面嗰個race fix入面嘅`battleAlreadyActiveFromMoveResponse`分支雖然啱咗resync battle嘅邏輯，但**冇同步advance`latestCompletedMovementSequence`呢個completion watermark**——即係話：如果有一個更舊、已經inflight嘅普通request C（冇觸發encounter），佢個response之後先姍姍來遲，有機會用C自己個舊`sequence`同一個未更新嘅watermark比較，繼續通過completion-order discard，將C嘅舊`worldPosition`/`predictionSuspended`/catch-up debt再次蓋過已經正確resync咗嘅battle畫面。修正：喺`battleAlreadyActiveFromMoveResponse(r)`嗰個分支入面，加一句`latestCompletedMovementSequence=Math.max(latestCompletedMovementSequence,requestSequence);`（喺`predictionSuspended`/`refresh()`之前），用`Math.max`確保watermark永遠唔會倒退。新增`test/world-encounter-client-race.test.mjs`嘅**P4-02-O**：完整模擬review描述嘅次序（C最舊、A觸發encounter、B撞`ERR_BATTLE_ACTIVE`——B先完成、A第二、C最後先完成），用真正嘅`battleAlreadyActiveFromMoveResponse`同sendWorldMove自己嗰句discard expression，斷言C最終一定俾discard咗；仲有source-level structural check確認個`Math.max`真係寫喺個分支入面、喺`return`之前。測試結果：395（上一round，內容完全不變）+ 1（新增）= **396 tests passed, 0 failed**（movement stale-generation tests、world-encounter A-K、client race M/N全部重新跑過都PASS）。
- Rollback基準：`main` @ `03cde3a869a06463c4d03124a3a7fd50c3e932d5`。

## P4-03A — 2026-09-22 — Deterministic World Monster Patrol

- 分類：《萬行誌：白手》Phase 4 P4-03A。先做咗一個read-only「P4-03 World Monster Behaviour Audit」（追蹤咗repo入面已有嘅Battle/Travel/Market三個「lazy elapsed-time-driven state advance」pattern——全部冇background server timer，淨係喺相關request嗰陣先用DB timestamp/watermark追落去），確認咗patrol唔需要background timer，亦唔需要新DB state（因為patrol position可以係一個純time-only formula，reload/restart完全唔受影響）。GPT Review批准咗最細嘅P4-03A切片：淨係做deterministic two-point patrol，**唔做**Monster主動撞企定玩家（留返P4-03B）。
- 起點：`main` @ `c69b9556b6b2a222abfe35976f4f36b9da666109`（PR #54 merge之後）。Baseline測試：**396 tests passed, 0 failed**（checkout main後親自跑，唔假設數字）。
- **`public/worldmonsters.js`改動**：`world-bandit-1`嘅單一static`position:{x:500,y:220}`欄位改做`patrolA:{x:460,y:220}`／`patrolB:{x:540,y:220}`／`patrolSpeed:0.02`（px/ms，80px一程4秒、一個完整來回8秒）／`patrolAnchorAt:0`（content常數，唔係runtime timestamp）——midpoint((460,220),(540,220))正正等於原本嘅(500,220)，保持喺同一個位置附近。新增`patrolPositionAt(monster,timeMs)`：純function、deterministic嘅A↔B三角波（triangle wave），冇random、冇pathfinding、冇mutable state、冇DB/DOM access——同一個(monster,timeMs)輸入永遠得出同一個輸出，喺Node（server.mjs）同瀏覽器（client cosmetic render）用嗰個一模一樣。有zero-length patrol、負數modulo、invalid speed嘅defensive fallback。Patrol路線經自動化data validation（`test/world-monster-patrol.test.mjs`嘅P4-03A-C/D）確認：全程喺`WORLD_BOUNDS`之內、同兩個現有obstacle（`ridge-a`/`ridge-b`）完全冇intersect、離四個城市entry radius最近都仲有240px（radius淨係48px）——唔係憑肉眼，真係跑program驗證。
- **`server.mjs`改動**：`availableWorldMonsters(characterId,now)`加咗`now`參數，`position`欄位由static`m.position`改做`patrolPositionAt(m,now)`。`snapshot()`加咗一句`const now=Date.now()`（成個function淨係呢一句，之後成個function都reuse呢個值，包括新增嘅additive`serverNowMs`欄位），俾`availableWorldMonsters(c.id,now)`同`serverNowMs:now`共用同一個時間點。`moveWorld()`嘅encounter check由`segmentEntersEncounterRadius(current,{nextX,nextY},m)`改做`segmentEntersEncounterRadius(current,{nextX,nextY},{...m,position:patrolPositionAt(m,now)})`——**reuse咗moveWorld()原有嗰句`const now=Date.now()`（movement allowance計算嗰句），冇喺encounter check入面再call多次`Date.now()`**，保證同一次判定用緊同一個時間點。`segmentEntersEncounterRadius()`本身（P4-02已有嘅swept-circle primitive）一個字冇改——圓心點計、check邏輯本身完全reuse。
- **`public/worldmap.js`：一個字冇改**——`renderWorldMapHtml()`嘅monster marker本身已經係generic咁讀`m.position.x/y`，而`m.position`而家已經係server算好嘅dynamic truth，client render code完全唔使跟住改。
- **`public/app.js`改動**：新增`export function computeServerTimeOffset(serverNowMs,clientNowMs)`（純calculation：`serverNowMs-clientNowMs`），`refresh()`每次攞到新snapshot就用呢個function更新`serverTimeOffset`——特登唔假設玩家部機個clock同server差極有限（唔淨係network latency嗰種幾百ms,手機clock理論上可以完全唔啱），只用嚟做cosmetic patrol interpolation，唔涉及任何game logic決定。`tickMovementFrame`（現有rAF loop）加咗一段monster marker patch——擺喺`if(!S.snap||S.snap.state!=='IN_WORLD')return;`個guard**之前**，因為IN_CITY都可以睇緊World Map（P2-07嘅「查看地圖」），patrol animation同player movement state冇關係；淨係`S.tab==='map'`先郁，淨係patch`S.snap.worldMonsters`（server已經filter好嘅「仲存在」清單）入面現存嘅monster，用`WORLD_MONSTER_DEFINITIONS.find(...)`攞返patrol參數再call`patrolPositionAt(definition,Date.now()+serverTimeOffset)`計cosmetic position——**冇新增任何network request，冇full`render()`**。Client刻意唔可以用自己算出嚟嘅position去開battle/consume monster/決定encounter/送encounterId或monster position俾server——呢啲全部繼續100% server-authoritative，client嘅formula純粹presentation。
- **不涉及**：DB schema（一個字冇改，patrol position係derived state，`world_monster_encounters`繼續係唯一persistent mutable monster state）、`public/movement.js`、`public/worldgeometry.js`（`segmentBlocked`/`PLAYER_COLLISION_RADIUS`/obstacle幾何一個字冇改——patrol唔用runtime collision，改用content-level static驗證test）、`public/cities.js`、`public/bus.js`、`public/goods.js`、`public/marketpricing.js`、戰鬥傷害/技能/速度/獎勵、movement/camera常數、城市座標、one-shot encounter ledger schema。**冇**server`setInterval`/`setTimeout`simulation loop、**冇**WebSocket、**冇**pathfinding/navmesh。Monster主動撞企定玩家（active stationary encounter）、World Map server polling、aggro、chase、leash、monster behaviour DB state全部**明確唔做**，留返P4-03B/C。
- **新增`test/world-monster-patrol.test.mjs`（9個新test，覆蓋P4-03A-A至I；J/K/L係regression gate，唔係呢個file入面嘅獨立test）**：deterministic formula（A）、triangle wave A→midpoint→B→midpoint→A（B）、全程喺`WORLD_BOUNDS`之內（C）、同obstacle/城市entry radius有安全margin，automated data validation（D）、snapshot兩次讀取（唔同已知`serverNowMs`）都同真正shared formula吻合，唔靠real sleep估估吓（E）、`computeServerTimeOffset`喺client clock刻意偏差幾個鐘之下仍然準確重構返server time（F）、喺monster仍然active嗰陣，一個喺patrol reachable範圍以外嘅固定點唔會誤觸發——特登**唔用**time-shift嘅「舊位置」做decoy（設計呢條test嗰陣用程式驗證咗：對呢種two-point reflecting patrol,**任何**固定嘅real-time shift都一定存在一個起始phase令個shifted position同current position完全重合,所以time-shift decoy本質上唔可靠,必須用空間上monster patrol路線範圍以外嘅點）（H）、撞入monster live patrol position exactly one battle+one consumption row（G）、consume咗之後snapshot唔再出現，加一個source-level structural test確認client個patch loop係每幀讀live`S.snap.worldMonsters`,冇任何cached list可以「復活」個monster（I）。
- **既有test更新（因為P4-03A令`snapshot()`嘅`worldMonsters[].position`同`serverNowMs`變成time-varying，唔係weaken任何assertion）**：
  - `test/world-encounter.test.mjs`：P4-02-A由斷言static`position:{x:500,y:220}`改做斷言`patrolA`/`patrolB`/`patrolSpeed`/`patrolAnchorAt`（其餘id/level/encounterId/encounterRadius/active/frozen斷言完全不變）；P4-02-B嘅`position`斷言由hardcode常數改做同`patrolPositionAt(WORLD_MONSTER_DEFINITIONS[0],snap.serverNowMs)`直接cross-check；P4-02-D/E由hardcode`(450,200)→(550,200)`改做先GET live monster position先再喺live position附近構造segment（同新slice嘅P4-03A-G/H用返完全同一個手法），trigger用嘅payload由hardcode常數變做動態變量`triggerMovePayload`，P4-02-H跟住改用返同一個變量做idempotency retry測試（唔係weaken retry測試本身，淨係令個payload同D/E實際送出嗰個一致）。
  - `test/phase3-economy-consistency.test.mjs`（Phase 3既有test，唔屬於P4-03A原本required files，但係新增嘅`serverNowMs`/dynamic`worldMonsters[].position`直接令佢兩句`assert.deepEqual(await snapshot(),afterBuy/after)`——測緊「idempotent retry對snapshot完全冇額外影響」——失敗，因為呢兩個新欄位本身就係time-varying，同retry idempotency呢個invariant完全無關）：加咗`omitVolatileSnapshotFields()`,喺嗰兩句deepEqual比較之前剔走`serverNowMs`同`worldMonsters`先比較，其餘全部wallet/cargo/market/economy_tx/item_trace嘅conservation斷言（真正嘅Phase 3 economy invariant）一個字冇改。
- 測試結果：396（baseline，除上面明確列出嘅`test/world-encounter.test.mjs`4句assertion更新、`test/phase3-economy-consistency.test.mjs`2句deepEqual改用`omitVolatileSnapshotFields`之外完全不變）+ 9（新增）= **405 tests passed, 0 failed**（連跑兩次確認唔flaky；同時重新跑咗`test/movement.test.mjs`／`test/world-movement.test.mjs`／`test/world-encounter-client-race.test.mjs`全部131個一樣PASS）。
- **Playwright真瀏覽器smoke test**（sandbox環境，唔係Render，亦唔係Charlie嘅真iPhone驗收）：確認**玩家完全冇郁**嗰陣，monster marker嘅`cx`喺3秒內由486.36變做528.3（真係喺patrol）；玩家state全程維持`IN_WORLD`唔受patrol影響；讀live monster position之後行過去，encounter正常觸發，reload後自動彈去Battle畫面；撤退之後，monster喺snapshot完全消失，DOM入面`[data-monster="world-bandit-1"]`亦都唔存在（冇resurrect）。發現一個同呢次改動完全無關嘅pre-existing cosmetic 404（`/favicon.ico`），如實記錄，唔屬於regression。
- 存檔影響：無schema變動；`characters`表、`world_monster_encounters`表結構完全不變。
- **PR #55 Review Fix round 1（純test-only，`server.mjs`/`public/app.js`一個字冇改）**：GPT Review發現原本P4-03A-H同E兩條test嘅automated evidence未夠嚴謹——(1) H原本用「patrol reachable範圍以外嘅固定decoy點」證明miss，但呢個decoy同舊P4-02 static`(500,220)`同monster真正live position都相差好遠，即使server真係退步返用返舊static position，H都會一樣PASS，完全冇證明力；仲發現原本80px patrol route（`(460,220)`↔`(540,220)`）令monster去到兩個端點嗰陣，離舊static`(500,220)`啱啱好係40px——同`encounterRadius`一模一樣，係一個boundary-exact嘅數值，根本無法可靠證明"static→dynamic"轉變。(2) E原本用`await wait(500)`+`notDeepEqual`嚟證明position隨時間改變，依賴真實wall-clock sleep。修正：patrol route由80px leg擴大做120px（`patrolA:{x:440,y:220}`／`patrolB:{x:560,y:220}`，midpoint繼續係`(500,220)`，speed維持`0.02`px/ms，一程變6000ms、一個來回12000ms）——擴大之後，monster喺端點離舊static有60px，喺40px radius之外有真正margin，唔再係boundary-exact巧合。Route安全性（`WORLD_BOUNDS`／obstacle／城市entry radius margin）重新用automated data validation確認（`test/world-monster-patrol.test.mjs`嘅P4-03A-C/D），全部PASS，冇憑肉眼。P4-03A-H重寫做純function differential proof：喺已知嘅`monster.patrolAnchorAt`時間，monster啱啱好喺`patrolA`（離舊static 60px，真正outside radius）；構造一條刻意「引誘」舊static`(500,220)`嘅segment（距離舊static 20px，喺radius之內，`wouldHitOldStatic`斷言呢個trap本身有效），再用真正live position check同一條segment（距離53.85px，喺radius之外），斷言真正結果係MISS——如果production regressed返用舊static center，`actualResult`就會錯誤變做true，即刻俾test捕捉到。呢條test完全冇用server、冇sleep，純粹`patrolPositionAt`+`segmentEntersEncounterRadius`（moveWorld()自己用嗰個primitive）。P4-03A-E簡化做「單次snapshot讀取，cross-check`worldMonsters[].position`同`patrolPositionAt(definition,snap.serverNowMs)`完全一致」——證明server真係wiring緊`patrolPositionAt`嚟計，唔靠sleep再證一次「monster會郁」（呢點已經由A/B兩條pure test完整證明咗）。連帶`test/world-encounter.test.mjs`嘅P4-02-A更新返`patrolA`/`patrolB`斷言去新數值。測試結果：405（上一round，內容除路由數值同E/H兩條test重寫之外完全不變）= **405 tests passed, 0 failed**（連跑兩次確認唔flaky；`test/world-encounter.test.mjs`／movement race regression全部重新跑過都PASS）。
- Rollback基準：`main` @ `c69b9556b6b2a222abfe35976f4f36b9da666109`。

## P4-03A Review Fix Round 2 — 2026-09-22

- **PR #55 Review Fix round 2（純test-only，冇改任何production檔案）**：GPT Review指出round 1嘅P4-03A-H雖然已經證明咗static/dynamic嘅geometry differential（static center→HIT、live patrol center→MISS），但個test直接將`livePosition`（test自己用`patrolPositionAt`計出嚟）傳入`segmentEntersEncounterRadius()`，從來冇touch過`server.mjs`——即係話,如果`moveWorld()`真係regress返用static/hardcoded position,呢條test都完全唔知,因為佢淨係測緊個primitive本身嘅行為,唔係production嘅實際wiring。
- 修正：喺`test/world-monster-patrol.test.mjs`加咗一條新test，將原本P4-03A-H正式分成兩層——**Layer 1**（原有嘅pure geometry differential proof，改名做「P4-03A-H (Layer 1)」，內容完全冇改）證明「static vs dynamic」呢個選擇本身係有意義、可分辨嘅；**Layer 2**（新增，「P4-03A-H (Layer 2)」）直接讀`server.mjs`嘅真實source，用`indexOf('function moveWorld(')`同下一個top-level function（`async function api(`）嘅位置，將檢查範圍**收窄到`moveWorld()`自己個function body**（唔係「`patrolPositionAt`喺成個500幾行嘅file入面某處出現過」呢種好弱嘅claim），斷言production source入面真係包含精確嘅wiring：`segmentEntersEncounterRadius(current,{x:nextX,y:nextY},{...m,position:patrolPositionAt(m,now)})`。
- 兩層合埋先真正鎖死regression：Layer 1證明「static定dynamic result會唔同」，Layer 2證明「production真係揀咗dynamic嗰個」——如果之後有人將`moveWorld()`嗰句改返做`segmentEntersEncounterRadius(current,{x:nextX,y:nextY},m)`（即係唔再傳`patrolPositionAt(m,now)`），Layer 2會即刻FAIL，唔使等Layer 1嘅geometry巧合先發現。修正呢個test之前，曾經用一個sed過嘅scratch copy（`/tmp`,冇碰過真正`server.mjs`）模擬呢種regression，確認Layer 2嘅`includes(...)`assertion正確變做`false`，證明呢條test真係work。
- 測試結果：405（上一round，內容完全不變）+ 1（新增Layer 2 test）= **406 tests passed, 0 failed**（連跑兩次確認唔flaky）。
- 存檔影響：無。
- Rollback基準：`main` @ `c69b9556b6b2a222abfe35976f4f36b9da666109`。

## P4-03A Merge Gate Fix — Account for Snapshot Transit Time — 2026-09-22

- **PR #55 Merge Gate Fix（純client-only，`server.mjs`／patrol formula／patrol speed／patrol route／encounter geometry／DB schema全部一個字冇改）**：Codex Review發現一個P2問題——`computeServerTimeOffset(serverNowMs,clientNowMs)`原本用`serverNowMs`（server喺response送出**之前**攞到嘅timestamp）直接同client嘅**收到response嗰刻**嘅`Date.now()`比較，即係將HTTP response嘅**成程單向transit time**都當做clock skew計埋落去。以呢隻monster嘅patrol speed（`0.02`px/ms）計，淨係2000ms嘅response delay就已經會讀出約40px嘅虛假visual lag——同`encounterRadius`一樣大，足以令client畫面上睇落好似player同monster撞埋一齊，但server嗰邊嘅真正authoritative position其實喺第二度（雖然真正encounter判定100%喺server用自己嘅`Date.now()`計，同呢個cosmetic bug完全無關，但畫面上嘅誤導本身已經唔可接受）。
- 修正：`computeServerTimeOffset`改做三個參數`(serverNowMs,requestStartedAt,responseReceivedAt)`，用**request嘅midpoint**（`requestStartedAt+(responseReceivedAt-requestStartedAt)/2`——標準symmetric-latency近似法，假設去程同回程transit time大約相等）嚟estimate `serverNowMs`實際對應緊client邊一刻，取代直接用收到response嗰刻嘅時間。`refresh()`嘅wiring相應改做：send request之前攞`requestStartedAt=Date.now()`，response resolve之後攞`responseReceivedAt=Date.now()`，兩個都傳入`computeServerTimeOffset`。刻意**唔**建立clock sync subsystem——冇歷史RTT averaging，冇NTP-style multi-sample estimation，每次`refresh()`淨係用嗰一次request嘅midpoint，同之前一樣係一次性wholesale recompute（唔會累積drift）。
- 新增`public/worldmonsters.js`／server端patrol計算／encounter判定**完全冇改**——呢個純粹係client cosmetic rendering嘅clock estimation修正，同game logic完全無關。
- 新增`test/world-monster-patrol.test.mjs`嘅**P4-03A-M至P**（取代原本嘅F，因為function signature由2個參數變3個）：**M**（zero latency：request start同response receive一樣，offset依然準確reconstruct`serverNowMs`）、**N**（symmetric RTT：明確證明個helper用緊midpoint而唔係直接用response receipt time——用同一組數字算出嚟舊方法會錯1000ms，新方法啱）、**O**（clock skew+latency一齊出現：device clock偏咗幾個鐘再加非零RTT，`midpoint+offset`依然準確等於`serverNowMs`）、**P**（production wiring：讀`public/app.js`真實source，收窄去`refresh()`自己個function body，斷言`requestStartedAt`真係喺send request之前攞、`responseReceivedAt`真係喺response resolve之後攞、兩個都傳咗入`computeServerTimeOffset`，而且次序啱）。曾經用一個sed過嘅scratch copy模擬返舊wiring（`server.mjs`／production檔案冇碰過），確認P會正確變做fail。
- 測試結果：406（上一round，內容除computeServerTimeOffset嘅signature/wiring之外完全不變）－1（移除舊F）＋4（新增M/N/O/P）= **409 tests passed, 0 failed**（連跑兩次確認唔flaky；`test/world-encounter.test.mjs`／`test/world-encounter-client-race.test.mjs`／movement race regression全部重新跑過都PASS）。
- **Playwright真瀏覽器smoke test**：地圖正常load、monster patrol依然smooth（3秒內marker位置有變）、行去live position觸發encounter正常、reload正常、冇新console error（淨係嗰個同呢次改動完全無關嘅pre-existing`/favicon.ico`）。
- 存檔影響：無。
- Rollback基準：`main` @ `c69b9556b6b2a222abfe35976f4f36b9da666109`。

## P4-03B — 2026-09-22 — Active Monster → Stationary Player Encounter

- **目標**：玩家完全企定喺World Map，巡邏中嘅Monster自己行埋嚟都可以由server權威判定Encounter，唔再淨係得「玩家自己撞入怪」（P4-02/P4-03A）呢個單向機制。跟足經批准嘅P4-03B Audit／Design Clarification Gate。
- **`public/worldmonsters.js`新增`patrolSegmentsBetween(monster,fromTime,toTime)`**——純function，將一段時間內嘅真實patrol路徑拆做多段直線segment（處理跨turnaround、啱啱好落喺turnaround時刻、跨多個turnaround、`fromTime===toTime`等edge case），唔再將`previousTime→now`當一條直線（會漏咗中間繞去A或B再返嚟嘅真實路徑）。
- **`server.mjs`新增`evaluateWorldMonsterExposure(characterId,playerPosition,fromTime,now)`**——單一shared primitive，將monster嘅swept patrol path（`patrolSegmentsBetween`）同player嘅static位置用現有`segmentEntersEncounterRadius()`做check（同P4-02嘅player-swept-vs-monster-point check岩岩相反角色，reuse同一個primitive，零新geometry code），命中就reuse現有`createBattleCore()`／`world_monster_encounters`PK做exactly-once consumption。
- **新增`POST /api/commands/world/heartbeat`**（`worldHeartbeat()`）——跟現有`check()`→`idem()`→SQLite transaction pattern，payload為空（client唔提供任何player position／monster identity／時間）。喺`state!=='IN_WORLD'`／有pending loot settlement／`battleIsActive()`時REJECTED，同現有command一致。
- **`moveWorld()`加入shared evaluator**：每次call嘅最頭（喺現有movement/collision邏輯之前）先評估historical exposure；一旦命中，今次requested movement**唔會**apply（response回返pre-move位置，好似個move從來冇發生過），亦唔會再執行現有P4-02 Player→Monster check（mutual exclusion，一個command最多開一場battle）。目的：即使玩家heartbeat延遲/停咗但仍然郁緊，`moveWorld()`都唔會俾人繞過Monster exposure。
- **Memory-only watermark**（`worldExposureWatermark`，process-global Map，冇DB schema改動——同`lastWorldMoveAt`一樣嘅接受咗嘅single-`char-demo`Prototype簡化）：`boundedExposureFromTime()`將evaluation窗口clamp喺`MAX_WORLD_EXPOSURE_LOOKBACK_MS=2000`（少過現時patrol leg嘅~6000ms，正常情況最多跨一個turnaround）；冇watermark（首次boot／server restart後）預設**zero window**（淨係check「而家」，唔會回溯）。`advanceWorldExposureWatermark()`**只喺`idem()`transaction commit之後、`result.status==='ACCEPTED'`先寫**（JS Map mutation唔會因為SQL rollback而還原，所以早咗寫就有可能靜靜雞skip咗本應補算嘅窗口），用`Math.max`保證單調（唔會倒退）。`exitCity()`喺ACCEPTED後將watermark rebase去exit-time`now`——因為IN_CITY→IN_WORLD係一次真正嘅position discontinuity（`world_x/world_y`跳咗去exitPoint），唔rebase就會拎住城入面嘅時間窗口去比對一個完全唔相關嘅新位置。
- **`public/app.js`**：新增`sendWorldHeartbeat()`，`boot()`加多一個同現有兩個`setInterval`同款式（永遠running+內部gate）嘅第三個interval，每1000ms喺`S.tab==='map'&&S.snap?.state==='IN_WORLD'&&document.visibilityState==='visible'&&S.battle?.status!=='ACTIVE'`先真正send。`battleAlreadyActiveFromMoveResponse`重命名做`battleAlreadyActiveFromWorldResponse`（response shape/邏輯完全冇變，純粹因為而家heartbeat都reuse緊同一個predicate，舊名太move-specific）——`sendWorldMove`同`test/world-encounter-client-race.test.mjs`嘅23個引用一齊機械式更新。P4-03A嘅cosmetic rAF monster rendering **完全冇改**，heartbeat同patrol畫面渲染係兩件獨立嘅事。Client authority完全冇增加：monster位置/選擇/時間永遠server決定。
- **新測試`test/world-monster-heartbeat.test.mjs`（P4-03B-A至U，21個）**：A-D係pure`patrolSegmentsBetween`/bounded-lookback proof（包括1000個patrol cycle嘅stress test，證明冇unbounded blowup）；E-M係real-server encounter/atomicity/race test（stationary player heartbeat命中、repeated heartbeat唔會開兩場、lost-response retry、ACTIVE battle guard、consumed monster唔再trigger、heartbeat+moveWorld並發收斂去exactly one battle、**heartbeat完全冇call過都可以靠moveWorld單獨偵測**、historical hit會擋住今次requested movement、現有P4-02 live-position encounter維持正常）；N-P係watermark嘅structural+behavioral proof；Q／R分別驗證`exitCity()`rebase同server restart fallback（用真嘅kill+respawn child process模擬restart，decoy位置刻意anchor喺patrol leg嘅正中點——離兩個turnaround都有60px margin——先至可以避開「real-time phase啱啱好行到接近turnaround」嗰種flaky巧合）；S-U係client source-scoped structural proof（hidden document唔send／resync reuse`battleAlreadyActiveFromWorldResponse`／poll gate涵蓋city/travel/battle/tab/hidden五個condition）。V-Y（P4-02/P4-03A/movement race regression、full suite）喺npm-test層面報告，唔係呢個檔案入面獨立嘅test。
- 測試結果：409（上一round）＋21（新P4-03B-A至U）＝**430 tests passed, 0 failed**（連跑三次確認唔flaky；R喺初稿有一次因為decoy用緊「未經控制嘅live position」撞正real-time phase巧合而flaky咗一次，已經改用固定嘅leg-midpoint decoy修正，再跑幾次全部穩定）。
- **Playwright真瀏覽器smoke test**：City Hub load → 離開城市入World Map → 玩家完全冇郁joystick，3秒內hero marker位置不變、monster marker正常patrol（cosmetic rendering不受影響）→ 用fixture DB將玩家teleport去monster live position → 1.5秒內（heartbeat interval 1000ms）自動觸發encounter，Battle畫面出現 → reload後Battle狀態正確保留 → 撤退後monster唔再出現喺snapshot。淨係嗰個同呢次改動完全無關嘅pre-existing`/favicon.ico`console 404。
- Scope check：冇aggro/chase/leash（P4-03C）、冇respawn、冇DB schema改動、冇WebSocket、冇server-side`setInterval`/`setTimeout`（`grep`確認`server.mjs`一個都冇）、冇pathfinding/navmesh、patrol speed／patrolA／patrolB／encounterRadius數值完全冇改。
- **已知限制**（如實記錄）：Encounter判定本身100%server-authoritative（時間、monster位置、swept geometry、battle creation、consumption全部server決定），但idle-world liveness依然需要**至少一個**client world request（heartbeat或者moveWorld）先會觸發evaluation。如果一個惡意client完全唔send任何world request（連heartbeat都唔send，亦完全唔郁），server唔會自己背景模擬encounter——呢個係request/response（無WebSocket、無server push）架構嘅固有限制，同市場tick／travel arrival呢啲現有lazy-evaluation機制屬於同一類已接受嘅Prototype限制，今次冇用server timer或WebSocket去解決（跟足Coding Order嘅明確要求）。
- 存檔影響：無schema變動。
- Rollback基準：`main` @ `314482d90951de39c425244927089ba8e41cc51e`。

## P4-03B Merge Gate Fix — exitCity Idempotent Replay Watermark Bug — 2026-09-22

- **Draft Review發現一個真實bug**：`exitCity()`嘅watermark rebase喺`idem()` return之後先攞`Date.now()`。但`idem()`對一個重複嘅idempotencyKey，可以直接返回cached嘅ACCEPTED result，完全唔會重新執行原本個transaction。舊code喺呢種replay情況下，依然會攞一個**全新**嘅`Date.now()`去rebase watermark——即係話一個已經成功咗嘅`exitCity`指令，如果client（或者retry機制）重新send多次同一個idempotencyKey，每次都會將watermark悄悄推前去retry嗰一刻，靜靜雞掉咗原本exit同retry之間嘅真正Monster→Player exposure歷史。
- 修正：喺`idem()`嘅callback**入面**（會俾caching住嘅嗰部分）攞`worldExposureRebasedAt:Date.now()`，rebase邏輯改用`result.data.worldExposureRebasedAt`（唔再喺`idem()`外面自己攞`Date.now()`）。Replay嘅時候，`idem()`返回嘅係cache低咗嘅原始result（包括原始個timestamp），所以rebase永遠用返第一次執行嗰刻嘅真正exit時間，唔會因為replay而被覆蓋。維持`Math.max`嘅monotonic寫法。
- `worldExposureRebasedAt`純粹係internal bookkeeping，讀完即刻喺response送出之前strip咗——`exitCity()`嘅client-facing response shape同之前完全一樣（呢個fix順便揭發咗一個我自己引入嘅regression：最初嘅fix直接將呢個欄位擺咗入client response，令`test/city-entry.test.mjs`一個成日已經有嘅strict-shape assertion唔再PASS；而家已經收返，`city-entry.test.mjs`一隻字都冇改過）。
- 新增**P4-03B-Q2**（`test/world-monster-heartbeat.test.mjs`）——真正behavioral regression test，唔淨係source-string assertion：exitCity第一次喺T0成功（player企喺patrol leg嘅正中點，離兩個turnaround都有60px margin，避免real-time phase巧合）→ 等2500ms真實時間（monster繼續行，已經離開返嗰個點約50px）→ 用**完全相同**嘅idempotencyKey重試exitCity（確認cached result同第一次一模一樣）→ heartbeat必須依然可以偵測到T0至今呢段窗口嘅exposure（`encounterTriggered:true`）。已經用scratch copy（將`server.mjs`複製去`/tmp`，將exitCity改返舊嘅buggy pattern，真係spawn個server行呢個test）確認：舊code會令呢個test FAIL（`encounterTriggered:false`，因為watermark錯誤咁被推前咗去retry時間），新code先會PASS。
- 亦已更新Q嘅structural assertion，同加多一句assert確認`worldExposureRebasedAt`唔會漏出client-visible response。
- 測試結果：430（上一round）＋1（新增P4-03B-Q2）＝**431 tests passed, 0 failed**（連跑三次確認唔flaky）。修正過程中一度發現自己喺實作呢個fix時，順手引入咗一個`test/city-entry.test.mjs`嘅regression（因為最初將`worldExposureRebasedAt`直接擺咗入client response，撞正嗰個test一個成日已經有嘅strict-shape assertion）——已經即刻改正（唔係削弱或者刪除嗰個既有test嘅assertion，而係將`server.mjs`改到符合佢一直以嚟嘅正確要求：`worldExposureRebasedAt`純internal，永遠唔應該漏出去client），`test/city-entry.test.mjs`本身一隻字都冇改過。
- Scope check：只改咗`server.mjs`同`test/world-monster-heartbeat.test.mjs`；patrol route／patrol speed／encounter radius／heartbeat cadence／lookback=2000ms／DB schema／Battle mechanics／movement constants／city coordinates／city entry radius／market economy／travel bus／WebSocket policy／server timer policy／aggro-chase-leash-respawn scope全部完全冇改。
- 存檔影響：無schema變動。
- Rollback基準：`main` @ `314482d90951de39c425244927089ba8e41cc51e`。

## P4-03C — 2026-09-22 — Aggro / Chase（`world-bandit-1`專屬）

- **目標**：由P4-03B「Monster企喺原地郁、Player企定會撞」升級做真正「見到你就追」——PATROL巡邏遇到Player進入`aggroRadius`就轉CHASE主動追蹤（追「最後已知位置」，唔係即時預知Player下一步），追近`encounterRadius`先開戰；Player走遠超出`leashRadius`就放棄，唔再追。跟足經批准嘅P4-03C Audit／Design Clarification／Final Design Clarification三份文件。今次**只做`world-bandit-1`一隻**，冇多monster類型、冇ranged/group aggro、冇pathfinding/navmesh、冇respawn、冇server timer/WebSocket、冇Phase 5戰鬥AI改動。
- **State Machine（只有兩態）**：`PATROL`／`CHASE`，冇`RETURNING`（disengage即刻`snap`去`patrolPositionAt(monster,now)`——因為`patrolAnchorAt`係fixed content常數，monster「本來就一直喺」canonical patrol curve上面，唔需要rebase任何嘢，接受呢下visual snap係刻意嘅trade-off，唔為咗消除佢加多一個state）。
- **`public/worldmonsters.js`新增content欄位**（`world-bandit-1`專屬，全部標示Prototype Parameters）：`aggroRadius:90`、`chaseSpeed:0.08`（px/ms，特登細過玩家自己`MOVE_SPEED_RATE`約0.1286px/ms，令玩家永遠可以靠郁走甩）、`leashRadius:150`（由`patrolA`/`patrolB`嘅**中點**度，唔係由monster live position或者chaseAnchorPos量度）；`encounterRadius`／`patrolSpeed`／`patrolA`／`patrolB`完全冇改。
- **`public/worldmonsters.js`新增`chasePositionAt(anchorPos,anchorAt,targetPos,chaseSpeed,timeMs)`**——純function，anchor+speed直線推進去`targetPos`，用`Math.min(distance,speed*elapsed)`夾住唔會overshoot。特登**冇**加`chaseSegmentsBetween`或者`relativeMotionEntersRadius`（Final Design Clarification已經證明：CHASE嘅anchor只會喺evaluate call嗰一刻先更新，同watermark嘅lookback窗口天然對齊，所以historical sweep永遠淨係一段segment，唔需要好似patrol咁嘅piecewise多段sweep；moving-vs-moving嘅情況亦已經證明可以完全reuse現有`segmentEntersEncounterRadius`，唔使發明player continuous trajectory）。
- **`server.mjs`新增memory-only runtime**（`worldChaseState`，`Map<characterId,ChaseState>`，冇DB schema改動——同`worldExposureWatermark`一樣嘅接受咗嘅single-`char-demo`簡化）同`evaluateWorldMonsterAggroChase(characterId,playerPosition,fromTime,now,acceptedMoveSegment?)`——**wrap**（唔膨脹）現有`evaluateWorldMonsterExposure()`：優先順序係encounterRadius先於aggroRadius（同一個patrol sweep直接入encounterRadius就即刻開戰，唔會俾CHASE截糊）；PATROL monster用swept patrol path（reuse`patrolSegmentsBetween`）check aggroRadius做transition；CHASE monster每次evaluate做「historical phase encounter check→chase movement resolve(obstacle-clamp+unconditional anchor rebase)→current-command phase encounter check(淨係moveWorld，用accepted move segment)→leash check」。CHASE嘅encounter check（historical同current-command兩個phase）都加咗**obstacle gate**（reuse現有`segmentBlocked`）——隔住obstacle唔會開戰；**PATROL既有嘅`evaluateWorldMonsterExposure`同moveWorld post-move check完全冇加呢個gate**（Coding Order §22明確要求，避免對已approve嘅P4-02/P4-03B行為有任何regression）。
- **Player Movement Time Semantics（Final Design Clarification §1，"Model A"）**：`lastWorldMoveAt`繼續**只**用嚟做throttle/elapsed allowance，唔再假設佢代表「玩家由嗰一刻開始連續郁緊」。Historical phase將player視為喺成個evaluate窗口企定喺pre-move位置；Current-command phase（淨係`moveWorld()`）用player**真正accepted**嘅`current→next`segment（`moveWorld()`而家會**先**pure計算candidate displacement，先call evaluator，最後至實際apply DB更新，令`lastWorldMoveAt`嘅mutation timing完全跟返P4-03B原本嘅「exposure/chase歷史命中就完全唔碰`lastWorldMoveAt`」規則）。
- **Idempotency/Rollback safety**：`advanceWorldChaseState(characterId,result)`跟`advanceWorldExposureWatermark`一模一樣嘅discipline——喺`idem()` return之後、只喺`status==='ACCEPTED'`先寫，用`evaluatedAt`monotonic比較（唔係raw overwrite）避免cached replay倒退返新嘅真實transition。`exitCity()`加返`chaseStateProposal:{evaluatedAt,state:null}`（reuse同一個function）——IN_CITY→IN_WORLD一定reset留低嘅CHASE runtime，唔會城入面嘅舊chase喺出返城之後復活。
- **`serializeWorldMonsters(characterId,now,state?)`**——一個shared、mode-aware嘅serializer，`snapshot()`／`worldHeartbeat()`／`moveWorld()`三個endpoint共用（取代舊嘅PATROL-only`availableWorldMonsters()`），PATROL輸出`id/displayName/level/mode/position/encounterRadius/serverNowMs`，CHASE多加`chaseAnchorPos/chaseAnchorAt/lastKnownPlayerPos`俾client做cosmetic interpolation；`encounterId`繼續withhold。一個evaluate call**自己嗰個response**要reflect**自己啱啱先proposal緊嘅**新chase state（唔係已經寫落live Map嗰個，因為`advanceWorldChaseState`喺idem()之後先寫）——用`effectiveChaseStateFor()`解決。
- **`public/app.js`**：`tickMovementFrame`嘅monster marker patch loop改做mode-aware（`mode==='CHASE'`用`chasePositionAt`+server-supplied anchor triple，`PATROL`繼續用返`patrolPositionAt`唔變）；新增`shouldApplyWorldMonstersSync`/`applyWorldMonstersSync`（用`serverNowMs`做staleness guard，獨立於現有`latestCompletedMovementSequence`機制，喺`sendWorldMove`／`sendWorldHeartbeat`都喺現有battle-resync check**之前**無條件執行，唔會延誤現有encounter/battle resync優先權）。
- **新測試`test/world-monster-aggro-chase.test.mjs`（33個，P4-03C-A至AG）**：A/B係pure content/`chasePositionAt`proof；I/J/K係obstacle-blocked CHASE嘅pure geometry+algorithm proof——已經用exported primitives嚴謹證明「今日嘅`leashRadius=150`由patrol中心量度，令任何inflated obstacle嘅最近點都喺150px以外，所以obstacle-blocked CHASE用現有content**實際上冧唔到**」（呢個係Audit已經記錄低嘅finding，唔係coverage漏洞），同時獨立證明個algorithm本身（唔靠今日content）遇到blocked segment會正確凍結+rebase；L係structural regression proof（`evaluateWorldMonsterExposure`／PATROL post-move check源碼一個字冇改）；C-H／M-V係real-server integration（aggro transition、priority順序、chase movement progress、target update、encounter、leash disengage、snap、city/travel/exitCity/restart/reload、heartbeat/moveWorld sync shape）；W-Z係client structural+pure proof；AA-AG係idempotency/rollback/concurrency proof。
- 測試結果：431（上一round）＋33（新增P4-03C-A至AG）＝**464 tests passed, 0 failed**（連跑五次confirm唔flaky）。
- **Full Regression過程中發現一個真實regression（唔係P4-03C production code嘅bug，係cross-feature座標coupling），已經修正**：`test/world-roads-non-constraining.test.mjs`（P1-05，完全同monster無關嘅道路測試）原本揀`x≈390-410,y=220`做「安全、遠離P1-04 obstacle」嘅測試點——但呢個座標寫嗰陣（P1-05）根本未有world monster content，離`world-bandit-1`嘅`patrolA(440,220)`得返30-50px，跌咗入新加嘅`aggroRadius=90`危險區。舊嘅`encounterRadius=40`危險區好窄，呢個file之前重複跑一直冇撞到過；而家aggroRadius加寬+CHASE主動追近，令呢個file自己嘅幾個test（用同一條spawned server）逐個move之間monster持續逼近，最終喺其中一個test嘅move觸發咗mutual-exclusion嘅encounter early-return（move冇apply、之後兩個test因為`ERR_BATTLE_ACTIVE`cascade failed）。修正：將呢個file入面嘅測試點由`x≈390-410`搬去`x≈240-270`（同一條`ac`道路上，一樣避開晒P1-04 obstacle，但離patrol路線同aggro zone都有190px以上margin），**assertion嚴謹度一個字冇改**，純粹搬個測試座標，同呢個file自己一直以嚟嘅設計原意（「一個完全唔受道路/obstacle以外任何嘢影響嘅安全點」）一致。已經連跑幾次確認穩定。
- **Manual Smoke Test**（HTTP-level，直接對住真正spawn緊嘅server走全部5個scenario；今次sandbox環境冇裝Playwright做project dependency，冇經過真正瀏覽器畫面check，如實記錄）：Scenario 1(Aggro：企喺aggro zone、PATROL轉CHASE、未開戰)、Scenario 3(Caught：企定俾CHASE追到、自動開戰、exactly one battle/consumption)、Scenario 2(Escape：走遠過leashRadius、CHASE disengage返PATROL、落一個heartbeat正常唔卡死)、Scenario 4(City safe zone：CHASE中入城、出返城之後monster reset做PATROL)、Scenario 5(Reload：CHASE中一個plain snapshot攞到完整anchor triple)全部PASS。
- **已知限制**（如實記錄）：冇pathfinding／冇LOS；obstacle-blocked monster會維持CHASE直到leash或者state離開IN_WORLD先disengage（今日content冚唔到呢個case，見上面I/J嘅geometry proof）；disengage snap可能有肉眼可見嘅瞬間跳動（刻意接受嘅trade-off，見上面State Machine段落）；成個世界模擬繼續係lazy request-driven（冇server timer/WebSocket，同P4-03B已接受嘅限制一致）；client CHASE interpolation純粹cosmetic。
- 存檔影響：無schema變動；`characters`表、`world_monster_encounters`表結構完全不變。
- Rollback基準：`main` @ `16753b03685318dac5c66ea8d0699e209c191383`。

## P4-03C Draft Review Fix — refresh() Stale-Response Watermark Bug — 2026-09-22

- **PR #57 Draft Review發現一個真實bug**：`public/app.js`嘅`lastWorldMonstersSyncAt`（`shouldApplyWorldMonstersSync`用嚟擋stale world response嘅watermark）**只**喺`sendWorldMove`／`sendWorldHeartbeat`嘅`applyWorldMonstersSync`入面先會advance——但`refresh()`（每次travel/arrival/settlement/reload都會將`S.snap`成個換做一份新嘅authoritative snapshot）從來冇touch過呢個watermark。於是：一個heartbeat/move request（serverNowMs=T1）喺`refresh()`嘅snapshot（serverNowMs=T2，T2>T1，真正更新）之前已經send咗出去，但因為network delay，喺`refresh()`嘅snapshot response**之後**先至完成——由於`lastWorldMonstersSyncAt`一直冇被`refresh()`advance過，`shouldApplyWorldMonstersSync`會錯誤咁俾呢個遲到、其實舊咗嘅T1 response通過staleness check，將啱啱先applied落嚟嘅、真正新嘅`worldMonsters`覆蓋返做舊資料。
- 修正：新增`export function nextWorldMonstersSyncWatermark(current,candidate)`（純function，NaN-safe monotonic advance，`current`未set當`-Infinity`，`candidate`唔係finite number就完全唔郁）——`applyWorldMonstersSync`同`refresh()`兩個地方**都**改用呢一個function嚟advance`lastWorldMonstersSyncAt`，`refresh()`喺`S.snap=await req(...)`之後即刻用`S.snap.serverNowMs`（同`serializeWorldMonsters()`計`worldMonsters[].serverNowMs`嗰個`now`係同一個，server端保證）嚟advance。**冇建立第二套獨立嘅freshness系統**——始終得一條freshness axis，兩個call site都共用同一個`lastWorldMonstersSyncAt`／同一個advance function。
- 新增3條test（`test/world-monster-aggro-chase.test.mjs`，「P4-03C-Y2」三層，跟返P4-03A-H Layer 1/Layer 2嘅精神）：**Layer 1**淨係用返（完全冇改過嘅）`shouldApplyWorldMonstersSync`本身，喺舊head嘅確實行為之下（`refresh()`冇advance過watermark，即係watermark喺snapshot apply咗之後仍然係`NaN`）reproduce個bug——遲到嘅T1 response錯誤咁通過check（`true`），直接證明呢個bug真係存在，唔使scratch copy都可以睇到。**Layer 2**用新嘅`nextWorldMonstersSyncWatermark`模擬`refresh()`嘅正確wiring：watermark advance去T2之後，同一個遲到T1 response正確咁被拒絕（`false`）；仲覆蓋埋兩個required side-case——一個真正更新嘅T3 response（喺snapshot之後）依然可以apply、同equal-timestamp semantics保持deterministic（唔會因為同一個時刻response咗兩次就當stale）；亦覆蓋埋defensive/NaN-safety case。**Layer 3**（structural）直接讀`public/app.js`真實source，收窄去`refresh()`同`applyWorldMonstersSync`各自嘅function body，斷言`refresh()`真係喺`S.snap=await req(...)`**之後**call咗`lastWorldMonstersSyncAt=nextWorldMonstersSyncWatermark(lastWorldMonstersSyncAt,S.snap.serverNowMs);`，同`applyWorldMonstersSync`真係用緊完全同一個function——證明production真係wiring啱，唔淨係個pure function本身啱。
- 測試結果：464（上一round）＋3（新增P4-03C-Y2三層）＝**467 tests passed, 0 failed**（focused：`test/world-monster-aggro-chase.test.mjs`36/36、`test/world-encounter-client-race.test.mjs`5/5、`test/world-monster-heartbeat.test.mjs`22/22；連跑full suite兩次確認唔flaky）。
- Scope check：只改咗`public/app.js`（`nextWorldMonstersSyncWatermark`／`applyWorldMonstersSync`／`refresh()`三處）同`test/world-monster-aggro-chase.test.mjs`（新增3條test）。冇碰server端chase邏輯、`aggroRadius`／`chaseSpeed`／`leashRadius`／DB／PATROL行為／`test/world-roads-non-constraining.test.mjs`（上一round已經修正過，今次冇再碰）／battle邏輯／heartbeat cadence／Model A movement semantics。
- 存檔影響：無。
- Rollback基準：`main` @ `16753b03685318dac5c66ea8d0699e209c191383`（同上一round）；本round起點PR #57 head `13f94bbfe00077002df06355e46c925687b57bf6`。

## P4-03C Codex Review Fix — Tombstone／Revision Counter／Phantom Patrol — 2026-09-22

- **PR #57喺Ready for Review之後，`chatgpt-codex-connector[bot]`自動Review發現4個真實correctness bug（2×P1、2×P2），已經全部verify並修正**：
  1. **P1（`server.mjs` `advanceWorldChaseState`，tombstone問題）**：舊code喺`chaseStateProposal.state===null`（disengage/leash/consumed/exitCity）嗰陣直接`worldChaseState.delete(characterId)`——刪除咗個Map entry連埋佢個`evaluatedAt`ordering watermark都一齊冇埋。之後如果有一個**更舊**嘅CHASE-acquiring proposal因為idempotent replay先至寫入（`current`讀出嚟係`undefined`，monotonic guard完全冇嘢好比較就直接通過），就會令一個已經合法clear咗嘅chase狀態**復活**，追一個已經應該安全嘅玩家。修正：clear嗰陣唔再delete，改寫一個**tombstone**（`{mode:'PATROL',evaluatedAt,revision}`，冇`monsterId`）——保留咗ordering watermark繼續發揮monotonic guard嘅作用；而因為冇`monsterId`，所有現有`state.monsterId===m.id`（「呢隻monster係咪而家CHASE緊」）嘅check天然就會將tombstone當「冇追緊」處理，零其他call site要改。
  2. **P2（`server.mjs` `advanceWorldChaseState`，millisecond tie問題）**：舊code用`Date.now()`嘅`evaluatedAt`做monotonic比較——millisecond resolution喺fast synchronous single-process request handling之下，**兩個真正唔同、有先後次序嘅evaluate完全可能撞正同一個millisecond**，令`>=`guard錯誤咁撞成「平手」，靜雞雞drop咗一個本應generate嘅newer合法proposal。修正：新增`worldStateRevisionCounter`（global、process生命週期內、永不重用、嚴格遞增嘅integer counter）同`nextChaseStateProposal(now,state)`helper，每個proposal都蓋一個`revision:++worldStateRevisionCounter`；`advanceWorldChaseState`嘅比較改做`current.revision>=proposal.revision`（唔再用`evaluatedAt`），永遠唔會撞平。
  3. **P2（`public/app.js` `shouldApplyWorldMonstersSync`，client-side同一類問題）**：同上，client嗰邊用`serverNowMs`做staleness guard一樣有millisecond-tie嘅風險。修正：將**成條**client-side freshness axis由`serverNowMs`改做用返同一個server-provided `revision`——`shouldApplyWorldMonstersSync`讀`worldMonsters[0].revision`，`lastWorldMonstersSyncAt`重命名做`lastWorldMonstersSyncRevision`，`applyWorldMonstersSync`／`refresh()`都改用返`nextWorldMonstersSyncWatermark`比較`revision`（function本身邏輯完全冇變，淨係傳落去嘅值由timestamp換做revision）——**冇建立第二套獨立freshness系統**，同Draft Review Fix round已經定咗嘅原則一致，繼續得一條axis。`snapshot()`／`worldHeartbeat()`／`moveWorld()`嘅response而家都額外帶多一個top-level`worldStateRevision`（讀`serializeWorldMonsters()`call完之後即刻嘅`worldStateRevisionCounter`），俾`worldMonsters`為空（monster已經被consumed晒）嗰種edge case都有值可以比較。
  4. **P1（`server.mjs` `evaluateWorldMonsterAggroChase`，phantom patrol copy問題）**：舊code喺CHASE狀態之下**依然**無條件call`evaluateWorldMonsterExposure()`（canonical PATROL patrol check）。如果玩家將monster引離晒patrol路線再兜返去canonical patrol strip附近（但同monster真正CHASE緊嘅位置依然好遠），呢個canonical check會用「patrol路線上嗰個phantom copy」錯誤咁開戰——同個真正CHASE緊嘅monster完全冇關係嘅一場battle。修正：`state?.mode==='CHASE'`嗰陣完全skip呢個canonical check（唔淨係deprioritize），因為monster一旦CHASE緊，patrol嗰個「canonical truth」對佢嚟講已經冇意義。**修正途中自己webbed一個bug**：第一次改法係`state?null:evaluateWorldMonsterExposure(...)`（淨係check truthy），俾**P4-03C-E**（已有嘅regression test）即刻抓到——tombstone（上面第1點）本身都係truthy，會令呢個check喺monster其實冇追緊（淨係有個clear咗嘅tombstone）嗰陣都錯誤咁被skip。已經改正做`state?.mode==='CHASE'`（check真正mode，唔係淨係存在與否）。
- **`P4-03C-AG`（structural test）跟住更新**：assertion由搵`current.evaluatedAt>=proposal.evaluatedAt`改做搵`current.revision>=proposal.revision`，並且新增一句assert確認source入面完全搵唔到`.delete(characterId)`（防止未來regression走回頭用返delete-based clear）。
- **`test/phase3-economy-consistency.test.mjs`**：`omitVolatileSnapshotFields`加多`worldStateRevision`落去destructure/omit嘅field list——同`serverNowMs`／`worldMonsters`一樣，呢個新field每次snapshot都會增加，同呢個test本身要驗證嘅economy conservation invariant完全無關。
- 測試結果：467（上一round）＋0（今round冇加新獨立test，全部係modify現有assertion／fix production bug）＝**467 tests passed, 0 failed**（`test/world-monster-aggro-chase.test.mjs`單獨36/36；full suite連跑兩次確認唔flaky）。
- Scope check：只改咗`server.mjs`（`advanceWorldChaseState`／`nextChaseStateProposal`／`worldStateRevisionCounter`／`evaluateWorldMonsterAggroChase`／`serializeWorldMonsters`／`snapshot`／`worldHeartbeat`／`moveWorld`／`exitCity`嘅proposal construction）、`public/app.js`（`lastWorldMonstersSyncAt`→`lastWorldMonstersSyncRevision`／`shouldApplyWorldMonstersSync`／`applyWorldMonstersSync`／`refresh()`）、`test/world-monster-aggro-chase.test.mjs`、`test/phase3-economy-consistency.test.mjs`。`aggroRadius=90`／`chaseSpeed=0.08`／`leashRadius=150`／`patrolA`／`patrolB`／`patrolSpeed`／`encounterRadius`數值完全冇改；`public/worldmonsters.js`一隻字冇改；DB schema冇改；`test/world-roads-non-constraining.test.mjs`今round冇再碰；battle邏輯（`triggerWorldMonsterBattle`）／heartbeat cadence／Model A movement semantics全部冇改。
- 存檔影響：無schema變動。
- Rollback基準：`main` @ `16753b03685318dac5c66ea8d0699e209c191383`；本round起點PR #57 head `daf6cb7f7041bed454a0e02b112155811207245d`（Ready Gate approved嗰個SHA）。

## P4-04 — 2026-09-23 — World Threat Micro Playtest（純Read-only playtest，唔改任何code）

- **目標**：跟approved嘅P4-04 Coding Order，驗證「見到怪→巡邏→Aggro→CHASE→玩家逃/避/入城/被追到→Battle」呢條世界威脅loop係咪已經值得保留、俾玩家理解同預測。今round**唔加任何Monster AI、唔加Battle功能、唔加新怪物、唔改任何code**，純粹用一個HTTP-level scratchpad driver（模擬真實client cadence）對住真正spawn緊嘅`server.mjs`跑8個Coding Order指定嘅scenario，加一個額外嘅「完全普通玩家由啟步城行去開拓城」對照組。
- **Baseline**：`main` @ `f61f838a018a7c799dd4cda925e3654e8530518d`（P4-03C merge commit），467/467 tests passed，冇任何code改動。
- **8個scenario全部real-server跑**：企定觀察巡邏（PASS）、主動接近aggro（PASS）、CHASE觸發（PASS）、直線逃跑甩怪（PASS，728ms內disengage）、唔逃俾捉到開戰（PASS，611ms內開戰，一次過）、被CHASE時入城（PASS WITH ISSUE——entry本身冇被擋，但leash永遠早過城門release，「入城避怪」呢個決策現實中完全冇機會發生）、CHASE期間reload（PASS，state完整保留）、CHASE期間用obstacle遮擋（NOT TESTABLE，同P4-03C-I已有嘅幾何證明一致，obstacle永遠喺leash半徑以外）。
- **關鍵額外發現（未列入原定8個scenario，但直接觸發咗P4-04A）**：用一個完全普通、冇刻意繞開嘅玩家行為（joystick一直指向開拓城,由啟步城出發）做測試,發現**592ms觸發CHASE、883ms（未夠1秒）就被迫開戰**,玩家全程冇任何主動反應機會。根本原因：monster patrol中心(500,220)幾乎坐正正響啟步城(220,220)去開拓城(780,220)嘅直線捷徑上(同一個y=220)。
- **Parameter Review**：aggroRadius(90)分類**太細**（同encounterRadius(40)差距太窄,喺正常移動速度下只夠約300-400ms反應窗）；chaseSpeed(0.08)分類**合理**（玩家一react就實逃得甩,已實測）；leashRadius(150)分類**合理，但同城市佈局有結構性衝突**（4個城市嘅entryRadius邊界全部遠過leashRadius,令「入城避怪」呢個設計意圖上嘅逃生選項現時完全用唔著）。
- **Recommendation：PHASE 4 SAFE TO CLOSE**——Section 7嘅10項Pass Criteria全部滿足,Section 8嘅FAIL Conditions一項都冇觸發,但強烈建議喺Phase 5之前優先處理上面兩個Parameter Tuning發現（呢個直接引出咗跟住嘅P4-04A Tuning）。
- 存檔影響：無。冇改任何檔案（純HTTP-level scratchpad playtest，冇commit）。
- Rollback基準：`main` @ `f61f838a018a7c799dd4cda925e3654e8530518d`（同上一round，今round冇新增commit）。

## P4-04A — 2026-09-23 — World Threat Parameter / Placement Tuning

- **目標**：跟approved嘅P4-04A Coding Order,修正P4-04 Micro Playtest發現嘅兩個player-value問題：(1) 普通商路行程同monster patrol corridor重疊,產生幾乎零預警嘅遭遇戰；(2) 現有leash幾何令「CHASE狀態下入城逃生」呢個決策喺現有map content下不可能發生。**只調Prototype content數值，冇新gameplay系統，冇DB schema改動。**
- **`public/worldmonsters.js`content數值改動**（3個，全部經Design Gate分析批准）：
  - `patrolA`由`(440,220)`改做`(440,80)`，`patrolB`由`(560,220)`改做`(560,80)`——搬離啟步城↔開拓城直線捷徑(y=220)140px，clearance(140-新aggroRadius110=30px)確保捷徑幾何上**永遠唔會**入aggro範圍（幾何事實,唔係機率降低）。
  - `aggroRadius`由`90`加到`110`——buffer由50px加到70px，俾刻意接近嘅玩家有更實在嘅336-544ms通知窗口（Design Gate分析：單靠加大aggroRadius但唔搬patrol嘅Option B需要207px先有意義,反而會令捷徑保證接觸問題更嚴重；搬patrol嘅Option A單獨已解決核心問題；今次揀Option C:細幅搬移+適度aggro微調）。
  - `leashRadius`由`150`加到`280`——令啟步城／開拓城嘅entryRadius邊界（新patrol中心量度都係265.1px）首次落入leash範圍之內，令「CHASE→跑向城→入城時仍然CHASE」成為真正可行嘅決策；obstacle距新patrol中心308.1px，依然喺新leash(280)之外，P4-03C-I嘅obstacle-unreachable finding維持不變。
  - `chaseSpeed`（0.08）／`encounterRadius`（40）**維持不變**——跟Coding Order明確要求，P4-04 Playtest已證實呢兩個數值functionally合理，冇證據要求改。
- **新測試`test/world-monster-tuning.test.mjs`（P4-04A-A至G，7個）**：A確認approved數值精確；B用真正segment-to-segment最短距離演算法（唔係假設嘅offset）證明捷徑同aggro掃描永遠唔相交；C確認patrol segment完全喺WORLD_BOUNDS之內；D確認patrol route冇同任何城市entryRadius重疊；E確認patrol route冇入任何inflated obstacle；F證明leashRadius(280)令啟步城/開拓城首次geometrically reachable-while-CHASE（同時記錄港口城/躍動城依然喺leash範圍外,呢個係刻意，唔係要求全部城市都reachable）；G複核P4-03C-I嘅obstacle-vs-leash finding喺新數值下依然成立。
- **既有test更新**（locked老數值,跟Coding Order §6明確批准）：`test/world-encounter.test.mjs`嘅P4-02-A、`test/world-monster-aggro-chase.test.mjs`嘅P4-03C-A（數值assertion）；`test/world-monster-aggro-chase.test.mjs`嘅`AGGRO_ONLY`fixture由`(500,290)`（相對舊patrol中心70px,舊aggroRadius90之內）重新計算做`(500,155)`（相對新patrol中心75px,新aggroRadius110之內,margin對稱~35px），同幾個stale嘅距離註解一併更新——`SAFE_FAR`／encounter/battle/reload/idempotency嘅行為assertion全部一個字冇改，純粹因為monster幾何搬咗位而要重新計算fixture座標，同P1-05嗰次道路座標搬遷屬於同一類「唔削弱assertion,純粹搬fixture座標」嘅改動。
- **HTTP gameplay驗證（真server,真實client cadence，Coding Order §7 Scenario A-E全部跑）**：
  - **A（普通商路行程）**：啟步城exitPoint直行去開拓城,173個tick全程PATROL,零aggro,零battle——保證接觸問題徹底解決。
  - **B（刻意接近）**：aggro喺78.3px（patrol中心量度）觸發,冇即時開戰。
  - **C（掉頭逃走）**：CHASE後1591ms自然disengage,全程未被捕。
  - **D（企定唔郁）**：aggro後611ms開戰,一次過,`world_monster_encounters`只有1行。
  - **E（入城逃生，mandatory scenario）**：CHASE觸發後全速跑向啟步城,1157ms踏入entryRadius**嗰一刻monster依然CHASE**,`enterCity`ACCEPTED,`exitCity`後monster正確reset做PATROL——leashRadius加大呢個改動嘅主要目的首次喺真server上實測confirm。
- **測試結果**：467（P4-03C baseline）＋7（新`world-monster-tuning.test.mjs`）＝**474 tests passed, 0 failed**。
- Scope check：冇新AI state（依然淨係PATROL/CHASE兩態）、冇pathfinding、冇LOS、冇新monster、冇DB schema改動、冇改battle系統、冇加任何UI polish（CHASE icon/顏色/警示/音效/動畫全部維持Phase 8 debt，今round冇碰）。改動檔案：`public/worldmonsters.js`、`test/world-monster-tuning.test.mjs`（新增）、`test/world-encounter.test.mjs`、`test/world-monster-aggro-chase.test.mjs`、`CHANGELOG.md`。
- **已知限制（如實記錄，P4-04B真人playtest先可以confirm）**：336-544ms嘅反應窗口喺真實mobile觸控延遲下係咪足夠,1.2秒「跑去城」嘅節奏感受,patrol搬去(500,80)之後喺實際world map畫面上嘅顯眼程度——呢啲全部係主觀體驗判斷,今round淨係用HTTP timing數據支持,唔可以單靠數學宣稱「感覺岩」。
- 存檔影響：無schema變動。
- Rollback基準：`main` @ `f61f838a018a7c799dd4cda925e3654e8530518d`。

## P4-04B1 — 2026-09-23 — Real Mobile Movement + Chase Diagnostic（純diagnostic，唔改任何code）

- **目標**：真人裝置playtest報告「角色移動卡頓／stop-start」、「monster喺幾步之內就捉到玩家」，同chaseSpeed(0.08px/ms)遠細過player nominal speed(0.1286px/ms)嘅設計預期矛盾。跟approved嘅P4-04B1 Coding Order，喺**唔改任何gameplay code**嘅前提下，用production嘅真實function（`nextEarnedPosition`／`clampEarnedTarget`／`advancePredictedPosition`／`movementDivergence`直接import，配合逐行對照`server.mjs`轉譯嘅throttle/allowance公式）做deterministic simulation，追查根本原因。
- **關鍵發現**：純粹「穩定高RTT」（即使300ms）本身有足夠margin（理論上要去到~389ms先撞頂`MAX_PREDICTION_LEAD=50px`），單一孤立spike都唔會出事（其他concurrent request會繼續完成）。**真正致命嘅係「連續多個request一齊被delay」（burst stall，例如WiFi/流動網絡切換）**——用真實production function模擬證實：`predictedPosition`會凍結450-700ms（正正就係玩家報告嘅stutter），而`serverPos`（authoritative位置）同一時間完全冇郁，monster卻繼續以real elapsed time全速closing（同player request throttle與否完全脫鈎）——喺CHASE觸發初期發生嘅burst stall（模擬證實），可以令trueGap由110px（aggroRadius）跌穿40px（encounterRadius），令玩家俾捕捉，**即使全程joystick輸入完全正確**。
- 結論：**唔係chaseSpeed太高**（穩定/jitter/單一spike情況下1.6倍速度優勢完全夠用），係movement/chase系統之間一個結構性時序缺口——player速度優勢淨係「長遠平均」保證，CHASE捕捉判定卻係「瞬時、連續real-time」判定。
- **額外發現**：現有P1-07C telemetry（`isCapFrozenFrame`）用緊嘅fixed 0.5px proximity tolerance，喺呢個exact configuration（60fps／而家嘅`MOVE_SPEED_RATE`）底下會漏檢真實凍結（凍結平衡點49.3px跌出49.5px門檻），令telemetry本身可能低估緊真實發生嘅freeze。
- 存檔影響：無。冇改任何檔案（純HTTP-level／deterministic simulation scratchpad diagnostic，冇commit）。
- Rollback基準：`main` @ `c3c218095db86b4cc4dca119bc4c4303f0f99f45`（同上一round，今round冇新增commit）。

## P4-04B2 — 2026-09-23 — Telemetry Diagnostic Fix + Real-Device Evidence Capture

- **目標**：跟approved嘅P4-04B2 Coding Order，(1)修正P4-04B1發現嘅telemetry false negative，(2)加一個最小、純記憶體嘅「最近事件」保留機制，令Charlie真機截圖可以捕捉到450-700ms嘅freeze event（人手反應時間唔可能即時截圖）。**今round完全冇改任何gameplay數值／movement邏輯／server行為**——`git diff`確認淨係`public/telemetry.js`（純function）、`public/app.js`（telemetry call site+一個新state block）、`public/worldmap.js`（overlay markup追加）。
- **Part A — cap-freeze false negative修正**：`isCapFrozenFrame`原本用`isNearLeadCap`嘅fixed 0.5px容差做「near cap」proximity判斷，但真正決定`advancePredictedPosition`凍唔凍嘅rule係`aheadCandidate=(forward.x-serverPosition.x)*dirX+...>maxLead`——喺而家嘅`MOVE_SPEED_RATE`/60fps底下，個凍結平衡點停喺49.3px，啱啱好跌出49.5px門檻，令舊邏輯漏檢。修正：唔再用proximity heuristic，改為直接複製production嗰條predicate——`aheadBefore+forwardStepPx>maxLead`，其中`forwardStepPx=magnitude*velocity*dt`（app.js call site已經有齊呢三個值，一行計得出）。數學上`aheadBefore+forwardStepPx`同`advancePredictedPosition`內部嘅`aheadCandidate`係完全相等嘅展開式（單位方向向量投影），**唔係重新估算嘅近似值**。`isNearLeadCap`／`TELEMETRY_LEAD_CAP_TOLERANCE_PX`完全冇改——佢哋仲有獨立用途（`#telemetry-leadcaphit`嘅proximity readout）。
- **Part B — Recent Movement Anomaly（最近事件）保留**：新增`shouldCommitFreezeEvent`／`buildRecentEvent`／`isRecentEventStale`／`formatEventAge`（`public/telemetry.js`，純function，同module一貫嘅diagnostic-only風格）。App.js每frame peak-hold現有telemetry讀數（超前距離、RTT、response gap、in-flight count），凍結streak一結束（`telemetryCapFrozenCurrentMs`由>0跌返做0）就將啱啱嗰個streak嘅peak值連同freeze duration一齊commit做`telemetryRecentEvent`，然後reset peak trackers等下一次。**冇包括hard-reset count**——因為hard reset同cap-freeze係兩個structurally互斥嘅tickMovementFrame分支（唔會同一個frame一齊發生），attribute一個delta俾單一freeze event會捏造一個現有per-frame branching結構本身確立唔到嘅關聯；現有`#telemetry-hardresets`已經以session累計方式獨立展示。事件保留**RECENT_EVENT_RETENTION_MS=5000ms**，純記憶體（module-level變數），reload會清，冇DB、冇server persistence、冇upload、冇history list（淨係最近一個event）。
- **Overlay擴充**：`public/worldmap.js`嘅`.telemetry-overlay`（一直visible喺World Map右下角，`aria-hidden`純屬accessibility標記,唔係display:none——Charlie唔需要任何開發者工具）追加6個新readout：凍結時長、尖峰超前、尖峰延遲、尖峰間隔、尖峰請求中、事件時間（"N.Ns ago"）。全部沿用現有`set(id,text)`／`formatMs`／`formatPx`／`formatCount`patch pattern，冇新UI設計，冇toggle。
- **新測試**：`test/telemetry.test.mjs`更新7條現有`isCapFrozenFrame`測試（加返`forwardStepPx`引數，逐條驗證新公式喺舊case底下結果不變）+ 新增P4-04B1發現嗰個exact false-negative case嘅regression test（`aheadBefore=49.3,forwardStepPx≈2.14,maxLead=50`，證明新公式正確判斷做frozen）+ 8條Part B pure function測試（常數鎖定、commit/stale/format邏輯）；`test/worldmap.test.mjs`加一條confirm新6個overlay id有出現、順序喺`telemetry-hardresets`之後（純additive）。
- **測試結果**：475（P4-04A baseline）＋12（新增/擴充嘅test）＝**487 tests passed, 0 failed**，連跑兩次確認唔flaky。
- Scope check：冇改`chaseSpeed`／`aggroRadius`／`leashRadius`／`encounterRadius`／monster patrol／player movement rate／`MAX_PREDICTION_LEAD`行為／`MOVE_CATCHUP_CAP_MS`／reconciliation邏輯／chase time semantics／movement API／DB／AI／Battle——`git diff`確認`predictedPosition`／`earnedPosition`／`advancePredictedPosition`／`movement.js`本身一個字都冇改，`server.mjs`冇被touch。
- **未有斷言呢個mechanism就係Charlie嗰次real-device事故嘅確認成因**——burst stall只係P4-04B1證明嘅reproducible failure mode，需要等呢round嘅telemetry fix部署之後、Charlie真機截圖返嚟先可以確認。冇提及`lastWorldMoveAt`process-global做過呢次事故嘅成因（純粹未來multi-character技術債務，同今次單人測試冇證據關聯）。
- 存檔影響：無schema變動。
- Rollback基準：`main` @ `c3c218095db86b4cc4dca119bc4c4303f0f99f45`。

## P4-04B2 Draft Review Fix — 2026-09-23 — Recent Movement Event Correlation Window

- **目標**：跟GPT/Charlie嘅Draft Review Fix指示，修正Recent Movement Anomaly嘅peak trackers（尖峰超前／延遲／間隔／請求中）會跨越「兩個retained event之間嘅任意窗口」累積嘅問題——即一個發生喺freeze之前好耐嘅unrelated RTT/gap/in-flight spike，有可能被錯誤歸咎去之後先發生嘅freeze event，令截圖產生誤導（例：freeze前20秒有一個unrelated 800ms RTT，實際freeze期間RTT淨係180ms，但retained event可能錯誤顯示Peak RTT=800ms）。**Part A（`isCapFrozenFrame`嘅cap-freeze predicate）今round完全冇改**——只改Part B嘅peak-window邏輯。
- **修正方式**：peak值而家嚴格限定喺「current freeze event自己嘅窗口」入面，唔再係「兩個retained event之間」。新增兩個pure function（`public/telemetry.js`）：`isFreezeEventStart(previousStreakMs,nextStreakMs)`（`shouldCommitFreezeEvent`嘅鏡像，判斷streak 0→>0嘅freeze開始一刻）同`maxIfTracking(trackingActive,previousPeak,candidate)`（每個peak讀數必經嘅單一gate，只有tracking啟動緊先會記錄）。App.js（`tickMovementFrame`／`recordMoveTelemetry`）新增最小追蹤狀態`telemetryFreezeEventTrackingActive`（一個boolean）：freeze開始（previous streak=0 → next streak>0）就清空四個peak tracker並啟動追蹤；freeze期間（`trackingActive`為true）先會累積lead／RTT／response gap／in-flight嘅peak；freeze結束（`shouldCommitFreezeEvent`為true）就用追蹤緊嘅peak值build`telemetryRecentEvent`，然後停止追蹤。令prediction解凍嗰個response如果喺偵測到freeze end嗰個frame之前完成,會啱啱好落喺追蹤窗口入面,合理咁被計入;但喺event已經commit咗之後先到嘅response,唔會再被追溯歸入嗰個已經close咗嘅event。`recordMoveTelemetry()`唔會再喺冇tracking緊嘅時候累積RTT／gap（之前嘅版本冇呢個限制）。
- **改正咗嘅誤導comment**：移除／改正咗聲稱peak值會「跨whatever window elapses between retained events」保留嘅wording,同埋暗示freeze event committed之後先到嘅response都會被歸入嗰個event嘅wording。而家準確咁講：peak metrics淨係嚟自freeze event自己個窗口。
- **新測試**（`test/telemetry.test.mjs`）：`isFreezeEventStart`嘅4條predicate測試、`maxIfTracking`嘅3條gate測試,加埋核心嘅contamination regression——完全跟order要求嘅6個步驟（tracking inactive → unrelated RTT=800ms → freeze start → freeze期間RTT=180ms → freeze end → 斷言retained event嘅Peak RTT係180ms,唔係800ms）,再加「peak喺每個新freeze開始時reset,第二個freeze唔會繼承第一個嘅peak」同「lead／in-flight喺freeze之外都會被忽略」兩條測試,合共10條新測試。原有7條`isCapFrozenFrame`測試同全部Part B測試維持不變（semantically intact，冇削弱任何assertion）。
- **測試結果**：487（P4-04B2 baseline）＋10（新增）＝**497 tests passed, 0 failed**，連跑兩次確認唔flaky。
- **改動檔案**：`public/telemetry.js`（新增兩個pure function）、`public/app.js`（新增`telemetryFreezeEventTrackingActive`state+改用新pure function嘅call site，comment更正）、`test/telemetry.test.mjs`（10條新測試）。**`public/worldmap.js`／`server.mjs`／`public/movement.js`今round完全冇改**。
- Scope check：`git diff`確認`isCapFrozenFrame`／`isNearLeadCap`／`nextCapFrozenStreakMs`（Part A approved嘅predicate）一個字都冇改；`predictedPosition`／`earnedPosition`／`advancePredictedPosition`／movement.js／server.mjs／DB／AI／Battle全部冇touch。
- 存檔影響：無schema變動。
- Rollback基準：`main` @ `c3c218095db86b4cc4dca119bc4c4303f0f99f45`（同P4-04B2一致，呢round淨係fix-on-top）。

## P4-04B2 Mobile Telemetry Overflow Fix — 2026-09-23 — Responsive 2-Column Overlay

- **目標**：修正`chatgpt-codex-connector[bot]`喺PR #59 Ready Gate之後提出嘅P2 finding——喺窄手機viewport（例：390px）,World Map容器高度約338px,但telemetry overlay已經有23行,以單column堆疊需要約366px,而overlay係`bottom`錨點向上疊,超出咗嘅部分（頂部,即FPS等頭幾行）會俾`.map-scroll`嘅`overflow:auto`頂部clip咗,睇唔到。因為呢個overlay整個P4-04B2 workstream嘅目的就係俾Charlie做real-device screenshot診斷,睇唔到FPS呢啲關鍵讀數會削弱成個workstream嘅價值,所以判斷做completion blocker,要修。
- **已獨立驗證finding**：跟`public/styles.css`實際數值計過——`.shell`(max-width 560,padding 12px×2)+`.card`(padding14px×2)後,390px viewport下`.map-scroll`淨返約338px闊,`.world-map`因`aspect-ratio:1/1`都係~338px高;23行×15.4px(11px/1.4 line-height)+12px padding≈366px——同Codex嘅估算一致。
- **修正方式（純CSS/layout,冇改任何markup/JS）**：`public/styles.css`加一個`@media(max-width:480px)`,窄屏底下將`.telemetry-overlay`由單column block stacking改做**CSS Grid 2欄×12列**（`grid-auto-flow:column;grid-template-columns:repeat(2,minmax(0,1fr));grid-template-rows:repeat(12,auto)`）——23個field原封不動,冇刪任何一個,冇accordion/collapse互動,冇internal scrolling。2欄×12列淨係需要大約12×15.4px+12px padding≈197px高,喺338px嘅高度預算入面仲有成140px margin,肯定唔會頂部或底部clip。每個row(`.telemetry-overlay>div`)加咗`overflow:hidden;text-overflow:ellipsis;white-space:nowrap`,連同`max-width:calc(100% - 20px)`令overlay闊度受container約束——正常field(label+短數值)喺~150px嘅單column闊度內完全夠位,唔需要ellipsis;淨係極端長字串(例如`#telemetry-errorcode`嗰種未bound嘅raw error message)先會被truncate,呢個係existing行為喺窄屏底下本身已經有嘅edge case,而家順便令佢更加安全。**冇縮細字體**——11px font size完全冇改,純粹靠2欄reflow就已經有充分margin。闊屏(>480px)嘅單column規則完全冇改,行為同之前一樣。
- **新測試**（`test/worldmap.test.mjs`）：(1)23個telemetry id逐一斷言喺`renderWorldMapHtml`輸出入面**啱啱好出現一次**——證明冇field被刪走；(2)joystick base/knob同map-view-toggle三個控制項斷言存在——證明冇被今round影響；(3)讀`public/styles.css`,斷言`.telemetry-overlay`嘅base(單column)rule仍然存在、有一個窄屏media query將佢轉做`display:grid`、確實係2欄（`grid-template-columns:repeat(2,`）、而且冇靠`overflow:auto/scroll`嚟解決（即冇internal scrolling）。合共3條新測試。
- **測試結果**：497（P4-04B2 Draft Review Fix baseline）＋3（新增）＝**500 tests passed, 0 failed**，連跑兩次確認唔flaky。Focused（`test/movement.test.mjs`/`test/telemetry.test.mjs`/`test/worldmap.test.mjs`）：255/255 pass。
- **改動檔案**：`public/styles.css`（加一個media query block，8行）、`test/worldmap.test.mjs`（3條新測試）。**`public/worldmap.js`（markup）、`public/app.js`、`public/telemetry.js`、`server.mjs`、`public/movement.js`今round完全冇改**——`git diff --stat`確認呢round淨係touch咗嗰兩個檔案。
- Scope check：`isCapFrozenFrame`／`MAX_PREDICTION_LEAD`／FPS計算／prediction velocity／movement rate／joystick cadence／server movement allowance／reconciliation／chaseSpeed／monster logic／server API／DB／Battle／telemetry event-window邏輯（`isFreezeEventStart`/`maxIfTracking`）／telemetry retained values全部一個字都冇改——今round純粹係display/layout fix。
- 存檔影響：無schema變動。
- Rollback基準：`main` @ `c3c218095db86b4cc4dca119bc4c4303f0f99f45`（同P4-04B2一致，呢round淨係fix-on-top）。
