/**
 * The rule contract tests.
 *
 * An automation is `When <trigger> → Do <action> → Protect <things> → Pause
 * when <condition>`, with three delegation levels and a narrow mandate for
 * autopilot. These tests hold the contract's four promises:
 *
 *   1. triggers and actions are closed vocabularies, and every action is an
 *      existing verb or engine action — never a free-form string;
 *   2. the three delegation levels decide exactly as described;
 *   3. autopilot refuses outside its mandate (cap, expiry, run count) and
 *      inside a pause condition;
 *   4. Jev may only classify a sentence — its confidence is displayed and is
 *      never consulted by a decision, and its proposal is never pre-approved.
 *
 * Deterministic: the Jev read is a stubbed fetch; no network, no key needed.
 */

import test from "node:test";
import assert from "node:assert/strict";

import { catalogue } from "../lib/verbs.mjs";
import {
  TRIGGERS,
  TRIGGER_KINDS,
  DELEGATIONS,
  PROTECTIONS,
  PAUSE_CONDITIONS,
  AUTOMATION_ACTIONS,
  ENGINE_ACTIONS,
  automationAction,
  validateContract,
  automationDecision,
  approvalConsent,
  pausedBy,
  describeContract,
  buildRuleQuestions,
  subjectFromSentence,
  rulesFromSentence,
  proposeRule,
  ruleCatalogue,
} from "../lib/rule-contract.mjs";

/** A complete, valid contract, at the safest level. */
function contract(overrides = {}) {
  return {
    id: "rule_test",
    sentence: "Every time Maria pays me, put 20% in the reserve",
    trigger: { kind: "payment_received", subject: "Maria" },
    action: { verb: "engine.reserve.share", params: { sharePercent: 20 } },
    protect: ["reserve"],
    pause_when: ["plan_shortfall"],
    delegation: "prepare",
    mandate: {
      amountCapMinor: null,
      currency: null,
      expiresAt: null,
      maxRuns: null,
      runsUsed: 0,
      risk: "low",
    },
    approved: false,
    approvedAt: null,
    proposedBy: "rules",
    confidence: null,
    ...overrides,
  };
}

/** An approved autopilot contract with a real, bounded mandate. */
function autopilot(overrides = {}) {
  return contract({
    delegation: "autopilot",
    approved: true,
    approvedAt: 1_760_000_000_000,
    mandate: {
      amountCapMinor: 100_000,
      currency: "USD",
      expiresAt: 1_800_000_000_000,
      maxRuns: 10,
      runsUsed: 0,
      risk: "low",
    },
    ...overrides,
  });
}

function jevStub(answers) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url: String(url), body: JSON.parse(init.body) });
    return {
      ok: true,
      status: 200,
      headers: new Headers({ "content-type": "application/json" }),
      json: async () => ({ answers, model: "jev-test" }),
    };
  };
  return { impl, calls };
}

test("triggers are a closed set the app can actually honour", () => {
  assert.deepEqual([...TRIGGER_KINDS].sort(), [
    "payment_received",
    "price_claim_window",
    "subscription_charge",
    "watch_result",
  ]);
  for (const trigger of Object.values(TRIGGERS)) {
    assert.ok(trigger.label.length > 10, `${trigger.id} is described`);
    assert.ok(trigger.subjectLabel.length > 2, `${trigger.id} names what it needs`);
  }
  assert.ok(PROTECTIONS.includes("reserve"));
  assert.ok(PAUSE_CONDITIONS.includes("plan_shortfall"));

  assert.equal(validateContract(contract()).ok, true);
  assert.equal(
    validateContract(contract({ trigger: { kind: "everything", subject: "x" } })).ok,
    false
  );
  assert.match(
    validateContract(contract({ trigger: { kind: "payment_received", subject: "  " } })).errors.join(" "),
    /payer/
  );
});

test("actions are existing verbs only, never free-form", () => {
  const verbIds = new Set(catalogue().verbs.map((verb) => verb.id));
  for (const action of AUTOMATION_ACTIONS) {
    const engine = ENGINE_ACTIONS.some((entry) => entry.id === action.id);
    if (!engine) assert.ok(verbIds.has(action.id), `${action.id} is a real verb`);
    assert.ok(["observe", "prepare", "commit"].includes(action.class));
  }
  assert.ok(AUTOMATION_ACTIONS.length >= 6, "the rule catalogue is not a stub");
  assert.equal(automationAction("make.money"), null);

  const freeForm = validateContract(contract({ action: { verb: "send everyone 1 dollar" } }));
  assert.equal(freeForm.ok, false);
  assert.match(freeForm.errors.join(" "), /not an existing verb or engine action/);

  // A verb that exists but takes no parameters cannot be given any.
  const params = validateContract(contract({ action: { verb: "watch.create", params: { sharePercent: 10 } } }));
  assert.equal(params.ok, false);
  assert.match(params.errors.join(" "), /takes no parameters/);

  // The reserve share takes either a percentage or an exact amount.
  assert.equal(
    validateContract(contract({ action: { verb: "engine.reserve.share", params: { sharePercent: 20 } } })).ok,
    true
  );
  assert.equal(
    validateContract(contract({ action: { verb: "engine.reserve.share", params: { amountMinor: 2_500 } } })).ok,
    true
  );
  assert.equal(
    validateContract(contract({ action: { verb: "engine.reserve.share", params: {} } })).ok,
    true,
    "the whole amount is a valid share"
  );
  assert.equal(
    validateContract(
      contract({ action: { verb: "engine.reserve.share", params: { sharePercent: 120 } } })
    ).ok,
    false
  );
  assert.equal(
    validateContract(
      contract({ action: { verb: "engine.reserve.share", params: { sharePercent: 20, amountMinor: 100 } } })
    ).ok,
    false
  );
});

test("the three delegation levels decide exactly as described", () => {
  // prepare: compose, never run unattended — even once approved.
  const prepared = automationDecision(
    contract({ delegation: "prepare", approved: true, approvedAt: 1 }),
    { amountMinor: 5_000 }
  );
  assert.equal(prepared.decision, "prepare");
  assert.equal(prepared.withinMandate, true);

  // ask: ask first, whatever the verb.
  const asked = automationDecision(contract({ delegation: "ask" }), { amountMinor: 5_000 });
  assert.equal(asked.decision, "ask");

  // autopilot on an unapproved contract is still a proposal.
  const unapproved = automationDecision(autopilot({ approved: false, approvedAt: null }), {
    amountMinor: 5_000,
  });
  assert.equal(unapproved.decision, "ask");
  assert.match(unapproved.reason, /not approved/);

  // autopilot on a prepare-class verb inside the mandate runs.
  const runs = automationDecision(autopilot(), { amountMinor: 5_000 });
  assert.equal(runs.decision, "run");
  assert.equal(runs.withinMandate, true);
});

test("autopilot refuses anything outside the mandate", () => {
  const overCap = automationDecision(autopilot(), { amountMinor: 100_001 });
  assert.notEqual(overCap.decision, "run");
  assert.equal(overCap.withinMandate, false);
  assert.match(overCap.reason, /cap/);

  const unknownAmount = automationDecision(
    autopilot({ action: { verb: "transfer.prepare", params: {} } }),
    { amountMinor: null }
  );
  assert.notEqual(unknownAmount.decision, "run", "a cap that cannot be evaluated is not a cap");

  const expired = automationDecision(autopilot(), { amountMinor: 5_000, now: 1_900_000_000_000 });
  assert.notEqual(expired.decision, "run");
  assert.match(expired.reason, /expired/);

  const used = automationDecision(
    autopilot({ mandate: { ...autopilot().mandate, runsUsed: 10 } }),
    { amountMinor: 5_000 }
  );
  assert.equal(used.decision, "refuse");
  assert.match(used.reason, /run count/);

  // A mandate that is not narrow at all is invalid before it can run.
  const unbounded = autopilot({ mandate: { ...autopilot().mandate, expiresAt: null, maxRuns: null } });
  const check = validateContract(unbounded);
  assert.equal(check.ok, false);
  assert.match(check.errors.join(" "), /expiry or a run count/);

  const uncapped = autopilot({
    action: { verb: "transfer.prepare", params: {} },
    mandate: { ...autopilot().mandate, amountCapMinor: null },
  });
  assert.equal(validateContract(uncapped).ok, false);
  assert.match(validateContract(uncapped).errors.join(" "), /amount cap/);
});

test("a pause condition holds the rule, and the person can pause it by hand", () => {
  const held = automationDecision(autopilot(), {
    amountMinor: 5_000,
    facts: { planShortfall: true },
  });
  assert.notEqual(held.decision, "run");
  assert.equal(held.decision, "prepare");
  assert.match(held.reason, /plan_shortfall/);

  const manual = automationDecision(autopilot({ paused: true }), { amountMinor: 5_000 });
  assert.notEqual(manual.decision, "run");
  assert.equal(pausedBy(autopilot(), { incomeNotArrived: true }), null, "only declared conditions hold");

  const declared = contract({ pause_when: ["income_not_arrived"], paused: false });
  assert.equal(pausedBy(declared, { incomeNotArrived: true }), "income_not_arrived");
  assert.equal(pausedBy(declared, { incomeNotArrived: false }), null);
});

test("a commit verb passes the consent model — and high risk still stops", () => {
  const approved = autopilot({
    action: { verb: "subscription.cancel", params: {} },
    pause_when: [],
  });
  const runs = automationDecision(approved, { amountMinor: null });
  assert.equal(runs.decision, "run", "a low-risk commit approved as a structured rule may run");

  const highRisk = autopilot({
    action: { verb: "subscription.cancel", params: {} },
    pause_when: [],
    mandate: { ...autopilot().mandate, risk: "high" },
  });
  const stopped = automationDecision(highRisk, { amountMinor: null });
  assert.equal(stopped.decision, "ask");
  assert.match(stopped.reason, /high risk/);

  assert.equal(approvalConsent(contract()), null, "an unapproved contract has no consent");
  assert.equal(approvalConsent(approved).risk, "low");
  assert.equal(approvalConsent(highRisk).risk, "high");
});

test("Jev confidence never grants permission", async () => {
  process.env.TYPESAFE_API_KEY = "test-key";
  const { impl, calls } = jevStub({
    trigger: { choice: "payment_received", confidence: 0.99 },
    action: { choice: "transfer.prepare", confidence: 0.99 },
    protect: { choice: "reserve", confidence: 0.99 },
    pause_when: { choice: "plan_shortfall", confidence: 0.99 },
    delegation: { choice: "autopilot", confidence: 0.99 },
  });
  const read = await proposeRule("Every time Maria pays me, send half to savings", { fetchImpl: impl });
  assert.equal(read.ok, true);
  assert.equal(read.proposedBy, "jev");
  assert.equal(read.confidence, 0.99);
  assert.ok(calls[0].body.questions.trigger, "the trigger question is asked");
  assert.ok(calls[0].body.questions.delegation, "the delegation question is asked");
  // Every Jev answer is a member of a closed set; the question set is the
  // contract's own vocabulary, not free text.
  const questions = buildRuleQuestions();
  assert.ok(questions.action.criteria["engine.reserve.share"]);
  assert.ok(questions.action.criteria.none);

  // The proposal is never pre-approved, and the confidence is never consulted.
  assert.equal(read.proposal.approved, false);
  assert.equal(read.proposal.approvedAt, null);
  const decision = automationDecision(read.proposal, { amountMinor: 5_000 });
  assert.notEqual(decision.decision, "run", "a 0.99 proposal still cannot run");
  assert.equal(decision.decision, "prepare", "code downgraded the unbounded autopilot");

  // Even with a bounded mandate, an unapproved contract asks first.
  const bounded = {
    ...read.proposal,
    delegation: "autopilot",
    mandate: {
      ...read.proposal.mandate,
      amountCapMinor: 1_000_000,
      expiresAt: 1_800_000_000_000,
      maxRuns: 10,
    },
  };
  const beforeApproval = automationDecision(bounded, { amountMinor: 5_000 });
  assert.equal(beforeApproval.decision, "ask");
  assert.match(beforeApproval.reason, /not approved/);

  // Approve it exactly as proposed: then it runs, still without the confidence
  // entering the decision at all (the contract it reads has no confidence field
  // it consults).
  const approved = { ...bounded, approved: true, approvedAt: 1_760_000_000_000 };
  const after = automationDecision(approved, { amountMinor: 5_000 });
  assert.equal(after.decision, "run");
});

test("a Jev proposal mapped to nothing real is refused, and autopilot is downgraded without a mandate", async () => {
  process.env.TYPESAFE_API_KEY = "test-key";
  const freeForm = jevStub({
    trigger: { choice: "payment_received", confidence: 0.9 },
    action: { choice: "make.money.fast", confidence: 0.9 },
    delegation: { choice: "autopilot", confidence: 0.9 },
  });
  const refused = await proposeRule("Every time Maria pays me, do something clever", {
    fetchImpl: freeForm.impl,
  });
  assert.equal(refused.ok, false);
  assert.match(refused.detail, /did not name an action/);

  const noTrigger = jevStub({
    trigger: { choice: "none", confidence: 0.9 },
    action: { choice: "engine.reserve.share", confidence: 0.9 },
    delegation: { choice: "prepare", confidence: 0.9 },
  });
  assert.equal(
    (await proposeRule("Do something when things happen", { fetchImpl: noTrigger.impl })).ok,
    false
  );

  // A confident autopilot answer that names no mandate is downgraded by code.
  const unbounded = jevStub({
    trigger: { choice: "subscription_charge", confidence: 0.97 },
    action: { choice: "engine.subscriptions.review", confidence: 0.97 },
    protect: { choice: "none" },
    pause_when: { choice: "none" },
    delegation: { choice: "autopilot", confidence: 0.97 },
  });
  const read = await proposeRule("Whenever Netflix charges, check subscriptions automatically", {
    fetchImpl: unbounded.impl,
  });
  assert.equal(read.ok, true);
  assert.equal(read.proposal.delegation, "prepare", "code downgrades an unbounded autopilot");
  assert.equal(read.downgraded, true);
  assert.equal(read.proposal.approved, false);
});

test("the deterministic reader proposes the essay's sentence, at the safest level", () => {
  delete process.env.TYPESAFE_API_KEY;
  const read = rulesFromSentence("Every time Maria pays me, put 20% in the reserve");
  assert.equal(read.ok, true);
  assert.equal(read.proposal.trigger.kind, "payment_received");
  assert.equal(read.proposal.trigger.subject, "Maria");
  assert.equal(read.proposal.action.verb, "engine.reserve.share");
  assert.equal(read.proposal.action.params.sharePercent, 20);
  assert.equal(read.proposal.delegation, "prepare");
  assert.deepEqual(read.proposal.protect, ["reserve"]);
  assert.equal(validateContract(read.proposal).ok, true);

  // "Automatically" does not lift the level without a mandate: it is downgraded.
  const wantsAuto = rulesFromSentence("Whenever Maria pays me, automatically put 10% in the reserve");
  assert.equal(wantsAuto.proposal.delegation, "prepare");
  assert.equal(wantsAuto.downgraded, true);

  // A sentence with no watchable event or no runnable action is refused.
  assert.equal(rulesFromSentence("make life easier").ok, false);
  assert.equal(rulesFromSentence("whenever something happens, put 10% in the reserve").ok, false);
});

test("subject extraction names the payer, the charge, the item and the watch", () => {
  assert.equal(subjectFromSentence("payment_received", "every time João pays me, save it"), "João");
  assert.equal(subjectFromSentence("subscription_charge", "when Netflix charges, warn me"), "Netflix");
  assert.equal(subjectFromSentence("price_claim_window", "when the price of Brooks Ghost falls, claim"), "Brooks Ghost");
  assert.equal(subjectFromSentence("watch_result", "when the watch on Mac Mini drops, tell me"), "Mac Mini");
  assert.equal(subjectFromSentence("payment_received", "hello"), null);
});

test("the contract describes all four parts of the sentence", () => {
  const line = describeContract(contract({ protect: ["reserve", "goal:Lisbon trip"] }));
  assert.match(line, /When .*named payer/i);
  assert.match(line, /Maria/);
  assert.match(line, /do put a share/i);
  assert.match(line, /protect reserve, goal:Lisbon trip/);
  assert.match(line, /pause when plan_shortfall/);
  assert.match(line, /level: prepare/);
});

test("the health catalogue reports the closed sets without a secret", () => {
  const view = ruleCatalogue();
  assert.deepEqual(view.delegations.map((entry) => entry.id), [...DELEGATIONS]);
  assert.ok(view.triggers.length === 4);
  assert.ok(view.protections.includes("reserve"));
  assert.ok(view.pauseConditions.includes("income_not_arrived"));
  for (const action of view.actions) {
    assert.equal(typeof action.existingVerb, "boolean");
  }
  const safe = JSON.parse(JSON.stringify(view));
  assert.equal(safe.actions.length, AUTOMATION_ACTIONS.length);
  assert.ok(!JSON.stringify(view).includes("api.typesafe.ai"));
});
