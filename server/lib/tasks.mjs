/**
 * Durable asynchronous task service.
 *
 * A task is created the moment the app asks for work the conversational path
 * cannot do (research, comparison, reservation/purchase preparation). It is
 * persisted to disk, scoped to one brand and one conversation, cancelable, and
 * executed in the background by the Hermes runtime. The app polls
 * `GET /v1/tasks/:id?brand=…`; it never waits on the agent.
 *
 * Guarantees:
 *   · an unguessable id (`task_` + 128 bits of randomness);
 *   · brand+conversation scoping — a task is never readable across brands or
 *     threads;
 *   · a persisted state machine that survives a restart: a task found
 *     `running` at load is re-queued (bounded by attempts), not lost;
 *   · honest errors — a failed run is `failed` with its reason, never a
 *     dressed-up success;
 *   · sources are the agent's real retrieved URLs, filtered through the URL
 *     safety check; nothing is invented here.
 */

import fs from "node:fs/promises";
import crypto from "node:crypto";
import path from "node:path";
import { getCapability } from "./capabilities.mjs";
import { runTaskAgent } from "./agent-runtime.mjs";
import { writeArtifact, artifactDirFor, resolveArtifact } from "./artifacts.mjs";
import { shouldAsk } from "./jev-read.mjs";
import { readReplyRole, readContinuation, DIALOGUE_FLOOR } from "./jev-dialogue.mjs";
import { enrichOptions } from "./thumbnails.mjs";
import { readPresentation, chooseLayout, defaultLayout } from "./jev-present.mjs";
import {
  detectTaskKind,
  extractSlots,
  fillAnswerSlots,
  continuationOf,
  deriveTitle,
  looksLikeAccountCommand,
  looksLikeDefinitionQuestion,
  looksLikeMealRequest,
  looksLikeMoneyMovement,
  isCurrencyOnlyRequest,
  looksLikeOwnRecurringSpend,
  looksLikeIssuerOffers,
  detectCounterparty,
} from "./task-router.mjs";

export const TASK_STATUS = Object.freeze({
  QUEUED: "queued",
  RUNNING: "running",
  COMPLETED: "completed",
  FAILED: "failed",
  NEEDS_INPUT: "needs_input",
});

const ACTIVE_STATUSES = new Set([TASK_STATUS.QUEUED, TASK_STATUS.RUNNING, TASK_STATUS.NEEDS_INPUT]);
const MAX_ATTEMPTS = 3;
const HISTORY_LIMIT = 12;

function newTaskId() {
  return `task_${crypto.randomBytes(16).toString("hex")}`;
}

function boundHistory(history) {
  if (!Array.isArray(history)) return [];
  return history
    .filter((turn) => turn && typeof turn.content === "string" && turn.content.trim())
    .slice(-HISTORY_LIMIT)
    .map((turn) => ({
      role: turn.role === "assistant" || turn.role === "mira" ? "assistant" : "user",
      content: String(turn.content).slice(0, 2000),
    }));
}

function mergeSlots(existing, incoming) {
  const merged = { ...(existing || {}) };
  for (const [key, value] of Object.entries(incoming || {})) {
    if (value !== null && value !== undefined && value !== "") merged[key] = value;
  }
  return merged;
}

/** How long a standing check waits between runs. */
const CADENCE_MS = {
  hourly: 3_600_000,
  daily: 86_400_000,
  weekly: 7 * 86_400_000,
  monthly: 30 * 86_400_000,
};

function cadenceMillis(cadence) {
  return CADENCE_MS[String(cadence || "").toLowerCase()] || CADENCE_MS.daily;
}

/**
 * The state of a standing watch: what it last saw and when it looks again.
 *
 * Kept on the task itself so the card can show it, a restart keeps it, and a
 * check that failed is recorded as a failed check rather than a silent gap.
 */
export function applyWatchCheck(task, { ok, result = {}, detail = "" } = {}) {
  const cadence = task.watch?.cadence || task.slots?.cadence || "daily";
  const now = Date.now();
  const summary = ok
    ? String(result.summary || "").slice(0, 300)
    : String(detail || "The check could not be completed.").slice(0, 300);
  const price = ok
    ? (Array.isArray(result.options) && result.options.find((option) => option?.priceNote)?.priceNote) || null
    : null;
  const entry = { at: now, ok: Boolean(ok), summary, price };
  const checks = [entry, ...(Array.isArray(task.watch?.checks) ? task.watch.checks : [])].slice(0, 10);
  task.watch = {
    active: task.watch ? task.watch.active !== false : true,
    cadence: String(cadence).slice(0, 20),
    checks,
    checkCount: (task.watch?.checkCount || 0) + 1,
    lastCheckAt: now,
    nextCheckAt: now + cadenceMillis(cadence),
    lastSummary: summary,
    lastPrice: price,
    lastOk: Boolean(ok),
  };
  return task.watch;
}

/**
 * A.4.3: the shapes `defaultLayout` already answers with no ambiguity — a
 * watch is a watch, a travel plan with a destination or origin is an
 * itinerary, an invest result with a symbol or size is an order, a delivered
 * meal is picks. Only a genuinely mixed shape (research/shopping/auction
 * picks, a restaurant without a mode) is worth a typed read.
 */
export function layoutIsUnambiguous({ kind, slots = {} } = {}) {
  switch (kind) {
    case "watch":
      return true;
    case "travel":
      return Boolean(slots.destination || slots.origin);
    case "invest":
      return Boolean(slots.symbol || slots.quantity || slots.amount);
    case "restaurant":
      return slots.mode === "delivery";
    default:
      return false;
  }
}

function missingRequired(capability, slots, message = "") {
  const required = [...(capability.requiredSlots || [])];
  // A meal to buy is asked about before it is researched: delivery, or eating
  // there. The question exists only when the person is actually buying a meal
  // and has not already said which way it is coming. It comes first because the
  // answer changes the search itself.
  if (capability.mealFirst && looksLikeMealRequest(message) && !slots?.mode) {
    required.unshift("mode");
  }
  return required.filter((slot) => {
    const value = slots?.[slot];
    return value === null || value === undefined || value === "";
  });
}

/**
 * Provider-side noise that a second run usually clears.
 *
 * The agent runtime talks to a model provider, and that provider occasionally
 * answers 5xx or produces nothing at all — "The model failed to generate a
 * response". That is not the task failing; it is the weather. One or two more
 * runs, a moment apart, and the person never learns it happened.
 */
const TRANSIENT_AGENT_FAILURE =
  /(server_error|failed to generate a response|returned no message|no usable result|timed out|timeout|ECONNRESET|socket hang up|\b429\b|\b50\d\b)/i;

const MAX_TRANSIENT_RETRIES = 2;

function isTransientAgentFailure(detail) {
  return TRANSIENT_AGENT_FAILURE.test(String(detail || ""));
}

/** The default executor: one bounded, evidence-recording agent run. */
async function defaultRunner(task, { onChild, onProgress, signal } = {}) {
  // Every channel the service offers is passed through: dropping one here — as
  // a narrower destructure did — silently disables live progress for the app.
  return runTaskAgent(task, { onChild, onProgress, signal });
}

export class TaskService {
  /**
   * @param {object} options
   * @param {string} options.dir            Directory for tasks.json + artifacts/.
   * @param {Function} [options.runner]     Executor; defaults to the Hermes runtime.
   * @param {number} [options.concurrency]  Parallel task runs (default 1).
   * @param {boolean} [options.autoStart]   Run the worker (default true).
   */
  constructor({ dir, runner, concurrency = 1, autoStart = true } = {}) {
    this.dir = dir;
    this.path = path.join(dir, "tasks.json");
    this.artifactDir = artifactDirFor(dir);
    this.runner = runner || defaultRunner;
    this.concurrency = Math.max(1, concurrency);
    this.autoStart = autoStart;
    this.tasks = new Map();
    this.queue = [];
    this.running = 0;
    this.children = new Map();
    this.controllers = new Map();
    this.pumping = false;
    this.loaded = false;
    this.writeChain = Promise.resolve();
  }

  async load() {
    try {
      const raw = await fs.readFile(this.path, "utf8");
      const parsed = JSON.parse(raw);
      for (const task of parsed?.tasks ?? []) {
        if (!task || typeof task.id !== "string") continue;
        if (task.status === TASK_STATUS.RUNNING) {
          // A restart found work in flight: make it recoverable rather than
          // silently stranded. It re-queues and is bounded by attempts.
          task.status = TASK_STATUS.QUEUED;
          task.steps = (task.steps || []).map((step) =>
            step.status === "running" ? { ...step, status: "pending" } : step
          );
          if ((task.attempts || 0) >= MAX_ATTEMPTS) {
            task.status = TASK_STATUS.FAILED;
            task.error = "Recovered after restart with no attempts left.";
          }
        }
        this.tasks.set(task.id, task);
      }
    } catch (err) {
      if (err.code !== "ENOENT") throw err;
    }
    this.loaded = true;
    if (this.autoStart) {
      for (const task of this.tasks.values()) {
        if (task.status === TASK_STATUS.QUEUED) this.queue.push(task.id);
      }
      this.#pump();
    }
    return this;
  }

  #save() {
    const payload = { version: 1, savedAt: Date.now(), tasks: [...this.tasks.values()] };
    const body = JSON.stringify(payload, null, 2);
    const tmp = `${this.path}.${process.pid}.${Date.now()}.tmp`;
    this.writeChain = this.writeChain.then(async () => {
      await fs.mkdir(this.dir, { recursive: true });
      await fs.writeFile(tmp, body, "utf8");
      await fs.rename(tmp, this.path);
    });
    return this.writeChain.catch(() => {});
  }

  async flush() {
    await this.writeChain.catch(() => {});
  }

  #touch(task) {
    task.updatedAt = Date.now();
    void this.#save();
  }

  get(id) {
    return this.tasks.get(id) || null;
  }

  /** Public task view, scoped to the exact brand. Null when not owned. */
  view(id, brand) {
    const task = this.tasks.get(id);
    if (!task || task.brand !== brand) return null;
    return this.toPublicView(task);
  }

  toPublicView(task) {
    return {
      id: task.id,
      brand: task.brand,
      kind: task.kind,
      status: task.status,
      title: task.title || "",
      summary: task.summary || "",
      // The details the task was given (route, dates, party size, product).
      // A card that shows a document — an itinerary, a reservation — needs
      // them, and they are already the agent's brief.
      slots: task.slots && typeof task.slots === "object" ? task.slots : {},
      // Which document the result is, decided when the run finished.
      layout: task.layout || defaultLayout({ kind: task.kind, slots: task.slots }),
      options: task.options || [],
      nextStep: task.nextStep || null,
      caveat: task.caveat || null,
      question: task.question ?? null,
      sources: Array.isArray(task.sources) ? task.sources : [],
      artifacts: Array.isArray(task.artifacts) ? task.artifacts.map((a) => ({
        title: a.title,
        url: a.url,
        mimeType: a.mimeType,
      })) : [],
      steps: Array.isArray(task.steps) ? task.steps : [],
      error: task.error ?? null,
      watch: task.watch
        ? {
            active: task.watch.active !== false,
            cadence: task.watch.cadence || "daily",
            lastCheckAt: task.watch.lastCheckAt ?? null,
            nextCheckAt: task.watch.nextCheckAt ?? null,
            lastSummary: task.watch.lastSummary || "",
            lastPrice: task.watch.lastPrice ?? null,
            lastOk: task.watch.lastOk !== false,
            checkCount: task.watch.checkCount || 0,
          }
        : null,
    };
  }

  /**
   * The most recent task in this conversation, finished or not. A follow-up
   * belongs to the subject the conversation has been about.
   */
  recentFor(brand, conversationId) {
    if (!conversationId) return null;
    let found = null;
    for (const task of this.tasks.values()) {
      if (task.brand !== brand || task.conversationId !== conversationId) continue;
      if (!found || (task.updatedAt || 0) > (found.updatedAt || 0)) found = task;
    }
    return found;
  }

  activeFor(brand, conversationId) {
    if (!conversationId) return null;
    let found = null;
    for (const task of this.tasks.values()) {
      if (task.brand !== brand || task.conversationId !== conversationId) continue;
      if (!ACTIVE_STATUSES.has(task.status)) continue;
      if (!found || (task.updatedAt || 0) > (found.updatedAt || 0)) found = task;
    }
    return found;
  }

  /**
   * The dialogue context a single batched read needs, computed before
   * `handleMessage` runs: the open question, the missing details and the
   * previous subject. Context only — it makes no decision and reads nothing.
   */
  dialogueContextFor(brand, conversationId, message = "", { pending = null } = {}) {
    const key = typeof conversationId === "string" && conversationId.trim() ? conversationId.trim() : null;
    if (!key) return null;
    const text = String(message || "");
    const accountCommand = looksLikeAccountCommand(text, {
      hasCounterparty: Boolean(detectCounterparty(text, brand)),
      hasPendingTransfer: pending?.kind === "transfer",
    });
    if (accountCommand) return null;
    const active = this.activeFor(brand, key);
    const previous = this.recentFor(brand, key);
    const context = {};
    if (active && active.status === TASK_STATUS.NEEDS_INPUT) {
      context.activeTitle = active.title || "";
      context.question = active.question || "";
      context.missing = Array.isArray(active.missing) ? active.missing : [];
    }
    if (previous) {
      context.previousTitle = previous.title || "";
      context.previousKind = previous.kind || "";
    }
    return Object.keys(context).length ? context : null;
  }

  /**
   * Route one inbound message. Returns `{ task, created }` when a task was
   * created or continued, or null when the message belongs to the
   * conversational path.
   */
  async handleMessage({ brand, conversationId, message, history, pending, understood = null, place = null, batch = null } = {}) {
    const text = String(message || "");
    const key = typeof conversationId === "string" && conversationId.trim() ? conversationId.trim() : null;
    const active = key ? this.activeFor(brand, key) : null;
    const counterparty = detectCounterparty(text, brand);
    const accountCommand = looksLikeAccountCommand(text, {
      hasCounterparty: Boolean(counterparty),
      hasPendingTransfer: pending?.kind === "transfer",
    });
    let newKind = detectTaskKind(text);
    const historyBounded = boundHistory([...(Array.isArray(history) ? history : []), { role: "user", content: text }]);

    // What the message is to the conversation is not always plain: a reply can
    // start a different request, and a refinement can arrive with no connector
    // ("somewhere quieter with outdoor seating"). Both are typed reads against
    // the same state — and they decide nothing on their own: every branch below
    // keeps its deterministic behaviour when a read fails or is not confident.
    //
    // A.4.2 gates, applied BEFORE any read: the deterministic fill already
    // answers the open question when it names the slot, a different kind is a
    // different request, and a message longer than eight words can never be
    // the refinement the caller would use. Those reads are never paid for.
    const previous = this.recentFor(brand, key);
    const filledAnswer =
      active && active.status === TASK_STATUS.NEEDS_INPUT && (!newKind || newKind === active.kind)
        ? fillAnswerSlots(active.kind, active.missing, text)
        : {};
    const firstMissing = Array.isArray(active?.missing) && active.missing.length ? active.missing[0] : null;
    const roleGate = Boolean(
      active &&
        active.status === TASK_STATUS.NEEDS_INPUT &&
        !accountCommand &&
        (!newKind || newKind === active.kind) &&
        !(firstMissing && filledAnswer[firstMissing])
    );
    // The app answers its own money paths — transfers, currency swaps, the
    // person's subscriptions, the issuer's offers — so a read must never let
    // one be refined into a research task instead.
    const moneyMovement = looksLikeMoneyMovement(text);
    const ownMoneySubject = looksLikeOwnRecurringSpend(text) || looksLikeIssuerOffers(text);
    const wordCount = text.trim().split(/\s+/).filter(Boolean).length;
    const continuationGate = Boolean(
      previous &&
        !continuationOf(text) &&
        !accountCommand &&
        !moneyMovement &&
        !ownMoneySubject &&
        !isCurrencyOnlyRequest(text) &&
        wordCount <= 8
    );

    // The batched call already carries these decisions when it was given the
    // dialogue context; otherwise — and whenever the batch failed — the
    // individual reads run exactly as before.
    const batchDialogue = batch && batch.ok && batch.dialogue && batch.dialogue.ok ? batch.dialogue : null;
    const replyRoleRead = roleGate
      ? batchDialogue
        ? batchDialogue
        : readReplyRole(text, {
            question: active.question || "",
            activeTitle: active.title || "",
            missing: Array.isArray(active.missing) ? active.missing : [],
          })
      : null;
    const continuationRead = continuationGate
      ? batchDialogue
        ? {
            ok: true,
            continues: batchDialogue.continues,
            confidence: batchDialogue.confidence,
            latencyMs: batchDialogue.latencyMs,
          }
        : readContinuation(text, {
            previousTitle: previous.title || "",
            previousKind: previous.kind || "",
          })
      : null;
    const [replyRead, continuationReadResult] = await Promise.all([replyRoleRead, continuationRead]);
    if (replyRoleRead || continuationRead) {
      const role = replyRead?.ok ? replyRead.role ?? "unclear" : "none";
      const roleConfidence = typeof replyRead?.roleConfidence === "number" ? replyRead.roleConfidence.toFixed(2) : "—";
      const continues = typeof continuationReadResult?.continues === "number" ? continuationReadResult.continues.toFixed(2) : "—";
      const latencyMs = Math.max(replyRead?.latencyMs || 0, continuationReadResult?.latencyMs || 0);
      console.log(`  jev dialogue: role=${role} (${roleConfidence}) continues=${continues} (${latencyMs}ms)`);
    }

    if (active && active.status === TASK_STATUS.NEEDS_INPUT && !accountCommand && (!newKind || newKind === active.kind)) {
      // A confident read that this is a different request outranks the fact
      // that a question is open: it falls through and is routed as if no task
      // were waiting. Unless the message itself carries the missing detail —
      // then it is the answer, whatever shape it has.
      const suppliesDetail = typeof replyRead?.suppliesDetail === "number" ? replyRead.suppliesDetail : null;
      const startsNewSubject =
        replyRead?.ok === true &&
        replyRead.role === "new_subject" &&
        typeof replyRead.roleConfidence === "number" &&
        replyRead.roleConfidence >= DIALOGUE_FLOOR &&
        !(suppliesDetail !== null && suppliesDetail >= DIALOGUE_FLOOR);
      if (!startsNewSubject) {
        // Both: the message may carry details in the usual shapes, and it is also
        // the answer to whatever the task last asked for.
        const answered = fillAnswerSlots(active.kind, active.missing, text);
        const merged = mergeSlots(
          mergeSlots(active.slots, extractSlots(active.kind, text)), answered);
        active.history = historyBounded;
        // The title stays about the subject, not about the answer: "Flights to São
        // Paulo", never "Travel: I am flying from São Paulo". The original message
        // is kept for that; the answer is only history.
        const task = await this.#applyState(active, merged, understood);
        return { task, created: false };
      }
    }

    // "And bars?" in a conversation that just researched restaurants means:
    // carry on, with bars. Same place, same day, same person — a fresh run on
    // the same subject, with the refinement stated, is what a person expects.
    // A short follow-up with no connector is still a refinement when Jev reads
    // it as one — and never through a money path the app owns.
    const continuation = continuationOf(text);
    const readRefinement =
      !continuation &&
      previous &&
      !accountCommand &&
      !moneyMovement &&
      !ownMoneySubject &&
      !isCurrencyOnlyRequest(text) &&
      continuationReadResult?.ok === true &&
      typeof continuationReadResult.continues === "number" &&
      continuationReadResult.continues >= DIALOGUE_FLOOR &&
      text.trim().split(/\s+/).filter(Boolean).length <= 8
        ? text.trim().slice(0, 120)
        : null;
    const refinement = continuation || readRefinement;
    if (refinement && !accountCommand) {
      // "and bars?" continues the subject. "and a flight to Lisbon" does not —
      // it names a different capability, and it becomes its own task.
      const differentKind = Boolean(newKind && previous && newKind !== previous.kind);
      if (previous && !differentKind) {
        const grown = mergeSlots(previous.slots, { refinement });
        previous.history = historyBounded;
        previous.originalMessage = `${previous.originalMessage} — ${text}`.slice(0, 400);
        const task = await this.#applyState(previous, grown, understood);
        return { task, created: false, continued: true };
      }
    }

    // A live price is a research question, not a trade and not advice: Mira goes
    // and reads it, cites the page, and says when the page did not state one.

    // A live price is a research question, not a trade and not advice: Mira goes
    // and reads it, cites the page, and says when the page did not state one.
    const marketPrice =
      !accountCommand &&
      understood &&
      (understood.wantsMarketPrice ?? 0) >= 0.5 &&
      (understood.wantsOwnConversion ?? 0) < 0.5;
    const kind = newKind || (marketPrice ? "research" : null);
    // "What is an auction?" names a capability but asks a question. It belongs
    // to the conversational path, never to a task with questions back.
    if (accountCommand || looksLikeDefinitionQuestion(text) || !kind) return null;

    const slots = extractSlots(kind, text);
    if (kind === "research" && marketPrice && !slots.topic) slots.topic = text.slice(0, 200);
    // No place named in the message: search where the person lives, from the
    // address they saved. A shop in another country is not an answer.
    if (!slots.location && place && (kind === "shopping" || kind === "restaurant" || kind === "auction")) {
      slots.location = String(place).slice(0, 120);
    }
    newKind = kind;
    const capability = getCapability(newKind);
    const task = {
      id: newTaskId(),
      brand,
      conversationId: key,
      kind: newKind,
      title: deriveTitle(newKind, slots, text),
      status: TASK_STATUS.QUEUED,
      summary: "",
      question: null,
      slots,
      missing: [],
      history: historyBounded,
      originalMessage: text,
      sources: [],
      artifacts: [],
      steps: (capability?.steps || []).map((label) => ({ label, status: "pending" })),
      error: null,
      attempts: 0,
      cancelRequested: false,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      startedAt: null,
      completedAt: null,
    };
    this.tasks.set(task.id, task);
    await this.#applyState(task, slots);
    return { task, created: true };
  }

  /**
   * Fold a mid-run update into the task. Deliberately narrow: a live line, and
   * the places found so far. The final result replaces both.
   */
  #applyProgress(task, progress) {
    if (!progress || task.status !== TASK_STATUS.RUNNING) return;
    if (typeof progress.summary === "string" && progress.summary.trim()) {
      task.summary = progress.summary.trim().slice(0, 300);
    }
    if (Array.isArray(progress.sources) && progress.sources.length) {
      const seen = new Set((task.sources || []).map((source) => source.url));
      for (const source of progress.sources) {
        const url = String(source?.url || "").trim();
        if (!url || seen.has(url)) continue;
        seen.add(url);
        task.sources = [...(task.sources || []), {
          title: String(source.title || url).slice(0, 160),
          url,
        }].slice(0, 8);
      }
    }
    this.#touch(task);
  }

  async #applyState(task, slots, understood = null) {
    const capability = getCapability(task.kind);
    task.slots = mergeSlots(task.slots, slots);
    task.title = deriveTitle(task.kind, task.slots, task.originalMessage) || task.title;
    task.missing = capability ? missingRequired(capability, task.slots, task.originalMessage || "") : [];

    // Jev has read the message. A detail it is confident is *already named* is
    // not missing, however badly the pattern matcher did — "Hey. I want to buy a
    // Mac Mini" must never be answered with "which brand or model?".
    if (understood && task.missing.length) {
      task.missing = task.missing.filter(
        (slot) => shouldAsk(understood, { kind: task.kind, slot, missing: [slot] }));
      task.understood = {
        namesTheThing: understood.namesTheThing ?? null,
        namesBrandOrModel: understood.namesBrandOrModel ?? null,
        statesBudget: understood.statesBudget ?? null,
        wants: understood.wants ?? null,
        triesToInstruct: understood.triesToInstruct ?? null,
      };
    }
    task.steps = (capability?.steps || []).map((label, index) => ({
      label,
      status: task.missing.length ? (index === 0 ? "done" : "pending") : index === 0 ? "done" : index === 1 ? "queued" : "pending",
    }));

    if (task.missing.length) {
      task.status = TASK_STATUS.NEEDS_INPUT;
      task.question = capability?.question
        ? capability.question(capability.id, task.missing, {
            message: task.originalMessage || "",
            slots: task.slots,
          })
        : null;
      task.summary = this.#knownSummary(task);
      this.#touch(task);
      return task;
    }

    task.status = TASK_STATUS.QUEUED;
    task.question = null;
    task.summary = "Researching live sources now.";
    task.error = null;
    this.#touch(task);
    if (this.autoStart) this.enqueue(task.id);
    return task;
  }

  #knownSummary(task) {
    const bits = [];
    const slots = task.slots || {};
    if (slots.destination) bits.push(`destination ${slots.destination}`);
    if (slots.origin) bits.push(`from ${slots.origin}`);
    if (slots.dates) bits.push(`dates ${slots.dates}`);
    if (slots.location) bits.push(`area ${slots.location}`);
    if (slots.product) bits.push(`product ${slots.product}`);
    if (slots.topic) bits.push(`topic ${slots.topic}`);
    const scope = bits.length ? ` I have ${bits.join(", ")}.` : "";
    return `I need one more detail before I can search.${scope}`;
  }

  enqueue(id) {
    const task = this.tasks.get(id);
    if (!task || task.status !== TASK_STATUS.QUEUED) return;
    if (!this.queue.includes(id)) this.queue.push(id);
    this.#pump();
  }

  #pump() {
    if (!this.autoStart || this.pumping) return;
    this.pumping = true;
    const next = () => {
      while (this.running < this.concurrency && this.queue.length) {
        const id = this.queue.shift();
        const task = this.tasks.get(id);
        if (!task || task.status !== TASK_STATUS.QUEUED) continue;
        this.running += 1;
        this.#runTask(id).finally(() => {
          this.running -= 1;
          next();
        });
      }
      if (this.running === 0 && this.queue.length === 0) this.pumping = false;
    };
    next();
  }

  async #runTask(id) {
    const task = this.tasks.get(id);
    if (!task) return;
    if (task.status !== TASK_STATUS.QUEUED) return;
    if (task.cancelRequested) {
      this.#fail(task, "Cancelled by user.");
      return;
    }

    task.status = TASK_STATUS.RUNNING;
    task.attempts = (task.attempts || 0) + 1;
    task.startedAt = Date.now();
    task.steps = (task.steps || []).map((step, index) => ({
      ...step,
      status: index === 0 ? "done" : index === 1 ? "running" : "pending",
    }));
    task.workspace = path.join(this.dir, "workspace", task.id);
    await fs.mkdir(task.workspace, { recursive: true }).catch(() => {});
    this.#touch(task);

    // A per-job controller so a cancel aborts the model call and every tool
    // call. Without it, a cancelled task would keep talking to the model and
    // the network in the background.
    const controller = new AbortController();
    this.controllers.set(id, controller);

    let outcome;
    try {
      outcome = await this.runner(task, {
        onChild: (child) => this.children.set(id, child),
        // What the agent is doing, while it does it. The app polls this, so a
        // minute of work reads as a minute of work rather than a blank card.
        onProgress: (progress) => this.#applyProgress(task, progress),
        signal: controller.signal,
      });
    } catch (err) {
      outcome = { ok: false, detail: String(err?.message || err) };
    }
    this.children.delete(id);
    this.controllers.delete(id);

    // If cancel() already made this task terminal, the late runner result must
    // not overwrite it.
    if (task.status !== TASK_STATUS.RUNNING) return;

    // Provenance is stored with the task so health and the evidence file can
    // report which tools were genuinely exercised, not which were configured.
    task.evidence = outcome?.evidence ?? null;

    if (task.cancelRequested) {
      this.#fail(task, "Cancelled by user.");
      return;
    }
    if (!outcome || !outcome.ok) {
      const detail = outcome?.detail || "The task agent did not return a usable result.";
      // A provider flake gets another run rather than becoming the person's
      // problem. The retries are bounded and spaced, and the card says so.
      if (
        isTransientAgentFailure(detail) &&
        (task.transientRetries || 0) < MAX_TRANSIENT_RETRIES &&
        !task.cancelRequested
      ) {
        task.transientRetries = (task.transientRetries || 0) + 1;
        task.status = TASK_STATUS.QUEUED;
        task.summary = "The provider stumbled — trying that again.";
        task.error = null;
        task.steps = (task.steps || []).map((step, index) => ({
          ...step,
          status: index === 0 ? "done" : "pending",
        }));
        this.#touch(task);
        const timer = setTimeout(() => this.enqueue(task.id), 1500 * task.transientRetries);
        if (typeof timer.unref === "function") timer.unref();
        return;
      }
      const tries = (task.transientRetries || 0) + 1;
      this.#fail(task, tries > 1 ? `${detail} It was tried ${tries} times.` : detail);
      // A watch that failed to check is still a watch: the failed check is
      // recorded and the next one is scheduled, rather than the watch dying
      // with the run.
      if (task.kind === "watch") {
        applyWatchCheck(task, { ok: false, detail: task.error || "The check could not be completed." });
        this.#touch(task);
      }
      return;
    }

    const result = outcome.result || {};
    if (result.question && (!result.options || result.options.length === 0)) {
      task.status = TASK_STATUS.NEEDS_INPUT;
      task.question = String(result.question).slice(0, 300);
      task.summary = String(result.summary || "").slice(0, 2000);
      task.error = null;
      task.steps = (task.steps || []).map((step) => ({ ...step, status: step.status === "running" ? "pending" : step.status }));
      this.#touch(task);
      return;
    }

    const capability = getCapability(task.kind);
    let summary = String(result.summary || "").slice(0, 2000);
    if (!summary) summary = "Mira finished the research.";
    // The caveat travels on its own field. Appended to the answer it read like a
    // footnote about pages, which is not what someone deciding wants to read.
    task.caveat = result.caveat ? String(result.caveat).slice(0, 400) : null;
    task.nextStep = result.next_step ? String(result.next_step).slice(0, 400) : null;
    task.options = Array.isArray(result.options)
      ? result.options.slice(0, 6).map((option) => ({
          name: String(option.name || "").slice(0, 160),
          url: option.url ? String(option.url).slice(0, 500) : null,
          why: option.why ? String(option.why).slice(0, 300) : "",
          priceNote: option.priceNote ? String(option.priceNote).slice(0, 60) : null,
          // A picture of the thing, so a list of names reads as a list of things.
          // The agent may have seen one; when it did not, the server reads the
          // page's own sharing image below.
          image: option.image ? String(option.image).slice(0, 500) : null,
        }))
      : [];
    // Thumbnails are read from the pages the picks point at — deterministically,
    // in parallel and inside a ~2 s bound — and, where a page refuses bots (most
    // marketplaces), found by an image search for the pick itself. A page that
    // refuses and a search that finds nothing simply leaves the pick as text;
    // the result is never delayed beyond a few seconds and never invented.
    // Tests switch this off: a unit test must not touch the network.
    if (process.env.MIRA_THUMBNAILS !== "off") {
      task.options = await enrichOptions(task.options, {
        context:
          task.slots?.location || task.slots?.product || task.slots?.subject || task.slots?.topic || task.title || "",
      }).catch(() => task.options);
    }
    // Blocked pages stay in the data. They are never appended to the answer: a
    // count of pages that failed is a report about the machinery, and the reader
    // wants to choose a restaurant.
    const blockedCount = Array.isArray(result.blocked) ? result.blocked.length : 0;
    task.blocked = blockedCount;
    // Belt and braces: a model may still narrate the count. Take the sentence
    // out; the caveat field is where a real limitation belongs.
    summary = summary
      .replace(/\s*\d+\s+page\(s\)\s+could not be read\.?/gi, "")
      .replace(/\s*\d+\s+pages?\s+could not be (?:read|opened|reached)\.?/gi, "")
      .replace(/\s{2,}/g, " ")
      .trim();
    task.summary = summary;
    task.sources = Array.isArray(result.sources) ? result.sources : [];
    task.error = null;

    if (capability?.artifact) {
      try {
        const built = capability.artifact({ slots: task.slots, result });
        const written = await writeArtifact(this.artifactDir, task.id, built);
        task.artifacts = [...(Array.isArray(task.artifacts) ? task.artifacts : []), written];
      } catch (err) {
        // An artifact failure does not erase a completed research result.
        task.artifacts = Array.isArray(task.artifacts) ? task.artifacts : [];
      }
    }

    task.steps = (task.steps || []).map((step) => ({ ...step, status: "done" }));
    task.status = TASK_STATUS.COMPLETED;
    task.completedAt = Date.now();
    // A standing watch keeps its schedule and its last result on the task, so
    // the card can say what it last saw and when it looks again.
    if (task.kind === "watch") applyWatchCheck(task, { ok: true, result });

    // Which document this result is: a typed read when one is available, the
    // shape of the result itself when it is not. Never a guess — a read outside
    // the catalogue the app can render is ignored.
    //
    // A.4.3 gate: when the shape already names the document (a watch, a travel
    // plan with a destination, a prepared order, a delivered meal) the typed
    // read is not paid for. Only a genuinely mixed shape asks.
    const layoutContext = { kind: task.kind, slots: task.slots };
    if (layoutIsUnambiguous(layoutContext)) {
      task.layout = defaultLayout(layoutContext);
    } else {
      const read = await readPresentation({
        kind: task.kind,
        title: task.title,
        summary: task.summary,
        options: task.options,
        slots: task.slots,
      }).catch(() => null);
      task.layout = chooseLayout(read, layoutContext);
    }
    this.#touch(task);
  }

  #fail(task, detail) {
    task.status = TASK_STATUS.FAILED;
    task.error = String(detail || "The task failed.").slice(0, 500);
    task.steps = (task.steps || []).map((step) =>
      step.status === "running" ? { ...step, status: "failed" } : step
    );
    task.completedAt = Date.now();
    this.#touch(task);
  }

  /** Cancel a task and return its current public view (or null if not owned). */
  async cancel(id, brand) {
    const task = this.tasks.get(id);
    if (!task || task.brand !== brand) return null;
    if (ACTIVE_STATUSES.has(task.status)) {
      task.cancelRequested = true;
      // Abort the model/tool calls of a running job...
      const controller = this.controllers.get(id);
      if (controller) controller.abort();
      // ...and kill any child process (Hermes/browser) it owns.
      const child = this.children.get(id);
      if (child && typeof child.kill === "function") {
        try {
          child.kill("SIGKILL");
        } catch {
          /* already gone */
        }
      }
      // Make it terminal immediately; the late runner result is discarded by
      // the status guard in #runTask.
      this.#fail(task, "Cancelled by user.");
    }
    return this.toPublicView(task);
  }

  /**
   * Run a failed task again, on the same id.
   *
   * Only `failed` is retryable. A task that is still active already has its
   * run ahead of it, and a completed result must never be run a second time —
   * a retry is a fresh attempt at the same task, never a second task. The
   * error and the transient-retry budget are cleared, the steps reset, and
   * the task goes back on the queue; any other status is returned unchanged.
   */
  async retry(id, brand) {
    const task = this.tasks.get(id);
    if (!task || task.brand !== brand) return null;
    if (task.status !== TASK_STATUS.FAILED) return this.toPublicView(task);
    task.error = null;
    task.transientRetries = 0;
    // A manual retry is a fresh bounded run: the restart-recovery budget
    // starts over rather than immediately re-failing a recovered task.
    task.attempts = 0;
    task.cancelRequested = false;
    task.status = TASK_STATUS.QUEUED;
    task.steps = (task.steps || []).map((step, index) => ({
      ...step,
      status: index === 0 ? "done" : "pending",
    }));
    this.#touch(task);
    this.enqueue(task.id);
    return this.toPublicView(task);
  }

  /** Watches whose next check has come due. Called on a timer. */
  async tickWatches(now = Date.now()) {
    const due = [...this.tasks.values()].filter(
      (task) =>
        task.kind === "watch" &&
        task.watch?.active !== false &&
        typeof task.watch?.nextCheckAt === "number" &&
        task.watch.nextCheckAt <= now &&
        !ACTIVE_STATUSES.has(task.status)
    );
    for (const task of due) {
      // A standing check is not a retry: the attempt budget must not end it.
      task.attempts = 0;
      task.error = null;
      task.cancelRequested = false;
      task.status = TASK_STATUS.QUEUED;
      task.steps = (task.steps || []).map((step, index) => ({
        ...step,
        status: index === 0 ? "done" : "pending",
      }));
      this.#touch(task);
      this.enqueue(task.id);
    }
    return due.length;
  }

  /** Run a watch's next check now, rather than waiting for the schedule. */
  async checkWatch(id, brand = null) {
    const task = this.tasks.get(id);
    if (!task || task.kind !== "watch") return null;
    if (brand && task.brand !== brand) return null;
    if (ACTIVE_STATUSES.has(task.status)) return this.toPublicView(task);
    task.watch = {
      ...(task.watch || { cadence: task.slots?.cadence || "daily", active: true }),
      active: true,
      nextCheckAt: Date.now(),
    };
    task.attempts = 0;
    task.error = null;
    task.status = TASK_STATUS.QUEUED;
    this.#touch(task);
    this.enqueue(task.id);
    return this.toPublicView(task);
  }

  /** Stop a standing watch. The last check stays; nothing more runs. */
  async stopWatch(id, brand = null) {
    const task = this.tasks.get(id);
    if (!task || task.kind !== "watch") return null;
    if (brand && task.brand !== brand) return null;
    task.watch = {
      ...(task.watch || { cadence: task.slots?.cadence || "daily" }),
      active: false,
      nextCheckAt: null,
    };
    this.#touch(task);
    return this.toPublicView(task);
  }

  /** Resolve an artifact file path, scoped to the owning brand. */
  artifactPath(id, brand, name) {
    const task = this.tasks.get(id);
    if (!task || task.brand !== brand) return null;
    const resolved = resolveArtifact(this.artifactDir, id, name);
    if (!resolved) return null;
    const known = (task.artifacts || []).some((artifact) => artifact.name === name);
    if (!known) return null;
    return resolved;
  }

  status() {
    const counts = {};
    const toolsExercised = {};
    let provenUrls = 0;
    for (const task of this.tasks.values()) {
      counts[task.status] = (counts[task.status] || 0) + 1;
      const summary = task.evidence;
      if (summary?.byTool) {
        for (const [tool, tally] of Object.entries(summary.byTool)) {
          toolsExercised[tool] = toolsExercised[tool] || { ok: 0, failed: 0 };
          toolsExercised[tool].ok += tally.ok;
          toolsExercised[tool].failed += tally.failed;
        }
      }
      provenUrls += Array.isArray(summary?.provenUrls) ? summary.provenUrls.length : 0;
    }
    return {
      storage: "durable-atomic",
      concurrency: this.concurrency,
      queueDepth: this.queue.length,
      running: this.running,
      counts,
      provenUrls,
      toolsExercised,
    };
  }
}
