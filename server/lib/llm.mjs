/**
 * Minimal OpenCode Go chat-completions client for the task agent.
 *
 * This is the one place the task runtime talks to a model. The key stays in the
 * server process; the request carries the `x-opencode-session` header the
 * upstream relay requires (without it the provider answers HTTP 400
 * `MissingSessionID`).
 *
 * A transport or provider error is returned as `{ ok:false, detail }`. Transient
 * failures (network, timeout, HTTP 5xx / 429) are retried a bounded number of
 * times; a client error is returned as-is. There is no retry-into-a-fabricated
 * result and no synthetic output.
 */

import { currentKey, keyCount, keysConfigured, noteKeyRefused, noteKeyWorked, orderedKeys } from "./api-keys.mjs";

const DEFAULT_BASE_URL = "https://opencode.ai/zen/go/v1";
const SESSION_HEADER = process.env.MIRA_TASK_SESSION || "mira-tasks-runtime";

export const LLM_BASE_URL = process.env.MIRA_TASK_BASE_URL || DEFAULT_BASE_URL;
export const LLM_MODEL = process.env.MIRA_TASK_MODEL || "deepseek-v4.1-flash";
export const LLM_REASONING = process.env.MIRA_TASK_REASONING || "high";

export function llmConfigured() {
  return keysConfigured();
}

/** Muse exposes tools through Responses, while DeepSeek uses Chat Completions. */
export function responsesTaskBody({ model, messages = [], tools, toolChoice, reasoning, json, maxTokens }) {
  const input = [];
  const instructions = [];
  for (const message of messages) {
    if (message.role === "system" || message.role === "developer") {
      instructions.push(String(message.content || ""));
    } else if (message.role === "tool") {
      input.push({ type: "function_call_output", call_id: message.tool_call_id, output: String(message.content || "") });
    } else {
      if (message.content) input.push({ role: message.role, content: message.content });
      for (const call of message.tool_calls || []) {
        input.push({ type: "function_call", call_id: call.id, name: call.function.name, arguments: call.function.arguments });
      }
    }
  }
  const body = { model, instructions: instructions.join("\n\n"), input };
  if (tools?.length) {
    body.tools = tools.map(tool => ({ type: "function", ...tool.function }));
    body.tool_choice = toolChoice || "auto";
  }
  if (reasoning && reasoning !== "none") body.reasoning = { effort: reasoning };
  if (json) body.text = { format: { type: "json_object" } };
  if (Number.isInteger(maxTokens) && maxTokens > 0) body.max_output_tokens = maxTokens;
  return body;
}

export function responsesTaskMessage(payload) {
  if (!Array.isArray(payload?.output) || payload.status === "incomplete") return null;
  const text = [];
  const calls = [];
  for (const item of payload.output) {
    if (item.type === "message") {
      for (const part of item.content || []) if (part.type === "output_text") text.push(part.text);
    } else if (item.type === "function_call") {
      calls.push({ id: item.call_id, type: "function", function: { name: item.name, arguments: item.arguments } });
    }
  }
  if (!text.length && !calls.length) return null;
  return { role: "assistant", content: text.join("\n") || null, ...(calls.length ? { tool_calls: calls } : {}) };
}

/**
 * @returns {Promise<{ok:boolean, message?:object, finishReason?:string, usage?:object, status?:number, detail?:string}>}
 */
export async function callModel(
  {
    messages,
    tools,
    toolChoice = "auto",
    timeoutMs = 120_000,
    model = LLM_MODEL,
    reasoning = LLM_REASONING,
    /// Ask the provider for a JSON object rather than prose. The task agent's
    /// final answer is parsed, so letting the model ramble around it is how a
    /// finished run became "no structured result".
    json = false,
    /// Room for the answer. A reasoning model can spend a small default budget
    /// on its own thinking and return an empty message, which is indistinguishable
    /// from a refusal — and was how finished runs became "no structured result".
    maxTokens = null,
    fetchImpl = globalThis.fetch,
    signal,
  } = {}
) {
  if (!keysConfigured()) {
    return { ok: false, detail: "No OpenCode Go credential in the server environment." };
  }

  let body = { model, messages };
  if (Array.isArray(tools) && tools.length) {
    body.tools = tools;
    body.tool_choice = toolChoice;
  }
  if (reasoning && reasoning !== "none") body.reasoning_effort = reasoning;
  if (json) body.response_format = { type: "json_object" };
  if (Number.isInteger(maxTokens) && maxTokens > 0) body.max_tokens = maxTokens;

  const usesResponses = /^muse-/i.test(model);
  if (usesResponses) body = responsesTaskBody({ model, messages, tools, toolChoice, reasoning, json, maxTokens });
  const url = `${LLM_BASE_URL}/${usesResponses ? "responses" : "chat/completions"}`;
  // One attempt per credential, plus a second pass so a transient blip on the
  // last key is still retried — bounded either way, and never fewer than three
  // attempts for a single-account deployment.
  const credentials = orderedKeys();
  const maxAttempts = Math.max(3, credentials.length + 1);
  let lastFailure = { ok: false, detail: "The model call failed." };
  let credentialIndex = 0;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    if (signal?.aborted) return { ok: false, aborted: true, detail: "The model call was cancelled." };

    // Rotate the account on every retry: a rate-limited key is not a reason to
    // stop, and a working key should be kept.
    const credential = credentials[credentialIndex % credentials.length];
    credentialIndex += 1;
    const apiKey = credential.key;

    const controller = new AbortController();
    const onExternalAbort = () => controller.abort();
    if (signal) {
      if (signal.aborted) controller.abort();
      else signal.addEventListener("abort", onExternalAbort, { once: true });
    }
    const timer = setTimeout(() => controller.abort(), Math.max(5_000, timeoutMs));

    let response = null;
    let text = "";
    try {
      response = await fetchImpl(url, {
        method: "POST",
        signal: controller.signal,
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${apiKey}`,
          "x-opencode-session": SESSION_HEADER,
        },
        body: JSON.stringify(body),
      });
      text = await response.text();
    } catch (err) {
      if (signal?.aborted) return { ok: false, aborted: true, detail: "The model call was cancelled." };
      const aborted = err?.name === "AbortError";
      lastFailure = { ok: false, detail: aborted ? "The model call timed out." : `The model call failed: ${err?.message || err}` };
    } finally {
      clearTimeout(timer);
      if (signal) signal.removeEventListener("abort", onExternalAbort);
    }

    if (response) {
      if (!response.ok) {
        let detail = `The model provider answered HTTP ${response.status}.`;
        try {
          const parsedError = JSON.parse(text);
          const message = parsedError?.error?.message || parsedError?.message;
          if (message) detail = `${detail} ${String(message).slice(0, 300)}`;
        } catch {
          /* non-JSON error body */
        }
        lastFailure = { ok: false, status: response.status, detail };
        // An account the provider refuses (401/403 — wrong region, no access to
        // this model) is skipped for the rest of the process; a rate limit or an
        // outage is worth another account. Anything else is a real answer.
        if (response.status === 401 || response.status === 403) {
          noteKeyRefused(credential.index);
          continue;
        }
        if (response.status < 500 && response.status !== 429) return lastFailure;
      } else {
        let parsed;
        try {
          parsed = JSON.parse(text);
        } catch {
          lastFailure = { ok: false, status: response.status, detail: "The model provider returned a non-JSON body." };
          parsed = null;
        }
        if (parsed) {
          const message = usesResponses ? responsesTaskMessage(parsed) : parsed?.choices?.[0]?.message;
          if (!message) {
            lastFailure = { ok: false, status: response.status, detail: "The model provider returned no message." };
          } else {
            noteKeyWorked(credential.index);
            return {
              ok: true,
              status: response.status,
              message,
              finishReason: usesResponses ? (message.tool_calls?.length ? "tool_calls" : "stop") : parsed?.choices?.[0]?.finish_reason,
              usage: parsed?.usage,
            };
          }
        }
      }
    }

    // Bounded backoff before retrying a transient failure.
    if (attempt < maxAttempts) {
      if (signal?.aborted) return { ok: false, aborted: true, detail: "The model call was cancelled." };
      await new Promise((resolve) => setTimeout(resolve, 400 * attempt));
    }
  }

  if (lastFailure.detail && keyCount() > 1) {
    lastFailure.detail = `${lastFailure.detail} (tried ${keyCount()} accounts)`;
  }
  return lastFailure;
}
