import test from "node:test";
import assert from "node:assert/strict";

import { canonicalFigure, checkReplyFigures, guardReply } from "../lib/reply-guard.mjs";

test("canonicalFigure treats the same value written two ways as one", () => {
  assert.equal(canonicalFigure("US$ 2,018.60"), "2018.6");
  assert.equal(canonicalFigure("2,018.60"), "2018.6");
  assert.equal(canonicalFigure("USD 300.00"), "300");
  assert.equal(canonicalFigure("R$ 190,00"), "190");
  assert.equal(canonicalFigure("190.00"), "190");
  assert.equal(canonicalFigure("5.0000"), "5");
  assert.equal(canonicalFigure("1.0870"), "1.087");
});

test("a figure taken from the user's own state passes", () => {
  const check = checkReplyFigures({
    say: "You have USD 2,018.60 available.",
    allowed: { digest: "BALANCES\nUSD 2,018.60", userMessage: "what is my balance?" },
  });
  assert.equal(check.ok, true);
});

test("a rate and fee stated in the quote pass", () => {
  const check = checkReplyFigures({
    say: "The rate is 5.0000 BRL per USD, with a USD 0.25 fee.",
    allowed: { quote: { pair: "USD/BRL", rate: "5.0000", fee: "USD 0.25" } },
  });
  assert.equal(check.ok, true);
});

test("a bare unit figure is still a figure", () => {
  // "1 USD = 5.0000 BRL" restates the rate, but the 1 comes from nowhere the
  // app actually said. The quote's own deterministic sentence covers this case.
  const check = checkReplyFigures({
    say: "The rate is 1 USD = 5.0000 BRL.",
    allowed: { quote: { pair: "USD/BRL", rate: "5.0000" } },
  });
  assert.equal(check.ok, false);
  assert.deepEqual(check.invented, ["1"]);
});

test("a figure the model invented is caught", () => {
  const check = checkReplyFigures({
    say: "Você pagou $190.00 em taxa neste extrato.",
    allowed: { digest: "BALANCES\nUSD 2,018.60", userMessage: "o que é uma taxa?" },
  });
  assert.equal(check.ok, false);
  assert.deepEqual(check.invented, ["190"]);
});

test("a total the model worked out itself is caught", () => {
  const check = checkReplyFigures({
    say: "You have about USD 1,900.00 saved.",
    allowed: { digest: "BALANCES\nUSD 2,018.60" },
  });
  assert.equal(check.ok, false);
  assert.deepEqual(check.invented, ["1900"]);
});

test("a figure that appears only in the person's own message passes", () => {
  const check = checkReplyFigures({
    say: "That converts 100 EUR at the rate shown.",
    allowed: { userMessage: "what does 100 eur get me?" },
  });
  assert.equal(check.ok, true);
});

test("guardReply keeps a clean sentence untouched", () => {
  const guarded = guardReply({
    say: "A fee is money you pay for a service.",
    fallback: "A fee is a charge for a service.",
    allowed: {},
  });
  assert.equal(guarded.guarded, false);
  assert.equal(guarded.say, "A fee is money you pay for a service.");
});

test("guardReply replaces the line when a figure has no source", () => {
  const guarded = guardReply({
    say: "That will cost you USD 999.00.",
    fallback: "Confirm it and I will prepare the transfer — nothing moves until you do.",
    allowed: { digest: "BALANCES\nUSD 2,018.60" },
  });
  assert.equal(guarded.guarded, true);
  assert.equal(guarded.say, "Confirm it and I will prepare the transfer — nothing moves until you do.");
  assert.deepEqual(guarded.invented, ["999"]);
});

test("guardReply never leaves the person with nothing to read", () => {
  const guarded = guardReply({ say: "The fee is 12.50.", allowed: {} });
  assert.equal(guarded.guarded, true);
  assert.ok(guarded.say.length > 0);
});
