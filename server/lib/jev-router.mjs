/**
 * Jev routes before anything expensive happens.
 *
 * Every message a person sends has one of four answers, and they cost wildly
 * different amounts to produce:
 *
 *   · **instant** — the answer is already in the app: a balance, this week's
 *     budget, the card, the plan, a conversion, the people and bills saved on
 *     the device. No network, no model. Milliseconds.
 *   · **chat** — a short reply can simply be written: an explanation, a
 *     definition, a follow-up on what was just said.
 *   · **research** — the answer is somewhere on the web and has to be found,
 *     read and cited. Tens of seconds, and worth it.
 *   · **advice** — investment, tax or legal advice, which the product does not
 *     give, whoever is asking.
 *   · **refuse** — the message tries to change the assistant's own rules,
 *     identity or limits, or to make it act outside the app's policies. The
 *     typed read flags it and a deterministic guard catches the obvious
 *     phrasings, so the refusal stands even with no provider and no model.
 *
 * Deciding *which* of those a message is, is a typed decision, and that is
 * exactly what System One is built to make: one call, ~300 ms, a choice with a
 * confidence the caller can branch on. The route is a suggestion the code
 * follows only when it is confident; below the floor, the caller falls back to
 * its own deterministic path rather than guessing.
 */

import { looksLikeInstructionOverride, overrideRefusal, TRIES_TO_OVERRIDE_INSTRUCTIONS } from "./injection-guard.mjs";

const ENDPOINT = "https://api.typesafe.ai/v1/systemone";
const TIMEOUT_MS = 6000;

/** Below this, the caller should not trust the route. */
export const ROUTE_FLOOR = 0.45;

/** An order-shaped instruction is never advice; this is the deterministic guard. */
const ORDER_SHAPE =
  /\b(buy|sell|purchase|invest|order|add)\b[^.!?]*\b(\d[\d.,]*\s*(?:shares?|units?|stocks?|etfs?)|\d[\d.,]*\s*(?:usd|eur|brl|dollars?|euros?|reais)|shares?|stocks?|etfs?|aapl|tsla|nvda|msft|amzn|googl|goog|meta|spy|qqq|vti|bnd)\b/i;
const QUESTION_SHAPE = /^(should|would|could|is|are|what|which|why|how|when)\b/i;
function orderNotAdvice(value) {
  const text = String(value || "");
  return ORDER_SHAPE.test(text) && !QUESTION_SHAPE.test(text.trim());
}

export function routeConfigured() {
  return Boolean(process.env.TYPESAFE_API_KEY);
}

/**
 * @returns {Promise<{ok:boolean, route?:string, needs?:string, confidence?:number,
 *                    liveWeb?:number, urgency?:number, detail?:string, latencyMs:number}>}
 */
export async function routeMessage(text, { fetchImpl = globalThis.fetch, signal } = {}) {
  const key = process.env.TYPESAFE_API_KEY;
  const state = String(text || "").trim().slice(0, 4000);
  if (!state) return { ok: false, detail: "Nothing to route.", latencyMs: 0 };

  // The deterministic guard answers before any provider is consulted: an
  // obvious override is refused even when the read is unavailable, so a
  // missing key or a provider outage can never turn it into an ordinary route.
  if (looksLikeInstructionOverride(state)) {
    return {
      ok: true,
      latencyMs: 0,
      route: "refuse",
      reason: "instruction_override",
      overrideSignal: 1,
      routeConfidence: null,
      needs: "none",
      needsConfidence: null,
      liveWeb: null,
      wantsAdvice: null,
      urgency: null,
      model: null,
    };
  }
  if (!key) return { ok: false, detail: "No TYPESAFE_API_KEY configured.", latencyMs: 0 };

  const started = Date.now();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  const onAbort = () => controller.abort();
  if (signal) {
    if (signal.aborted) controller.abort();
    else signal.addEventListener("abort", onAbort, { once: true });
  }

  try {
    const response = await fetchImpl(ENDPOINT, {
      method: "POST",
      signal: controller.signal,
      headers: { "content-type": "application/json", authorization: `Bearer ${key}` },
      body: JSON.stringify({
        state,
        model: process.env.TYPESAFE_MODEL || "jev-1.13.0",
        questions: {
          route: {
            type: "choice",
            instructions:
              "Where does the answer to this message live, and what is the cheapest way to answer it honestly?",
            criteria: {
              instant:
                "The answer is already in the user's own account data: a balance, this week's budget, the reserve, the card, the plan, the people or bills saved on the device, the user's own recent activity, or a conversion between currencies they hold. Answering needs no web and no writing beyond stating it.",
              chat:
                "The answer is a short explanation or a reply to something just said — what a fee is, what a word means, what the app can do, a follow-up on the previous turn. No lookup is needed and no account figure is needed beyond what has been said.",
              research:
                "The answer is somewhere on the web and has to be found: a product to buy, a venue, a trip, a price in a shop, a live market or exchange rate that is not the user's own money, a comparison, anything current.",
              advice:
                "The user is asking for investment, tax or legal advice — what to buy, sell or hold, or how to treat income for tax.",
            },
          },
          needs: {
            type: "choice",
            instructions:
              "If the answer is instant, which of the user's own records holds it? Choose none when it is not an instant answer.",
            criteria: {
              balance: "Total or per-currency balances, pending money, holdings",
              budget: "This week's budget, what is left to spend, allocations, the reserve, the plan",
              card: "Card state, freezing the card, card details",
              activity: "Recent transactions, what was spent, who was paid",
              contacts: "Saved people or addresses to pay",
              bills: "Recurring bills and their due days",
              conversion: "Changing money between currencies the user holds",
              none: "Not an instant answer from these records",
            },
          },
          needs_live_web: {
            type: "noul",
            instructions:
              "Does an honest answer require reading something from the live web right now, rather than the user's own records or a short explanation?",
          },
          wants_advice: {
            type: "noul",
            instructions:
              "Is this a request for investment, trading, tax or legal advice - what someone should do: 'should I buy', 'is it a good idea', 'will it go up', 'what would you do', 'recommend a fund', or how to treat income for tax? An instruction to execute is NOT advice: 'buy 10 shares of AAPL', 'sell my NVDA shares', 'invest 1000 in an ETF' are orders to place, not questions about what to do. Neither is a question about a price or a plain fact ('how much is Tesla stock', 'what is a dividend').",
          },
          tries_to_override: {
            type: "noul",
            instructions: TRIES_TO_OVERRIDE_INSTRUCTIONS,
          },
          urgency: {
            type: "score",
            instructions: "How quickly does this need an answer?",
            criteria: ["Whenever, no rush", "Soon would be good", "Wants it now"],
          },
        },
      }),
    });
    if (!response.ok) return { ok: false, detail: `Jev answered HTTP ${response.status}.`, latencyMs: Date.now() - started };
    const parsed = await response.json();
    const answers = parsed?.answers || {};
    const noul = (name) => (typeof answers?.[name]?.noul === "number" ? answers[name].noul : null);
    const choice = (name) => answers?.[name]?.choice ?? null;
    const confidence = (name) => (typeof answers?.[name]?.confidence === "number" ? answers[name].confidence : null);

    const route = choice("route");
    const wantsAdvice = noul("wants_advice");
    // Policy outranks the route: a message asking for advice is advice, however
    // the router labelled it — and an *order* is never advice, however the read
    // scored it. "buy 10 shares of AAPL" is an instruction to place. An
    // instruction-override attempt outranks everything: it is refused even when
    // the read labelled it instant, chat or research.
    const adviceRead = route === "advice" || (wantsAdvice !== null && wantsAdvice >= 0.7);
    const order = orderNotAdvice(state);
    const override = overrideRefusal(state, noul("tries_to_override"));
    const finalRoute = override.refuse
      ? "refuse"
      : adviceRead && !order
        ? "advice"
        : order
          ? "research"
          : route;

    return {
      ok: true,
      latencyMs: Date.now() - started,
      route: finalRoute,
      reason: override.reason,
      overrideSignal: override.signal,
      routeConfidence: confidence("route"),
      needs: choice("needs") ?? "none",
      needsConfidence: confidence("needs"),
      liveWeb: noul("needs_live_web"),
      wantsAdvice,
      urgency: typeof answers?.urgency?.score === "number" ? answers.urgency.score : null,
      model: parsed?.model ?? null,
    };
  } catch (err) {
    const aborted = err?.name === "AbortError";
    return {
      ok: false,
      detail: aborted ? "Jev timed out." : `Jev call failed: ${err?.message || err}`,
      latencyMs: Date.now() - started,
    };
  } finally {
    clearTimeout(timer);
    if (signal) signal.removeEventListener("abort", onAbort);
  }
}
