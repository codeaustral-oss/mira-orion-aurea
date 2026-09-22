/**
 * Bounded execution verbs.
 *
 * WHY: the competitor scan (docs/nubank-revolut-scan.md, §2.1 and §4.1) found
 * that agentic help enters as analysis plus *bounded* execution, never as
 * unbounded money movement. Nubank's Pix-by-AI still asks for the PIN on every
 * transfer; Revolut's AIR asks for biometrics before anything sensitive. The
 * chat is a command surface over deterministic controls.
 *
 * This module is that surface written down: one small, typed catalogue of what
 * an agent may do, and one policy function that says whether a verb may run
 * right now. It is deliberately a *typing layer*, not a router — the existing
 * routes still do the work, and this file only names their class.
 *
 * Three classes, and they must not feel the same:
 *
 *   observe  — read-only. A balance, a report, a task result. Nothing moves and
 *              nothing is composed; the person is never asked to confirm.
 *   prepare  — composes an action or a document. A transfer proposal, a budget
 *              change, a research task, a requirements checklist. Still nothing
 *              moves: the preparation itself is the answer, and the person
 *              confirms only when they want it to happen.
 *   commit   — moves money or commits an order. A transfer leaves, a swap
 *              posts, a card is frozen, a merchant is blocked, a subscription
 *              is cancelled. A commit always requires the person's word, read
 *              through the one consent model this repository already has
 *              (`jev-consent.mjs`). There is deliberately no second model here.
 *
 * Every verb is `{ id, class, requires, route }`: what it needs to act, and the
 * existing path that performs it. `verbFor(action)` maps the proxy's typed
 * actions (`ACTION_TYPES` in `orchestrate.mjs`) onto verbs. The mapping is keyed
 * by the action-type strings, so this module never imports the orchestrator and
 * the dependency runs one way only; `server/test/verbs.test.mjs` keeps the two
 * in step, so a new typed action cannot silently arrive without a verb class.
 *
 * `catalogue()` is the JSON-safe view a health endpoint can report: classes,
 * verbs, their requirements and their routes. Never a secret, never live state.
 */

import { decideConsent } from "./jev-consent.mjs";

export const VERB_CLASSES = Object.freeze(["observe", "prepare", "commit"]);

/** The class definitions, for catalogue() and for any prose that renders them. */
const CLASS_INFO = Object.freeze([
  { id: "observe", label: "Read-only. Nothing moves, nothing is composed." },
  { id: "prepare", label: "Composes an action or a document. Nothing moves." },
  {
    id: "commit",
    label: "Moves money or commits an order. Always requires the person's word.",
  },
]);

/**
 * The catalogue.
 *
 * It is small on purpose: every entry names a path this build actually has, and
 * a verb without a route does not belong in it. `requires` is the data the
 * route needs to act; a commit always lists `consent` because the class rule
 * says so (the test asserts that invariant).
 */
const VERB_LIST = Object.freeze([
  // -- observe: read-only, never a question ---------------------------------
  Object.freeze({ id: "balance.read", class: "observe", requires: [], route: "orchestrate.show_balance" }),
  Object.freeze({ id: "budget.read", class: "observe", requires: [], route: "orchestrate.show_budget" }),
  Object.freeze({ id: "card.read", class: "observe", requires: [], route: "orchestrate.open_card_controls" }),
  Object.freeze({ id: "receive.read", class: "observe", requires: [], route: "orchestrate.open_receive" }),
  Object.freeze({ id: "question.answer", class: "observe", requires: [], route: "orchestrate.reply" }),
  Object.freeze({ id: "task.read", class: "observe", requires: ["taskId"], route: "tasks.view" }),
  // A desk report answers a question about fees, offers or claims. It composes
  // a document, but it composes no action and changes nothing, so it reads.
  Object.freeze({ id: "desk.report", class: "observe", requires: ["kind"], route: "desk.report" }),

  // -- prepare: composes, nothing moves -------------------------------------
  Object.freeze({
    id: "transfer.prepare",
    class: "prepare",
    requires: ["to", "asset", "amountMinor"],
    route: "orchestrate.propose_transfer",
  }),
  Object.freeze({
    id: "budget.prepare",
    class: "prepare",
    requires: ["asset", "amountMinor"],
    route: "orchestrate.propose_budget_update",
  }),
  Object.freeze({ id: "task.create", class: "prepare", requires: ["request"], route: "tasks.agent_task" }),
  Object.freeze({ id: "watch.create", class: "prepare", requires: ["subject"], route: "tasks.watch" }),
  Object.freeze({
    id: "requirements.prepare",
    class: "prepare",
    requires: ["topic"],
    route: "orchestrate.requirements_flow",
  }),

  // -- commit: the person's word, exactly once ------------------------------
  Object.freeze({
    id: "transfer.commit",
    class: "commit",
    requires: ["consent", "to", "asset", "amountMinor"],
    route: "relay.transfer",
  }),
  Object.freeze({
    id: "fx.swap",
    class: "commit",
    requires: ["consent", "pair", "amountMinor"],
    route: "fx.swap",
  }),
  Object.freeze({
    id: "card.freeze",
    class: "commit",
    requires: ["consent", "cardId"],
    route: "card.freeze",
  }),
  Object.freeze({
    id: "card.block",
    class: "commit",
    requires: ["consent", "merchant"],
    route: "card.block",
  }),
  Object.freeze({
    id: "subscription.cancel",
    class: "commit",
    requires: ["consent", "subscriptionId"],
    route: "subscription.cancel",
  }),
]);

const VERBS = new Map(VERB_LIST.map((verb) => [verb.id, verb]));

/**
 * The proxy's typed actions, mapped onto the catalogue.
 *
 * Keyed by the action-type strings in `ACTION_TYPES` (orchestrate.mjs). The
 * conversational path may only ever produce observe and prepare verbs: a chat
 * turn proposes, it never commits. The commit verbs above are reached through
 * the app's own controls, with consent read by `mayRun`.
 */
const ACTION_VERBS = Object.freeze({
  ask_transfer_details: "transfer.prepare",
  propose_transfer: "transfer.prepare",
  show_budget: "budget.read",
  propose_budget_update: "budget.prepare",
  show_balance: "balance.read",
  open_card_controls: "card.read",
  open_receive: "receive.read",
  requirements_flow: "requirements.prepare",
  agent_task: "task.create",
  reply: "question.answer",
});

function describe(value) {
  if (typeof value === "string") return value;
  if (value && typeof value === "object" && typeof value.type === "string") return value.type;
  if (value && typeof value === "object" && typeof value.id === "string") return value.id;
  return String(value);
}

function resolveVerb(value) {
  if (typeof value === "string") return VERBS.get(value) ?? null;
  if (value && typeof value === "object" && typeof value.id === "string") {
    return VERBS.get(value.id) ?? null;
  }
  return null;
}

/**
 * A violation of this catalogue is a programming error, not a user error.
 *
 * In development it throws immediately, so it is caught by the test run and by
 * the first person who touches the path. In production it must not take the
 * proxy down: it is logged, and the caller refuses to act on the violation.
 */
function noteOrThrow(message) {
  if (process.env.NODE_ENV === "production") {
    console.error(`verb catalogue violation: ${message}`);
    return false;
  }
  throw new Error(`verb catalogue violation: ${message}`);
}

/** The typed action → verb mapping. Null when the action is not in the catalogue. */
export function verbFor(action) {
  const type = typeof action === "string" ? action : action?.type;
  const id = typeof type === "string" ? ACTION_VERBS[type] : null;
  return id ? VERBS.get(id) ?? null : null;
}

/**
 * May this verb run now?
 *
 * observe and prepare always may: they cannot move anything, and a confirmation
 * on a read is noise. A commit may only when the person's word is on the record
 * — read by the existing consent policy (`decideConsent`), never by a model
 * here. The result is a decision, not a bare boolean, so the caller can show
 * the right card:
 *
 *   { ok: true,  decision: "proceed" } — run it
 *   { ok: false, decision: "confirm" } — one final confirmation is needed
 *   { ok: false, decision: "ask" }     — a detail is genuinely missing
 *   { ok: false, decision: "unknown" } — the verb is not in the catalogue
 *
 * `consent` is the raw typed read from `readConsent` (the same shape the
 * app sends to /v1/consent). A failed or absent read is never an authorisation:
 * `decideConsent` turns it into "confirm", and the app asks.
 */
export function mayRun(verbOrId, { consent = null, known = {} } = {}) {
  const verb = resolveVerb(verbOrId);
  if (!verb) {
    noteOrThrow(`mayRun: '${describe(verbOrId)}' is not in the verb catalogue`);
    return { ok: false, decision: "unknown", reason: "not in the verb catalogue", detail: null };
  }
  if (verb.class !== "commit") {
    return {
      ok: true,
      decision: "proceed",
      reason: `class '${verb.class}' needs no confirmation`,
    };
  }
  const decision = decideConsent(consent, { known, action: verb.id });
  if (decision.decision === "proceed") {
    return { ok: true, decision: "proceed", reason: decision.reason };
  }
  return {
    ok: false,
    decision: decision.decision,
    reason: decision.reason,
    detail: decision.detail ?? null,
  };
}

/**
 * The wiring guard: assert that a composed action belongs to the expected verb
 * class *before* anything is composed around it. This is a typing check on the
 * caller's own output, not a new gate:
 *
 *   assertVerbClass(action, "prepare", { where: "buildAction.propose_transfer" })
 *
 * A wrong-class action (or one with no verb at all) is a programming error.
 * Development throws; production logs and returns false, and the caller refuses
 * to compose. Returns true when the class matches.
 */
export function assertVerbClass(action, expectedClass, { where = "action" } = {}) {
  const verb = verbFor(action);
  if (!verb) {
    return noteOrThrow(`${where}: no verb is mapped for action '${describe(action)}'`);
  }
  if (verb.class !== expectedClass) {
    return noteOrThrow(
      `${where}: action '${describe(action)}' maps to '${verb.id}' (class '${verb.class}'), not '${expectedClass}'`
    );
  }
  return true;
}

/** A JSON-safe view of the catalogue, for /health-style introspection. */
export function catalogue() {
  return {
    classes: CLASS_INFO.map((entry) => ({ ...entry })),
    verbs: VERB_LIST.map((verb) => ({
      id: verb.id,
      class: verb.class,
      requires: [...verb.requires],
      route: verb.route,
    })),
  };
}
