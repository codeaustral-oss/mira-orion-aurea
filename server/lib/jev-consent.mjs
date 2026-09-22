/**
 * When does a person step in?
 *
 * Three kinds of action, and they should not feel the same:
 *
 *   · **observe** — a balance, a rate, a search, a watch's last check. Nothing
 *     moves, nothing is at stake: never a question, never a confirmation.
 *   · **prepare** — a quote, a checkout, a task, a card shown in chat. Still
 *     nothing moves: the preparing *is* the answer. Ask only for a detail that
 *     is genuinely absent, and never for one the app already holds.
 *   · **commit** — a swap posts, an order is placed, a transfer leaves. This is
 *     where a person steps in, exactly once: either they said it in the message
 *     ("just buy it now"), or they set a standing approval, or they get one
 *     final confirmation that shows the exact figures.
 *
 * Reading which of those a message is, and whether it already carries the
 * authorisation or the missing detail, is a typed decision — the kind System
 * One makes well. Code still owns the policy: Jev supplies the reading, and the
 * decision below is deterministic and testable.
 */

import { escalate } from "./jev-escalate.mjs";

const ENDPOINT = "https://api.typesafe.ai/v1/systemone";
const TIMEOUT_MS = 6000;

/** Below this the typed read is not trusted; the caller asks or confirms. */
export const READ_FLOOR = 0.5;

export function consentConfigured() {
  return Boolean(process.env.TYPESAFE_API_KEY);
}

/**
 * @returns {Promise<{ok:boolean, authorises?:number, suppliesDetail?:number,
 *                    missing?:string, risk?:string, confidence?:number, latencyMs:number}>}
 */
export async function readConsent(
  message,
  { action = "checkout", known = {}, fetchImpl = globalThis.fetch, signal } = {}
) {
  const key = process.env.TYPESAFE_API_KEY;
  const text = String(message || "").trim().slice(0, 2000);
  if (!key) return { ok: false, detail: "No TYPESAFE_API_KEY configured.", latencyMs: 0 };
  if (!text) return { ok: false, detail: "Nothing to read.", latencyMs: 0 };

  const knownLines = Object.entries(known)
    .filter(([, value]) => value !== null && value !== undefined && value !== "")
    .map(([name, value]) => `${name}: ${value}`)
    .join("\n");
  const state = [
    `Action being considered: ${action}.`,
    knownLines ? `Already known to the app:\n${knownLines}` : "Already known to the app: nothing.",
    `The person's message: ${text}`,
  ].join("\n");

  /** One consent read against the same state. The escalation reuses it. */
  const ask = async (questions) => {
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
          questions,
        }),
      });
      if (!response.ok) {
        return { ok: false, detail: `Jev answered HTTP ${response.status}.`, latencyMs: Date.now() - started };
      }
      const parsed = await response.json();
      return { ok: true, answers: parsed?.answers || {}, model: parsed?.model ?? null, latencyMs: Date.now() - started };
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
  };

  const first = await ask({
    authorises: {
      type: "noul",
      instructions:
        "Does this message itself authorise the action to happen now, without another confirmation? 'buy it now', 'just order it', 'place the order', 'go ahead and pay' — yes. 'buy the Ghost 15' (which starts a checkout), 'find me one', 'how much is it' — no.",
    },
    supplies_detail: {
      type: "noul",
      instructions:
        "Does the message itself state the detail the action still needs — a delivery place, a payment card, an amount — rather than leaving it to be asked for?",
    },
    missing: {
      type: "choice",
      instructions:
        "Given what the app already knows, which detail is genuinely absent from the request? Choose none when nothing needed is absent.",
      criteria: {
        address: "Where it should go is not known and not in the message",
        payment: "Which card pays is not known and not in the message",
        amount: "How much is not known and not in the message",
        item: "What to buy is not known and not in the message",
        none: "Nothing needed is absent",
      },
    },
    risk: {
      type: "choice",
      instructions:
        "How much should a person want to look at this before it happens?",
      criteria: {
        none: "Nothing at stake — a lookup, a quote, a preference",
        low: "Ordinary: a small purchase, a swap of their own money, a card frozen",
        high: "Worth stopping on: a large amount, a new recipient, an irreversible step, anything unusual",
      },
    },
  });
  if (!first.ok) return { ok: false, detail: first.detail, latencyMs: first.latencyMs };

  const answers = first.answers || {};
  const noul = (source, name) => (typeof source?.[name]?.noul === "number" ? source[name].noul : null);
  const confidenceOf = (source, name) =>
    typeof source?.[name]?.confidence === "number" ? source[name].confidence : null;

  // A.4: an authorisation read below the floor is a coin flip, and a coin flip
  // must never count as "buy it now". One second, negated question resolves it;
  // when that is below the floor too, the first read stands and the decision is
  // exactly the confirmation it always was.
  const authorises = await escalate(
    "consent.authorises",
    {
      ok: true,
      value: noul(answers, "authorises"),
      confidence: confidenceOf(answers, "authorises"),
      latencyMs: first.latencyMs,
    },
    async () => {
      const second = await ask({
        leaves_to_confirm: {
          type: "noul",
          instructions:
            "Does this message leave the action for the person to confirm, rather than authorising it to happen now? Answer yes when the message asks about, suggests or describes the purchase; answer no only when it tells the assistant to do it now ('buy it now', 'go ahead and pay', 'place the order').",
        },
      });
      const leaves = noul(second.answers, "leaves_to_confirm");
      return {
        ok: second.ok,
        detail: second.detail,
        // The same quantity asked the other way round: authorisation is the
        // inverse of leaving the decision to confirmation.
        value: typeof leaves === "number" ? 1 - leaves : null,
        confidence: confidenceOf(second.answers, "leaves_to_confirm"),
        latencyMs: second.latencyMs,
      };
    },
    { floor: READ_FLOOR }
  );

  return {
    ok: true,
    latencyMs: authorises.latencyMs,
    authorises: authorises.value,
    suppliesDetail: noul(answers, "supplies_detail"),
    missing: answers?.missing?.choice ?? null,
    confidence: confidenceOf(answers, "missing"),
    risk: answers?.risk?.choice ?? null,
    model: first.model ?? null,
    // Measurement, not a second answer: how the below-floor read was resolved.
    escalated: authorises.escalated === true,
  };
}

/**
 * The policy. Deterministic, so it can be read, tested and argued with.
 *
 * @returns {{decision:"proceed"|"confirm"|"ask", detail?:string, reason:string}}
 */
export function decideConsent(read, { known = {}, action = "checkout" } = {}) {
  // Without a reading, the safe default is the single confirmation. A failed
  // read never becomes an authorisation.
  if (!read?.ok) return { decision: "confirm", reason: "no typed read" };

  const missing = read.missing || "none";
  // Code knows what the app holds. A detail the app already has is never asked
  // for, whatever the read says about the message.
  const knownKeys = new Set(
    Object.entries(known)
      .filter(([, value]) => value !== null && value !== undefined && value !== "")
      .map(([name]) => (name === "place" ? "address" : name))
  );
  if (missing !== "none" && !knownKeys.has(missing)) {
    // The message may supply it in words ("deliver it to my office") — then it
    // is not missing, it is being given.
    if (!(read.suppliesDetail !== null && read.suppliesDetail >= READ_FLOOR)) {
      return { decision: "ask", detail: missing, reason: "detail genuinely absent" };
    }
  }

  if (read.risk === "high") {
    return { decision: "confirm", reason: "high risk" };
  }
  if (read.authorises !== null && read.authorises >= READ_FLOOR) {
    return { decision: "proceed", reason: "authorised in the message" };
  }
  return { decision: "confirm", reason: "one confirmation" };
}
