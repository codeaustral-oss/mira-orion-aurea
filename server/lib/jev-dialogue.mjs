/**
 * What is this message to the conversation?
 *
 * A specialist asks one question at a time — where the trip starts, which
 * dates, which product — and the person answers. Most of the time the reply is
 * plainly the answer. But the same words can start a different request, and a
 * refinement of the subject can arrive with no connector at all ("somewhere
 * quieter with outdoor seating"). The deterministic shapes in `task-router.mjs`
 * catch the obvious cases; the rest is a reading.
 *
 * Jev answers typed *decisions*, not text:
 *
 *   · is this the answer to the open question?       (choice)
 *   · does the message carry the missing detail?     (noul — does it)
 *   · is this a refinement of the subject before it? (noul — does it)
 *
 * The reads decide nothing. The caller keeps every deterministic fallback: a
 * failed read, or a confidence below the floor, leaves the old behaviour
 * exactly as it was. Nothing here invents a detail or a subject.
 */

const ENDPOINT = "https://api.typesafe.ai/v1/systemone";
const TIMEOUT_MS = 6000;

/** Below this, a dialogue read is not trusted and changes nothing. */
export const DIALOGUE_FLOOR = 0.6;

export function dialogueConfigured() {
  return Boolean(process.env.TYPESAFE_API_KEY);
}

/**
 * One POST to System One with the same envelope the other readers use: a 6s
 * hard timeout, the key only in the header, and every failure an `ok:false`.
 * Nothing private is logged, and an unreadable body is a failure, not a guess.
 */
async function systemOne({ state, questions, fetchImpl, signal } = {}) {
  const key = process.env.TYPESAFE_API_KEY;
  if (!key) return { ok: false, detail: "No TYPESAFE_API_KEY configured.", latencyMs: 0 };

  const started = Date.now();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  const onAbort = () => controller.abort();
  if (signal) {
    if (signal.aborted) controller.abort();
    else signal.addEventListener("abort", onAbort, { once: true });
  }

  try {
    const response = await fetchImpl(ENDPOINT, {
      method: "POST",
      signal: controller.signal,
      headers: { "content-type": "application/json", authorization: `Bearer ${key}` },
      body: JSON.stringify({
        state,
        model: process.env.TYPESAFE_MODEL || "jev-1.13.0",
        questions,
      }),
    });
    if (!response.ok) {
      return { ok: false, detail: `Jev answered HTTP ${response.status}.`, latencyMs: Date.now() - started };
    }
    const parsed = await response.json();
    return { ok: true, latencyMs: Date.now() - started, answers: parsed?.answers || {} };
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
}

/**
 * What is the person's message to the question the task last asked?
 *
 * @returns {Promise<{ok:boolean, role?:string, roleConfidence?:number,
 *                    suppliesDetail?:number, detail?:string, latencyMs:number}>}
 */
export async function readReplyRole(
  message,
  { question = "", activeTitle = "", missing = [], fetchImpl = globalThis.fetch, signal } = {}
) {
  const text = String(message || "").trim().slice(0, 2000);
  if (!text) return { ok: false, detail: "Nothing to read.", latencyMs: 0 };

  const missingList = Array.isArray(missing) ? missing.filter(Boolean).join(", ") : "";
  const read = await systemOne({
    state: [
      activeTitle ? `The task in progress: ${activeTitle}.` : "The task in progress: (untitled).",
      `The question the specialist is waiting on: ${String(question || "").trim() || "(no question text was recorded)"}`,
      missingList ? `Still missing: ${missingList}.` : "Still missing: nothing recorded.",
      `The person's message: ${text}`,
    ].join("\n"),
    questions: {
      role: {
        type: "choice",
        instructions: "What is this message to the open question?",
        criteria: {
          answer: "This message supplies the detail the question asked for",
          new_subject: "It starts a different request",
          unclear: "Neither clearly: a greeting, an acknowledgement, or something unrelated",
        },
      },
      supplies_detail: {
        type: "noul",
        instructions: "Does the message itself contain the missing detail the question asked for?",
      },
    },
    fetchImpl,
    signal,
  });
  if (!read.ok) return read;

  const answers = read.answers;
  return {
    ok: true,
    latencyMs: read.latencyMs,
    role: answers?.role?.choice ?? null,
    roleConfidence: typeof answers?.role?.confidence === "number" ? answers.role.confidence : null,
    suppliesDetail: typeof answers?.supplies_detail?.noul === "number" ? answers.supplies_detail.noul : null,
  };
}

/**
 * Does the message refine the subject already in the conversation, or start
 * something new? One typed question; the caller keeps the word-count and
 * money guard-rails around the answer.
 *
 * @returns {Promise<{ok:boolean, continues?:number, confidence?:number,
 *                    detail?:string, latencyMs:number}>}
 */
export async function readContinuation(
  message,
  { previousTitle = "", previousKind = "", fetchImpl = globalThis.fetch, signal } = {}
) {
  const text = String(message || "").trim().slice(0, 2000);
  if (!text) return { ok: false, detail: "Nothing to read.", latencyMs: 0 };

  const read = await systemOne({
    state: [
      `The previous subject: ${String(previousTitle || "").trim() || "(untitled)"}${previousKind ? ` (${previousKind})` : ""}`,
      `The person's message: ${text}`,
    ].join("\n"),
    questions: {
      continues: {
        type: "noul",
        instructions: "Is this a follow-up refining the previous subject rather than a new request?",
      },
    },
    fetchImpl,
    signal,
  });
  if (!read.ok) return read;

  const answers = read.answers;
  return {
    ok: true,
    latencyMs: read.latencyMs,
    continues: typeof answers?.continues?.noul === "number" ? answers.continues.noul : null,
    confidence: typeof answers?.continues?.confidence === "number" ? answers.continues.confidence : null,
  };
}
