/**
 * Bounded-execution verb tests.
 *
 * WHY: docs/nubank-revolut-scan.md §4.1 asks for one typed catalogue of
 * bounded verbs, with consent read through the model the repository already
 * has. These tests hold that contract: the catalogue is complete and internally
 * consistent, every typed action the proxy can compose maps onto it, and no
 * commit verb runs without a confident authorisation. Deterministic: no
 * network, no model.
 */

import test from "node:test";
import assert from "node:assert/strict";

import { ACTION_TYPES } from "../lib/orchestrate.mjs";
import { VERB_CLASSES, catalogue, verbFor, mayRun, assertVerbClass } from "../lib/verbs.mjs";

const { classes, verbs } = catalogue();
const commits = verbs.filter((verb) => verb.class === "commit");

/** A typed consent read, shaped exactly like the one `readConsent` returns. */
function consentRead(overrides = {}) {
  return {
    ok: true,
    authorises: 0.1,
    suppliesDetail: 0.1,
    missing: "none",
    risk: "low",
    ...overrides,
  };
}

test("the catalogue is typed: three classes, complete entries, no duplicates", () => {
  assert.deepEqual(classes.map((entry) => entry.id), ["observe", "prepare", "commit"]);
  for (const entry of classes) assert.ok(entry.label.length > 10, `${entry.id} is explained`);
  assert.ok(verbs.length >= 12, "the catalogue is not a stub");

  const ids = new Set();
  for (const verb of verbs) {
    assert.ok(VERB_CLASSES.includes(verb.class), `${verb.id} has a known class`);
    assert.ok(Array.isArray(verb.requires), `${verb.id} lists what it requires`);
    assert.equal(typeof verb.route, "string");
    assert.ok(verb.route.length > 0, `${verb.id} names the route that performs it`);
    assert.ok(!ids.has(verb.id), `${verb.id} appears exactly once`);
    ids.add(verb.id);
    if (verb.class === "commit") {
      assert.ok(verb.requires.includes("consent"), `commit ${verb.id} requires the person's word`);
    } else {
      assert.ok(!verb.requires.includes("consent"), `${verb.id} never asks for consent`);
    }
  }

  // Health-style introspection must be JSON-safe, and must not leak the
  // catalogue's own objects to a caller that mutates what it receives.
  const copy = catalogue();
  assert.doesNotThrow(() => JSON.parse(JSON.stringify(copy)));
  copy.verbs[0].requires.push("mutated");
  assert.notDeepEqual(catalogue().verbs[0].requires, copy.verbs[0].requires);
});

test("every typed action maps onto a verb, and none of them onto a commit", () => {
  for (const type of Object.values(ACTION_TYPES)) {
    const verb = verbFor({ type });
    assert.ok(verb, `${type} maps onto a verb`);
    assert.notEqual(verb.class, "commit", `${type} can never commit from the chat turn`);
  }
  assert.equal(verbFor(ACTION_TYPES.PROPOSE_TRANSFER).id, "transfer.prepare");
  assert.equal(verbFor(ACTION_TYPES.AGENT_TASK).id, "task.create");
  assert.equal(verbFor(ACTION_TYPES.REPLY).class, "observe");
  assert.equal(verbFor("not_a_real_action"), null);
  assert.equal(verbFor(null), null);
});

test("observe and prepare run without the person's word", () => {
  for (const verb of verbs.filter((entry) => entry.class !== "commit")) {
    const decision = mayRun(verb, {});
    assert.equal(decision.ok, true, `${verb.id} does not wait for consent`);
    assert.equal(decision.decision, "proceed");
  }
  assert.equal(mayRun("balance.read").ok, true);
  assert.equal(mayRun(verbFor({ type: ACTION_TYPES.AGENT_TASK }), {}).ok, true);
});

test("a commit never runs without the person's word", () => {
  assert.ok(commits.length >= 4, "the catalogue has real commit verbs");
  for (const verb of commits) {
    assert.equal(mayRun(verb, {}).ok, false, `${verb.id} waits for consent`);
    assert.equal(mayRun(verb, { consent: { ok: false, detail: "no read" } }).ok, false);
    assert.equal(
      mayRun(verb, { consent: consentRead() }).ok,
      false,
      "an ordinary purchase intent is not an authorisation"
    );
    assert.equal(
      mayRun(verb, { consent: consentRead({ authorises: 0.99, risk: "high" }) }).ok,
      false,
      "high risk stops for a person however the message reads"
    );
  }
  const gate = mayRun("transfer.commit", { consent: consentRead() });
  assert.equal(gate.decision, "confirm");
  assert.ok(gate.reason.length > 0);
});

test("a confident authorisation proceeds", () => {
  const decision = mayRun("fx.swap", { consent: consentRead({ authorises: 0.93 }) });
  assert.equal(decision.ok, true);
  assert.equal(decision.decision, "proceed");
  assert.match(decision.reason, /authorised/);
  assert.equal(decision.detail, undefined, "a proceed carries no missing detail");
});

test("a detail the app holds is not asked for twice; one it lacks still is", () => {
  const read = consentRead({ authorises: 0.9, missing: "amount" });
  const asked = mayRun("transfer.commit", { consent: read });
  assert.equal(asked.ok, false);
  assert.equal(asked.decision, "ask");
  assert.equal(asked.detail, "amount");

  const known = mayRun("transfer.commit", { consent: read, known: { amount: "USD 25.00" } });
  assert.equal(known.ok, true);
  assert.equal(known.decision, "proceed");
});

test("a wrong-class or unmapped action is a development error", () => {
  const propose = { type: ACTION_TYPES.PROPOSE_TRANSFER };
  assert.equal(assertVerbClass(propose, "prepare", { where: "test" }), true);
  assert.throws(
    () => assertVerbClass(propose, "commit", { where: "test" }),
    /maps to 'transfer\.prepare' \(class 'prepare'\), not 'commit'/
  );
  assert.throws(
    () => assertVerbClass({ type: "no_such_action" }, "prepare", { where: "test" }),
    /no verb is mapped/
  );
  assert.throws(() => mayRun("no.such.verb"), /not in the verb catalogue/);
});

test("in production the same violation is logged and refused, never thrown", () => {
  const previous = process.env.NODE_ENV;
  const originalError = console.error;
  const logged = [];
  process.env.NODE_ENV = "production";
  console.error = (...args) => logged.push(args.join(" "));
  try {
    assert.equal(
      assertVerbClass({ type: ACTION_TYPES.PROPOSE_TRANSFER }, "commit", { where: "test" }),
      false
    );
    const unknown = mayRun("no.such.verb");
    assert.equal(unknown.ok, false);
    assert.equal(unknown.decision, "unknown");
    assert.match(logged.join("\n"), /verb catalogue violation/);
  } finally {
    console.error = originalError;
    if (previous === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = previous;
  }
});
