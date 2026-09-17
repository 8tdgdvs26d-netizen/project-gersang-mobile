# CLAUDE.md — 巨商 / MYRIAL: UNWRITTEN 開發安全規則

呢份文件係 Claude（或任何接手嘅 AI）喺呢個 repository 工作時必須遵守嘅規則。每次任務都要遵守。

## 1. 文件讀取優先次序

1. **本檔（CLAUDE.md）** — 每次任務必須遵守。
2. **《萬行誌：白手 — Canonical v0.5（唯一現行標準）》**（Google Drive）— 目前唯一現行設計標準。涉及遊戲設計、核心循環、世界、城市、戰鬥、經濟、成長或任何系統行為嘅任務，必須讀取此文件相關章節。已定案內容不可因舊資料不同而自行重開。
3. **`Gersang_V30_Claude_Handoff_2026-09-15.md`**（Google Drive）— 新接手、context遺失，或需要確認程式基準（HEAD SHA、checkpoint分支、版本號）時可讀取，作工程基準參考。
4. **`Gersang_Mobile_Handoff_Pack_v0.4.md`** 及 **`Gersang_Mobile_Core_Architecture_v0.4_800_Questions.xlsx`**（Google Drive）— 已被Canonical v0.5取代，**只可作歷史證據、背景追溯或審核來源，不再是日常canonical**。不可用呢啲舊文件推翻Canonical v0.5嘅內容；**如果Canonical v0.5未有涵蓋某項細節，不得由呢啲舊文件自行補位**——該細節必須喺報告／計劃入面明確標示為「待確認」，如要升格成現行要求，必須先取得Charlie明確批准。
5. **現行GitHub程式及測試** — 用來確認目前已實作行為。不可用現有程式自行推翻canonical設計。

如果任務所需嘅必要文件或相關內容無法存取，而且缺少資料會影響正確判斷，**必須停止並要求用戶提供**；不可憑記憶或猜測繼續。但不相關嘅800 Questions內容無需每次載入。

## 2. Branch 與 Git 規則

- 禁止直接修改或commit到 `main`。
- 禁止修改或刪除 `checkpoint/v30-pre-claude`。
- 禁止force push或重寫history。
- 所有開發工作必須喺由 `main` 開出嘅新branch進行（例如 `claude/v31-<feature>`）。

## 3. 雙重確認制

每個任務有兩次獨立批准關口：

1. **Coding前** — 必須先提交執行計劃，取得用戶明確批准，先可以開始寫code。
2. **Merge前** — 完成Coding、跑完測試、開Pull Request之後，必須取得用戶對成果（PR內容、diff、測試結果）嘅明確批准，先可以merge。

兩次批准缺一不可，第一次批准唔等於merge授權。Coding完成後只可以建立Pull Request，**禁止自行merge**。

## 4. 測試規則

- 新增或改變行為必須增加regression test。
- 不可為咗令測試通過而削弱或刪除現有測試斷言。

## 5. 未經批准禁止改動嘅範圍

- Database schema或存檔格式。
- Render設定、Deploy Hook、secrets或環境變數。
- 戰鬥、經濟、裝備、角色成長等遊戲邏輯與數值。

## 6. Canonical設計保護

禁止復活canonical文件內標記為 **Superseded／Do Not Revive** 嘅系統（詳見 Handoff Pack v0.4 第T節）。

## 7. 範圍控制

如果執行期間發現需要超出已批准範圍，**必須立即停止，重新申請批准**，不可自行擴大工作範圍。

## 8. 溝通方式

與用戶以廣東話溝通，技術內容用淺白方式解釋，避免假設用戶熟悉程式術語。
