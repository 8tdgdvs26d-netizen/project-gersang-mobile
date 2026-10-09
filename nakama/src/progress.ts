// VS-01 WP01 — server-owned trade progress for ONE representative character.
//
// One storage object per player holds everything a trade reads or changes, so
// a trade is a single optimistic-concurrency (OCC) write: if anything changed
// since the read, Nakama rejects the write and the command is recomputed.
//
// WP01 boundaries (approved D3 / D6):
// - Only money, backpack goods, the player's Prototype market and the market
//   recovery anchor. No ledger / profit display, no warehouse, no growth.
// - The market is the Prototype per-player market (as in local Save v14), not
//   the VS-02 shared economy.
// - Capacity uses the Prototype formula with the server-held Base STR; growth,
//   allocation and equipment are not server-authoritative yet, so Effective
//   STR = Base STR = the Prototype default.
// - This is a new SERVER data contract. It does not read, write or change the
//   local Godot Save (v14) or its schema.

const PROGRESS_COLLECTION = "vs01_wp01_progress";
const PROGRESS_KEY = "trade";
const PROGRESS_CONTRACT = "myrial.vs01.wp01.trade_progress";
const PROGRESS_CONTRACT_VERSION = 1;
const PROGRESS_RECOVERY_UNSET = -1;

interface MarketEntry {
  reference_price: number;
  current_stock: number;
  target_stock: number;
}

interface TradeProgress {
  contract: string;
  contract_version: number;
  revision: number;
  gameplay_session_id: string;
  money: number;
  character: { strength: number };
  backpack: { [goodId: string]: number };
  market: { [cityId: string]: { [goodId: string]: MarketEntry } };
  market_recovery_anchor_ms: number;
}

function progressCreateDefault(): TradeProgress {
  const market: { [cityId: string]: { [goodId: string]: MarketEntry } } = {};
  const goods = rulesGoodIds();
  for (let c = 0; c < RULES_ACTIVE_CITY_IDS.length; c++) {
    const city = RULES_ACTIVE_CITY_IDS[c];
    market[city] = {};
    for (let g = 0; g < goods.length; g++) {
      market[city][goods[g]] = {
        reference_price: rulesBaselinePrice(city, goods[g]),
        current_stock: RULES_INITIAL_STOCK,
        target_stock: RULES_TARGET_STOCK,
      };
    }
  }
  return {
    contract: PROGRESS_CONTRACT,
    contract_version: PROGRESS_CONTRACT_VERSION,
    revision: 0,
    gameplay_session_id: "",
    money: RULES_STARTING_MONEY,
    character: { strength: RULES_DEFAULT_STRENGTH },
    backpack: {},
    market: market,
    market_recovery_anchor_ms: PROGRESS_RECOVERY_UNSET,
  };
}

function progressKeysExactly(obj: any, keys: string[]): boolean {
  if (obj === null || typeof obj !== "object" || Object.prototype.toString.call(obj) !== "[object Object]") return false;
  const own = Object.keys(obj);
  if (own.length !== keys.length) return false;
  for (let i = 0; i < keys.length; i++) {
    if (!Object.prototype.hasOwnProperty.call(obj, keys[i])) return false;
  }
  return true;
}

// Strict validation of a stored document. Anything unexpected is treated as
// corruption and the command fails closed (no repair, no guessing).
function progressIsValid(p: any): boolean {
  if (!progressKeysExactly(p, ["contract", "contract_version", "revision", "gameplay_session_id", "money",
    "character", "backpack", "market", "market_recovery_anchor_ms"])) return false;
  if (p.contract !== PROGRESS_CONTRACT || p.contract_version !== PROGRESS_CONTRACT_VERSION) return false;
  if (!rulesIsInt(p.revision) || p.revision < 0) return false;
  if (typeof p.gameplay_session_id !== "string") return false;
  if (!rulesIsInt(p.money) || p.money < 0) return false;
  if (!progressKeysExactly(p.character, ["strength"]) || !rulesIsPositiveInt(p.character.strength)) return false;
  if (!rulesIsInt(p.market_recovery_anchor_ms) || p.market_recovery_anchor_ms < PROGRESS_RECOVERY_UNSET) return false;
  if (p.backpack === null || typeof p.backpack !== "object") return false;
  const backpackIds = Object.keys(p.backpack);
  for (let i = 0; i < backpackIds.length; i++) {
    if (rulesCapacityCost(backpackIds[i]) <= 0 || !rulesIsPositiveInt(p.backpack[backpackIds[i]])) return false;
  }
  const goods = rulesGoodIds();
  if (!progressKeysExactly(p.market, RULES_ACTIVE_CITY_IDS)) return false;
  for (let c = 0; c < RULES_ACTIVE_CITY_IDS.length; c++) {
    const cityMarket = p.market[RULES_ACTIVE_CITY_IDS[c]];
    if (!progressKeysExactly(cityMarket, goods)) return false;
    for (let g = 0; g < goods.length; g++) {
      const e = cityMarket[goods[g]];
      if (!progressKeysExactly(e, ["reference_price", "current_stock", "target_stock"])) return false;
      if (!rulesIsInt(e.reference_price) || e.reference_price < RULES_MIN_REFERENCE_PRICE) return false;
      if (!rulesIsInt(e.current_stock) || e.current_stock < 0) return false;
      if (!rulesIsPositiveInt(e.target_stock)) return false;
    }
  }
  return true;
}

function progressClone(p: TradeProgress): TradeProgress {
  return JSON.parse(JSON.stringify(p));
}

function progressUsedCapacity(p: TradeProgress): number {
  let used = 0;
  const ids = Object.keys(p.backpack);
  for (let i = 0; i < ids.length; i++) used += p.backpack[ids[i]] * rulesCapacityCost(ids[i]);
  return used;
}

// MarketRecovery.advance applied to a copy. Returns the number of steps.
function progressAdvanceRecovery(p: TradeProgress, nowMs: number): number {
  if (!rulesIsInt(nowMs) || nowMs < 0) return 0;
  if (p.market_recovery_anchor_ms === PROGRESS_RECOVERY_UNSET || p.market_recovery_anchor_ms > nowMs) {
    p.market_recovery_anchor_ms = nowMs;
    return 0;
  }
  let elapsed = nowMs - p.market_recovery_anchor_ms;
  if (elapsed > RULES_RECOVERY_MAX_ELAPSED_MS) {
    p.market_recovery_anchor_ms = nowMs - RULES_RECOVERY_MAX_ELAPSED_MS;
    elapsed = RULES_RECOVERY_MAX_ELAPSED_MS;
  }
  const steps = rulesRecoverySteps(elapsed);
  if (steps === 0) return 0;
  p.market_recovery_anchor_ms += steps * RULES_RECOVERY_STEP_MS;
  const amount = steps * RULES_RECOVERY_STOCK_PER_STEP;
  for (let c = 0; c < RULES_ACTIVE_CITY_IDS.length; c++) {
    const cityMarket = p.market[RULES_ACTIVE_CITY_IDS[c]];
    const goods = Object.keys(cityMarket);
    for (let g = 0; g < goods.length; g++) {
      const e = cityMarket[goods[g]];
      e.current_stock = rulesRecoverStock(e.current_stock, e.target_stock, amount);
    }
  }
  return steps;
}

function progressQuote(p: TradeProgress, cityId: string, goodId: string): { buy_price: number; buyback_price: number; stock: number } | null {
  if (!rulesCityExists(cityId) || rulesCapacityCost(goodId) <= 0) return null;
  const e = p.market[cityId][goodId];
  const dynamic = rulesDynamicReference(e.reference_price, e.current_stock, e.target_stock);
  return { buy_price: rulesBuyPrice(dynamic), buyback_price: rulesBuybackPrice(dynamic), stock: e.current_stock };
}

// What the client may cache. The client never sends any of it back as truth.
function progressView(p: TradeProgress): { [key: string]: any } {
  const quotes: { [city: string]: { [good: string]: any } } = {};
  const goods = rulesGoodIds();
  for (let c = 0; c < RULES_ACTIVE_CITY_IDS.length; c++) {
    const city = RULES_ACTIVE_CITY_IDS[c];
    quotes[city] = {};
    for (let g = 0; g < goods.length; g++) quotes[city][goods[g]] = progressQuote(p, city, goods[g]);
  }
  return {
    contract: p.contract,
    contract_version: p.contract_version,
    revision: p.revision,
    money: p.money,
    backpack: JSON.parse(JSON.stringify(p.backpack)),
    used_capacity: progressUsedCapacity(p),
    max_capacity: rulesMaxCapacity(p.character.strength),
    quotes: quotes,
  };
}
