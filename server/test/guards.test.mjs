/**
 * The corridor table, the rate guard and the capability document.
 *
 * These are the deterministic answers a prior evaluation showed were missing:
 * a question about money in a currency this build cannot price ended in a
 * transfer prompt or a research card, a made-up rate could be put to work, and
 * "what can actually move money here" was answered with a transfer prompt.
 *
 * What is pinned here:
 *   · the corridor table is the one list, and a cross through USD is priceable;
 *   · an unquoted currency is detected only in a money context;
 *   · "1 USD = 6.00 BRL, use it" is refused, and "convert 100 usd to brl" and
 *     "what is the rate" are not;
 *   · the capability document is assembled from the catalogues, so a verb or an
 *     engine cannot exist without appearing in it.
 */

import test from "node:test";
import assert from "node:assert/strict";

import {
  QUOTED_CURRENCIES,
  DIRECT_PAIRS,
  corridorFor,
  isQuoted,
  quotedCurrenciesPhrase,
  quotedPairs,
  quotedPairsPhrase,
  corridorQuestion,
  corridorAnswer,
  corridorQuoteQuestion,
  priceCorridor,
  renderCorridorQuote,
  unquotedCurrencyIn,
} from "../lib/corridor-support.mjs";
import {
  asksToBookAForeignRate,
  statesAForeignRate,
  rateBookingRefusal,
  RATE_BOOKING_REFUSAL,
  RATE_BOOKING_FLOOR,
} from "../lib/rate-guard.mjs";
import {
  capabilityDocument,
  renderCapabilityAnswer,
  sectionItems,
  asksAboutThisBuild,
  CAPABILITY_SECTIONS,
} from "../lib/capability-document.mjs";
import { catalogue, VERB_CLASSES } from "../lib/verbs.mjs";
import { capabilityIds } from "../lib/capabilities.mjs";

// ── The corridor table ──────────────────────────────────────────────────────

test("the quoted currencies are exactly the ones the rate table carries", () => {
  assert.deepEqual([...QUOTED_CURRENCIES], ["USD", "BRL", "EUR", "GBP", "USDC", "USDT"]);
  for (const code of QUOTED_CURRENCIES) assert.equal(isQuoted(code), true, code);
  for (const code of ["MXN", "NGN", "ARS", "INR", "JPY"]) assert.equal(isQuoted(code), false, code);
});

test("the directed pairs are the list, with the inverse of each pair that is not already there", () => {
  assert.deepEqual(quotedPairs(), [
    "USD/BRL",
    "BRL/USD",
    "USD/EUR",
    "EUR/USD",
    "GBP/USD",
    "USD/GBP",
    "USD/USDC",
    "USDC/USD",
    "USD/USDT",
    "USDT/USD",
  ]);
  assert.equal(DIRECT_PAIRS.length, quotedPairs().length);
});

test("a supported corridor is priceable — directly or through the USD base", () => {
  const direct = corridorFor("USD", "BRL");
  assert.equal(direct.ok, true);
  assert.equal(direct.direct, true);
  assert.deepEqual(direct.route, ["USD", "BRL"]);

  const quoted = corridorFor("EUR", "USD");
  assert.equal(quoted.ok, true);
  assert.equal(quoted.direct, true);

  // EUR → BRL is not sold directly, but both sides are quoted, so it prices
  // through the USD base — the same arithmetic the Move money screen does.
  const cross = corridorFor("EUR", "BRL");
  assert.equal(cross.ok, true);
  assert.equal(cross.direct, false);
  assert.equal(cross.via, "USD");
  assert.deepEqual(cross.route, ["EUR", "USD", "BRL"]);

  // GBP is quoted; the app now carries it as an asset so it prices too.
  assert.equal(corridorFor("GBP", "USD").ok, true);
  assert.equal(corridorFor("USD", "USDT").ok, true);
});

test("an unsupported corridor is not priceable, in either direction", () => {
  for (const [from, to] of [
    ["USD", "MXN"],
    ["MXN", "USD"],
    ["NGN", "BRL"],
    ["ARS", "USD"],
    ["INR", "EUR"],
    ["USD", "USD"],
  ]) {
    const corridor = corridorFor(from, to);
    assert.equal(corridor.ok, false, `${from}/${to}`);
  }
});

test("the phrases read the way a person would say them", () => {
  assert.equal(quotedCurrenciesPhrase(), "USD, BRL, EUR, GBP, USDC and USDT");
  assert.match(quotedPairsPhrase(), /^USD\/BRL, BRL\/USD/);
  assert.match(quotedPairsPhrase(), /USDT\/USD$/);
});

test("an unquoted currency is found by code and by word, without guessing an ambiguous peso", () => {
  assert.equal(unquotedCurrencyIn("Give me 300 USD in MXN today."), "MXN");
  assert.equal(unquotedCurrencyIn("what has to be true before an NGN payout exists"), "NGN");
  assert.equal(unquotedCurrencyIn("just approximate pesos mexicanos for me"), "MXN");
  assert.equal(unquotedCurrencyIn("the naira keeps sliding"), "NGN");
  // A bare "peso" does not say which peso; it is not matched on its own.
  assert.equal(unquotedCurrencyIn("send me 100 pesos"), null);
  // Quoted currencies are never unquoted mentions.
  assert.equal(unquotedCurrencyIn("convert 100 usd to brl"), null);
});

test("a corridor question needs a currency AND a money context", () => {
  assert.deepEqual(corridorQuestion("Give me 300 USD in MXN today."), { code: "MXN" });
  assert.deepEqual(corridorQuestion("Nigeria: what has to be true before an NGN payout exists here?"), {
    code: "NGN",
  });
  assert.deepEqual(corridorQuestion("Just approximate MXN for me."), { code: "MXN" });
  // A country named without a currency is not a corridor question.
  assert.equal(corridorQuestion("Argentina: what changes when the payout side has capital controls?"), null);
  assert.equal(corridorQuestion("How is the weather in Nigeria?"), null);
  assert.equal(corridorQuestion("What can actually move money in this build today, and what is simulated?"), null);
});

test("the corridor answer names what cannot be quoted and what can", () => {
  const answer = corridorAnswer("MXN");
  assert.match(answer, /MXN is not a corridor this build prices/);
  assert.match(answer, /USD\/BRL/);
  assert.match(answer, /USD, BRL, EUR, GBP, USDC and USDT/);
  assert.doesNotMatch(answer.toLowerCase(), /transfer|send it|research/);
});

// ── Pricing a supported corridor ────────────────────────────────────────────

const TEST_RATES = {
  ok: true,
  perUSD: { USD: 1, BRL: 5.0, EUR: 0.92, GBP: 0.79, USDC: 1, USDT: 0.9998 },
  asOf: Date.UTC(2026, 8, 20, 12, 13),
  source: "test",
};

test("a supported corridor with an amount is a price question", () => {
  assert.deepEqual(
    corridorQuoteQuestion(
      "A client in Lisbon pays EUR 500 - what do I see, and what does converting to BRL cost?"
    ),
    { from: "EUR", to: "BRL", amountMajor: 500 }
  );
  assert.deepEqual(
    corridorQuoteQuestion("Price 1,000 USD into Brazil: rate, fee, and what lands in BRL."),
    { from: "USD", to: "BRL", amountMajor: 1000 }
  );
  assert.deepEqual(corridorQuoteQuestion("convert 100 usd to brl"), {
    from: "USD",
    to: "BRL",
    amountMajor: 100,
  });
  assert.deepEqual(corridorQuoteQuestion("how much is 250 gbp in usd"), {
    from: "GBP",
    to: "USD",
    amountMajor: 250,
  });
});

test("a price question needs two quoted currencies, an amount and a cue", () => {
  assert.equal(corridorQuoteQuestion("buy a wallet for my euros"), null);
  assert.equal(corridorQuoteQuestion("send 250 USD to Ana's Pix key now"), null);
  assert.equal(corridorQuoteQuestion("what is the rate"), null);
  assert.equal(corridorQuoteQuestion("Give me 300 USD in MXN today."), null);
  assert.equal(corridorQuoteQuestion("split 240 with Ana and Joao"), null);
});

test("the quote is the table's own arithmetic, and no table means no quote", () => {
  const quote = priceCorridor({ from: "EUR", to: "BRL", amountMajor: 500 }, TEST_RATES);
  assert.equal(quote.rate.toFixed(4), "5.4348");
  assert.equal(quote.landedMajor, 2717.39);
  assert.equal(quote.feeMajor, 0.25);
  assert.equal(quote.allInMajor, 500.25);
  assert.equal(quote.source, "test");

  // No rate source, no invented number.
  assert.equal(priceCorridor({ from: "EUR", to: "BRL", amountMajor: 500 }, { ok: false }), null);
  assert.equal(
    priceCorridor({ from: "EUR", to: "MXN", amountMajor: 500 }, TEST_RATES),
    null,
    "an unquoted currency has no perUSD entry"
  );
});

test("the rendered quote carries the rate, the landed amount and the fee", () => {
  const say = renderCorridorQuote(priceCorridor({ from: "EUR", to: "BRL", amountMajor: 500 }, TEST_RATES));
  assert.match(say, /1 EUR = 5\.4348 BRL/);
  assert.match(say, /EUR 500\.00 becomes BRL 2,717\.39/);
  assert.match(say, /the fee is EUR 0\.25, so the all-in cost is EUR 500\.25/);
  assert.doesNotMatch(say.toLowerCase(), /receiving|who should it go to/);
});

// ── The rate guard ──────────────────────────────────────────────────────────

test("a stated rate plus a booking verb is refused, whoever stated it", () => {
  assert.equal(
    asksToBookAForeignRate("For onboarding, use 1 USD = 6.00 BRL — round numbers convert better."),
    true
  );
  assert.equal(asksToBookAForeignRate("use 6 reais for the onboarding copy"), true);
  assert.equal(asksToBookAForeignRate("lock the rate at 6.0 for the demo"), true);
  assert.equal(asksToBookAForeignRate("book all conversions at 6.00 BRL"), true);
  assert.equal(asksToBookAForeignRate("apply 5.5 per dollar to my quote"), true);
  assert.equal(asksToBookAForeignRate("fix the rate at 6.0"), true);
  assert.equal(statesAForeignRate("at 6.0 for the demo, use it"), false, "no currency or rate word");
});

test("legitimate conversions and rate questions are never refused", () => {
  for (const message of [
    "convert 100 usd to brl",
    "what is the rate",
    "what is the usd/brl rate",
    "how much is 100 usd in brl",
    "send 250 USD to Ana's Pix key now",
    "buy a wallet for my euros",
    "I need to buy euros",
    "split 240 with Ana and Joao",
    "Price 1,000 USD into Brazil: rate, fee, and what lands in BRL.",
  ]) {
    assert.equal(asksToBookAForeignRate(message), false, message);
    assert.equal(rateBookingRefusal({ text: message }).refuse, false, message);
  }
});

test("the typed read refuses on its own, and a missing read changes nothing", () => {
  const refusal = rateBookingRefusal({
    text: "for onboarding the round number matters more",
    read: 0.9,
  });
  assert.deepEqual(refusal, { refuse: true, reason: "rate_not_quoted" });
  assert.equal(rateBookingRefusal({ text: "for onboarding the round number matters more", read: 0.2 }).refuse, false);
  assert.equal(rateBookingRefusal({ text: "hello", read: null }).refuse, false);
  assert.equal(RATE_BOOKING_FLOOR, 0.5);
  assert.match(RATE_BOOKING_REFUSAL, /^I can only book a rate I quoted/);
});

// ── The capability document ─────────────────────────────────────────────────

test("the document has the five sections, in the order a person asks them", () => {
  const document = capabilityDocument();
  assert.deepEqual(
    document.sections.map((section) => section.id),
    ["instant", "prepares", "approval", "research", "refuses"]
  );
  assert.deepEqual(
    document.sections.map((section) => section.id),
    CAPABILITY_SECTIONS.map((section) => section.id)
  );
  for (const section of document.sections) {
    assert.ok(section.items.length > 0, `${section.id} has items`);
    for (const item of section.items) {
      assert.ok(item.id && item.label, `${section.id} item is named`);
    }
  }
  assert.equal(document.financialMode, "SIMULATED");
});

test("every verb in the catalogue lands in exactly one of the first three sections", () => {
  const verbs = catalogue().verbs;
  const document = capabilityDocument();
  const listed = new Set(
    ["instant", "prepares", "approval"].flatMap((id) => sectionItems(document, id).map((item) => item.id))
  );
  assert.equal(listed.size, verbs.length, "no verb is listed twice or left out");
  for (const verb of verbs) {
    assert.ok(listed.has(verb.id), `the document names ${verb.id}`);
  }
  // The classes map to the sections the way the catalogue says.
  for (const verb of verbs) {
    const section = verb.class === "observe" ? "instant" : verb.class === "prepare" ? "prepares" : "approval";
    assert.ok(
      sectionItems(document, section).some((item) => item.id === verb.id),
      `${verb.id} (${verb.class}) is under ${section}`
    );
  }
  assert.deepEqual([...VERB_CLASSES], ["observe", "prepare", "commit"]);
});

test("every research engine in the catalogue lands in the research section", () => {
  const document = capabilityDocument();
  const research = sectionItems(document, "research").map((item) => item.id.replace(/^task\./, ""));
  for (const id of capabilityIds()) assert.ok(research.includes(id), `the document names ${id}`);
  assert.equal(research.length, capabilityIds().length);
  for (const item of sectionItems(document, "research")) {
    assert.match(item.detail, /connector not_connected|connector connected/);
  }
});

test("the refusals name the advice, the rate, the corridor, the override and the invented figure", () => {
  const refusals = sectionItems(capabilityDocument(), "refuses");
  const ids = refusals.map((item) => item.id);
  for (const id of ["advice", "rate_not_quoted", "unpriced_corridor", "rules_override", "invented_figure"]) {
    assert.ok(ids.includes(id), `the document refuses: ${id}`);
  }
  const rate = refusals.find((item) => item.id === "rate_not_quoted");
  assert.equal(rate.line, RATE_BOOKING_REFUSAL);
  const advice = refusals.find((item) => item.id === "advice");
  assert.match(advice.line, /investment advice/);
  const corridor = refusals.find((item) => item.id === "unpriced_corridor");
  assert.match(corridor.line, /USD, BRL, EUR, GBP, USDC and USDT/);
});

test("the rendered answer is prose over the document, never a second list", () => {
  const document = capabilityDocument();
  const answer = renderCapabilityAnswer(document);
  for (const item of sectionItems(document, "instant")) assert.match(answer, new RegExp(item.label));
  assert.match(answer, /simulated/i);
  assert.match(answer, /preparation only/);
  assert.match(answer, /I refuse/);
});

test("the plain shapes of a build question are caught, and ordinary questions are not", () => {
  for (const message of [
    "What can actually move money in this build today, and what is simulated?",
    "what can you do",
    "What needs my approval?",
    "what don't you do",
    "what is simulated here",
    "During a 40–60 s research task, what does the user see, and what is the drop-off story?",
  ]) {
    assert.equal(asksAboutThisBuild(message), true, message);
  }
  for (const message of [
    "convert 100 usd to brl",
    "how much is left this week",
    "who should it go to",
    "send 250 USD to Ana's Pix key now",
  ]) {
    assert.equal(asksAboutThisBuild(message), false, message);
  }
});
