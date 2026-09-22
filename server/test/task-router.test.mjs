/**
 * Task-router regressions for shopping product and budget extraction.
 *
 * "find me running shoes size 43 under 120 euros" used to start a shopping
 * task with `missing: ["product"]`, because extractProduct only understood
 * explicit "buy …" phrasings. These cases pin the fix.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { defaultLayout } from "../lib/jev-present.mjs";
import {
  detectTaskKind,
  continuationOf,
  extractSlots,
  fillAnswerSlots,
  extractMode,
  looksLikeMealRequest,
  looksLikeDefinitionQuestion,
  deriveTitle,
} from "../lib/task-router.mjs";

test("'find me running shoes size 43 under 120 euros' picks the product and the budget", () => {
  const message = "find me running shoes size 43 under 120 euros";
  assert.equal(detectTaskKind(message), "shopping");
  const slots = extractSlots("shopping", message);
  assert.equal(slots.product, "running shoes");
  assert.equal(slots.budget, "EUR 120");
});

test("'shoes 43 size' keeps the noun and drops the size", () => {
  assert.equal(extractSlots("shopping", "shoes 43 size").product, "shoes");
});

test("'where can i buy a mechanical keyboard' keeps the modifiers", () => {
  assert.equal(detectTaskKind("where can i buy a mechanical keyboard"), "shopping");
  assert.equal(extractSlots("shopping", "where can i buy a mechanical keyboard").product, "mechanical keyboard");
});

test("greetings and account questions carry no product", () => {
  assert.equal(extractSlots("shopping", "hi").product, null);
  assert.equal(extractSlots("shopping", "what is my balance").product, null);
});

test("lead-in phrasings and word currencies are understood", () => {
  const slots = extractSlots("shopping", "i need a laptop under 1000 dollars");
  assert.equal(slots.product, "laptop");
  assert.equal(slots.budget, "USD 1000");

  assert.equal(extractSlots("shopping", "i want some headphones").product, "headphones");
  assert.equal(extractSlots("shopping", "best keyboard in Lisbon").product, "keyboard");
});

test("travel budgets still parse the same helper", () => {
  const slots = extractSlots("travel", "flight to Lisbon under 500 euros");
  assert.equal(slots.budget, "EUR 500");
});

test("reserve is not a restaurant: a money question never opens a task", () => {
  // The owner's own question, which used to be routed to a restaurant task by
  // the word "reserve".
  assert.equal(detectTaskKind("how much can I spend this week without using my reserve?"), null);
  assert.equal(detectTaskKind("what is my reserve for?"), null);
  // A table still has to be named.
  assert.equal(detectTaskKind("reserve a table for two in Lisbon"), "restaurant");
  assert.equal(detectTaskKind("book a table somewhere nice"), "restaurant");
});

test("an answer to a question fills the slot that was asked for", () => {
  // The owner's flow: a travel task asked for origin and dates, and the reply
  // "São Paulo" was ignored, so it asked the same question again.
  assert.deepEqual(fillAnswerSlots("travel", ["origin", "dates"], "São Paulo"), { origin: "São Paulo" });
  assert.deepEqual(fillAnswerSlots("shopping", ["product"], "Nike Pegasus 41"), { product: "Nike Pegasus 41" });
  assert.equal(fillAnswerSlots("travel", ["dates"], "12-19 October").dates != null, true);
  // A whole sentence is not a place name.
  assert.deepEqual(fillAnswerSlots("travel", ["origin"], "I do not know yet"), {});
});

test("a greeting does not hide the product, and never earns a brand question", () => {
  // The owner's message, which asked "which brand or model?" back at him.
  for (const message of [
    "Hey. I want to buy a Mac Mini",
    "Hey, I want to buy a Mac Mini",
    "Hi there! I want to buy a Mac Mini",
  ]) {
    const kind = detectTaskKind(message);
    assert.equal(kind, "shopping");
    const slots = extractSlots(kind, message);
    assert.match(String(slots.product), /Mac Mini/i);
  }
});

test("a meal to buy has a mode, and both answers are understood", () => {
  // The owner's request: "I need to buy lunch" — a meal, and it could honestly
  // be delivery or a table. The mode is what the question asks for.
  assert.equal(detectTaskKind("I need to buy lunch"), "restaurant");
  assert.equal(looksLikeMealRequest("I need to buy lunch"), true);
  assert.equal(extractSlots("restaurant", "I need to buy lunch").mode, null);

  // Saying it outright fills the slot: no question.
  assert.equal(extractMode("order lunch on ifood"), "delivery");
  assert.equal(extractMode("get takeout for dinner"), "delivery");
  assert.equal(extractMode("dinner at a restaurant in Lisbon"), "dine-in");
  assert.equal(extractMode("book a table for two"), "dine-in");

  // Both answers to the question, and a place on the same line.
  assert.deepEqual(fillAnswerSlots("restaurant", ["mode", "location"], "Delivery"), { mode: "delivery" });
  assert.deepEqual(fillAnswerSlots("restaurant", ["mode", "location"], "to eat there"), { mode: "dine-in" });
  assert.deepEqual(fillAnswerSlots("restaurant", ["mode", "location"], "delivery to Canasvieiras"), {
    mode: "delivery",
    location: "Canasvieiras",
  });
  // A place name answers the place question when the mode is already known.
  assert.deepEqual(fillAnswerSlots("restaurant", ["location"], "Canasvieiras"), { location: "Canasvieiras" });
});

test("looking for a venue is not buying a meal and is never asked the delivery question", () => {
  // "restaurants in Lisbon" is about a place to sit; the mode question must not
  // appear for it. Bars are not a meal either.
  assert.equal(looksLikeMealRequest("Find me a restaurant in Lisbon for Friday"), false);
  assert.equal(looksLikeMealRequest("bars in Lisbon"), false);
  assert.equal(looksLikeMealRequest("dinner in Lisbon"), true);
  // Which is why a venue request carries a mode when it says one — naming a
  // restaurant is itself the dine-in signal, and delivery words win when both
  // appear.
  assert.equal(extractSlots("restaurant", "restaurants in Lisbon").mode, "dine-in");
  assert.equal(extractSlots("restaurant", "sushi delivered in Lisbon").mode, "delivery");
});

test("a place answer with a comma is still a place", () => {
  // The live failure: the task asked where to deliver, the answer was
  // "Canasvieiras, Florianopolis", and the comma made it look like a sentence.
  assert.deepEqual(fillAnswerSlots("restaurant", ["location"], "Canasvieiras, Florianopolis"), {
    location: "Canasvieiras Florianopolis",
  });
  assert.deepEqual(fillAnswerSlots("travel", ["origin"], "São Paulo, Brazil"), { origin: "São Paulo Brazil" });
});

test("an auction request is its own kind, with the lot's own slots", () => {
  assert.equal(detectTaskKind("find me an auction for a vintage watch under 300 dollars"), "auction");
  assert.equal(detectTaskKind("I want to bid on a Rolex on eBay"), "auction");
  assert.equal(detectTaskKind("sealed Game Boy auction in Lisbon"), "auction");

  const slots = extractSlots("auction", "find me an auction for a vintage watch under 300 dollars");
  assert.equal(slots.product, "vintage watch");
  assert.equal(slots.budget, "USD 300");

  assert.equal(extractSlots("auction", "bid on a Rolex on eBay").product, "Rolex");
  assert.equal(extractSlots("auction", "sealed Game Boy auction in Lisbon").condition, "sealed");
  assert.equal(extractSlots("auction", "sealed Game Boy auction in Lisbon").product, "sealed Game Boy");
  // No item named: the task must ask rather than search for the word "auction".
  assert.equal(extractSlots("auction", "find me an auction").product, null);
});

test("a definition question is not a search", () => {
  assert.equal(looksLikeDefinitionQuestion("what is an auction?"), true);
  assert.equal(looksLikeDefinitionQuestion("how do auctions work?"), true);
  // A request wearing a question's clothes is still a request.
  assert.equal(looksLikeDefinitionQuestion("what is the best restaurant in Lisbon"), false);
  assert.equal(looksLikeDefinitionQuestion("where can I find an auction for a watch"), false);
});

test("a standing watch is its own kind, with a subject, a target and a cadence", () => {
  assert.equal(detectTaskKind("watch the price of the Brooks Ghost 15 under 100 dollars"), "watch");
  assert.equal(detectTaskKind("let me know when the Brooks Ghost 15 drops under 100"), "watch");
  assert.equal(detectTaskKind("check every day for flights to Lisbon under 400 euros"), "watch");
  // Not a watch: a purchase of a watch, of a monitor, or a movie.
  assert.equal(detectTaskKind("find me a watch"), "shopping");
  assert.equal(detectTaskKind("find me a monitor"), "shopping");
  assert.notEqual(detectTaskKind("I want to watch a movie tonight"), "shopping");
  assert.notEqual(detectTaskKind("I want to watch a movie tonight"), "watch");

  const slots = extractSlots("watch", "watch the price of the Brooks Ghost 15 under 100 dollars");
  assert.equal(slots.subject, "Brooks Ghost 15");
  assert.equal(slots.target, "USD 100");
  assert.equal(slots.cadence, null);
  assert.equal(extractSlots("watch", "check every day for flights to Lisbon under 400 euros").cadence, "daily");
  assert.equal(extractSlots("watch", "let me know when the Brooks Ghost 15 drops under 100").subject, "Brooks Ghost 15");
  assert.equal(extractSlots("watch", "keep an eye on the Pegasus 41 price").subject, "Pegasus 41");
});

test("a place stops at the next preposition, and the date is not part of it", () => {
  // The live failure: an itinerary read "São Paulo TO Lisbon → Lisbon IN October".
  const slots = extractSlots("travel", "find me flights from Sao Paulo to Lisbon in October");
  assert.equal(slots.origin, "Sao Paulo");
  assert.equal(slots.destination, "Lisbon");
  assert.match(String(slots.dates), /October/i);
  // Existing shapes still hold.
  assert.equal(extractSlots("travel", "flight to Lisbon under 500 euros").destination, "Lisbon");
  assert.equal(extractSlots("travel", "somewhere to stay in Lisbon").destination, "Lisbon");
});

test("'Ok I need a flight…' is a new request, not a refinement of the last subject", () => {
  // The live failure: an "Ok"-prefixed message was merged into a sushi
  // restaurant task as a refinement, and the flight request ran with the
  // restaurant's slots and progress.
  assert.equal(
    continuationOf("Ok I need a flight to Lisbon buy anything for tomorrow"),
    null);
  assert.equal(
    continuationOf("Ok, and bars?"),
    "bars");
  assert.equal(continuationOf("ok also sushi"), "sushi");
  assert.equal(continuationOf("and with a view"), "with a view");
  // The flight sentence also yields a real place, not a verb phrase.
  const slots = extractSlots("travel", "I need a flight to Lisbon buy anything for tomorrow");
  assert.equal(slots.destination, "Lisbon");
});

test("buying a currency is a conversion, never a shopping task", () => {
  // The live failure: "I need to buy euros" became "Shopping: euros".
  assert.equal(detectTaskKind("I need to buy euros"), null);
  assert.equal(detectTaskKind("buy 100 dollars"), null);
  assert.equal(detectTaskKind("I need to buy some reais for my trip"), null);
  // A real product still shops.
  assert.equal(detectTaskKind("buy running shoes"), "shopping");
  assert.equal(detectTaskKind("Hey. I want to buy a Mac Mini"), "shopping");
  // And a currency alongside a product is that product.
  assert.equal(detectTaskKind("buy a wallet for my euros"), "shopping");
});

test("titles read like subjects, never like capability labels", () => {
  assert.equal(deriveTitle("shopping", { product: "food for my cat" }, "buy cat food"), "Food for my cat");
  assert.equal(
    deriveTitle("shopping", { product: "running shoes", budget: "USD 100" }, "find me running shoes"),
    "Running shoes");
  assert.equal(deriveTitle("restaurant", { location: "Lisbon", mode: "dine-in" }, "x"), "Restaurants in Lisbon");
  assert.equal(
    deriveTitle("restaurant", { location: "Canasvieiras", mode: "delivery" }, "x"),
    "Delivery to Canasvieiras");
  assert.equal(deriveTitle("watch", { subject: "Brooks Ghost 15" }, "x"), "Watching Brooks Ghost 15");
  assert.equal(deriveTitle("travel", { destination: "Lisbon" }, "flights"), "Flights to Lisbon");
  // Never a capability label.
  for (const kind of ["shopping", "research", "admin", "auction"]) {
    const title = deriveTitle(kind, { product: "a thing", topic: "a thing", goal: "a thing" }, "x");
    assert.doesNotMatch(title, /^(Shopping|Research|Plan|Auctions)\b/);
  }
});

test("a purchase is titled for the thing, not the city it ships to", () => {
  assert.equal(
    deriveTitle("shopping", { product: "cat food", location: "Florianopolis, Brazil" }, "buy cat food"),
    "Cat food");
  assert.equal(
    deriveTitle("auction", { product: "vintage Seiko", location: "Lisbon" }, "bid on a Seiko"),
    "Vintage Seiko");
  assert.equal(deriveTitle("travel", { destination: "Lisbon" }, "x"), "Flights to Lisbon");
});

test("buying a security is an order; asking its price is research; Pix is a transfer", () => {
  // Investing has its own capability now.
  assert.equal(detectTaskKind("buy 10 shares of AAPL"), "invest");
  assert.equal(detectTaskKind("invest 1000 dollars in an ETF"), "invest");
  const slots = extractSlots("invest", "buy 10 shares of AAPL");
  assert.equal(slots.symbol, "AAPL");
  assert.equal(slots.quantity, "10 shares");
  assert.equal(deriveTitle("invest", slots, "buy 10 shares of AAPL"), "AAPL · 10 shares");

  // A price question is research; an unnamed instrument asks rather than guesses.
  assert.equal(detectTaskKind("how much is Tesla stock"), "research");
  assert.equal(extractSlots("invest", "invest 1000 dollars in an ETF").symbol, null);

  // Money movement is never a task — the app's transfer path owns it.
  assert.equal(detectTaskKind("I need to send pix to a friend"), null);
  assert.equal(detectTaskKind("send 50 dollars to Maria"), null);
  assert.equal(detectTaskKind("how do I send money to Brazil"), null);
  assert.equal(detectTaskKind("what is a pix"), null);
});

test("an invest result is laid out as an order", () => {
  assert.equal(defaultLayout({ kind: "invest", slots: { symbol: "AAPL", quantity: "10 shares" } }), "order");
  assert.equal(defaultLayout({ kind: "invest", slots: {} }), "picks");
  assert.equal(defaultLayout({ kind: "invest", slots: { symbol: "AAPL" } }), "order");
  assert.equal(defaultLayout({ kind: "shopping", slots: {} }), "picks");
});

test("the person's own recurring spend is the app's record, never a task", () => {
  // The app holds the subscriptions; a search cannot know them.
  assert.equal(detectTaskKind("how much do I spend on subscriptions?"), null);
  assert.equal(detectTaskKind("what subscriptions can I cancel"), null);
  assert.equal(detectTaskKind("cancel Adobe please"), null);
  assert.equal(detectTaskKind("when does Netflix renew"), null);
  // But finding a cheaper alternative is research.
  assert.equal(detectTaskKind("find me a cheaper alternative to Adobe"), "research");
});

test("offers and cashback are the issuer's data, not a research subject", () => {
  assert.equal(detectTaskKind("how much cashback did I earn?"), null);
  assert.equal(detectTaskKind("what offers do I have on my card"), null);
  assert.equal(detectTaskKind("which card gives the most cashback at pet shops"), null);
  // Comparing products that carry cashback is still research.
  assert.equal(detectTaskKind("compare cashback credit cards"), "research");
});
