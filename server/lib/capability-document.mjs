/**
 * What this build can actually do — one document, assembled from the code.
 *
 * WHY this file exists: "what can move money here, and what is simulated?" is a
 * fair question with an embarrassing failure mode — the answer was a transfer
 * prompt. The honest answer is a list of the app's real capabilities, and a
 * hand-written list goes stale the first time a verb changes. So the document
 * is assembled from the catalogues that already drive behaviour:
 *
 *   · `verbs.mjs`           — every typed verb, by class (observe / prepare /
 *                             commit). The three middle sections are exactly
 *                             that catalogue, filtered by class; a verb cannot
 *                             exist without appearing here.
 *   · `capabilities.mjs`    — the engines that run as research tasks, with
 *                             their real connector state (none connected).
 *   · `corridor-support.mjs` and `rate-guard.mjs` — the refusals, with the
 *                             lines the app actually says.
 *
 * The same five sections are mirrored in the app (`CapabilityDocument.swift`),
 * so a question asked with the proxy down gets the same answer.
 */

import { catalogue } from "./verbs.mjs";
import { capabilityStates } from "./capabilities.mjs";
import { quotedCurrenciesPhrase, quotedPairsPhrase, unquotedCodes } from "./corridor-support.mjs";
import { RATE_BOOKING_REFUSAL } from "./rate-guard.mjs";
import { REFUSAL_LINE } from "./injection-guard.mjs";

export const CAPABILITY_DOCUMENT_VERSION = 1;

/** The refusal line for investment, tax and legal advice. One wording. */
export const ADVICE_REFUSAL =
  "That is investment advice and I do not give it — nobody should, without knowing your whole position. " +
  "I can show you what you hold, what a fee costs you, and the public facts about anything you name.";

/** The line used when a model-written reply may not be trusted. */
export const UNGROUNDED_REFUSAL = "Let me not put a number on that without checking your account first.";

/** The five sections, in the order a person would ask about them. */
export const CAPABILITY_SECTIONS = Object.freeze([
  Object.freeze({ id: "instant", label: "Answered here and now, from your own records" }),
  Object.freeze({ id: "prepares", label: "Prepared, with nothing moved" }),
  Object.freeze({ id: "approval", label: "Moves only after one approval" }),
  Object.freeze({ id: "research", label: "Runs as research, on the Mac runtime, preparation only" }),
  Object.freeze({ id: "refuses", label: "Refused, deterministically" }),
]);

/**
 * A human name per verb. Keyed by the verb ids in `verbs.mjs`; the test asserts
 * this table covers every id in the catalogue, so a new verb cannot be added
 * without either naming it or failing.
 */
const VERB_LABELS = Object.freeze({
  "balance.read": "your balances",
  "budget.read": "this week's budget and the reserve",
  "card.read": "the card and its controls",
  "receive.read": "your receiving details",
  "question.answer": "a short explanation or a follow-up",
  "task.read": "the state of a running task",
  "desk.report": "a desk report — fees, offers, claims",
  "transfer.prepare": "a transfer, ready for your confirmation",
  "budget.prepare": "a change to the weekly budget",
  "task.create": "a research or comparison task",
  "watch.create": "a standing watch on something you name",
  "requirements.prepare": "the requirements checklist when no provider is connected",
  "transfer.commit": "sending money to a saved recipient",
  "fx.swap": "a currency swap at a rate we quoted",
  "card.freeze": "freezing or unfreezing the card",
  "card.block": "blocking a merchant on the card",
  "subscription.cancel": "cancelling a subscription",
});

/** The refusals, with the words the app actually uses. */
function refusals() {
  return [
    {
      id: "advice",
      label: "investment, tax and legal advice",
      line: ADVICE_REFUSAL,
    },
    {
      id: "rate_not_quoted",
      label: "a rate we did not quote",
      line: RATE_BOOKING_REFUSAL,
    },
    {
      id: "unpriced_corridor",
      label: `a corridor this build does not price (${unquotedCodes().slice(0, 6).join(", ")}, …)`,
      line: `Any pair among ${quotedCurrenciesPhrase()}. I will not invent a rate outside them.`,
    },
    {
      id: "rules_override",
      label: "instructions that try to change my rules, limits or approvals",
      line: REFUSAL_LINE,
    },
    {
      id: "invented_figure",
      label: "an invented figure in a model-written line",
      line: UNGROUNDED_REFUSAL,
    },
  ];
}

/**
 * The document, built from the catalogues. Nothing here is transcribed by hand
 * except the labels, which the tests hold to the catalogue's own ids.
 */
export function capabilityDocument() {
  const verbs = catalogue().verbs;
  const byClass = (verbClass) => verbs.filter((verb) => verb.class === verbClass);
  const item = (verb) => ({
    id: verb.id,
    label: VERB_LABELS[verb.id] ?? verb.id,
    detail: verb.route,
    requires: [...verb.requires],
  });

  const engines = capabilityStates();

  return {
    version: CAPABILITY_DOCUMENT_VERSION,
    sections: [
      {
        id: "instant",
        label: CAPABILITY_SECTIONS[0].label,
        items: byClass("observe").map(item),
      },
      {
        id: "prepares",
        label: CAPABILITY_SECTIONS[1].label,
        items: byClass("prepare").map(item),
      },
      {
        id: "approval",
        label: CAPABILITY_SECTIONS[2].label,
        items: byClass("commit").map(item),
      },
      {
        id: "research",
        label: CAPABILITY_SECTIONS[3].label,
        items: engines.map((engine) => ({
          id: `task.${engine.id}`,
          label: engine.label,
          detail: `research and preparation only; connector ${engine.connector.status}`,
        })),
      },
      {
        id: "refuses",
        label: CAPABILITY_SECTIONS[4].label,
        items: refusals(),
      },
    ],
    corridors: {
      quoted: quotedPairsPhrase(),
      currencies: quotedCurrenciesPhrase(),
      unquotedExamples: unquotedCodes(),
    },
    financialMode: "SIMULATED",
  };
}

/** The document's items for one section, or an empty list. */
export function sectionItems(document, id) {
  return document.sections.find((section) => section.id === id)?.items ?? [];
}

/**
 * A deterministic read for the obvious shapes of "tell me about this build":
 * what it can do, what moves money, what needs approval, what is simulated,
 * what it refuses. The typed question in the batch catches paraphrases; this
 * narrow shape answers the plain phrasings even when the provider is down.
 */
const ABOUT_THE_BUILD =
  /\b(?:what can (?:you|this|the app|this build|the product|it|mira)|what (?:does|do) (?:this|you|the app|mira|the build|it)(?:\s+\w+){0,2}\s+(?:do|offer|support|handle)|what (?:can't|can’t|cannot|don't|do not|doesn't|does not) (?:you|this|the app|mira|it|this build)|what (?:actually )?moves? money|move money (?:in|here|in this build)|what(?:'s| is) simulated|what needs (?:my|your|one|an?) approval|what do you do|capabilit(?:y|ies)|what are you (?:able|allowed) to do|how does (?:mira|this|the app) work|what does the user see)\b/i;

export function asksAboutThisBuild(text) {
  return ABOUT_THE_BUILD.test(String(text || ""));
}

/**
 * The one-paragraph answer to "what can this build do?". It is prose over the
 * document, never a second list: the items it names are the document's own.
 */
export function renderCapabilityAnswer(document = capabilityDocument()) {
  const names = (id) =>
    sectionItems(document, id)
      .map((entry) => entry.label)
      .join(", ");
  const research = sectionItems(document, "research").length;
  return [
    `This build is simulated money, and it is honest about the line. Instantly, from your own records: ${names("instant")}.`,
    `Prepared, with nothing moved: ${names("prepares")}.`,
    `One approval, then it moves: ${names("approval")}.`,
    `${research} engines run as research on the Mac runtime, and every one of them is preparation only — no vendor is connected.`,
    `I refuse ${sectionItems(document, "refuses")
      .map((entry) => entry.label)
      .join(", ")}.`,
  ].join(" ");
}
