/**
 * The rule contract — an automation written the way the essay writes it:
 *
 *   When <trigger> → Do <action> → Protect <things> → Pause when <condition>
 *
 * with three delegation levels — `prepare`, `ask`, `autopilot` — and an
 * editable, persisted contract the person approves as a *structured object*,
 * never as the sentence that proposed it.
 *
 * What this module owns, and what it refuses to own:
 *
 *   · Triggers are a closed vocabulary of events this app can actually honour
 *     with records it holds: a settled relay payment arriving from a named
 *     payer, a subscription charge day, a price-claim window, a watch result.
 *   · Actions are existing verbs only — the `verbs.mjs` catalogue plus the
 *     app's own engine actions, both listed here. An action that is not one of
 *     them is a programming error, not a sentence to interpret.
 *   · Code validates; Jev may only *classify* a sentence into the closed
 *     vocabularies (`proposeRule`). Its confidence is returned for display and
 *     is never consulted by `automationDecision` — a confident sentence is a
 *     proposal, and a proposal is not a permission.
 *   · `autopilot` may run a verb whose class is `prepare`, or a `commit` whose
 *     consent has already passed the one consent model this repository has
 *     (`verbs.mjs` / `jev-consent.mjs`), and only inside the narrow mandate:
 *     an amount cap, an expiry and a run count. Outside the mandate it asks.
 *
 * The contract itself is plain JSON, so the app persists exactly what was
 * approved and edits nothing silently.
 */

import { mayRun, catalogue } from "./verbs.mjs";

/** The bounded verb catalogue, by id. `verbFor` maps typed actions; this maps verbs. */
const VERB_BY_ID = new Map(catalogue().verbs.map((verb) => [verb.id, verb]));

export const TRIGGERS = Object.freeze({
  payment_received: Object.freeze({
    id: "payment_received",
    label: "A settled payment arrives from a named payer",
    subjectLabel: "payer",
  }),
  subscription_charge: Object.freeze({
    id: "subscription_charge",
    label: "A subscription reaches its charge day",
    subjectLabel: "subscription name",
  }),
  price_claim_window: Object.freeze({
    id: "price_claim_window",
    label: "A price-claim window is open (or closing)",
    subjectLabel: "item",
  }),
  watch_result: Object.freeze({
    id: "watch_result",
    label: "A standing watch returns a new result",
    subjectLabel: "watched subject",
  }),
});

export const TRIGGER_KINDS = Object.freeze(Object.keys(TRIGGERS));

/** The three levels, weakest to strongest. */
export const DELEGATIONS = Object.freeze(["prepare", "ask", "autopilot"]);

export const DELEGATION_INFO = Object.freeze({
  prepare: "Compose the action and show it; the person confirms once.",
  ask: "Ask the person first; nothing is composed until they say yes.",
  autopilot: "Run inside the mandate without asking. Bounded, revocable.",
});

/** Things a rule can promise not to disturb. `goal:<name>` names the fund. */
export const PROTECTIONS = Object.freeze(["reserve", "plan", "goal", "standing"]);

/** Conditions that hold the rule, evaluated against facts the app holds. */
export const PAUSE_CONDITIONS = Object.freeze([
  "amount_above_cap",
  "plan_shortfall",
  "income_not_arrived",
  "goal_protected",
  "paused",
]);

/**
 * The actions a rule may carry.
 *
 * Every id is either a real verb in the bounded catalogue (`verbs.mjs`) or an
 * engine action the app itself implements. `class` is the verb class, and it is
 * what the delegation rules are written against — there is no fourth class and
 * no free-form action.
 */
export const ENGINE_ACTIONS = Object.freeze([
  Object.freeze({
    id: "engine.reserve.share",
    class: "prepare",
    label: "Put a share of the money into the reserve",
    amountBearing: true,
  }),
  Object.freeze({
    id: "engine.income.smooth",
    class: "prepare",
    label: "Carve the money into tax, buffer and spendable",
    amountBearing: true,
  }),
  Object.freeze({
    id: "engine.subscriptions.review",
    class: "observe",
    label: "Review the recurring charges for waste",
    amountBearing: false,
  }),
  Object.freeze({
    id: "engine.price_claim.prepare",
    class: "prepare",
    label: "Prepare the price-match claim",
    amountBearing: false,
  }),
]);

/**
 * The curated automation set. Kept deliberately smaller than the whole verb
 * catalogue: a rule is a standing promise, so it may only name actions that
 * make sense to repeat.
 */
const ACTION_LABELS = Object.freeze({
  "engine.reserve.share": "Put a share of the money into the reserve",
  "engine.income.smooth": "Carve the money into tax, buffer and spendable",
  "engine.subscriptions.review": "Review the recurring charges for waste",
  "engine.price_claim.prepare": "Prepare the price-match claim",
  "watch.create": "Start or keep a standing watch",
  "task.create": "Start a research or preparation task",
  "transfer.prepare": "Prepare a transfer to the named person",
  "budget.prepare": "Prepare an allocation or budget change",
  "subscription.cancel": "Cancel the named recurring charge",
});

/** Amount-bearing verbs: a cap is meaningful for these. */
const AMOUNT_BEARING_VERBS = Object.freeze(
  new Set(["transfer.prepare", "transfer.commit", "fx.swap", "budget.prepare"])
);

export const AUTOMATION_ACTIONS = Object.freeze(
  Object.entries(ACTION_LABELS).map(([id, label]) => {
    const engine = ENGINE_ACTIONS.find((entry) => entry.id === id);
    if (engine) return Object.freeze({ ...engine, label });
    const verb = VERB_BY_ID.get(id);
    if (!verb) throw new Error(`rule contract: '${id}' is not a verb in the catalogue`);
    return Object.freeze({
      id,
      class: verb.class,
      label,
      amountBearing: AMOUNT_BEARING_VERBS.has(id),
    });
  })
);

const ACTION_BY_ID = new Map(AUTOMATION_ACTIONS.map((action) => [action.id, action]));

/** The action behind an id, or null. Unknown ids never become an action. */
export function automationAction(id) {
  return typeof id === "string" ? ACTION_BY_ID.get(id) ?? null : null;
}

/** True when this string is one of the app's own engine action ids. */
export function isEngineAction(id) {
  return ENGINE_ACTIONS.some((entry) => entry.id === id);
}

function asArray(value) {
  if (Array.isArray(value)) return value;
  if (value === null || value === undefined) return [];
  return [value];
}

function isProtection(value) {
  const text = String(value || "");
  if (PROTECTIONS.includes(text)) return true;
  return text.startsWith("goal:") && text.slice("goal:".length).trim().length > 0;
}

function validateParams(action, params) {
  const entries = params && typeof params === "object" ? Object.keys(params) : [];
  if (action.id !== "engine.reserve.share") {
    if (entries.length) return [`'${action.id}' takes no parameters`];
    return [];
  }
  const errors = [];
  const share = params?.sharePercent;
  const amount = params?.amountMinor;
  const hasShare = share !== null && share !== undefined;
  const hasAmount = amount !== null && amount !== undefined;
  if (hasShare && hasAmount) errors.push("a reserve share is either a percentage or an amount, not both");
  if (!hasShare && !hasAmount) return []; // the whole amount is a valid share
  if (hasShare && !(typeof share === "number" && Number.isFinite(share) && share > 0 && share <= 100)) {
    errors.push("sharePercent must be between 0 and 100");
  }
  if (hasAmount && !(Number.isSafeInteger(amount) && amount > 0)) {
    errors.push("amountMinor must be a positive integer");
  }
  return errors;
}

/**
 * Validate a contract. Deterministic and total: every unknown value is named.
 * @returns {{ok:boolean, errors:string[]}}
 */
export function validateContract(contract) {
  if (!contract || typeof contract !== "object") {
    return { ok: false, errors: ["a contract is an object"] };
  }
  const errors = [];

  const trigger = TRIGGERS[contract.trigger?.kind];
  if (!trigger) {
    errors.push("the trigger is not one this app can honour");
  } else {
    const subject = String(contract.trigger?.subject ?? "").trim();
    if (!subject) errors.push(`a ${trigger.id} rule needs its ${trigger.subjectLabel} named`);
  }

  const action = automationAction(contract.action?.verb);
  if (!action) {
    errors.push("the action is not an existing verb or engine action");
  } else {
    errors.push(...validateParams(action, contract.action?.params));
  }

  if (!DELEGATIONS.includes(contract.delegation)) {
    errors.push("the delegation is not prepare, ask or autopilot");
  }

  for (const protection of asArray(contract.protect)) {
    if (!isProtection(protection)) errors.push(`unknown protection '${protection}'`);
  }
  for (const condition of asArray(contract.pause_when)) {
    if (!PAUSE_CONDITIONS.includes(condition)) errors.push(`unknown pause condition '${condition}'`);
  }

  const mandate = contract.mandate && typeof contract.mandate === "object" ? contract.mandate : {};
  if (mandate.amountCapMinor !== null && mandate.amountCapMinor !== undefined) {
    if (!(Number.isSafeInteger(mandate.amountCapMinor) && mandate.amountCapMinor > 0)) {
      errors.push("the amount cap must be a positive integer in minor units");
    }
  }
  if (mandate.expiresAt !== null && mandate.expiresAt !== undefined) {
    if (!(Number.isFinite(mandate.expiresAt) && mandate.expiresAt > 0)) {
      errors.push("the expiry must be a timestamp in milliseconds");
    }
  }
  if (mandate.maxRuns !== null && mandate.maxRuns !== undefined) {
    if (!(Number.isSafeInteger(mandate.maxRuns) && mandate.maxRuns > 0)) {
      errors.push("the run count must be a positive integer");
    }
  }
  if (mandate.runsUsed !== null && mandate.runsUsed !== undefined) {
    if (!(Number.isSafeInteger(mandate.runsUsed) && mandate.runsUsed >= 0)) {
      errors.push("runsUsed must be a whole number of runs");
    }
  }
  if (mandate.risk !== null && mandate.risk !== undefined && !["low", "high"].includes(mandate.risk)) {
    errors.push("risk is low or high");
  }

  if (contract.delegation === "autopilot") {
    // The narrow mandate: an autopilot rule is capped, expiring or counted.
    if (mandate.expiresAt === null || mandate.expiresAt === undefined) {
      if (mandate.maxRuns === null || mandate.maxRuns === undefined) {
        errors.push("an autopilot rule needs an expiry or a run count");
      }
    }
    if (action?.amountBearing) {
      if (!(Number.isSafeInteger(mandate.amountCapMinor) && mandate.amountCapMinor > 0)) {
        errors.push(`'${action.id}' carries an amount, so autopilot needs an amount cap`);
      }
    }
  }

  return { ok: errors.length === 0, errors };
}

/** The pause condition holding this rule right now, or null. */
export function pausedBy(contract, facts = {}) {
  const active = new Set(asArray(contract?.pause_when).filter((entry) => PAUSE_CONDITIONS.includes(entry)));
  if (facts.paused === true || contract?.paused === true || active.has("paused")) return "paused";
  if (facts.planShortfall === true && active.has("plan_shortfall")) return "plan_shortfall";
  if (facts.incomeNotArrived === true && active.has("income_not_arrived")) return "income_not_arrived";
  if (facts.goalProtected === true && active.has("goal_protected")) return "goal_protected";
  if (facts.amountAboveCap === true && active.has("amount_above_cap")) return "amount_above_cap";
  return null;
}

/**
 * The person's approval of the structured contract, read as the typed consent
 * the one consent model already understands.
 *
 * An unapproved contract has no consent — a proposal is not a permission. A
 * high-risk mandate produces a `high` read, and `decideConsent` (through
 * `mayRun`) still stops it for a person. Nothing here is a model's opinion, and
 * nothing here consults a confidence.
 */
export function approvalConsent(contract) {
  if (contract?.approved !== true || typeof contract?.approvedAt !== "number") return null;
  const risk = contract?.mandate?.risk === "high" ? "high" : "low";
  return { ok: true, authorises: 1, suppliesDetail: 1, missing: "none", risk };
}

/**
 * May this rule run, right now?
 *
 * @returns {{decision:"run"|"ask"|"prepare"|"refuse", reason:string,
 *            detail:string|null, withinMandate:boolean}}
 */
export function automationDecision(
  contract,
  { amountMinor = null, now = Date.now(), facts = {}, consent = null } = {}
) {
  const check = validateContract(contract);
  if (!check.ok) {
    return {
      decision: "refuse",
      reason: "the contract is invalid",
      detail: check.errors.join("; "),
      withinMandate: false,
    };
  }

  const paused = pausedBy(contract, facts);
  if (paused) {
    return {
      decision: "prepare",
      reason: `held: ${paused}`,
      detail: `One of the rule's pause conditions is true (${paused}); nothing runs.`,
      withinMandate: true,
    };
  }

  const mandate = contract.mandate || {};
  if (mandate.expiresAt !== null && mandate.expiresAt !== undefined && now > mandate.expiresAt) {
    return { decision: "refuse", reason: "the rule expired", detail: null, withinMandate: false };
  }
  if (
    mandate.maxRuns !== null &&
    mandate.maxRuns !== undefined &&
    (mandate.runsUsed || 0) >= mandate.maxRuns
  ) {
    return { decision: "refuse", reason: "the rule used its run count", detail: null, withinMandate: false };
  }

  const action = automationAction(contract.action.verb);
  if (mandate.amountCapMinor !== null && mandate.amountCapMinor !== undefined) {
    if (amountMinor === null && action.amountBearing) {
      // A cap that cannot be evaluated is not a cap.
      return { decision: "ask", reason: "the amount is not known, so the cap cannot be checked", detail: null, withinMandate: false };
    }
    if (amountMinor !== null && amountMinor > mandate.amountCapMinor) {
      return { decision: "ask", reason: "outside the amount cap", detail: null, withinMandate: false };
    }
  }

  if (contract.delegation === "prepare") {
    return { decision: "prepare", reason: "the rule prepares; the person confirms", detail: null, withinMandate: true };
  }
  if (contract.delegation === "ask") {
    return { decision: "ask", reason: "the rule asks before it acts", detail: null, withinMandate: true };
  }

  // Autopilot. The person's approval of this exact contract is what lets it
  // stand; an unapproved contract asks.
  if (contract.approved !== true || typeof contract.approvedAt !== "number") {
    return { decision: "ask", reason: "the rule is not approved yet", detail: null, withinMandate: false };
  }

  if (action.class === "commit") {
    const read = consent ?? approvalConsent(contract);
    if (!read) {
      return { decision: "ask", reason: "a commit needs the person's word", detail: null, withinMandate: false };
    }
    const gate = mayRun(contract.action.verb, { consent: read });
    if (gate.ok) {
      return { decision: "run", reason: gate.reason, detail: null, withinMandate: true };
    }
    return {
      decision: "ask",
      reason: gate.reason || "the consent model did not clear it",
      detail: gate.detail ?? null,
      withinMandate: true,
    };
  }

  return {
    decision: "run",
    reason: `class '${action.class}' runs inside its mandate`,
    detail: null,
    withinMandate: true,
  };
}

/** The contract as one sentence a person can check before approving. */
export function describeContract(contract) {
  if (!contract || typeof contract !== "object") return "Not a rule.";
  const trigger = TRIGGERS[contract.trigger?.kind];
  const action = automationAction(contract.action?.verb);
  const level = DELEGATIONS.includes(contract.delegation) ? contract.delegation : "prepare";
  const bits = [];
  bits.push(
    `When ${trigger ? trigger.label.toLowerCase() : "?"}` +
      (contract.trigger?.subject ? ` (${contract.trigger.subject})` : "")
  );
  bits.push(`do ${action ? action.label.toLowerCase() : "?"}`);
  const protect = asArray(contract.protect);
  if (protect.length) bits.push(`protect ${protect.join(", ")}`);
  const pauses = asArray(contract.pause_when);
  if (pauses.length) bits.push(`pause when ${pauses.join(", ")}`);
  bits.push(`level: ${level}`);
  const mandate = contract.mandate || {};
  if (mandate.amountCapMinor) bits.push(`cap ${mandate.amountCapMinor} minor units`);
  if (mandate.maxRuns) bits.push(`up to ${mandate.maxRuns} runs`);
  return bits.join(" → ") + ".";
}

// ---------------------------------------------------------------------------
// Jev classifies the sentence; code validates the contract
// ---------------------------------------------------------------------------

const ENDPOINT = "https://api.typesafe.ai/v1/systemone";
const TIMEOUT_MS = 6000;

/** Below this the classification is still a proposal, and nothing more. */
export const PROPOSAL_FLOOR = 0.5;

export function ruleConfigured() {
  return Boolean(process.env.TYPESAFE_API_KEY);
}

function questionFor(criteria, instructions) {
  return { type: "choice", instructions, criteria };
}

/** The question set Jev answers. Every answer is a member of a closed set. */
export function buildRuleQuestions() {
  const triggerCriteria = {};
  for (const trigger of Object.values(TRIGGERS)) triggerCriteria[trigger.id] = trigger.label;
  triggerCriteria.none = "No standing event this app holds was named";

  const actionCriteria = {};
  for (const action of AUTOMATION_ACTIONS) actionCriteria[action.id] = action.label;
  actionCriteria.none = "No action this app can run was named";

  const protectionCriteria = {
    reserve: "The reserve earmark",
    plan: "The monthly allocation plan",
    goal: "A protected goal or fund",
    none: "Nothing specific",
  };
  const pauseCriteria = {
    amount_above_cap: "The amount is above the cap the person set",
    plan_shortfall: "It would push the plan into a shortfall",
    income_not_arrived: "It relies on income that has not arrived",
    goal_protected: "It would touch a protected goal",
    none: "No condition named",
  };
  return {
    trigger: questionFor(
      triggerCriteria,
      "Which standing event does the person want this rule to run on? Choose none unless the person names an event this assistant can actually watch."
    ),
    action: questionFor(
      actionCriteria,
      "Which one of these actions does the person want the rule to take? Choose the closest; choose none when no listed action fits."
    ),
    protect: questionFor(
      protectionCriteria,
      "What does the person want the rule not to disturb? Choose none when nothing specific was said."
    ),
    pause_when: questionFor(
      pauseCriteria,
      "Under what condition should the rule hold and ask instead? Choose none when no condition was said."
    ),
    delegation: questionFor(
      {
        prepare: "Prepare it and show it; the person confirms",
        ask: "Ask the person before doing anything",
        autopilot: "Do it without asking, inside a bounded mandate",
      },
      "How much should this rule be allowed to do on its own? With no clear instruction, choose prepare — the safest level."
    ),
  };
}

function choice(answers, name) {
  const value = answers?.[name]?.choice;
  return typeof value === "string" ? value : null;
}

function confidenceOf(answers, name) {
  return typeof answers?.[name]?.confidence === "number" ? answers[name].confidence : null;
}

/** The payer / subscription / item / subject the sentence names. Code, not Jev. */
export function subjectFromSentence(kind, message) {
  const text = String(message || "");
  const name = "[A-Za-zÀ-ÖØ-öø-ÿ0-9'’][A-Za-zÀ-ÖØ-öø-ÿ0-9'’ .-]{1,39}";
  const patterns = {
    payment_received: [
      new RegExp(`every time\\s+(${name}?)\\s+pays me`, "i"),
      new RegExp(`when(?:ever)?\\s+(${name}?)\\s+pays me`, "i"),
      new RegExp(`(?:payment|transfer)\\s+(?:arrives\\s+)?from\\s+(${name}?)(?:\\s|,|\\.|$)`, "i"),
      new RegExp(`(${name}?)\\s+(?:sends|transfers|pays)\\s+me`, "i"),
    ],
    subscription_charge: [
      new RegExp(`when(?:ever)?\\s+(?:my\\s+)?(${name}?)\\s+(?:charges|renews|is charged)`, "i"),
      new RegExp(`before\\s+(?:my\\s+)?(${name}?)\\s+charges`, "i"),
      new RegExp(`(${name}?)\\s+charge day`, "i"),
    ],
    price_claim_window: [
      new RegExp(`when the price of\\s+(${name}?)\\s+(?:falls|drops)`, "i"),
      new RegExp(`the\\s+(${name}?)\\s+claim window`, "i"),
      new RegExp(`window (?:opens|closes) (?:on|for)\\s+(${name}?)(?:\\s|,|\\.|$)`, "i"),
    ],
    watch_result: [
      new RegExp(`when the watch on\\s+(${name}?)\\s+(?:finds|drops|reports|returns)`, "i"),
      new RegExp(`when\\s+(${name}?)\\s+drops below`, "i"),
      new RegExp(`watch(?:ing)?\\s+(${name}?)\\s+(?:drops|falls)`, "i"),
    ],
  };
  for (const pattern of patterns[kind] || []) {
    const match = pattern.exec(text);
    if (!match) continue;
    const subject = String(match[1] || "").trim().replace(/[.,;:]+$/, "");
    if (subject.length >= 2) return subject;
  }
  return null;
}

function sharePercentFromSentence(message) {
  const match = /(\d{1,3}(?:[.,]\d+)?)\s*%/.exec(String(message || ""));
  if (!match) return null;
  const value = Number.parseFloat(match[1].replace(",", "."));
  return Number.isFinite(value) && value > 0 && value <= 100 ? value : null;
}

function protectionsFromSentence(message) {
  const text = String(message || "").toLowerCase();
  const protect = [];
  if (/\breserve\b/.test(text)) protect.push("reserve");
  if (/\b(plan|budget|allocation)\b/.test(text)) protect.push("plan");
  if (/\b(goal|fund|trip|saving)\b/.test(text)) protect.push("goal");
  return protect;
}

function pausesFromSentence(message) {
  const text = String(message || "").toLowerCase();
  const pauses = [];
  if (/\bcap\b|\bup to\b/.test(text)) pauses.push("amount_above_cap");
  if (/\bshortfall\b|\bbreak the plan\b|\bover budget\b/.test(text)) pauses.push("plan_shortfall");
  if (/\bnot arrived\b|\bhasn'?t arrived\b|\bclears?\b|\bpending\b/.test(text)) pauses.push("income_not_arrived");
  if (/\bgoal\b|\bprotected\b/.test(text)) pauses.push("goal_protected");
  return pauses.length ? pauses : ["plan_shortfall"];
}

function actionFromSentence(message) {
  const text = String(message || "").toLowerCase();
  if (/reserve|put .*away|set .*aside/.test(text)) {
    return { verb: "engine.reserve.share", params: shareFromSentenceParams(message) };
  }
  if (/carve|tax|buffer|smooth/.test(text)) return { verb: "engine.income.smooth", params: {} };
  if (/zombie|unused|review.*(subscriptions|charges)|audit/.test(text)) {
    return { verb: "engine.subscriptions.review", params: {} };
  }
  if (/claim|price.?match/.test(text)) return { verb: "engine.price_claim.prepare", params: {} };
  if (/watch|watching/.test(text)) return { verb: "watch.create", params: {} };
  if (/research|find|compare|look for/.test(text)) return { verb: "task.create", params: {} };
  if (/send|transfer|pay/.test(text)) return { verb: "transfer.prepare", params: {} };
  if (/cancel/.test(text)) return { verb: "subscription.cancel", params: {} };
  return null;
}

function shareFromSentenceParams(message) {
  const share = sharePercentFromSentence(message);
  return share === null ? {} : { sharePercent: share };
}

/**
 * The deterministic reading, used when no Jev key is configured and as the
 * fallback when the typed read names nothing this contract can carry.
 * @returns {{ok:boolean, proposal?:object, detail?:string}}
 */
export function rulesFromSentence(message, { now = Date.now() } = {}) {
  const text = String(message || "");
  let kind = null;
  if (/pays me|paid me|payment (?:arrives|received)|gets paid/i.test(text)) kind = "payment_received";
  else if (/charges|renews|subscription/i.test(text)) kind = "subscription_charge";
  else if (/price (?:falls|drops)|price.?match|claim window/i.test(text)) kind = "price_claim_window";
  else if (/watch|watching|drops below/i.test(text)) kind = "watch_result";
  if (!kind) return { ok: false, detail: "No standing event this app can watch was named." };

  const action = actionFromSentence(text);
  if (!action) return { ok: false, detail: "No action this app can run was named." };

  const subject = subjectFromSentence(kind, text);
  if (!subject) {
    return { ok: false, detail: `A rule for ${kind} needs its ${TRIGGERS[kind].subjectLabel} named.` };
  }

  const wantsAutopilot = /without asking|automatically|on its own|autopilot|just do it/i.test(text);
  const proposal = {
    id: `rule_${Math.random().toString(36).slice(2, 12)}`,
    sentence: text.slice(0, 300),
    trigger: { kind, subject },
    action,
    protect: protectionsFromSentence(text),
    pause_when: pausesFromSentence(text),
    delegation: wantsAutopilot ? "autopilot" : "prepare",
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
    proposedAt: now,
  };
  // An autopilot the mandate cannot carry is downgraded by code, not upgraded
  // by confidence: everything runs as a normal proposal until a person edits it.
  const check = validateContract(proposal);
  const accepted = check.ok ? proposal : { ...proposal, delegation: "prepare" };
  return { ok: true, proposal: accepted, downgraded: !check.ok || undefined };
}

/**
 * Classify one sentence into a proposed contract. Jev chooses from the closed
 * sets; code builds, validates and never approves. The returned confidence is
 * for display only — the tests hold that it never changes a decision.
 */
export async function proposeRule(message, { fetchImpl = globalThis.fetch, signal, now = Date.now() } = {}) {
  const key = process.env.TYPESAFE_API_KEY;
  const text = String(message || "").trim().slice(0, 2000);
  if (!text) return { ok: false, detail: "Nothing to read.", latencyMs: 0 };

  if (!key) {
    const local = rulesFromSentence(text, { now });
    return {
      ok: local.ok,
      proposal: local.proposal,
      proposedBy: "rules",
      confidence: null,
      latencyMs: 0,
      detail: local.ok ? "Read by the deterministic rule reader." : local.detail,
    };
  }

  const started = Date.now();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  const onAbort = () => controller.abort();
  if (signal) {
    if (signal.aborted) controller.abort();
    else signal.addEventListener("abort", onAbort, { once: true });
  }

  let answers = null;
  let model = null;
  try {
    const response = await fetchImpl(ENDPOINT, {
      method: "POST",
      signal: controller.signal,
      headers: { "content-type": "application/json", authorization: `Bearer ${key}` },
      body: JSON.stringify({
        state: `The person's words: ${text}`,
        model: process.env.TYPESAFE_MODEL || "jev-1.13.0",
        questions: buildRuleQuestions(),
      }),
    });
    if (!response.ok) {
      return { ok: false, detail: `Jev answered HTTP ${response.status}.`, latencyMs: Date.now() - started };
    }
    const parsed = await response.json();
    answers = parsed?.answers || {};
    model = parsed?.model ?? null;
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

  const triggerKind = choice(answers, "trigger");
  const actionId = choice(answers, "action");
  const delegation = choice(answers, "delegation") ?? "prepare";
  const confidence = confidenceOf(answers, "trigger") ?? confidenceOf(answers, "action");

  if (!TRIGGERS[triggerKind]) {
    return { ok: false, detail: "The sentence did not name an event this app can watch.", latencyMs: Date.now() - started };
  }
  if (!automationAction(actionId)) {
    // Code refuses a sentence that Jev mapped to nothing real. A free-form
    // action is not a proposal; it is a refusal.
    return { ok: false, detail: "The sentence did not name an action this app can run.", latencyMs: Date.now() - started };
  }

  const subject = subjectFromSentence(triggerKind, text);
  if (!subject) {
    return {
      ok: false,
      detail: `A rule for ${triggerKind} needs its ${TRIGGERS[triggerKind].subjectLabel} named.`,
      latencyMs: Date.now() - started,
    };
  }

  const protectChoice = choice(answers, "protect");
  const protect = protectChoice && isProtection(protectChoice)
    ? [protectChoice]
    : protectionsFromSentence(text);
  const pauseChoice = choice(answers, "pause_when");
  const pauses = PAUSE_CONDITIONS.includes(pauseChoice)
    ? [pauseChoice]
    : pausesFromSentence(text);

  const action = { verb: actionId, params: {} };
  if (actionId === "engine.reserve.share") {
    const share = sharePercentFromSentence(text);
    if (share !== null) action.params = { sharePercent: share };
  }

  const proposal = {
    id: `rule_${Math.random().toString(36).slice(2, 12)}`,
    sentence: text.slice(0, 300),
    trigger: { kind: triggerKind, subject },
    action,
    protect,
    pause_when: pauses,
    delegation,
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
    proposedBy: "jev",
    confidence,
    proposedAt: now,
  };

  // Code validates the model's proposal. Anything the mandate cannot carry is
  // downgraded to the safest level — a confident sentence never lifts a limit.
  const check = validateContract(proposal);
  if (!check.ok) {
    proposal.delegation = "prepare";
  }
  return {
    ok: true,
    proposal,
    proposedBy: "jev",
    confidence,
    model,
    latencyMs: Date.now() - started,
    downgraded: delegation === "autopilot" && proposal.delegation !== "autopilot" ? true : undefined,
  };
}

/** JSON-safe view for /health-style introspection. */
export function ruleCatalogue() {
  return {
    triggers: Object.values(TRIGGERS).map((trigger) => ({ ...trigger })),
    delegations: DELEGATIONS.map((id) => ({ id, label: DELEGATION_INFO[id] })),
    protections: [...PROTECTIONS],
    pauseConditions: [...PAUSE_CONDITIONS],
    actions: AUTOMATION_ACTIONS.map((action) => ({
      id: action.id,
      class: action.class,
      label: action.label,
      existingVerb: VERB_BY_ID.has(action.id),
    })),
    verbs: catalogue().verbs.length,
  };
}
