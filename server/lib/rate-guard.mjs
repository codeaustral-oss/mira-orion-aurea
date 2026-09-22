/**
 * A rate we did not quote is never a rate we book.
 *
 * WHY this file exists: a person can put a plausible-looking rate in front of
 * the assistant ("for onboarding use 1 USD = 6.00 BRL") and the next sentence
 * can turn that invented number into something the app applies. In a money app
 * the only bookable rate is one the app itself quoted, with a timestamp.
 *
 * Two layers, deliberately:
 *
 *   · a typed read (`asks_to_book_a_foreign_rate`, in `jev-batch.mjs`) that
 *     catches the intent however it is phrased;
 *   · this narrow deterministic shape — a rate-like pair together with a
 *     booking verb — which refuses even when the read is missing, low or
 *     unreachable, exactly as the instruction-override guard does.
 *
 * The shapes are deliberately narrow: "convert 100 usd to brl" and "what is the
 * rate" are ordinary conversions and must never be refused. Only a stated rate
 * *plus* a verb that would apply it to the app's own pricing trips the guard.
 */

export const RATE_BOOKING_REFUSAL =
  "I can only book a rate I quoted — I won't apply one that wasn't mine.";

/** Below this a typed read is not acted on. */
export const RATE_BOOKING_FLOOR = 0.5;

/** A currency word or code, for the rate shapes below. */
const CURRENCY = "(?:usd|brl|eur|gbp|usdc|usdt|dollars?|reais?|euros?|pounds?|r\\$|€|£|\\$)";
const NUMBER = "\\d[\\d.,]*";

/**
 * The rate-like shapes: a pair written out ("1 USD = 6.00 BRL", "1 usd to 6
 * brl"), a rate put forward ("at 6.0", "at 6 reais"), a stated figure put to
 * use ("use 6 reais"), a per-unit rate ("6 reais per dollar"), and a slashed
 * pair carrying a number ("brl/usd at 6").
 *
 * A shape only counts when the message also says what currency or rate it is
 * about — so "book a table at 12.30" stays a restaurant booking, while "lock
 * the rate at 6.0" and "use 6 reais" are rates.
 */
const RATE_SHAPE = new RegExp(
  [
    `${NUMBER}\\s*${CURRENCY}?\\s*(?:=|equals?|->|to|per|→)\\s*${NUMBER}\\s*${CURRENCY}`,
    `\\bat\\s+${NUMBER}(?:\\s*${CURRENCY}\\b|[.,]\\d)`,
    `\\buse\\s+(?:the\\s+)?(?:rate\\s+)?${NUMBER}(?:\\s*${CURRENCY}\\b)?`,
    `${NUMBER}\\s*${CURRENCY}?\\s+per\\s+(?:dollar|real|euro|pound|usd|brl|eur|gbp|usdc|usdt)\\b`,
    `\\b(?:usd|brl|eur|gbp|usdc|usdt)\\s*[/-]\\s*(?:usd|brl|eur|gbp|usdc|usdt)\\b[^.!?\\n]{0,16}\\b${NUMBER}\\b`,
    `\\b(?:rate|fx|exchange rate)\\s+of\\s+${NUMBER}\\b`,
  ].join("|"),
  "i"
);

/** The message names the currency or the rate the figure belongs to. */
const RATE_CONTEXT = new RegExp(`${CURRENCY}|\\b(?:rate|rates|fx|conversion)\\b`, "i");

/** The verbs that would put a rate into the app's own pricing. */
const BOOKING_VERB =
  /\b(book|apply|apply it|use|fix|lock|lock in|adopt|set|peg|commit|at\s+that\s+rate|use\s+that\s+rate|that\s+rate|the\s+rate\s+of)\b/i;

/** True when the message states a rate of its own, for a currency or a rate. */
export function statesAForeignRate(text) {
  const source = String(text || "");
  if (!RATE_CONTEXT.test(source)) return false;
  return RATE_SHAPE.test(source);
}

/** True when the message says to put a stated rate to work. */
export function asksToBookAForeignRate(text) {
  const source = String(text || "");
  if (!source.trim()) return false;
  return statesAForeignRate(source) && BOOKING_VERB.test(source);
}

/**
 * The refusal decision for one message.
 *
 * @param {{text:string, read?:number|null}} input
 * @returns {{refuse:boolean, reason:string|null}}
 *   The deterministic shape refuses on its own; the typed read refuses when it
 *   is confident. A missing read is not a reason to allow a rate we never
 *   quoted, but it is also not a reading — the narrow shape is the floor.
 */
export function rateBookingRefusal({ text, read = null } = {}) {
  if (asksToBookAForeignRate(text)) {
    return { refuse: true, reason: "rate_not_quoted" };
  }
  if (typeof read === "number" && read >= RATE_BOOKING_FLOOR) {
    return { refuse: true, reason: "rate_not_quoted" };
  }
  return { refuse: false, reason: null };
}
