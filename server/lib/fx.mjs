/**
 * Near-live exchange rates, from sources that need no key.
 *
 * A rate is a fact with a timestamp, so this module reports both: the rates it
 * fetched, when it fetched them, and which source said them. The cache is one
 * minute — short enough that a quote feels current, long enough that a chat
 * conversation does not hammer a public endpoint.
 *
 * Two public sources are tried in turn. Neither is a trading feed; both are
 * good enough to price a demo swap honestly, and when neither answers the app
 * falls back to its own reference table and says so. Nothing here is ever
 * invented: a failed fetch is a failure, not a number.
 */

const CACHE_MS = 60_000;
const TIMEOUT_MS = 6000;

/** The currencies the product prices. Stablecoins default to par. */
const STABLECOINS = { USDC: 1, USDT: 0.9998 };

let cache = { at: 0, value: null };

async function timedJson(fetchImpl, url, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(url, {
      signal: controller.signal,
      headers: { accept: "application/json", "user-agent": "mira-prototype/1.0" },
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

/** Coinbase's public spot endpoint: fiat and stablecoins, updated continuously. */
async function fromCoinbase(fetchImpl, timeoutMs) {
  const data = await timedJson(fetchImpl, "https://api.coinbase.com/v2/exchange-rates?currency=USD", timeoutMs);
  const rates = data?.data?.rates;
  if (!rates || typeof rates !== "object") throw new Error("no rates");
  const perUSD = { USD: 1 };
  for (const code of ["EUR", "BRL", "GBP"]) {
    const value = Number(rates[code]);
    if (Number.isFinite(value) && value > 0) perUSD[code] = value;
  }
  for (const [code, fallback] of Object.entries(STABLECOINS)) {
    const value = Number(rates[code]);
    perUSD[code] = Number.isFinite(value) && value > 0 ? value : fallback;
  }
  if (perUSD.EUR == null && perUSD.BRL == null) throw new Error("no usable rates");
  return { perUSD, source: "coinbase" };
}

/** The ExchangeRate-API open endpoint: fiat only, once a day. */
async function fromOpenErApi(fetchImpl, timeoutMs) {
  const data = await timedJson(fetchImpl, "https://open.er-api.com/v6/latest/USD", timeoutMs);
  const rates = data?.rates;
  if (!rates || typeof rates !== "object") throw new Error("no rates");
  const perUSD = { USD: 1 };
  for (const code of ["EUR", "BRL", "GBP"]) {
    const value = Number(rates[code]);
    if (Number.isFinite(value) && value > 0) perUSD[code] = value;
  }
  for (const [code, fallback] of Object.entries(STABLECOINS)) perUSD[code] = fallback;
  if (perUSD.EUR == null && perUSD.BRL == null) throw new Error("no usable rates");
  return { perUSD, source: "open.er-api.com" };
}

/**
 * @returns {Promise<{ok:boolean, perUSD?:object, asOf?:number, source?:string,
 *                    cached?:boolean, detail?:string}>}
 */
export async function liveRates({ fetchImpl = globalThis.fetch, now = Date.now(), timeoutMs = TIMEOUT_MS } = {}) {
  if (cache.value && now - cache.at < CACHE_MS) {
    return { ...cache.value, cached: true };
  }
  let lastDetail = "";
  for (const source of [fromCoinbase, fromOpenErApi]) {
    try {
      const { perUSD, source: name } = await source(fetchImpl, timeoutMs);
      const value = { ok: true, base: "USD", perUSD, asOf: Date.now(), source: name };
      cache = { at: now, value };
      return { ...value, cached: false };
    } catch (err) {
      lastDetail = String(err?.message || err);
    }
  }
  cache = { at: now, value: null };
  return { ok: false, detail: `No live rate source answered (${lastDetail}).` };
}

/** For tests. */
export function clearRateCache() {
  cache = { at: 0, value: null };
}
