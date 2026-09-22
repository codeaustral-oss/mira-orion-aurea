/**
 * The corridors this build actually quotes.
 *
 * WHY this file exists: a question about money in a currency the build does not
 * price used to end anywhere — a transfer prompt, a research task, or a model
 * paragraph that guessed. The honest answer needs one list of what is priced,
 * and it has to be the same list the rate table and the app use. So the list
 * lives here once, and every answer about a corridor reads it.
 *
 * A corridor is priced when both of its currencies are quoted. The rate table
 * quotes everything against one USD base, so a pair without a direct entry
 * (EUR/BRL, say) is still a priced cross through USD — the same arithmetic the
 * Move money screen does. A currency outside the quoted set has no rate at all,
 * and the answer says so instead of inventing one.
 */

/** The currencies a quote can be made in. One list; the rate sources and the
 *  app's own asset table carry the same codes. */
export const QUOTED_CURRENCIES = Object.freeze(["USD", "BRL", "EUR", "GBP", "USDC", "USDT"]);

/**
 * The directed pairs the product sells as corridors: USD/BRL, BRL/USD,
 * USD/EUR, EUR/USD, GBP/USD, USD/USDC and USD/USDT, with the inverse of every
 * pair whose inverse is not already listed (USD/GBP, USDC/USD, USDT/USD).
 */
export const DIRECT_PAIRS = Object.freeze([
  Object.freeze(["USD", "BRL"]),
  Object.freeze(["BRL", "USD"]),
  Object.freeze(["USD", "EUR"]),
  Object.freeze(["EUR", "USD"]),
  Object.freeze(["GBP", "USD"]),
  Object.freeze(["USD", "GBP"]),
  Object.freeze(["USD", "USDC"]),
  Object.freeze(["USDC", "USD"]),
  Object.freeze(["USD", "USDT"]),
  Object.freeze(["USDT", "USD"]),
]);

const QUOTED = new Set(QUOTED_CURRENCIES);
const DIRECT = new Set(DIRECT_PAIRS.map(([from, to]) => `${from}/${to}`));

/** True when a quote can be made in this currency at all. */
export function isQuoted(code) {
  return QUOTED.has(String(code || "").toUpperCase());
}

/**
 * What this build can say about a pair.
 *
 * @returns {{ok:boolean, from:string, to:string, direct:boolean, via:string|null,
 *            route:string[]}}
 *   `ok` is the only thing a caller needs to branch on: true means a rate can be
 *   quoted (directly or through the USD base), false means there is no honest
 *   number to give.
 */
export function corridorFor(from, to) {
  const source = String(from || "").toUpperCase();
  const destination = String(to || "").toUpperCase();
  if (!isQuoted(source) || !isQuoted(destination) || source === destination) {
    return { ok: false, from: source, to: destination, direct: false, via: null, route: [] };
  }
  if (DIRECT.has(`${source}/${destination}`)) {
    return { ok: true, from: source, to: destination, direct: true, via: null, route: [source, destination] };
  }
  // Priced by crossing the USD base: EUR → USD → BRL.
  return { ok: true, from: source, to: destination, direct: false, via: "USD", route: [source, "USD", destination] };
}

/** The pairs a person can read, in the order the product states them. */
export function quotedPairs() {
  return DIRECT_PAIRS.map(([from, to]) => `${from}/${to}`);
}

/** "USD/BRL, BRL/USD, USD/EUR, EUR/USD, GBP/USD, USD/GBP, USD/USDC, USDC/USD, USD/USDT, USDT/USD" */
export function quotedPairsPhrase() {
  return quotedPairs().join(", ");
}

/** "USD, BRL, EUR, GBP, USDC and USDT" — a list a person would read out. */
export function quotedCurrenciesPhrase() {
  const codes = [...QUOTED_CURRENCIES];
  return `${codes.slice(0, -1).join(", ")} and ${codes[codes.length - 1]}`;
}

/**
 * Currency markers the build does not quote, and the words people actually use
 * for them. Codes only, plus the words that name one currency unambiguously: a
 * bare "peso" is not enough to know whether the answer is MXN or ARS, so the
 * ambiguous ones carry their country.
 */
const UNQUOTED_MARKERS = Object.freeze([
  { code: "MXN", words: ["mxn", "mexican peso", "mexican pesos", "pesos mexicanos"] },
  { code: "ARS", words: ["ars", "argentine peso", "argentine pesos", "peso argentino", "pesos argentinos"] },
  { code: "NGN", words: ["ngn", "naira", "nairas"] },
  { code: "INR", words: ["inr", "rupee", "rupees", "rupia", "rupias"] },
  { code: "JPY", words: ["jpy", "yen"] },
  { code: "CNY", words: ["cny", "yuan", "renminbi"] },
  { code: "ZAR", words: ["zar", "rand"] },
  { code: "CLP", words: ["clp", "chilean peso", "chilean pesos"] },
  { code: "COP", words: ["cop", "colombian peso", "colombian pesos"] },
  { code: "PEN", words: ["pen", "sol", "soles"] },
  { code: "TRY", words: ["try", "lira", "liras"] },
  { code: "AED", words: ["aed", "dirham", "dirhams"] },
  { code: "THB", words: ["thb", "baht"] },
  { code: "CHF", words: ["chf", "swiss franc", "swiss francs"] },
  { code: "AUD", words: ["aud", "australian dollar", "australian dollars"] },
  { code: "CAD", words: ["cad", "canadian dollar", "canadian dollars"] },
  { code: "NZD", words: ["nzd", "new zealand dollar", "new zealand dollars"] },
  { code: "SEK", words: ["sek", "swedish krona", "swedish kronor"] },
  { code: "NOK", words: ["nok", "norwegian krone", "norwegian kroner"] },
  { code: "DKK", words: ["dkk", "danish krone", "danish kroner"] },
  { code: "PLN", words: ["pln", "zloty", "złoty"] },
  { code: "SGD", words: ["sgd", "singapore dollar", "singapore dollars"] },
  { code: "HKD", words: ["hkd", "hong kong dollar", "hong kong dollars"] },
  { code: "KRW", words: ["krw", "won"] },
  { code: "ILS", words: ["ils", "shekel", "shekels"] },
]);

/** A currency mention that cannot be priced, first one wins. */
export function unquotedCurrencyIn(text) {
  const source = String(text || "").toLowerCase();
  for (const marker of UNQUOTED_MARKERS) {
    for (const word of marker.words) {
      if (new RegExp(`\\b${word}\\b`).test(source)) return marker.code;
    }
  }
  return null;
}

/** The words that make a message about money rather than, say, a country. */
const MONEY_CONTEXT =
  /\b(convert|converting|exchange|change|changing|swap|price|pricing|quote|rate|send|sending|receive|receiving|payout|pay\s?out|pay|paid|transfer|hold|holding|deposit|withdraw|buy|sell|get|give|gives|corridor|balance|worth|cost|costs|approximate|estimate|figures?|number)\b/i;

/** The same table, as words people write: code, symbol and name. */
const QUOTED_WORDS = Object.freeze([
  { code: "USD", pattern: /\b(?:usd|us dollars?|dollars?|dólares?|dolares?)\b|\bus\$/gi },
  { code: "BRL", pattern: /\b(?:brl|reais?|real)\b|\br\$/gi },
  { code: "EUR", pattern: /\b(?:eur|euros?)\b|€/gi },
  { code: "GBP", pattern: /\b(?:gbp|pounds?|sterling)\b|£/gi },
  { code: "USDC", pattern: /\b(?:usdc|usd coin)\b/gi },
  { code: "USDT", pattern: /\b(?:usdt|tether)\b/gi },
]);

/** The conversion cues that make a message a request for a price. */
const PRICE_CUE =
  /\b(convert|converting|exchange|changing|change|swap|price|pricing|quote|rate|how much|worth|cost|costs|lands|becomes|in brl|in usd|in eur|to reais|to dollars|to euros|to pounds|to dollars)\b/i;

/** The swap fee, in the source asset's major units. Mirrors
 *  `SimulatedSwapProvider.feeMajorUnits` in the app. */
export const SWAP_FEE_MAJOR = 0.25;

/** Places a currency is written with. */
const MINOR_SCALE = { USD: 2, BRL: 2, EUR: 2, GBP: 2, USDC: 6, USDT: 6 };

/** Every quoted currency named in the message, in the order it appears. */
export function quotedCurrenciesIn(text) {
  const source = String(text || "");
  const found = [];
  for (const { code, pattern } of QUOTED_WORDS) {
    pattern.lastIndex = 0;
    let match;
    while ((match = pattern.exec(source)) !== null) {
      found.push({ code, index: match.index, end: match.index + match[0].length });
    }
  }
  return found
    .sort((a, b) => a.index - b.index)
    .filter((entry, position, list) => position === 0 || entry.code !== list[position - 1].code);
}

/**
 * A priceable corridor question with an amount in one of the currencies, or
 * null. Narrow: two quoted currencies, an amount written beside one of them,
 * and a conversion cue. "Buy a wallet for my euros" names one currency and is
 * left alone; a question naming a currency the build cannot price belongs to
 * the corridor answer instead.
 */
export function corridorQuoteQuestion(text) {
  const source = String(text || "");
  if (!PRICE_CUE.test(source)) return null;
  const mentions = quotedCurrenciesIn(source);
  if (mentions.length < 2) return null;

  for (const mention of mentions) {
    const before = source.slice(Math.max(0, mention.index - 18), mention.index);
    const after = source.slice(mention.end, mention.end + 18);
    const afterAmount = /^\s*([0-9][0-9.,]*)\b/.exec(after);
    const beforeAmount = /([0-9][0-9.,]*)\s*$/.exec(before);
    const raw = afterAmount?.[1] ?? beforeAmount?.[1] ?? null;
    if (!raw) continue;
    const amountMajor = Number.parseFloat(raw.replace(/,/g, ""));
    if (!Number.isFinite(amountMajor) || amountMajor <= 0) continue;
    const destination = mentions.find((entry) => entry.code !== mention.code);
    if (!destination) continue;
    return { from: mention.code, to: destination.code, amountMajor };
  }
  return null;
}

/** Round to the currency's own scale, never a float artifact on the screen. */
function roundToScale(value, code) {
  const scale = MINOR_SCALE[code] ?? 2;
  const factor = 10 ** scale;
  return Math.round(value * factor) / factor;
}

function formatMajor(value, code) {
  const scale = MINOR_SCALE[code] ?? 2;
  return `${code} ${roundToScale(value, code).toLocaleString("en-US", {
    minimumFractionDigits: scale,
    maximumFractionDigits: scale,
  })}`;
}

/**
 * Price a supported corridor from a rate table. Pure: the table is passed in,
 * so the arithmetic is tested without a network, and a failed rate source is a
 * null — never an invented number.
 *
 * @param {{from:string,to:string,amountMajor:number}} question
 * @param {{ok:boolean, perUSD?:object, asOf?:number, source?:string}} rates
 */
export function priceCorridor(question, rates) {
  if (!question || !rates?.ok || !rates.perUSD) return null;
  const from = Number(rates.perUSD[question.from]);
  const to = Number(rates.perUSD[question.to]);
  if (!Number.isFinite(from) || !Number.isFinite(to) || from <= 0 || to <= 0) return null;
  const rate = to / from;
  const landed = roundToScale(question.amountMajor * rate, question.to);
  return {
    from: question.from,
    to: question.to,
    amountMajor: question.amountMajor,
    rate,
    feeMajor: SWAP_FEE_MAJOR,
    landedMajor: landed,
    allInMajor: question.amountMajor + SWAP_FEE_MAJOR,
    asOf: rates.asOf ?? null,
    source: rates.source ?? null,
  };
}

/** The same words the app's FX answer uses. */
export function renderCorridorQuote(quote) {
  const age = quote.asOf ? ` · live ${new Date(quote.asOf).toISOString().slice(11, 16)} UTC` : "";
  const rateLine = `1 ${quote.from} = ${quote.rate.toFixed(4)} ${quote.to}${age}`;
  return (
    `${rateLine}. ${formatMajor(quote.amountMajor, quote.from)} becomes ` +
    `${formatMajor(quote.landedMajor, quote.to)}; the fee is ` +
    `${formatMajor(quote.feeMajor, quote.from)}, so the all-in cost is ` +
    `${formatMajor(quote.allInMajor, quote.from)}. ` +
    "Say the word and I'll make the swap — nothing moves until you do."
  );
}

/**
 * A question about money in a currency this build cannot price, or null.
 *
 * Narrow on purpose: a currency the build does not quote, named in a message
 * that is asking about money. "Argentina" alone is a country question and is
 * left to the model; "NGN payout" is a corridor question and gets the honest
 * answer deterministically.
 */
export function corridorQuestion(text) {
  const code = unquotedCurrencyIn(text);
  if (!code) return null;
  if (!MONEY_CONTEXT.test(String(text || ""))) return null;
  return { code };
}

/**
 * The deterministic answer for a corridor the build cannot price. It names the
 * currency that cannot be quoted, then exactly what can, and nothing else.
 */
export function corridorAnswer(code) {
  return (
    `${code} is not a corridor this build prices. I can quote ${quotedPairsPhrase()} — ` +
    `any pair among ${quotedCurrenciesPhrase()} — and I won't invent a rate for anything else.`
  );
}

export function unquotedCodes() {
  return UNQUOTED_MARKERS.map((marker) => marker.code);
}

/** A spot-rate question is a read, never a transfer proposal or research job. */
export function spotRateQuestion(text) {
  const source = String(text || "");
  if (!/\b(rate|fx|exchange rate|cotacao|cotação|cambio|câmbio)\b/i.test(source)) return null;
  if (/\b(send|pay|book|lock|buy|sell|transfer|swap|convert|use|apply|yesterday|historical|forecast|predict|tomorrow|last week)\b/i.test(source)) return null;
  if (corridorQuoteQuestion(source)) return null;
  const mentions = quotedCurrenciesIn(source);
  const currencies = [...new Set(mentions.map(item => item.code))];
  if (currencies.length !== 2) return null;
  return { from: currencies[0], to: currencies[1] };
}

export function renderSpotRate(question, rates) {
  const from = Number(rates?.perUSD?.[question.from]);
  const to = Number(rates?.perUSD?.[question.to]);
  if (!rates?.ok || !Number.isFinite(from) || !Number.isFinite(to) || from <= 0 || to <= 0) {
    return `I couldn't check the ${question.from}/${question.to} rate right now. Please try again in a moment.`;
  }
  const checked = rates.asOf ? new Date(rates.asOf).toISOString().replace("T", " ").slice(0, 16) + " UTC" : "time unavailable";
  return `1 ${question.from} = ${(to / from).toFixed(4)} ${question.to}.\n\nSource: ${rates.source || "exchange-rate provider"} · checked ${checked}. This is an indicative rate; your final exchange quote may differ.`;
}
