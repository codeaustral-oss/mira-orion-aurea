import { keyCount, keysConfigured } from "./api-keys.mjs";
/**
 * Task runtime selector.
 *
 * `limited` (default) — Mira's own bounded tool-use loop with in-process
 * provenance and pre-fetch SSRF guards.
 * `hermes`            — the installed Hermes agent, log-derived provenance.
 *
 * Only read-only web tools are available in either mode.
 */

import { getCapability } from "./capabilities.mjs";
import { callModel } from "./llm.mjs";
import { makeWebSearch } from "./search.mjs";
import { browserAvailable } from "./browser-read.mjs";
import { createToolset, runLimitedAgent, evidenceSummary } from "./limited-agent.mjs";
import { runHermes, hermesRuntimeStatus } from "./hermes.mjs";

export const TASK_RUNTIME = process.env.MIRA_TASK_RUNTIME === "hermes" ? "hermes" : "limited";

export const MAX_TURNS = Number(process.env.MIRA_TASK_MAX_TURNS || 10);
export const MAX_TOOL_CALLS = Number(process.env.MIRA_TASK_MAX_TOOL_CALLS || 16);
export const DEADLINE_MS = Number(process.env.MIRA_TASK_DEADLINE_MS || 180_000);

function brandLabel(brand) {
  return brand === "aurea" ? "Mira Aurea" : "Mira Orion";
}

/**
 * Non-secret runtime description for /health, including which tools are live.
 *
 * `runtime` is the executor that actually runs tasks. The default is Mira's own
 * bounded loop; Hermes is reported separately as an opt-in alternative so the
 * health payload never claims Hermes is doing the work when it is not.
 */
export function runtimeStatus() {
  const browser = browserAvailable();
  return {
    runtime: TASK_RUNTIME,
    defaultRuntime: "limited",
    executors: { limited: TASK_RUNTIME === "limited", hermes: TASK_RUNTIME === "hermes" },
    tools: {
      web_search: { available: true, backend: "parallel-keyless + duckduckgo-html" },
      web_fetch: { available: true, guard: "dns-pinned+redirect-validated" },
      browser_read: {
        available: browser,
        mode: browser ? "isolated-chromium-headless-readonly-guarded-proxy" : "unavailable",
        note: browser ? null : "No chromium headless shell installed.",
      },
    },
    limits: { maxTurns: MAX_TURNS, maxToolCalls: MAX_TOOL_CALLS, deadlineMs: DEADLINE_MS },
    model: {
      provider: "opencode-go",
      model: process.env.MIRA_TASK_MODEL || "deepseek-v4.1-flash",
      configured: keysConfigured(),
      accounts: keyCount(),
    },
    // Optional, non-default executor. Only truthful when runtime === "hermes".
    hermesOptional: { ...hermesRuntimeStatus(), active: TASK_RUNTIME === "hermes" },
  };
}

/** Run one task and return `{ ok, result?, evidence?, detail? }`. */
export async function runTaskAgent(task, { onChild, onProgress, signal } = {}) {
  const capability = getCapability(task.kind);
  if (!capability) return { ok: false, detail: `Unknown task kind '${task.kind}'.` };

  const system = capability.prompt({
    slots: task.slots,
    message: task.originalMessage,
    history: task.history,
    brandLabel: brandLabel(task.brand),
  });
  const user = "Begin now. Search, open the pages you intend to cite, then return the JSON object.";

  if (TASK_RUNTIME === "hermes") {
    const outcome = await runHermes({
      prompt: system,
      workspace: task.workspace,
      onProgress,
      onChild: (child) => {
        onChild?.(child);
        if (signal) {
          const kill = () => {
            try {
              child.kill("SIGKILL");
            } catch {
              /* gone */
            }
          };
          if (signal.aborted) kill();
          else signal.addEventListener("abort", kill, { once: true });
        }
      },
    });
    if (!outcome.ok) return { ok: false, detail: outcome.detail };
    return { ok: true, result: outcome.result, evidence: outcome.evidence };
  }

  const toolset = createToolset({
    search: makeWebSearch(),
    includeBrowser: browserAvailable(),
  });
  const outcome = await runLimitedAgent({
    system,
    user,
    toolset,
    callModel,
    maxTurns: MAX_TURNS,
    maxToolCalls: MAX_TOOL_CALLS,
    deadlineMs: DEADLINE_MS,
    signal,
  });
  if (!outcome.ok) return { ok: false, detail: outcome.detail, evidence: outcome.evidence };
  return { ok: true, result: outcome.result, evidence: evidenceSummary(outcome.evidence) };
}
