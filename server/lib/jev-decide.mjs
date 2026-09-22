/**
 * More of what Jev is for.
 *
 * `jev-read.mjs` reads an inbound message. This module uses the same primitives
 * for the rest of the money path, where a *decision with a confidence* is worth
 * more than a sentence:
 *
 *   1. **A quote, before you confirm it.** Direction, plausibility, and whether
 *      the figure reads as the amount or as the all-in cost. A conversion shown
 *      the wrong way round is the mistake that actually costs money, so it is
 *      checked by something that answers yes/no with a probability.
 *   2. **A payment, before it goes.** Whether it looks like the person's usual
 *      pattern, and whether anything about it is inconsistent.
 *   3. **A question that needs advice.** Investment, tax and legal questions are
 *      classified and refused *by policy*, not by luck: the model is asked
 *      whether this is a request for advice, and code decides what to do.
 *   4. **The language to answer in.**
 *
 * Nothing here generates text and nothing here decides money. Every answer is a
 * choice, a score or a probability, and the caller branches on it in code.
 */

import { escalate } from "./jev-escalate.mjs";

const ENDPOINT = "https://api.typesafe.ai/v1/systemone";
const TIMEOUT_MS = 8000;

async function systemOne(questions, state, { fetchImpl = globalThis.fetch, signal } = {}) {
  const key = process.env.TYPESAFE_API_KEY;
  if (!key) return { ok: false, detail: "No TYPESAFE_API_KEY configured." };
  if (!state) return { ok: false, detail: "Nothing to evaluate." };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  const onAbort = () => controller.abort();
  if (signal) {
    if (signal.aborted) controller.abort();
    else signal.addEventListener("abort", onAbort, { once: true });
  }

  const started = Date.now();
  try {
    const response = await fetchImpl(ENDPOINT, {
      method: "POST",
      signal: controller.signal,
      headers: { "content-type": "application/json", authorization: `Bearer ${key}` },
      body: JSON.stringify({
        state: String(state).slice(0, 8000),
        model: process.env.TYPESAFE_MODEL || "jev-1.13.0",
        questions,
      }),
    });
    if (!response.ok) return { ok: false, detail: `Jev answered HTTP ${response.status}.` };
    const parsed = await response.json();
    return { ok: true, answers: parsed?.answers || {}, latencyMs: Date.now() - started };
  } catch (err) {
    const aborted = err?.name === "AbortError";
    return { ok: false, detail: aborted ? "Jev timed out." : `Jev call failed: ${err?.message || err}` };
  } finally {
    clearTimeout(timer);
    if (signal) signal.removeEventListener("abort", onAbort);
  }
}

/** The probability that a statement is true, or null when Jev did not answer. */
function noul(answers, name) {
  const value = answers?.[name]?.noul;
  return typeof value === "number" ? value : null;
}

function score(answers, name) {
  const value = answers?.[name]?.score;
  return typeof value === "number" ? value : null;
}

/** How sure the model said it was; never a substitute for the answer's value. */
function confidenceOf(answers, name) {
  const value = answers?.[name]?.confidence;
  return typeof value === "number" ? value : null;
}

// ── 1 · the quote ──────────────────────────────────────────────────────────

/**
 * Check a conversion before a person confirms it.
 *
 * The app already computes the arithmetic; this asks the questions arithmetic
 * cannot: does the stated direction match the pair, is the rate plausible, and
 * is the figure being read as the amount rather than the all-in total. A low
 * score produces a review flag with a reason, never a changed number.
 */
export async function verifyQuote(quote, options = {}) {
  if (!quote) return { ok: false, detail: "No quote to check." };
  const state = [
    `Conversion from ${quote.fromAmount?.display || "?"} to ${quote.toAmount?.display || "?"}.`,
    `Quoted rate: ${quote.rateLabel || `${quote.from} to ${quote.to}`}.`,
    `Fee ${quote.fee?.display || "?"}. Total debit ${quote.totalDebit?.display || "?"}.`,
  ].join(" ");
  const questions = {
    direction_is_right: {
      type: "noul",
      instructions: "Does the stated rate convert the source currency into the destination currency in the direction written (source = destination), rather than the reverse?",
    },
    rate_is_plausible: {
      type: "noul",
      instructions: "Is this exchange rate plausible for this pair of currencies, as an order of magnitude? Answer no if it looks like an inverted rate or off by a factor of ten or more.",
    },
    reads_as_the_amount: {
      type: "noul",
      instructions: "Does the figure being confirmed read as the amount being converted, rather than as the fee or the all-in total?",
    },
    confidence: {
      type: "score",
      instructions: "How confident is the person likely to be that this is the conversion they intended?",
      criteria: ["Not confident, this looks wrong", "Probably right, worth a look", "Clear and correct"],
    },
  };
  const result = await systemOne(questions, state, options);
  if (!result.ok) return result;
  const plausible = noul(result.answers, "rate_is_plausible");
  const readsAsAmount = noul(result.answers, "reads_as_the_amount");
  // A.4: a direction read below the floor is the coin flip that hides a
  // reversed rate. One second, two-way question settles the direction; when it
  // is below the floor too, the first read stands and the concern is raised
  // exactly as before.
  const direction = await escalate(
    "quote.direction_is_right",
    {
      ok: true,
      value: noul(result.answers, "direction_is_right"),
      confidence: confidenceOf(result.answers, "direction_is_right"),
      latencyMs: result.latencyMs,
    },
    async () => {
      const second = await systemOne(
        {
          rate_direction: {
            type: "choice",
            instructions: `Is the quoted rate written as ${quote.from || "the source currency"} per ${quote.to || "the destination currency"} (one source unit equals N destination units), or as ${quote.to || "the destination currency"} per ${quote.from || "the source currency"} (one destination unit equals N source units)?`,
            criteria: {
              source_per_destination: `1 ${quote.from || "source"} = N ${quote.to || "destination"}: the direction the conversion is being made in`,
              destination_per_source: `1 ${quote.to || "destination"} = N ${quote.from || "source"}: the reverse of the conversion being made`,
            },
          },
        },
        state,
        options
      );
      if (!second.ok) return { ok: false, detail: second.detail, latencyMs: second.latencyMs ?? 0 };
      const choice = second.answers?.rate_direction?.choice ?? null;
      return {
        ok: true,
        value: choice === "source_per_destination" ? 1 : choice === "destination_per_source" ? 0 : null,
        confidence: confidenceOf(second.answers, "rate_direction"),
        latencyMs: second.latencyMs,
      };
    },
    { floor: 0.5 }
  );
  const concerns = [];
  if (direction.value !== null && direction.value < 0.5) concerns.push("the rate may be the wrong way round");
  if (plausible !== null && plausible < 0.5) concerns.push("the rate looks off for this pair");
  if (readsAsAmount !== null && readsAsAmount < 0.5) concerns.push("the figure may be the total rather than the amount");
  return {
    ok: true,
    latencyMs: direction.latencyMs || result.latencyMs,
    checked: true,
    clear: concerns.length === 0,
    concerns,
    direction: direction.value,
    directionEscalated: direction.escalated === true,
    plausible,
    readsAsAmount,
    confidence: score(result.answers, "confidence"),
  };
}

// ── 2 · the payment ────────────────────────────────────────────────────────

/**
 * Look at a payment the way a careful friend would: does this fit, and is
 * anything about it inconsistent?
 */
export async function checkPayment(payment, digest, options = {}) {
  if (!payment) return { ok: false, detail: "No payment to check." };
  const state = [
    `Payment of ${payment.amount?.display || payment.totalDebit?.display || "?"} to ${payment.payee || "an unnamed recipient"}.`,
    payment.memo ? `Reference: ${payment.memo}.` : null,
    "Recent activity and balances follow.",
    String(digest || "").slice(0, 3000),
  ]
    .filter(Boolean)
    .join("\n");

  const result = await systemOne(
    {
      fits_the_pattern: {
        type: "noul",
        instructions: "Is this payment consistent with the account holder's usual payments in amount, recipient and frequency?",
      },
      anything_inconsistent: {
        type: "noul",
        instructions: "Is there anything about this payment that a careful reviewer would question — a mismatch between the recipient and the reference, a duplicated amount, or an unusual destination?",
      },
      risk: {
        type: "score",
        instructions: "How much does this payment warrant a second look?",
        criteria: ["Nothing unusual", "Worth a glance", "Needs review before sending"],
      },
    },
    state,
    options
  );
  if (!result.ok) return result;
  const risk = score(result.answers, "risk");
  const inconsistent = noul(result.answers, "anything_inconsistent");
  return {
    ok: true,
    latencyMs: result.latencyMs,
    risk,
    inconsistent,
    fits: noul(result.answers, "fits_the_pattern"),
    note:
      risk !== null && risk >= 1.5
        ? "Worth a second look before this goes."
        : inconsistent !== null && inconsistent >= 0.6
          ? "One thing here does not match the rest."
          : null,
  };
}

// ── 3 · advice that must not be given ──────────────────────────────────────

/**
 * Investment, tax and legal questions are out of scope by policy. Jev decides
 * whether the message is one of those, and code decides what to answer — the
 * model never gets the chance to advise.
 */
export async function classifyAdvice(text, options = {}) {
  const state = String(text || "").slice(0, 2000);
  if (!state) return { ok: false, detail: "Nothing to classify." };
  const result = await systemOne(
    {
      wants_advice: {
        type: "noul",
        instructions:
          "Is this a request for investment, trading, tax or legal advice - what someone should do: 'should I buy', 'is it a good idea', 'will it go up', 'what would you do', 'recommend a fund', or how to treat income for tax? An instruction to execute is NOT advice: 'buy 10 shares of AAPL', 'sell my NVDA shares', 'invest 1000 in an ETF' are orders to place, not questions about what to do. Neither is a question about a price or a plain fact ('how much is Tesla stock', 'what is a dividend').",
      },
      is_about_market_prices: {
        type: "noul",
        instructions:
          "Is this asking for a live market price, a stock or share price, or a rate that changes by the minute? " +
          "Answer no when the person is asking to convert their own money between currencies: that is a conversion, not a market quote.",
      },
      is_own_conversion: {
        type: "noul",
        instructions:
          "Is this asking to convert, exchange or change their own money from one currency into another (dollars into euros, reais into dollars)?",
      },
      topic: {
        type: "choice",
        instructions: "What is this about?",
        criteria: {
          own_money: "Their own balances, payments, cards or plan",
          market: "Markets, prices, shares, investments or yield",
          tax_or_legal: "Tax, visa or legal questions",
          general: "Anything else",
        },
      },
    },
    state,
    options
  );
  if (!result.ok) return result;
  const read = noul(result.answers, "wants_advice");
  const order = orderNotAdvice(state);
  // A.4: the advice band. A plain order is already deterministic (the guard
  // below), below 0.35 the deterministic path stands without paying twice, and
  // only the 0.35–0.5 band buys one more, differently-asked read. When that
  // read is below the floor as well, the first answer stands.
  const wantsAdvice = await escalate(
    "advice.wants_advice",
    {
      ok: true,
      value: order ? 0 : read,
      confidence: confidenceOf(result.answers, "wants_advice"),
      latencyMs: result.latencyMs,
    },
    async () => {
      const second = await systemOne(
        {
          wants_advice: {
            type: "noul",
            instructions:
              "Is this asking what the person should do — investment, trading, tax or legal advice? Answer yes for 'should I buy', 'is it a good idea', 'will it go up', 'what would you do', 'recommend a fund', or how to treat income for tax. Answer no for a plain instruction to execute: 'buy 10 shares of AAPL', 'sell my NVDA shares', 'invest 1000 in an ETF', 'order 5 shares' are orders to place, not questions about what to do. A question about a price or a plain fact ('how much is Tesla stock', 'what is a dividend') is not advice either.",
          },
        },
        state,
        options
      );
      if (!second.ok) return { ok: false, detail: second.detail, latencyMs: second.latencyMs ?? 0 };
      return {
        ok: true,
        value: noul(second.answers, "wants_advice"),
        confidence: confidenceOf(second.answers, "wants_advice"),
        latencyMs: second.latencyMs,
      };
    },
    { floor: 0.5, min: 0.35 }
  );
  return {
    ok: true,
    latencyMs: wantsAdvice.latencyMs || result.latencyMs,
    // An order to place is not a request for advice, whatever the read said:
    // "buy 10 shares of AAPL" is an instruction, not "should I buy".
    wantsAdvice: order ? 0 : wantsAdvice.value,
    adviceEscalated: wantsAdvice.escalated === true,
    wantsMarketPrice: noul(result.answers, "is_about_market_prices"),
    wantsOwnConversion: noul(result.answers, "is_own_conversion"),
    topic: result.answers?.topic?.choice ?? null,
  };
}

/** An order-shaped instruction is never advice; this is the deterministic guard. */
const ORDER_SHAPE =
  /\b(buy|sell|purchase|invest|order|add)\b[^.!?]*\b(\d[\d.,]*\s*(?:shares?|units?|stocks?|etfs?)|\d[\d.,]*\s*(?:usd|eur|brl|dollars?|euros?|reais)|shares?|stocks?|etfs?|aapl|tsla|nvda|msft|amzn|googl|goog|meta|spy|qqq|vti|bnd)\b/i;
const QUESTION_SHAPE = /^(should|would|could|is|are|what|which|why|how|when)\b/i;
function orderNotAdvice(value) {
  const text = String(value || "");
  return ORDER_SHAPE.test(text) && !QUESTION_SHAPE.test(text.trim());
}

// ── 4 · the language to answer in ──────────────────────────────────────────

export async function readLanguage(text, options = {}) {
  const state = String(text || "").trim();
  if (!state) return { ok: false, detail: "Nothing to read." };
  const result = await systemOne(
    {
      language: {
        type: "choice",
        instructions: "Which language did the person write in?",
        criteria: {
          english: "English",
          portuguese: "Portuguese",
          spanish: "Spanish",
        },
      },
    },
    state,
    options
  );
  if (!result.ok) return result;
  return {
    ok: true,
    latencyMs: result.latencyMs,
    language: result.answers?.language?.choice ?? null,
    confidence: result.answers?.language?.confidence ?? null,
  };
}
