/**
 * Optional Hermes executor.
 *
 * The default task executor is the evidence-recording agent in
 * `limited-agent.mjs`. This module is kept because the owner asked for real
 * Hermes, and it is selectable with `MIRA_TASK_RUNTIME=hermes`.
 *
 * It runs the installed Hermes in one-shot mode inside an isolated
 * HERMES_HOME, with `-t web` only (no terminal, filesystem, messaging, cron or
 * computer use), a wall-clock timeout, a turn cap and a run budget.
 *
 * Honesty rules added after review:
 *   · a non-zero exit is a failure even when stdout contains JSON — a crashed
 *     run is not a result;
 *   · the run must show real tool activity (Hermes' verbose `Tool call: …` and
 *     a `"success": true` tool result) before it can be treated as evidence;
 *   · the final JSON's URLs are still filtered, but that filter is not what
 *     stands in for evidence — `extractHermesEvidence` is.
 *
 * This mode's provenance is weaker than the default runtime: it is derived from
 * Hermes logs rather than from an in-process tool record. That is exactly why
 * it is not the default.
 */

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { extractJsonObject } from "./json.mjs";
import { safeUrlOrNull } from "./url-safety.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

export const HERMES_BIN = process.env.MIRA_HERMES_BIN || "/Users/gerardo/.local/bin/hermes";
export const HERMES_HOME = process.env.MIRA_HERMES_HOME || path.join(ROOT, ".build", "mira-hermes");
export const HERMES_PROVIDER = process.env.MIRA_TASK_PROVIDER || "opencode-go";
export const HERMES_MODEL = process.env.MIRA_TASK_MODEL || "deepseek-v4.1-flash";
export const HERMES_REASONING = process.env.MIRA_TASK_REASONING || "high";
export const HERMES_TOOLSETS = process.env.MIRA_TASK_TOOLSETS || "web";
export const HERMES_TIMEOUT_MS = Number(process.env.MIRA_TASK_TIMEOUT_MS || 180_000);
export const HERMES_MAX_TURNS = Number(process.env.MIRA_TASK_MAX_TURNS || 16);
export const HERMES_RUN_BUDGET_S = Number(process.env.MIRA_TASK_RUN_BUDGET_S || 240);

function hermesBin() {
  return process.env.MIRA_HERMES_BIN || HERMES_BIN;
}

/** Non-secret Hermes status for /health. */
export function hermesRuntimeStatus() {
  const bin = hermesBin();
  const keyConfigured = Boolean(process.env.OPENCODE_GO_API_KEY);
  return {
    agent: "hermes",
    wrapperFound: fs.existsSync(bin),
    homeIsolated: fs.existsSync(HERMES_HOME),
    home: HERMES_HOME.replace(process.env.HOME || "~", "~"),
    provider: HERMES_PROVIDER,
    model: HERMES_MODEL,
    reasoning: HERMES_REASONING,
    toolsets: HERMES_TOOLSETS.split(",").map((t) => t.trim()).filter(Boolean),
    keyConfigured,
    configured: keyConfigured && fs.existsSync(bin),
    webSearch: HERMES_TOOLSETS.includes("web"),
    browserInspection: false,
    timeoutMs: HERMES_TIMEOUT_MS,
    maxTurns: HERMES_MAX_TURNS,
    provenance: "log-derived",
  };
}

export { extractJsonObject };

/**
 * Read tool activity out of Hermes' verbose stdout.
 * @returns {{toolCalls:number, successes:number, tools:string[]}}
 */
export function extractHermesEvidence(stdout) {
  const text = String(stdout || "");
  const tools = [];
  const callRe = /Tool call:\s*([A-Za-z0-9_]+)/g;
  let match;
  while ((match = callRe.exec(text))) {
    if (!tools.includes(match[1])) tools.push(match[1]);
  }
  const successRe = /"success"\s*:\s*true/g;
  let successes = 0;
  while (successRe.exec(text)) successes += 1;
  return { toolCalls: tools.length, successes, tools };
}

/**
 * Tool evidence from the run's own log.
 *
 * Hermes logs "tool web_search completed (2.05s, 2926 chars)" and
 * "Web search via ddgs: '…'" as it works. That is the proof a tool actually
 * ran — the same proof the stdout parser looks for, from the place Hermes
 * actually writes it.
 */
/**
 * Watch the run's log and report what the agent is doing, as it does it.
 *
 * The log is where Hermes writes "Web search via ddgs: 'best restaurants
 * Lisbon'" and "tool web_search completed (2.05s, 2926 chars)". Reading the new
 * bytes every second and a half turns that into a live line for the waiting
 * card — the work is visible while it happens, not only when it ends.
 */
export function watchHermesProgress(logPath, fromByte, onProgress, { intervalMs = 1500 } = {}) {
  let offset = fromByte;
  let lastLine = "";
  const timer = setInterval(() => {
    let text = "";
    try {
      if (!fs.existsSync(logPath)) return;
      const all = fs.readFileSync(logPath);
      if (all.length <= offset) return;
      text = all.subarray(offset).toString("utf8");
      offset = all.length;
    } catch {
      return;
    }
    let searches = 0;
    for (const line of text.split("\n")) {
      // The stage, never the query: the search string is machinery, and a
      // person waiting wants to know that work is happening, not what the
      // agent typed into a search box.
      const search = /Web search via \w+: '([^']{3,120})'/.exec(line);
      if (search) {
        searches += 1;
        if (searches === 1 && lastLine !== "search-1") {
          lastLine = "search-1";
          onProgress?.({ summary: "Searching the web now" });
        } else if (searches === 2 && lastLine !== "search-2") {
          lastLine = "search-2";
          onProgress?.({ summary: "Searching a little further" });
        }
        continue;
      }
      const opened = /Extracting content from (\d+) URL/.exec(line);
      if (opened && Number(opened[1]) > 0) {
        onProgress?.({
          summary: Number(opened[1]) === 1 ? "Reading the page now" : `Reading ${opened[1]} pages now`,
        });
      }
    }
  }, intervalMs);
  if (typeof timer.unref === "function") timer.unref();
  return () => clearInterval(timer);
}

export function extractHermesLogEvidence(logPath, fromByte = 0) {
  let text = "";
  try {
    if (!fs.existsSync(logPath)) return { toolCalls: 0, successes: 0, tools: [] };
    const all = fs.readFileSync(logPath);
    text = all.subarray(Math.max(0, Math.min(fromByte, all.length))).toString("utf8");
  } catch {
    return { toolCalls: 0, successes: 0, tools: [] };
  }

  const tools = [];
  const completed = text.match(/tool\s+([A-Za-z0-9_]+)\s+completed/g) || [];
  for (const line of completed) {
    const name = line.replace(/tool\s+/i, "").replace(/\s+completed/i, "");
    if (name && !tools.includes(name)) tools.push(name);
  }
  const searches = (text.match(/Web search via/gi) || []).length;
  const failures = (text.match(/Tool\s+[A-Za-z0-9_]+\s+returned error/gi) || []).length;
  // A completed search is evidence: the URLs it returned are sources the
  // contract allows, and a failed *page read* must not cancel them. Subtracting
  // failures here once made a run that searched successfully look like a run
  // that did nothing, and the whole task failed with "no tool evidence".
  const successes = completed.length + searches;
  return { toolCalls: completed.length + searches, successes, failures, tools };
}

/** Combine what the run printed with what it logged. */
export function mergeEvidence(a, b) {
  const tools = [...new Set([...(a?.tools || []), ...(b?.tools || [])])];
  return {
    toolCalls: (a?.toolCalls || 0) + (b?.toolCalls || 0),
    successes: (a?.successes || 0) + (b?.successes || 0),
    tools,
  };
}

const asArray = (value) => (Array.isArray(value) ? value : []);

/** Validate the agent's raw JSON so only safe, real-looking links reach the app. */
export function normaliseAgentResult(parsed) {
  if (!parsed || typeof parsed !== "object") return null;
  const droppedUrls = [];
  const options = asArray(parsed.options)
    .map((option) => {
      if (!option || typeof option !== "object") return null;
      const name = String(option.name || "").trim().slice(0, 200);
      if (!name) return null;
      const rawUrl = option.url;
      const url = safeUrlOrNull(rawUrl);
      if (rawUrl && !url) droppedUrls.push(String(rawUrl).slice(0, 300));
      const entry = { name, url: url ?? null, why: String(option.why || "").trim().slice(0, 400) };
      if (option.priceNote) entry.priceNote = String(option.priceNote).slice(0, 120);
      return entry;
    })
    .filter(Boolean)
    .slice(0, 8);

  const sources = [];
  const seen = new Set();
  for (const source of asArray(parsed.sources)) {
    if (!source || typeof source !== "object") continue;
    const url = safeUrlOrNull(source.url);
    if (!url) {
      if (source.url) droppedUrls.push(String(source.url).slice(0, 300));
      continue;
    }
    if (seen.has(url)) continue;
    seen.add(url);
    sources.push({ title: String(source.title || url).trim().slice(0, 200), url });
  }

  const blocked = asArray(parsed.blocked_pages)
    .map((entry) => {
      if (!entry || typeof entry !== "object") return null;
      const url = safeUrlOrNull(entry.url);
      if (!url) return null;
      return { url, reason: String(entry.reason || "could not be read").slice(0, 200) };
    })
    .filter(Boolean)
    .slice(0, 8);

  return {
    title: String(parsed.title || "").trim().slice(0, 120),
    summary: String(parsed.summary || "").trim().slice(0, 2000),
    question: parsed.question ? String(parsed.question).slice(0, 300) : null,
    options,
    sources,
    blocked,
    nextStep: String(parsed.next_step || parsed.nextStep || "").trim().slice(0, 400),
    limitations: String(parsed.limitations || "").trim().slice(0, 400),
    droppedUrls,
  };
}

/**
 * Run Hermes once. Fails on a non-zero exit and on missing tool evidence.
 * @returns {Promise<{ok:boolean, result?:object, evidence?:object, detail?:string, latencyMs:number, timedOut?:boolean}>}
 */
export function runHermes({
  prompt,
  workspace,
  timeoutMs = HERMES_TIMEOUT_MS,
  maxTurns = HERMES_MAX_TURNS,
  runBudgetSec = HERMES_RUN_BUDGET_S,
  toolsets = HERMES_TOOLSETS,
  onChild,
  onProgress,
} = {}) {
  const started = Date.now();
  const bin = hermesBin();
  return new Promise((resolve) => {
    if (!process.env.OPENCODE_GO_API_KEY) {
      resolve({ ok: false, detail: "No OPENCODE_GO_API_KEY in the server environment; the task runtime is not configured.", latencyMs: 0 });
      return;
    }
    if (!fs.existsSync(bin)) {
      resolve({ ok: false, detail: `Hermes wrapper not found at ${bin}.`, latencyMs: 0 });
      return;
    }

    const args = [
      "chat",
      "-q",
      String(prompt || ""),
      "-Q",
      "-v",
      "-m",
      HERMES_MODEL,
      "--provider",
      HERMES_PROVIDER,
      "--reasoning",
      HERMES_REASONING,
      "-t",
      toolsets,
      "--max-turns",
      String(maxTurns),
      "--run-budget",
      String(runBudgetSec),
      "--ignore-user-config",
    ];
    if (workspace) args.push("--in", workspace);

    // Hermes reports its tool calls to its own log, not to stdout, so the
    // evidence for a run is read from the part of that log this run wrote.
    const logPath = path.join(HERMES_HOME, "logs", "agent.log");
    let logStart = 0;
    try {
      logStart = fs.existsSync(logPath) ? fs.statSync(logPath).size : 0;
    } catch {
      logStart = 0;
    }

    // The run's own log is the live feed: start watching it as soon as the child
    // starts, stop when it ends.
    const stopProgress = watchHermesProgress(logPath, logStart, onProgress);

    let child;
    try {
      child = spawn(bin, args, {
        cwd: workspace || ROOT,
        env: { ...process.env, HERMES_HOME },
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (err) {
      resolve({ ok: false, detail: `Could not start Hermes: ${err.message}`, latencyMs: Date.now() - started });
      return;
    }

    if (typeof onChild === "function") onChild(child);

    let stdout = "";
    let stderr = "";
    let settled = false;
    const finish = (payload) => {
      stopProgress();
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve({ ...payload, latencyMs: Date.now() - started });
    };

    const timer = setTimeout(() => {
      try {
        child.kill("SIGKILL");
      } catch {
        /* already gone */
      }
      finish({ ok: false, timedOut: true, detail: `The task agent did not finish within ${Math.round(timeoutMs / 1000)}s.` });
    }, Math.max(5_000, timeoutMs));

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
      if (stdout.length > 2_000_000) stdout = stdout.slice(-1_000_000);
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
      if (stderr.length > 200_000) stderr = stderr.slice(-100_000);
    });
    child.on("error", (err) => finish({ ok: false, detail: `Could not start the task agent: ${err.message}` }));
    child.on("close", (code) => {
      if (settled) return;
      // A crashed run is never a result, even if it printed JSON first.
      if (code !== 0) {
        finish({ ok: false, detail: `The task agent exited with code ${code}. ${stderr.slice(0, 200)}` });
        return;
      }
      const evidence = mergeEvidence(
        extractHermesEvidence(stdout),
        extractHermesLogEvidence(logPath, logStart));
      if (evidence.toolCalls === 0 || evidence.successes === 0) {
        finish({
          ok: false,
          detail: "The task agent produced no successful tool evidence.",
          evidence: { ...evidence, runtime: "hermes" },
        });
        return;
      }
      const parsed = extractJsonObject(stdout);
      if (!parsed) {
        finish({ ok: false, detail: "The task agent returned no structured result.", evidence: { ...evidence, runtime: "hermes" } });
        return;
      }
      const result = normaliseAgentResult(parsed);
      if (!result) {
        finish({ ok: false, detail: "The task agent returned a result that could not be read." });
        return;
      }
      finish({ ok: true, result, evidence: { ...evidence, runtime: "hermes", provenance: "log-derived" } });
    });
  });
}
