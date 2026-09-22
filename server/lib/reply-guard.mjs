/**
 * Every figure in a reply must exist somewhere real.
 *
 * The product's first rule is that a language model never produces an amount.
 * The model writes the sentence, but the numbers in it may only come from three
 * places: the app's own state (the digest), the action being described (a quote,
 * a conversion, a task's result), or what the person themselves said. Anything
 * else is an invention, and an invented figure in a money app is worse than no
 * answer at all.
 *
 * The check is deliberately deterministic and instant — no model, no network —
 * and it compares *canonicalised* numbers, so "USD 2,018.60" in the reply and
 * "USD 2,018.60" in the digest match, "5.0000 BRL" and "5.0000" match, and
 * "R$ 190,00" is understood as 190. Formatting differences are not inventions;
 * a figure from nowhere is.
 *
 * When the reply fails, the caller replaces it with the deterministic line. The
 * person still gets an answer, and the answer is true.
 */

/** A money figure: a symbol or code near digits. Captures the digits' shape. */
const FIGURE = /(?:US\$|R\$|\$|€|£)\s?\d[\d.,]*|\b\d[\d.,]*\s?(?:USD|BRL|EUR|GBP|USDC|USDT)\b/gi;

/** Any number with a decimal separator: a rate, a fee, a percentage. */
const DECIMAL = /\b\d+[.,]\d+\b/g;

/**
 * Canonical form of a numeric token, so the same value written two ways has one
 * representation: strip symbols and codes, decide which separator is decimal,
 * drop thousands separators, trim meaningless trailing zeros.
 *
 * "US$ 2,018.60" → "2018.6"   "5.0000" → "5"   "R$ 190,00" → "190"
 */
export function canonicalFigure(raw) {
  const compact = String(raw)
    .toLowerCase()
    .replace(/(?:us\$|r\$|\$|€|£)/g, "")
    .replace(/(usd|brl|eur|gbp|usdc|usdt)/g, "")
    .replace(/\s+/g, "");
  const digits = compact.match(/\d[\d.,]*/);
  if (!digits) return "";
  let value = digits[0];

  const lastComma = value.lastIndexOf(",");
  const lastDot = value.lastIndexOf(".");
  if (lastComma >= 0 && lastDot >= 0) {
    // Whichever separator comes last is the decimal one.
    const decimal = lastComma > lastDot ? "," : ".";
    const thousands = decimal === "," ? "." : ",";
    value = value.split(thousands).join("").replace(decimal, ".");
  } else if (lastComma >= 0) {
    const parts = value.split(",");
    const grouped = parts.length > 1 && parts[0].length <= 3 && parts.slice(1).every((p) => p.length === 3);
    value = grouped ? parts.join("") : value.replace(",", ".");
  } else if (lastDot >= 0) {
    const parts = value.split(".");
    const grouped = parts.length > 1 && parts[0].length <= 3 && parts.slice(1).every((p) => p.length === 3);
    if (grouped) value = parts.join("");
  }

  if (value.includes(".")) value = value.replace(/0+$/, "").replace(/\.$/, "");
  return value.replace(/^0+(?=\d)/, "");
}

function figures(text) {
  const value = typeof text === "string" ? text : text == null ? "" : JSON.stringify(text);
  const found = new Set();
  for (const match of value.match(FIGURE) || []) {
    const canonical = canonicalFigure(match);
    if (canonical) found.add(canonical);
  }
  for (const match of value.match(DECIMAL) || []) {
    const canonical = canonicalFigure(match);
    if (canonical) found.add(canonical);
  }
  return found;
}

/**
 * Everything a figure may legitimately come from, as a set of canonical numbers:
 * the digest, the action, the quote, the person's own words, the task result.
 */
export function allowedFigures(...sources) {
  const allowed = new Set();
  for (const source of sources) {
    if (!source) continue;
    for (const figure of figures(source)) allowed.add(figure);
  }
  return allowed;
}

/**
 * @param {object} options
 * @param {string} options.say      the reply the model wrote
 * @param {object|string[]} options.allowed  everything a figure may come from
 * @returns {{ok:boolean, invented:string[]}}
 */
export function checkReplyFigures({ say, allowed = {} } = {}) {
  const reply = String(say || "");
  if (!reply) return { ok: true, invented: [] };

  const sources = Array.isArray(allowed)
    ? allowed
    : [
        allowed.digest,
        allowed.action,
        allowed.quote,
        allowed.userMessage,
        allowed.taskResult,
        allowed.snapshot,
        // The compacted conversation state: the person's own figures and the
        // quotes they were shown, carried verbatim across a long thread. A
        // model may repeat them; the guard must not call them inventions.
        allowed.compact,
      ];
  const permitted = allowedFigures(...sources);

  // A figure is clean when the same *value* appears in a permitted source; the
  // raw text is also accepted, so odd formatting never counts as invention.
  const invented = [];
  for (const figure of figures(reply)) {
    if (permitted.has(figure)) continue;
    if (sources.some((s) => typeof s === "string" && s.toLowerCase().includes(figure))) continue;
    if (sources.some((s) => s && JSON.stringify(s).toLowerCase().includes(figure))) continue;
    invented.push(figure);
  }
  return { ok: invented.length === 0, invented };
}

/**
 * Apply the check: a clean reply passes through, an invented figure replaces the
 * whole line. Trimming only the offending sentence was tempting, but a half
 * sentence about money reads worse than the plain deterministic line.
 */
export function guardReply({ say, fallback, allowed = {} } = {}) {
  const check = checkReplyFigures({ say, allowed });
  if (check.ok) return { say, guarded: false, invented: [] };
  const plain = String(fallback || "").trim();
  return {
    say: plain || UNGUARDED_FALLBACK,
    guarded: true,
    invented: check.invented,
  };
}

/**
 * The plain line used whenever a model-written reply may not be trusted — an
 * invented figure, or a line the groundedness read will not vouch for. One
 * source, so the replacement never grows a second wording.
 */
export const UNGUARDED_FALLBACK = "Let me not put a number on that without checking your account first.";
