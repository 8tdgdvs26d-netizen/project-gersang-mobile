# VS-01 WP01 Backend Provider 簡短比較：Supabase／PlayFab／Firebase

狀態：DRAFT — 待 GPT Review。日期：2026-10-09。

**證據等級要分清楚：**

- Supabase：有實機 Spike 證據（本目錄 `EVIDENCE.md`）。
- PlayFab、Firebase：**只係文件研究，冇實機 Spike**。內容按一般公開資料整理，鎖定前必須以官方最新文件及價格頁再核實。
- 本文件**唔係 Provider 鎖定決定**。鎖定由 Charlie 決定（Canonical A11）。

## 比較表

| 項目 | Supabase | PlayFab（Microsoft） | Firebase（Google） |
|---|---|---|---|
| **核心模型** | PostgreSQL 關係型數據庫 + Auth + Edge Functions（Deno） | 遊戲專用 BaaS：玩家帳號、Player Data、Economy／Inventory、排行榜、CloudScript | NoSQL 文件數據庫（Firestore）+ Auth + Cloud Functions |
| **Godot 整合** | ✅ **已驗證**：Godot 4.7.2 用內建 `HTTPRequest` 直接呼叫 REST／Edge Function（Mac Live Probe PASS）；唔需要 SDK | REST API 可以用 `HTTPRequest` 呼叫；冇官方 Godot SDK（官方 SDK 主要係 Unity／Unreal／C++），要自己包裝或用社群插件 | REST API 可以用 `HTTPRequest` 呼叫；冇官方 Godot SDK，有社群插件；Firestore REST 介面較繁複 |
| **Server Authority** | ✅ **已驗證**：RLS + 只限 service_role 嘅 `SECURITY DEFINER` RPC；Client 直接寫入被拒 | CloudScript（Azure Functions）+ 只容許 Server API 改經濟數據；需要逐項設定 Client 權限 | Security Rules + Cloud Functions；Rules 寫法同 SQL 唔同，複雜規則較難測試 |
| **防重複／原子性** | ✅ **已驗證**：SQL transaction、row lock、收據表；並行重複 x20 只生效一次 | Economy API 有部分內建保護；自訂 command 嘅 idempotency 需要自己設計 | Firestore transaction 有支援；跨文件 idempotency 及收據要自己設計，並受 transaction 限制 |
| **安全** | RLS 預設開啟；已知問題：Supabase 預設授權令 `service_role` 有多出權限（已記錄為 Known Risk） | 遊戲反作弊導向設計（Server 驗證經濟）；Title Secret Key 必須只留 Server | Security Rules 寫錯容易造成資料外洩；App Check 可以加強 |
| **成本** | 有免費層（閒置項目會暫停）；正式用通常需要月費方案；按用量加收。數據庫規模可預測 | 按 MAU 及功能分級；免費開發層；正式上線後費用隨玩家數上升 | 免費層；按讀寫次數及流量計費；遊戲高頻讀寫可能令成本難預測 |
| **維護難度** | 中：要識 SQL、RLS、Migration；但工具成熟，Spike 已經建立模式 | 中：遊戲功能現成，但 CloudScript 及設定散落喺 Dashboard，版本控制較弱 | 中至高：NoSQL 資料建模、Security Rules 測試、索引管理 |
| **未來擴展（對照 Canonical）** | 共享市場 Aggregation（VS-02）可以用 SQL／排程處理；開源可以自行託管，減少供應商鎖定 | 排行榜、Economy、Matchmaking 現成，適合長期 Online 功能；平台鎖定較高 | 實時同步強；但複雜經濟查詢及 Aggregation 較難；平台鎖定較高 |
| **A12 低固定成本** | 符合（需核實正式方案價格） | 符合（需核實 MAU 計費） | 符合起步期；高頻寫入時需要監察 |
| **A13 Modular Monolith** | 符合：一個數據庫 + 少量 Function | 大致符合：功能由平台模組提供 | 大致符合：但容易散成多個 Function |

## 初步觀察（唔係決定）

1. Supabase 係目前**唯一有實機證據**嘅候選，而且 WP01 核心準則（Authority、防重複、Session、跨帳號、Godot 連接）全部 PASS。
2. PlayFab 嘅優勢係遊戲功能現成；如果 Charlie 想喺鎖定前比較，最低成本係做一個同 WP01 相同準則嘅小型 PlayFab Spike。
3. Firebase 嘅 NoSQL 模型同 VS-02 共享經濟（Aggregation、Supply／Demand）嘅需要較唔匹配，估計需要較多額外設計。
4. Provider 鎖定前建議補做：正式方案價格核實、流動網絡延遲量度、Supabase 最小權限正式 schema 設計。

是否需要 PlayFab／Firebase 實機 Spike，及是否鎖定 Supabase，交 GPT Review 後由 Charlie 決定。
