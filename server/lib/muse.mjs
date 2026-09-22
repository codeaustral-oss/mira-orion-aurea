import { currentKey, keyCount, keysConfigured, noteKeyWorked, orderedKeys } from "./api-keys.mjs";
/**
 * Mira agent model — direct server-side OpenCode Go Responses API client.
 *
 * Why this exists: previously the proxy shelled out to the `opencode` CLI to
 * reach the model. That put a process boundary, a CLI install and a working
 * directory between the app and the model. This talks to the documented HTTP
 * endpoint directly, which is faster, testable, and keeps the credential in
 * exactly one process.
 *
 *   POST https://opencode.ai/zen/go/v1/responses
 *   Authorization: Bearer OPENCODE_GO_API_KEY
 *   x-opencode-session: <session id>
 *
 * The API key is read from the environment, never returned, never logged, and
 * never echoed to the app. A failure is reported as a failure; there is no
 * canned answer anywhere in this file.
 */

export const MUSE_ENDPOINT =
  process.env.MIRA_MUSE_ENDPOINT || "https://opencode.ai/zen/go/v1/responses";
export const MUSE_MODEL = process.env.MIRA_AGENT_MODEL || "muse-spark-1.3-contributor";
/** Used once when the preferred model cannot answer at all — a flake should not
 * cost the person their reply. Read per call, so an override set after import
 * (the tests) is honoured. */
export const MUSE_FALLBACK_MODEL =
  process.env.MIRA_AGENT_FALLBACK_MODEL || "deepseek-v4.1-flash";

/** The model to try first when the caller does not name one. */
function agentModel() {
  return process.env.MIRA_AGENT_MODEL || MUSE_MODEL;
}

/** The second model to try. Never the same string as the first. */
function fallbackModel() {
  return process.env.MIRA_AGENT_FALLBACK_MODEL || MUSE_FALLBACK_MODEL;
}
export const MUSE_REASONING = process.env.MIRA_AGENT_REASONING || "xhigh";
export const MUSE_TIMEOUT_MS = Number(process.env.MIRA_AGENT_TIMEOUT_MS || 120_000);

/** Cap on any conversation we send upstream. */
export const MAX_INPUT_CHARS = 24_000;

function apiKey() {
  return currentKey();
}

export function museConfigured() {
  return Boolean(apiKey());
}

/**
 * Build the Responses API `input` array.
 *
 * `history` is a compact transcript the app already has; it is sent as real
 * user/assistant turns so the model resolves pronouns without the app having to
 * pretend each message is standalone.
 */
export function buildInput({ input, history }) {
  const turns = [];
  if (Array.isArray(history)) {
    for (const turn of history) {
      if (!turn || typeof turn.content !== "string" || !turn.content.trim()) continue;
      const role = turn.role === "assistant" || turn.role === "mira" ? "assistant" : "user";
      turns.push({ role, content: turn.content.slice(0, 4000) });
    }
  }
  const finalText = typeof input === "string" ? input : "";
  turns.push({ role: "user", content: finalText.slice(0, 8000) });
  return turns;
}

/** Pull the assistant text out of a Responses payload. */
export function extractText(payload) {
  if (!payload || !Array.isArray(payload.output)) return "";
  let text = "";
  for (const item of payload.output) {
    if (item?.type !== "message") continue;
    for (const part of item.content ?? []) {
      if (part?.type === "output_text" && typeof part.text === "string") {
        text += part.text;
      }
    }
  }
  return text;
}

function reasoningTokens(payload) {
  const details = payload?.usage?.output_tokens_details;
  return typeof details?.reasoning_tokens === "number" ? details.reasoning_tokens : 0;
}

/**
 * One model call.
 *
 * @param {object} options
 * @param {string} options.instructions  System prompt. Never contains the key.
 * @param {string} options.input         The user's turn.
 * @param {Array<{role:string, content:string}>} [options.history]
 * @param {string} [options.sessionId]   Sent as `x-opencode-session`.
 * @param {number} [options.timeoutMs]
 * @param {boolean} [options.json]       Ask for JSON output formatting.
 * @returns {Promise<object>} `{ ok: true, text, model, sessionId, latencyMs, usage }`
 *          or `{ ok: false, detail, latencyMs, status? }`.
 */
export async function askMuse({
  instructions,
  input,
  history,
  sessionId,
  timeoutMs = MUSE_TIMEOUT_MS,
  json = false,
  reasoning = MUSE_REASONING,
  model,
} = {}) {
  const started = Date.now();
  const key = apiKey();
  const preferred = model || agentModel();

  if (!key) {
    return {
      ok: false,
      detail:
        "No OpenCode Go credential (OPENCODE_GO_API_KEY) configured on the server. The assistant cannot reach a model.",
      latencyMs: Date.now() - started,
      model: preferred,
      configured: false,
    };
  }

  const body = {
    model: preferred,
    instructions: String(instructions || "").slice(0, MAX_INPUT_CHARS),
    input: buildInput({ input, history }),
    reasoning: { effort: reasoning || MUSE_REASONING },
  };
  if (json) body.text = { format: { type: "json_object" } };

  const deadline = started + Math.max(1000, timeoutMs);

  /** One attempt on one model, with its own controller. A non-2xx, an empty
   *  answer or a transport error is a failure — never an exception: a network
   *  blip on the preferred model must not skip the fallback that exists for
   *  exactly that case. */
  const attempt = async (modelName) => {
    const attemptBody = { ...body, model: modelName || body.model };
    const credentials = orderedKeys();
    const remaining = deadline - Date.now();
    if (remaining <= 0) return { ok: false, status: 0, upstream: "", detail: "no time left in the reply budget" };
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), remaining);

    try {
      let res = null;
      for (let index = 0; index < credentials.length; index += 1) {
        const credential = credentials[index];
        try {
          res = await fetch(MUSE_ENDPOINT, {
            method: "POST",
            headers: {
              Authorization: `Bearer ${credential.key}`,
              "Content-Type": "application/json",
              "x-opencode-session": sessionId || `mira-${Date.now()}`,
            },
            body: JSON.stringify(attemptBody),
            signal: controller.signal,
          });
        } catch (err) {
          // Aborted or unreachable: not a reason to stop before the fallback.
          return {
            ok: false,
            status: 0,
            upstream: "",
            detail: err?.name === "AbortError" ? "timed out" : `unreachable: ${err?.message || err}`,
          };
        }
        if (res.ok) {
          noteKeyWorked(credential.index);
          break;
        }
        if (res.status < 500 && res.status !== 429) break;
        // Drain the failed attempt so the socket can be reused.
        await res.text().catch(() => "");
      }
      if (!res || !res.ok) {
        const upstream = await res.text().catch(() => "");
        return { ok: false, status: res?.status ?? 0, upstream: upstream.slice(0, 200) };
      }
      const payload = await res.json().catch(() => null);
      const text = extractText(payload).trim();
      if (!text) {
        return { ok: false, status: payload?.status === "incomplete" ? 499 : 200, empty: true, payload };
      }
      return { ok: true, text, payload };
    } finally {
      clearTimeout(timer);
    }
  };

  try {
    // The preferred model first, then one distinct model after it — never the
    // same name twice. The reply path's preferred model is allowed to be the
    // process-wide fallback (`MIRA_AGENT_REPLY_MODEL`), and that used to leave
    // no second attempt at all: the person was told the model was unreachable
    // while the agent model was sitting right there. A reply matters more than
    // which model wrote it, and the answer still says which one did.
    const chain = [];
    for (const candidate of [preferred, fallbackModel(), agentModel()]) {
      if (candidate && !chain.includes(candidate)) chain.push(candidate);
    }

    let result = null;
    let answeredBy = null;
    for (let index = 0; index < chain.length; index += 1) {
      const candidate = chain[index];
      result = await attempt(candidate);
      if (result.ok) {
        answeredBy = candidate;
        break;
      }
      if (chain[index + 1]) {
        console.log(
          `  model fallback: ${candidate} failed (${result.status || result.detail || "no status"}), trying ${chain[index + 1]}`
        );
      }
    }
    const usedFallback = answeredBy !== null && answeredBy !== preferred;

    if (!result?.ok) {
      return {
        ok: false,
        status: result?.status,
        detail: result?.empty
          ? "The model returned no text."
          : `The model endpoint answered ${result?.status || "nothing"}. No answer was generated.`,
        upstreamDetail: result?.upstream,
        latencyMs: Date.now() - started,
        model: preferred,
        configured: true,
      };
    }

    return {
      ok: true,
      text: result.text,
      model: result.payload?.model || answeredBy || preferred,
      fellBack: usedFallback,
      sessionId: sessionId || null,
      latencyMs: Date.now() - started,
      usage: result.payload?.usage ?? null,
      reasoningTokens: reasoningTokens(result.payload),
      configured: true,
    };
  } catch (err) {
    const aborted = err && err.name === "AbortError";
    return {
      ok: false,
      detail: aborted
        ? `The model did not answer within ${Math.round(timeoutMs / 1000)}s.`
        : "The model endpoint is unreachable.",
      latencyMs: Date.now() - started,
      model: preferred,
      configured: true,
    };
  }
}
