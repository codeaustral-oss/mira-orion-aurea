/**
 * Orchestration regression tests.
 *
 * These cover the deterministic half of the chat loop: amount parsing, recipient
 * detection, intent → specialist routing and the typed action the app renders.
 * No network and no model are involved, so they are fast and stable.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  parseAmount,
  detectCounterparty,
  buildAction,
  refineIntent,
  shouldUseFastPath,
  deterministicReply,
  ACTION_TYPES,
} from "../lib/orchestrate.mjs";
import { brandRoster, specialistForIntent, agentById } from "../lib/roster.mjs";

// Force the deterministic path; a live key must not change these expectations.
process.env.TYPESAFE_API_KEY = "";

test("amount parsing resolves both localised formats", () => {
  assert.deepEqual(parseAmount("send USD 100"), { asset: "USD", amountMinor: 10_000, value: 100 });
  assert.equal(parseAmount("BRL 1.234,56")?.amountMinor, 123_456);
  assert.equal(parseAmount("BRL 1,234.56")?.amountMinor, 123_456);
  assert.equal(parseAmount("send 250.50 USDC")?.amountMinor, 250_500_000);
  assert.equal(parseAmount("R$ 150,00")?.amountMinor, 15_000);
  assert.equal(parseAmount("no amount here"), null);
});

test("a token amount uses the token's six decimals, not cents", () => {
  const parsed = parseAmount("move 1.5 USDC");
  assert.equal(parsed.asset, "USDC");
  assert.equal(parsed.amountMinor, 1_500_000);
});

test("recipient detection maps names to the other identity", () => {
  assert.equal(detectCounterparty("send money to Mira Orion", "aurea"), "Mira Orion");
  assert.equal(detectCounterparty("send money to Mira Aurea", "orion"), "Mira Aurea");
  assert.equal(detectCounterparty("pay the other app", "orion"), "Mira Aurea");
  assert.equal(detectCounterparty("hello", "aurea"), null);
});

test("travel and shopping language refines the intent", () => {
  assert.equal(refineIntent("balance", "find me a cheap flight to Lisbon"), "travel");
  assert.equal(refineIntent("balance", "is this a good deal on a laptop"), "shopping");
  assert.equal(refineIntent("budget", "how much is left this week"), "budget");
});

test("a complete transfer request becomes a proposal, never a payment", () => {
  const action = buildAction({
    intent: "prepare_payment",
    message: "Send USD 100.00 to Mira Orion",
    brand: "aurea",
  });
  assert.equal(action.type, ACTION_TYPES.PROPOSE_TRANSFER);
  assert.equal(action.from, "Mira Aurea");
  assert.equal(action.to, "Mira Orion");
  assert.equal(action.asset, "USD");
  assert.equal(action.amountMinor, 10_000);
});

test("a missing amount asks for it instead of guessing", () => {
  const action = buildAction({
    intent: "prepare_payment",
    message: "Send money to Mira Orion",
    brand: "aurea",
  });
  assert.equal(action.type, ACTION_TYPES.ASK_TRANSFER_DETAILS);
  assert.deepEqual(action.missing, ["amount and currency"]);
});

test("a follow-up turn reuses the pending recipient", () => {
  const action = buildAction({
    intent: "prepare_payment",
    message: "100 USD",
    brand: "aurea",
    pending: { kind: "transfer", to: "Mira Orion" },
  });
  assert.equal(action.type, ACTION_TYPES.PROPOSE_TRANSFER);
  assert.equal(action.to, "Mira Orion");
  assert.equal(action.amountMinor, 10_000);
});

test("a bare amount after a transfer question completes it, even when Jev reads it as ambiguous", () => {
  const action = buildAction({
    intent: "ambiguous",
    message: "25 USD",
    brand: "aurea",
    pending: { kind: "transfer", to: "Mira Orion" },
  });
  assert.equal(action.type, ACTION_TYPES.PROPOSE_TRANSFER);
  assert.equal(action.to, "Mira Orion");
  assert.equal(action.asset, "USD");
  assert.equal(action.amountMinor, 2500);
});

test("a pending transfer does not swallow a question that has no amount", () => {
  const action = buildAction({
    intent: "ambiguous",
    message: "how much is left this week?",
    brand: "aurea",
    pending: { kind: "transfer", to: "Mira Orion" },
  });
  assert.equal(action.type, ACTION_TYPES.REPLY);
});

test("travel and shopping produce a requirements flow that admits no provider", () => {
  const travel = buildAction({ intent: "travel", message: "book a flight", brand: "orion" });
  assert.equal(travel.type, ACTION_TYPES.REQUIREMENTS_FLOW);
  assert.equal(travel.providerConnected, false);
  assert.ok(travel.requirements.length >= 3);

  const shopping = buildAction({ intent: "shopping", message: "buy this", brand: "orion" });
  assert.equal(shopping.type, ACTION_TYPES.REQUIREMENTS_FLOW);
  assert.equal(shopping.providerConnected, false);
});

test("a budget change is a proposal, not an applied change", () => {
  const action = buildAction({
    intent: "budget",
    message: "raise my weekly budget to USD 500",
    brand: "aurea",
  });
  assert.equal(action.type, ACTION_TYPES.PROPOSE_BUDGET_UPDATE);
  assert.equal(action.asset, "USD");
  assert.equal(action.amountMinor, 50_000);
});

test("balance, receive and card intents map to the right action", () => {
  assert.equal(buildAction({ intent: "balance", message: "how much do I have", brand: "aurea" }).type, ACTION_TYPES.SHOW_BALANCE);
  assert.equal(buildAction({ intent: "receive", message: "how do I receive", brand: "aurea" }).type, ACTION_TYPES.OPEN_RECEIVE);
  assert.equal(buildAction({ intent: "card_help", message: "freeze my card", brand: "aurea" }).type, ACTION_TYPES.OPEN_CARD_CONTROLS);
  assert.equal(buildAction({ intent: "ambiguous", message: "hello", brand: "aurea" }).type, ACTION_TYPES.REPLY);
});

test("each brand has six distinct specialists with wired asset names", () => {
  const aurea = brandRoster("aurea");
  const orion = brandRoster("orion");
  assert.equal(aurea.length, 6);
  assert.equal(orion.length, 6);
  const ids = new Set([...aurea, ...orion].map((a) => a.id));
  assert.equal(ids.size, 12);
  for (const agent of [...aurea, ...orion]) {
    assert.match(agent.assetName, /^agent-(aurea|orion)-[a-z]+$/);
    assert.ok(agent.instructions.length > 100);
  }
});

test("an unknown named payee is never substituted with the other app", () => {
  const action = buildAction({
    intent: "prepare_payment",
    message: "Send USD 20 to Bob",
    brand: "aurea",
  });
  assert.equal(action.type, ACTION_TYPES.ASK_TRANSFER_DETAILS);
  assert.equal(action.to, null);
  assert.ok(action.missing.includes("recipient"));
  assert.deepEqual(action.knownRecipients, ["Mira Aurea", "Mira Orion"]);
});

test("a bill is offered as a manual checklist, not a cross-app transfer", () => {
  const action = buildAction({
    intent: "prepare_payment",
    message: "Pay my electricity bill USD 100",
    brand: "aurea",
  });
  assert.equal(action.type, ACTION_TYPES.REQUIREMENTS_FLOW);
  assert.equal(action.topic, "bill");
  assert.equal(action.providerConnected, false);
  assert.equal(action.amountMinor, 10_000);
});

test("a transfer with no recipient at all asks, and carries no recipient", () => {
  const action = buildAction({
    intent: "prepare_payment",
    message: "Send USD 20",
    brand: "orion",
  });
  assert.equal(action.type, ACTION_TYPES.ASK_TRANSFER_DETAILS);
  assert.equal(action.to, null);
  assert.ok(action.missing.includes("recipient"));
});

test("an explicit supported recipient still resolves and proposes", () => {
  const action = buildAction({
    intent: "prepare_payment",
    message: "Send USD 20 to Mira Aurea",
    brand: "orion",
  });
  assert.equal(action.type, ACTION_TYPES.PROPOSE_TRANSFER);
  assert.equal(action.to, "Mira Aurea");
  assert.equal(action.from, "Mira Orion");
  assert.equal(action.amountMinor, 20_00);
});

test("the fast path covers determined actions and skips open conversation", () => {
  const propose = buildAction({
    intent: "prepare_payment", message: "Send USD 25 to Mira Orion", brand: "aurea",
  });
  assert.equal(shouldUseFastPath(propose), true);
  const line = deterministicReply(propose, { brand: "aurea" });
  // The only figure in the sentence is the action's own amount.
  assert.match(line, /USD 25\.00/);
  assert.match(line, /Mira Orion/);

  const ask = buildAction({
    intent: "prepare_payment", message: "Send money to Mira Orion", brand: "aurea",
  });
  assert.equal(shouldUseFastPath(ask), true);
  assert.match(deterministicReply(ask, { brand: "aurea" }), /amount and currency/);

  const travel = buildAction({ intent: "travel", message: "book a flight", brand: "aurea" });
  assert.equal(shouldUseFastPath(travel), false);
  const chat = buildAction({ intent: "ambiguous", message: "hello", brand: "aurea" });
  assert.equal(shouldUseFastPath(chat), false);
  assert.equal(deterministicReply(chat, { brand: "aurea" }), null);
});

test("intent → specialist routing is brand-specific and deterministic", () => {
  assert.equal(specialistForIntent("aurea", "budget").id, "accountant");
  assert.equal(specialistForIntent("orion", "budget").id, "analyst");
  assert.equal(specialistForIntent("aurea", "card_help").id, "guardian");
  assert.equal(specialistForIntent("orion", "card_help").id, "sentinel");
  assert.equal(specialistForIntent("aurea", "unsupported").id, "planner");
  assert.equal(agentById("orion", "does-not-exist").id, "navigator");
});
