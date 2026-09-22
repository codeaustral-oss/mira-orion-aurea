/**
 * Mira's bounded, evidence-recording task agent.
 *
 * Instead of trusting a model's final JSON, this runs a small tool-use loop and
 * keeps a provenance record of what actually happened: every tool call, whether
 * it succeeded, and the exact URLs that came back from a search result or a
 * successful retrieval.
 *
 * The result is only accepted when:
 *   · at least one tool call was made;
 *   · at least one call actually produced evidence (search hits or a fetched
 *     page);
 *   · every URL the model reports as a source/option is one that provenance
 *     recorded — a URL the model merely made up is dropped, and if that leaves
 *     nothing to stand on, the task fails instead of writing a confident lie.
 *
 * The toolset is fixed and read-only: web_search, web_fetch and (when the
 * installed chromium allows it) browser_read. There is no terminal, no
 * filesystem, no messaging, no cron and no code execution.
 */

import { extractJsonObject } from "./json.mjs";
import { safeFetch } from "./safe-fetch.mjs";
import { extractImage, htmlToText } from "./html-text.mjs";
import { browserAvailable, browserRead } from "./browser-read.mjs";

const MAX_TOOL_RESULT_CHARS = 8_000;

export const TOOL_SCHEMAS = {
  web_search: {
    type: "function",
    function: {
      name: "web_search",
      description: "Search the public web. Returns result titles, URLs and snippets. Use this first to find candidate pages.",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string", description: "The search query." },
          limit: { type: "integer", description: "Maximum results (1-10).", minimum: 1, maximum: 10 },
        },
        required: ["query"],
        additionalProperties: false,
      },
    },
  },
  web_fetch: {
    type: "function",
    function: {
      name: "web_fetch",
      description:
        "Fetch one public page and return its readable text. Only http/https public pages; private, internal and link-local addresses are refused.",
      parameters: {
        type: "object",
        properties: { url: { type: "string", description: "Absolute http(s) URL to read." } },
        required: ["url"],
        additionalProperties: false,
      },
    },
  },
  browser_read: {
    type: "function",
    function: {
      name: "browser_read",
      description:
        "Load one public page in an isolated headless browser and return its rendered text. Read-only: no clicking, typing, signing in or submitting. Use for pages that need JavaScript.",
      parameters: {
        type: "object",
        properties: { url: { type: "string", description: "Absolute http(s) URL to load." } },
        required: ["url"],
        additionalProperties: false,
      },
    },
  },
};

function summariseArgs(args) {
  if (!args || typeof args !== "object") return "";
  return JSON.stringify(args).slice(0, 300);
}

function recordEvidence(evidence, entry) {
  evidence.calls.push(entry);
  evidence.toolCalls += 1;
  if (entry.ok) {
    evidence.groundedCalls += entry.grounded ? 1 : 0;
    for (const url of entry.urls || []) evidence.provenUrls.add(url);
  }
}

/**
 * Build the read-only toolset bound to a provenance record.
 * `overrides` lets tests inject search/fetch/browser implementations.
 */
export function createToolset({ search, overrides = {}, includeBrowser = browserAvailable() } = {}) {
  const impls = {
    web_search: async (args, { evidence }) => {
      if (typeof search !== "function") return { ok: false, detail: "search backend is not configured" };
      const outcome = await search(args.query, args.limit);
      if (!outcome?.ok || !outcome.results?.length) {
        return { ok: false, detail: outcome?.reason || "no search results" };
      }
      return {
        ok: true,
        grounded: true,
        resultCount: outcome.results.length,
        urls: outcome.results.map((result) => result.url),
        backend: outcome.backend,
        content: { backend: outcome.backend, results: outcome.results },
      };
    },
    web_fetch: async (args, { signal } = {}) => {
      const outcome = await safeFetch(args.url, { signal });
      if (!outcome.ok) return { ok: false, detail: outcome.reason, code: outcome.code };
      const isHtml = /html/i.test(outcome.contentType || "");
      const text = isHtml ? htmlToText(outcome.body) : String(outcome.body || "").slice(0, MAX_TOOL_RESULT_CHARS);
      // The page's own share image, kept with the run so a source can carry a
      // picture once the model names it.
      if (isHtml && evidence && evidence.pageImages) {
        const image = extractImage(outcome.body, outcome.finalUrl);
        if (image) evidence.pageImages.set(outcome.finalUrl, image);
      }
      return {
        ok: true,
        grounded: true,
        retrieval: true,
        status: outcome.status,
        bytes: outcome.bytes,
        urls: [outcome.finalUrl],
        content: {
          url: outcome.finalUrl,
          status: outcome.status,
          contentType: outcome.contentType,
          text: text.slice(0, MAX_TOOL_RESULT_CHARS),
          truncated: Boolean(outcome.truncated),
        },
      };
    },
    browser_read: async (args, { signal } = {}) => {
      const outcome = await browserRead(args.url, { signal });
      if (!outcome.ok) return { ok: false, detail: outcome.reason, code: outcome.code };
      return {
        ok: true,
        grounded: true,
        retrieval: true,
        bytes: outcome.bytes,
        urls: [outcome.url],
        content: { url: outcome.url, title: outcome.title, text: String(outcome.text).slice(0, MAX_TOOL_RESULT_CHARS) },
      };
    },
  };

  for (const [name, impl] of Object.entries(overrides)) impls[name] = impl;

  const names = ["web_search", "web_fetch"];
  if (includeBrowser) names.push("browser_read");

  return {
    names,
    schemas: names.map((name) => TOOL_SCHEMAS[name]),
    impls,
  };
}

/**
 * Run one bounded tool-use loop.
 *
 * @returns {Promise<{ok:boolean, result?:object, evidence:object, detail?:string, turns:number, toolCalls:number}>}
 */
export async function runLimitedAgent({
  system,
  user,
  toolset,
  callModel,
  maxTurns = 8,
  maxToolCalls = 16,
  deadlineMs = 150_000,
  now = () => Date.now(),
  signal,
} = {}) {
  const evidence = { calls: [], provenUrls: new Set(), pageImages: new Map(), toolCalls: 0, groundedCalls: 0, backends: new Set(), failed: [] };
  const started = now();
  const messages = [
    { role: "system", content: String(system || "") },
    { role: "user", content: String(user || "Begin the task now.") },
  ];
  let turns = 0;
  let forceAnswer = false;
  let repairAttempted = false;

  const fail = (detail) => {
    const snapshot = snapshotEvidence(evidence, started, now);
    return { ok: false, detail, evidence: snapshot, turns, toolCalls: evidence.toolCalls };
  };

  while (turns < maxTurns) {
    if (signal?.aborted) return fail("Stopped at your request.");
    if (now() - started > deadlineMs) return fail("This took longer than Mira allows, so it stopped.");
    turns += 1;

    const response = await callModel({
      messages,
      tools: forceAnswer ? undefined : toolset.schemas,
      toolChoice: forceAnswer ? undefined : "auto",
      // The forced-answer turn is the one whose text must parse as JSON: give it
      // room to answer, and ask it to think less so the budget goes on the object.
      json: Boolean(forceAnswer),
      maxTokens: forceAnswer ? 4_000 : null,
      reasoning: forceAnswer ? "low" : undefined,
      signal,
    });
    if (signal?.aborted) return fail("Stopped at your request.");
    if (!response?.ok) return fail(response?.detail || "The model call failed.");

    const message = response.message || {};
    const toolCalls = Array.isArray(message.tool_calls) ? message.tool_calls : [];
    messages.push({
      role: "assistant",
      content: message.content || "",
      ...(toolCalls.length ? { tool_calls: toolCalls } : {}),
    });

    if (!toolCalls.length) {
      const parsed = extractJsonObject(message.content || "");
      if (parsed) return finalise({ parsed, evidence, started, turns, now });
      // The model answered in prose instead of the required object. Ask once,
      // strictly, before giving up: the tool evidence it gathered is real and
      // should not be thrown away over formatting.
      if (!repairAttempted) {
        repairAttempted = true;
        forceAnswer = true;
        messages.push({
          role: "user",
          content:
            "Return ONLY the JSON object described in the system prompt — a single {\"title\":…,\"summary\":…,\"sources\":[…],\"options\":[…]}. No prose, no markdown fences.",
        });
        continue;
      }
      return fail("Mira could not finish this one properly.");
    }

    const callsThisTurn = [];
    for (const call of toolCalls) {
      const name = call?.function?.name;
      let args = {};
      try {
        args = call?.function?.arguments ? JSON.parse(call.function.arguments) : {};
      } catch {
        args = null;
      }
      callsThisTurn.push({ id: call?.id, name, args });
    }

    const remainingBudget = maxToolCalls - evidence.toolCalls;
    for (const { id: callId, name, args } of callsThisTurn) {
      const impl = toolset.impls[name];
      const startedCall = now();
      let envelope;
      if (signal?.aborted) {
        envelope = { ok: false, detail: "The task was cancelled." };
      } else if (args === null) {
        envelope = { ok: false, detail: "arguments were not valid JSON" };
      } else if (remainingBudget <= 0 && evidence.toolCalls >= maxToolCalls) {
        envelope = { ok: false, detail: "tool-call budget exhausted; answer with what you have" };
      } else if (!impl) {
        envelope = { ok: false, detail: `unknown tool '${name}'` };
      } else {
        try {
          envelope = await impl(args || {}, { evidence, signal });
        } catch (err) {
          envelope = { ok: false, detail: `tool crashed: ${err?.message || err}` };
        }
      }

      const entry = {
        tool: name,
        args: summariseArgs(args),
        ok: Boolean(envelope?.ok),
        grounded: Boolean(envelope?.grounded),
        retrieval: Boolean(envelope?.retrieval),
        resultCount: envelope?.resultCount ?? 0,
        urls: envelope?.urls || [],
        status: envelope?.status,
        bytes: envelope?.bytes,
        backend: envelope?.backend,
        detail: envelope?.ok ? undefined : envelope?.detail,
        ms: now() - startedCall,
      };
      recordEvidence(evidence, entry);
      if (entry.backend) evidence.backends.add(entry.backend);
      if (!entry.ok) evidence.failed.push({ tool: entry.tool, args: entry.args, detail: entry.detail });

      const payload = envelope?.ok
        ? envelope.content
        : { error: envelope?.detail || "tool failed", hint: "Use another URL or answer from what you have." };
      messages.push({
        role: "tool",
        tool_call_id: callId,
        content: JSON.stringify(payload ?? {}).slice(0, MAX_TOOL_RESULT_CHARS),
      });
    }

    if (evidence.toolCalls >= maxToolCalls) forceAnswer = true;
  }

  return fail("Mira ran out of road on this one before it found an answer.");
}

function snapshotEvidence(evidence, started, now) {
  return {
    toolCalls: evidence.toolCalls,
    groundedCalls: evidence.groundedCalls,
    provenUrls: [...evidence.provenUrls],
    backends: [...evidence.backends],
    calls: evidence.calls,
    failed: evidence.failed,
    durationMs: now() - started,
  };
}

/**
 * Turn the model's final JSON into an accepted result, enforcing provenance.
 * Exported so the contract can be tested without a live model.
 */
export function finalise({ parsed, evidence, started = 0, turns = 0, now = () => Date.now() }) {
  const snapshot = snapshotEvidence(evidence, started, now);
  if (evidence.toolCalls === 0) {
    return { ok: false, detail: "The task agent produced no tool evidence.", evidence: snapshot, turns, toolCalls: 0 };
  }
  if (evidence.groundedCalls === 0) {
    return {
      ok: false,
      detail: "Every tool call failed or returned nothing, so there is no evidence to report.",
      evidence: snapshot,
      turns,
      toolCalls: evidence.toolCalls,
    };
  }

  const proven = evidence.provenUrls;
  const dropped = [];
  const options = [];
  for (const option of Array.isArray(parsed.options) ? parsed.options : []) {
    if (!option || typeof option !== "object") continue;
    const name = String(option.name || "").trim();
    if (!name) continue;
    const rawUrl = option.url ? String(option.url).trim() : "";
    if (rawUrl && !proven.has(rawUrl)) {
      dropped.push(rawUrl);
      continue; // URL was never retrieved: do not present it as a source
    }
    const entry = { name: name.slice(0, 200), url: rawUrl || null, why: String(option.why || "").trim().slice(0, 400) };
    if (option.priceNote) entry.priceNote = String(option.priceNote).slice(0, 120);
    options.push(entry);
    if (options.length >= 8) break;
  }

  const sources = [];
  const seen = new Set();
  for (const source of Array.isArray(parsed.sources) ? parsed.sources : []) {
    if (!source || typeof source !== "object") continue;
    const url = String(source.url || "").trim();
    if (!url) continue;
    if (!proven.has(url)) {
      dropped.push(url);
      continue;
    }
    if (seen.has(url)) continue;
    seen.add(url);
    const entry = {
      title: String(source.title || url).replace(/\s+/g, " ").trim().slice(0, 200),
      url,
    };
    const image = evidence.pageImages?.get(url);
    if (image) entry.thumbnail = image;
    sources.push(entry);
  }

  const blocked = [];
  for (const entry of Array.isArray(parsed.blocked_pages) ? parsed.blocked_pages : []) {
    if (!entry || typeof entry !== "object") continue;
    const url = String(entry.url || "").trim();
    if (!url) continue;
    blocked.push({ url: url.slice(0, 300), reason: String(entry.reason || "could not be read").slice(0, 200) });
    if (blocked.length >= 8) break;
  }

  const claimedLinks = options.length + sources.length;
  if (dropped.length && claimedLinks === 0) {
    return {
      ok: false,
      detail: `The agent reported ${dropped.length} link(s) that no tool actually retrieved; refusing to present unverified results.`,
      evidence: snapshot,
      turns,
      toolCalls: evidence.toolCalls,
      dropped,
    };
  }

  const result = {
    title: String(parsed.title || "").trim().slice(0, 120),
    summary: String(parsed.summary || "").trim().slice(0, 2000),
    question: parsed.question ? String(parsed.question).slice(0, 300) : null,
    options,
    sources,
    blocked,
    nextStep: String(parsed.next_step || parsed.nextStep || "").trim().slice(0, 400),
    limitations: String(parsed.limitations || "").trim().slice(0, 400),
    droppedUrls: dropped,
  };
  return {
    ok: true,
    result,
    evidence: snapshot,
    turns,
    toolCalls: evidence.toolCalls,
  };
}

/** A short, non-secret summary of provenance for health/evidence files. */
export function evidenceSummary(evidence) {
  if (!evidence) return null;
  return {
    toolCalls: evidence.toolCalls ?? 0,
    groundedCalls: evidence.groundedCalls ?? 0,
    provenUrls: (evidence.provenUrls || []).slice(0, 20),
    backends: evidence.backends || [],
    failed: (evidence.failed || []).length,
    byTool: (evidence.calls || []).reduce((acc, call) => {
      acc[call.tool] = acc[call.tool] || { ok: 0, failed: 0 };
      if (call.ok) acc[call.tool].ok += 1;
      else acc[call.tool].failed += 1;
      return acc;
    }, {}),
  };
}
