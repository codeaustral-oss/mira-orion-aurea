/**
 * Below-floor escalation (plan A.4).
 *
 * What is pinned here:
 *   · the helper: exactly one second call below the floor, zero at or above
 *     it, and the first answer returned unchanged when the second is low too;
 *   · the three call sites the plan names — consent authorisation, quote
 *     direction, advice/order — and nowhere else.
 */

import test from "node:test";
import assert from "node:assert/strict";

import { escalate } from "../lib/jev-escalate.mjs";
import { readConsent, decideConsent } from "../lib/jev-consent.mjs";
import { verifyQuote, classifyAdvice } from "../lib/jev-decide.mjs";

process.env.TYPESAFE_API_KEY = "test-key";

/** A fetch stub whose answers can differ per call. */
function jevStub(answersByCall) {
  const calls = [];
  const impl = async (url, init) => {
    const index = calls.length;
    calls.push({ url: String(url), body: JSON.parse(init.body) });
    const answers = typeof answersByCall === "function" ? answersByCall(index, calls[index].body) : answersByCall;
    const payload = JSON.stringify({ answers, model: "jev-test" });
    return {
      ok: true,
      status: 200,
      headers: new Headers({ "content-type": "application/json" }),
      json: async () => JSON.parse(payload),
      text: async () => payload,
    };
  };
  return { impl, calls };
}

// ── The helper ──────────────────────────────────────────────────────────────

test("a below-floor reading pays for exactly one differently-asked second read", async () => {
  let calls = 0;
  const outcome = await escalate("t.low", { ok: true, value: 0.4, confidence: 0.6 }, async () => {
    calls += 1;
    return { ok: true, value: 0.9, confidence: 0.8, latencyMs: 5 };
  });
  assert.equal(calls, 1);
  assert.equal(outcome.value, 0.9, "the second reading clears the floor and is used");
  assert.equal(outcome.source, "second");
  assert.equal(outcome.escalated, true);
  assert.equal(outcome.latencyMs, 5, "both calls' latency is reported");
});

test("a confident reading never pays for a second one", async () => {
  let calls = 0;
  const outcome = await escalate("t.high", { ok: true, value: 0.9, confidence: 0.9 }, async () => {
    calls += 1;
    return { ok: true, value: 0.1 };
  });
  assert.equal(calls, 0, "at or above the floor there is nothing to resolve");
  assert.equal(outcome.value, 0.9);
  assert.equal(outcome.escalated, false);
});

test("when the second reading is also below the floor, the first is returned unchanged", async () => {
  const first = { ok: true, value: 0.42, confidence: 0.55, latencyMs: 3 };
  const outcome = await escalate("t.both-low", first, async () => ({
    ok: true,
    value: 0.47,
    confidence: 0.99,
    latencyMs: 4,
  }));
  assert.equal(outcome.value, 0.42, "the caller sees exactly what it would have seen without the second call");
  assert.equal(outcome.confidence, 0.55);
  assert.equal(outcome.source, "first");
  assert.equal(outcome.escalated, true);
  assert.equal(outcome.latencyMs, 7);
});

test("a failed second read is not an answer: the first stands", async () => {
  const outcome = await escalate("t.fail", { ok: true, value: 0.4 }, async () => {
    throw new Error("SystemOne down");
  });
  assert.equal(outcome.value, 0.4);
  assert.equal(outcome.source, "first");
});

test("the min band keeps a plainly-low reading from paying twice", async () => {
  let calls = 0;
  const outcome = await escalate(
    "t.band",
    { ok: true, value: 0.2 },
    async () => {
      calls += 1;
      return { ok: true, value: 0.9 };
    },
    { min: 0.35 }
  );
  assert.equal(calls, 0);
  assert.equal(outcome.value, 0.2);
  assert.equal(outcome.escalated, false);
});

test("a read with no answer never escalates", async () => {
  let calls = 0;
  const outcome = await escalate("t.null", { ok: true, value: null }, async () => {
    calls += 1;
    return { ok: true, value: 0.9 };
  });
  assert.equal(calls, 0);
  assert.equal(outcome.value, null);
});

// ── Consent: authorises below the floor ─────────────────────────────────────

test("consent: a below-floor authorisation asks the negated question once", async () => {
  const { impl, calls } = jevStub((index) =>
    index === 0
      ? {
          authorises: { noul: 0.45, confidence: 0.5 },
          supplies_detail: { noul: 0.2 },
          missing: { choice: "none", confidence: 0.9 },
          risk: { choice: "low", confidence: 0.8 },
        }
      : { leaves_to_confirm: { noul: 0.45, confidence: 0.9 } }
  );
  const read = await readConsent("buy the Ghost 15", { action: "checkout", fetchImpl: impl });
  assert.equal(calls.length, 2);
  assert.ok(calls[1].body.questions.leaves_to_confirm);
  assert.equal(calls[1].body.questions.authorises, undefined, "the second call asks the negated form only");
  assert.equal(read.authorises, 0.55, "authorisation is the inverse of leaving it to confirmation");
  assert.equal(read.escalated, true);
  assert.equal(decideConsent(read, { known: {} }).decision, "proceed");
});

test("consent: a high negated answer counts as no authorisation", async () => {
  const { impl, calls } = jevStub((index) =>
    index === 0
      ? {
          authorises: { noul: 0.45 },
          supplies_detail: { noul: 0.1 },
          missing: { choice: "none" },
          risk: { choice: "low" },
        }
      : { leaves_to_confirm: { noul: 0.85, confidence: 0.95 } }
  );
  const read = await readConsent("buy the Ghost 15", { fetchImpl: impl });
  assert.equal(calls.length, 2, "the second read was attempted");
  assert.equal(read.authorises, 0.45, "the first reading stands; the negated answer adds no authorisation");
  assert.equal(decideConsent(read, { known: {} }).decision, "confirm");
});

test("consent: a confident authorisation never pays for a second read", async () => {
  const { impl, calls } = jevStub({
    authorises: { noul: 0.92 },
    supplies_detail: { noul: 0.1 },
    missing: { choice: "none" },
    risk: { choice: "low" },
  });
  const read = await readConsent("buy it now", { fetchImpl: impl });
  assert.equal(calls.length, 1);
  assert.equal(read.authorises, 0.92);
  assert.equal(read.escalated, false);
  assert.equal(decideConsent(read, { known: {} }).decision, "proceed");
});

test("consent: both readings below the floor is today's confirmation", async () => {
  const { impl, calls } = jevStub((index) =>
    index === 0
      ? {
          authorises: { noul: 0.42 },
          supplies_detail: { noul: 0.1 },
          missing: { choice: "none" },
          risk: { choice: "low" },
        }
      : { leaves_to_confirm: { noul: 0.6, confidence: 0.9 } }
  );
  const read = await readConsent("buy the Ghost 15", { fetchImpl: impl });
  assert.equal(calls.length, 2);
  assert.equal(read.authorises, 0.42, "the first read is the one the caller sees");
  assert.equal(decideConsent(read, { known: {} }).decision, "confirm");
});

// ── Quote: direction below the floor ────────────────────────────────────────

const QUOTE = {
  from: "USD",
  to: "BRL",
  fromAmount: { display: "USD 100.00" },
  toAmount: { display: "BRL 500.00" },
  rateLabel: "USD to BRL",
  fee: { display: "USD 2.00" },
  totalDebit: { display: "USD 102.00" },
};

test("quote: a below-floor direction asks the two-way question once", async () => {
  const { impl, calls } = jevStub((index) =>
    index === 0
      ? {
          direction_is_right: { noul: 0.4, confidence: 0.5 },
          rate_is_plausible: { noul: 0.95 },
          reads_as_the_amount: { noul: 0.95 },
          confidence: { score: 2 },
        }
      : { rate_direction: { choice: "source_per_destination", confidence: 0.9 } }
  );
  const check = await verifyQuote(QUOTE, { fetchImpl: impl });
  assert.equal(calls.length, 2);
  assert.ok(calls[1].body.questions.rate_direction);
  assert.equal(calls[1].body.questions.direction_is_right, undefined);
  assert.match(calls[1].body.questions.rate_direction.instructions, /USD per BRL/);
  assert.equal(check.direction, 1, "the two-way reading settles the direction");
  assert.equal(check.directionEscalated, true);
  assert.equal(check.clear, true);
});

test("quote: a confident direction never pays for a second read", async () => {
  const { impl, calls } = jevStub({
    direction_is_right: { noul: 0.9 },
    rate_is_plausible: { noul: 0.9 },
    reads_as_the_amount: { noul: 0.9 },
    confidence: { score: 2 },
  });
  const check = await verifyQuote(QUOTE, { fetchImpl: impl });
  assert.equal(calls.length, 1);
  assert.equal(check.direction, 0.9);
  assert.equal(check.directionEscalated, false);
  assert.equal(check.clear, true);
});

test("quote: a reverse second reading is below the floor too, so the concern stands as before", async () => {
  const { impl, calls } = jevStub((index) =>
    index === 0
      ? {
          direction_is_right: { noul: 0.4 },
          rate_is_plausible: { noul: 0.9 },
          reads_as_the_amount: { noul: 0.9 },
        }
      : { rate_direction: { choice: "destination_per_source", confidence: 0.95 } }
  );
  const check = await verifyQuote(QUOTE, { fetchImpl: impl });
  assert.equal(calls.length, 2);
  assert.equal(check.direction, 0.4, "a second reading below the floor changes nothing");
  assert.equal(check.clear, false);
  assert.deepEqual(check.concerns, ["the rate may be the wrong way round"]);
});

// ── Advice: only the 0.35–0.5 band ──────────────────────────────────────────

test("advice: the 0.35-0.5 band asks the order-versus-advice question once more", async () => {
  const { impl, calls } = jevStub((index) =>
    index === 0
      ? {
          wants_advice: { noul: 0.42, confidence: 0.6 },
          is_about_market_prices: { noul: 0.1 },
          is_own_conversion: { noul: 0.1 },
          topic: { choice: "market" },
        }
      : { wants_advice: { noul: 0.8, confidence: 0.85 } }
  );
  const read = await classifyAdvice("should I buy Tesla stock?", { fetchImpl: impl });
  assert.equal(calls.length, 2);
  assert.ok(calls[1].body.questions.wants_advice);
  assert.match(calls[1].body.questions.wants_advice.instructions, /buy 10 shares/);
  assert.equal(read.wantsAdvice, 0.8, "the second reading clears the floor and decides");
  assert.equal(read.adviceEscalated, true);
});

test("advice: a confident reading never pays twice", async () => {
  const { impl, calls } = jevStub({
    wants_advice: { noul: 0.88 },
    is_about_market_prices: { noul: 0.1 },
    is_own_conversion: { noul: 0.1 },
    topic: { choice: "market" },
  });
  const read = await classifyAdvice("should I buy Tesla stock?", { fetchImpl: impl });
  assert.equal(calls.length, 1);
  assert.equal(read.wantsAdvice, 0.88);
  assert.equal(read.adviceEscalated, false);
});

test("advice: below 0.35 the deterministic path stands without a second call", async () => {
  const { impl, calls } = jevStub({
    wants_advice: { noul: 0.2 },
    is_about_market_prices: { noul: 0.1 },
    is_own_conversion: { noul: 0.1 },
    topic: { choice: "general" },
  });
  const read = await classifyAdvice("what is a dividend?", { fetchImpl: impl });
  assert.equal(calls.length, 1);
  assert.equal(read.wantsAdvice, 0.2);
  assert.equal(read.adviceEscalated, false);
});

test("advice: when the second reading is also below the floor the first stands", async () => {
  const { impl, calls } = jevStub((index) =>
    index === 0
      ? {
          wants_advice: { noul: 0.42 },
          is_about_market_prices: { noul: 0.1 },
          is_own_conversion: { noul: 0.1 },
          topic: { choice: "market" },
        }
      : { wants_advice: { noul: 0.3, confidence: 0.9 } }
  );
  const read = await classifyAdvice("should I buy Tesla stock?", { fetchImpl: impl });
  assert.equal(calls.length, 2);
  assert.equal(read.wantsAdvice, 0.42, "both below the floor: the caller sees the first answer");
  assert.equal(read.adviceEscalated, true);
});

test("advice: a plainly-shaped order is deterministic and never escalated", async () => {
  const { impl, calls } = jevStub({
    wants_advice: { noul: 0.95 },
    is_about_market_prices: { noul: 0.1 },
    is_own_conversion: { noul: 0.1 },
    topic: { choice: "market" },
  });
  const read = await classifyAdvice("buy 10 shares of AAPL", { fetchImpl: impl });
  assert.equal(calls.length, 1);
  assert.equal(read.wantsAdvice, 0, "an instruction to execute is not advice");
  assert.equal(read.adviceEscalated, false);
});
