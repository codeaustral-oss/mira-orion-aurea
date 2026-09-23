/**
 * Task runtime regressions.
 *
 * These cover the parts that were wrong in the first cut and that must not
 * regress:
 *   · SSRF: private/link-local/internal DNS and redirects are refused BEFORE a
 *     fetch happens, not filtered afterwards;
 *   · evidence: a task completes only when a tool actually produced evidence,
 *     and a URL the model invented is never presented as a source;
 *   · a crashed run is a failure even when it printed JSON;
 *   · task lifecycle, brand ownership, cancellation, follow-up and restart
 *     recovery.
 *
 * Everything here is deterministic: no network, no model.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";

import {
  isSafePublicUrl,
  isPublicIp,
  safeArtifactName,
  resolveWithin,
  assessUrl,
} from "../lib/url-safety.mjs";
import { validateTarget, validateHostPort, safeFetch } from "../lib/safe-fetch.mjs";
import { splitHostPort, startGuardedProxy } from "../lib/browser-read.mjs";
import { createToolset, runLimitedAgent, finalise, evidenceSummary } from "../lib/limited-agent.mjs";
import { callModel } from "../lib/llm.mjs";
import { runtimeStatus } from "../lib/agent-runtime.mjs";
import { extractHermesEvidence, runHermes } from "../lib/hermes.mjs";
import { TaskService, TASK_STATUS } from "../lib/tasks.mjs";
import { detectTaskKind, extractSlots, looksLikeAccountCommand } from "../lib/task-router.mjs";
import { getCapability } from "../lib/capabilities.mjs";

process.env.TYPESAFE_API_KEY = "";
// Thumbnail enrichment touches the network; unit tests must not.
process.env.MIRA_THUMBNAILS = "off";

const tmpDir = () => fs.mkdtemp(path.join(os.tmpdir(), "mira-tasks-test-"));

function lookupFor(map) {
  return async (host) => {
    const value = map[host];
    if (!value) {
      const err = new Error(`ENOTFOUND ${host}`);
      err.code = "ENOTFOUND";
      throw err;
    }
    const records = Array.isArray(value) ? value : [value];
    return records.map((address) => ({ address, family: address.includes(":") ? 6 : 4 }));
  };
}

const publicLookup = lookupFor({ "example.com": "93.184.216.34", "listings-public.com": "203.0.113.10" });

// ── SSRF: URL and resolved-address checks ────────────────────────────────────

test("unsafe URL shapes are refused", () => {
  for (const url of [
    "http://localhost/",
    "http://127.0.0.1/",
    "http://10.0.0.5/",
    "http://192.168.1.1/",
    "http://169.254.169.254/latest/meta-data/",
    "http://172.16.0.1/",
    "http://100.64.0.1/",
    "http://[::1]/",
    "http://[fd00::1]/",
    "http://metadata.google.internal/",
    "http://foo.internal/",
    "http://router.local/",
    "http://user:pass@example.com/",
    "file:///etc/passwd",
    "ftp://example.com/",
    "gopher://example.com/",
    "",
    "not a url",
  ]) {
    assert.equal(isSafePublicUrl(url), false, `expected ${url} to be refused`);
  }
  for (const url of ["https://example.com/", "https://guide.michelin.com/br/pt_BR/x", "http://listings-public.com/a"]) {
    assert.equal(isSafePublicUrl(url), true, `expected ${url} to be allowed`);
  }
});

test("IP classification rejects private, loopback and link-local ranges", () => {
  assert.equal(isPublicIp("93.184.216.34"), true);
  assert.equal(isPublicIp("8.8.8.8"), true);
  assert.equal(isPublicIp("10.1.2.3"), false);
  assert.equal(isPublicIp("127.0.0.1"), false);
  assert.equal(isPublicIp("169.254.169.254"), false);
  assert.equal(isPublicIp("192.168.0.1"), false);
  assert.equal(isPublicIp("172.20.0.1"), false);
  assert.equal(isPublicIp("::1"), false);
  assert.equal(isPublicIp("fe80::1"), false);
  assert.equal(isPublicIp("fd12::1"), false);
  assert.equal(isPublicIp("not-an-ip"), false);
});

/** A fake transport matching the pinnedHttpTransport contract. */
function fakeTransport({ status = 200, contentType = "text/html", location = null, body = "<html><body>hello</body></html>", onCall } = {}) {
  return async ({ url, addresses, signal }) => {
    onCall?.({ url, addresses, signal });
    return {
      status,
      headers: {
        get: (name) => {
          const key = String(name).toLowerCase();
          if (key === "content-type") return contentType;
          if (key === "location") return location;
          return null;
        },
      },
      stream: null,
      text: async () => body,
    };
  };
}

test("a public hostname resolving to a private address is refused before any fetch", async () => {
  const calls = [];
  const outcome = await safeFetch("https://rebind-public.com/", {
    lookup: lookupFor({ "rebind-public.com": "10.0.0.7" }),
    transport: fakeTransport({ onCall: () => calls.push("fetch") }),
  });
  assert.equal(outcome.ok, false);
  assert.equal(outcome.code, "blocked_ip");
  assert.match(outcome.reason, /10\.0\.0\.7/);
  assert.equal(calls.length, 0, "the guarded fetch must not run");
});

test("DNS rebinding cannot redirect the connection to a private address", async () => {
  // The name answers with a public address first and a private one afterwards.
  // The transport must only ever receive the validated (public) address, and
  // the name must not be resolved a second time for the connection.
  let lookups = 0;
  const rebindingLookup = async () => {
    lookups += 1;
    return lookups === 1 ? [{ address: "93.184.216.34", family: 4 }] : [{ address: "10.0.0.9", family: 4 }];
  };
  let pinned = null;
  const outcome = await safeFetch("https://rebind-example.com/", {
    lookup: rebindingLookup,
    transport: fakeTransport({ onCall: ({ addresses }) => { pinned = addresses; } }),
  });
  assert.equal(outcome.ok, true);
  assert.deepEqual(pinned, ["93.184.216.34"], "the connection must target the validated address");
  assert.equal(lookups, 1, "the hostname must not be re-resolved for the connection");
});

test("the timeout covers body reading, not just headers", async () => {
  const slowTransport = ({ signal }) =>
    new Promise((resolve) => {
      const stream = (async function* () {
        yield Buffer.from("<html><body>");
        await new Promise((_, reject) => {
          const timer = setTimeout(() => reject(new Error("stream never ended")), 5_000);
          signal.addEventListener("abort", () => {
            clearTimeout(timer);
            reject(Object.assign(new Error("aborted"), { name: "AbortError" }));
          });
        });
      })();
      resolve({
        status: 200,
        headers: { get: (name) => (String(name).toLowerCase() === "content-type" ? "text/html" : null) },
        stream,
      });
    });
  const started = Date.now();
  const outcome = await safeFetch("https://example.com/", { lookup: publicLookup, transport: slowTransport, timeoutMs: 200 });
  assert.equal(outcome.ok, false);
  assert.equal(outcome.code, "timeout");
  assert.ok(Date.now() - started < 4_000, "the request must not wait for a stalled body");
});

test("DNS failure is reported, not followed", async () => {
  const outcome = await safeFetch("https://does-not-exist-public.com/", { lookup: lookupFor({}), transport: fakeTransport() });
  assert.equal(outcome.ok, false);
  assert.equal(outcome.code, "dns_failure");
});

test("a redirect to a private address is refused before the second hop", async () => {
  const seen = [];
  const transport = fakeTransport({
    status: 302,
    location: "http://169.254.169.254/latest/meta-data/",
    onCall: ({ url }) => seen.push(String(url)),
  });
  const outcome = await safeFetch("https://example.com/", { lookup: publicLookup, transport });
  assert.equal(outcome.ok, false);
  assert.equal(outcome.code, "blocked_ip");
  assert.equal(seen.length, 1, "only the first hop may be requested");
  assert.equal(outcome.redirects.length, 1);
});

test("a redirect to an internal hostname is refused", async () => {
  const outcome = await safeFetch("https://example.com/", {
    lookup: publicLookup,
    transport: fakeTransport({ status: 302, location: "http://intranet.internal/admin" }),
  });
  assert.equal(outcome.ok, false);
  assert.equal(outcome.code, "blocked_host");
});

test("a safe redirect chain is followed and the final URL recorded", async () => {
  let call = 0;
  const transport = async ({ url }) => {
    call += 1;
    if (call === 1) {
      return { status: 301, headers: { get: (n) => (String(n).toLowerCase() === "location" ? "https://listings-public.com/final" : null) }, stream: null };
    }
    assert.equal(String(url), "https://listings-public.com/final");
    return {
      status: 200,
      headers: { get: (n) => (String(n).toLowerCase() === "content-type" ? "text/html; charset=utf-8" : null) },
      stream: null,
      text: async () => "<html><body>hello</body></html>",
    };
  };
  const outcome = await safeFetch("https://example.com/", { lookup: publicLookup, transport });
  assert.equal(outcome.ok, true);
  assert.equal(outcome.finalUrl, "https://listings-public.com/final");
  assert.equal(outcome.redirects.length, 1);
});

test("non-text content and non-GET methods are refused", async () => {
  const binary = await safeFetch("https://example.com/image.png", {
    lookup: publicLookup,
    transport: fakeTransport({ contentType: "image/png" }),
  });
  assert.equal(binary.ok, false);
  assert.equal(binary.code, "unsupported_content");

  const post = await safeFetch("https://example.com/", { method: "POST", lookup: publicLookup, transport: fakeTransport() });
  assert.equal(post.ok, false);
  assert.equal(post.code, "bad_method");
});

test("validateTarget and assessUrl report why a target is refused", async () => {
  assert.equal((await validateTarget("https://10.0.0.1/", { lookup: publicLookup })).code, "blocked_ip");
  assert.equal(assessUrl("http://127.0.0.1/").code, "blocked_ip");
  assert.equal(assessUrl("file:///etc/passwd").code, "bad_scheme");
  assert.equal(assessUrl("http://user:pass@example.com/").code, "credentials_in_url");
  assert.equal((await validateTarget("https://example.com/", { lookup: publicLookup })).ok, true);
});

// ── Browser proxy: IP-literal and private targets are refused at the proxy ───

test("validateHostPort refuses private addresses and disallowed ports", async () => {
  assert.equal((await validateHostPort("127.0.0.1", 443, { lookup: publicLookup })).code, "blocked_ip");
  assert.equal((await validateHostPort("169.254.169.254", 80, { lookup: publicLookup })).code, "blocked_ip");
  assert.equal((await validateHostPort("example.com", 70000, { lookup: publicLookup })).code, "bad_port");
  assert.equal((await validateHostPort("example.com", 443, { lookup: publicLookup })).ok, true);
});

test("CONNECT targets are parsed, including IPv6 literals", () => {
  assert.deepEqual(splitHostPort("example.com:443"), { host: "example.com", port: 443 });
  assert.deepEqual(splitHostPort("[::1]:443"), { host: "::1", port: 443 });
  assert.deepEqual(splitHostPort("example.com"), { host: "example.com", port: null });
});

test("the guarded browser proxy refuses IP-literal and private targets", async () => {
  const proxy = await startGuardedProxy({ lookup: lookupFor({ "example.com": "93.184.216.34" }) });
  try {
    const httpStatus = await new Promise((resolve, reject) => {
      const req = http.request(
        { host: "127.0.0.1", port: proxy.port, method: "GET", path: "http://169.254.169.254/latest/meta-data/" },
        (res) => {
          res.resume();
          resolve(res.statusCode);
        }
      );
      req.on("error", reject);
      req.end();
    });
    assert.equal(httpStatus, 403);

    const connectStatus = await new Promise((resolve, reject) => {
      const socket = net.connect(proxy.port, "127.0.0.1", () => {
        socket.write("CONNECT 127.0.0.1:443 HTTP/1.1\r\nHost: 127.0.0.1:443\r\n\r\n");
      });
      let data = "";
      socket.on("data", (chunk) => {
        data += chunk.toString();
        if (data.includes("\r\n\r\n")) {
          socket.destroy();
          resolve(data.split(" ")[1]);
        }
      });
      socket.on("error", reject);
    });
    assert.equal(connectStatus, "403");
  } finally {
    await proxy.close();
  }
});

test("the guarded browser proxy refuses non-read methods", async () => {
  const proxy = await startGuardedProxy({ lookup: lookupFor({ "example.com": "93.184.216.34" }) });
  try {
    const status = await new Promise((resolve, reject) => {
      const req = http.request(
        { host: "127.0.0.1", port: proxy.port, method: "POST", path: "http://example.com/checkout" },
        (res) => {
          res.resume();
          resolve(res.statusCode);
        }
      );
      req.on("error", reject);
      req.end();
    });
    assert.equal(status, 405);
  } finally {
    await proxy.close();
  }
});

test("the guarded browser proxy only tunnels web ports", async () => {
  const proxy = await startGuardedProxy({ lookup: lookupFor({ "example.com": "93.184.216.34" }) });
  try {
    const status = await new Promise((resolve, reject) => {
      const socket = net.connect(proxy.port, "127.0.0.1", () => {
        socket.write("CONNECT example.com:22 HTTP/1.1\r\nHost: example.com:22\r\n\r\n");
      });
      let data = "";
      socket.on("data", (chunk) => {
        data += chunk.toString();
        if (data.includes("\r\n\r\n")) {
          socket.destroy();
          resolve(data.split(" ")[1]);
        }
      });
      socket.on("error", reject);
    });
    assert.equal(status, "403");
  } finally {
    await proxy.close();
  }
});

// ── Artifact path safety ─────────────────────────────────────────────────────

test("artifact names and paths cannot escape their directory", () => {
  assert.equal(safeArtifactName("task-abc-result.md"), "task-abc-result.md");
  for (const bad of ["../tasks.json", "a/../../b.md", "sub/dir.md", "..", ".hidden", "x\\y.md", ""]) {
    assert.equal(safeArtifactName(bad), null, `expected ${bad} to be refused`);
  }
  assert.equal(resolveWithin("/tmp/base", "../etc/passwd"), null);
  assert.equal(resolveWithin("/tmp/base", "ok.md"), "/tmp/base/ok.md");
});

// ── Evidence: the model's word is not proof ──────────────────────────────────

function baseEvidence(urls = [], { toolCalls = 1, groundedCalls = 1 } = {}) {
  return {
    calls: [],
    provenUrls: new Set(urls),
    toolCalls,
    groundedCalls,
    backends: new Set(),
    failed: [],
  };
}

test("a URL the model invented is dropped, never presented as a source", () => {
  const evidence = baseEvidence(["https://real-site.com/page"], { toolCalls: 2, groundedCalls: 1 });
  const outcome = finalise({
    parsed: {
      title: "t",
      summary: "s",
      sources: [{ title: "real", url: "https://real-site.com/page" }, { title: "fake", url: "https://hallucinated-site.com/x" }],
      options: [{ name: "Real place", url: "https://real-site.com/page", why: "w" }],
    },
    evidence,
  });
  assert.equal(outcome.ok, true);
  assert.deepEqual(outcome.result.sources.map((s) => s.url), ["https://real-site.com/page"]);
  assert.deepEqual(outcome.result.droppedUrls, ["https://hallucinated-site.com/x"]);
});

test("a result whose only links were invented fails instead of being reported", () => {
  const evidence = baseEvidence([], { toolCalls: 2, groundedCalls: 1 });
  const outcome = finalise({
    parsed: {
      summary: "I found great options",
      sources: [{ title: "made up", url: "https://hallucinated-site.com/x" }],
      options: [{ name: "Ghost", url: "https://hallucinated-site.com/y", why: "w" }],
    },
    evidence,
  });
  assert.equal(outcome.ok, false);
  assert.match(outcome.detail, /unverified/i);
});

test("a result with no tool calls at all is not accepted", () => {
  const outcome = finalise({ parsed: { summary: "trust me" }, evidence: baseEvidence([], { toolCalls: 0, groundedCalls: 0 }) });
  assert.equal(outcome.ok, false);
  assert.match(outcome.detail, /no tool evidence/i);
});

test("when every tool call failed, the task fails rather than completing", () => {
  const outcome = finalise({ parsed: { summary: "x" }, evidence: baseEvidence([], { toolCalls: 3, groundedCalls: 0 }) });
  assert.equal(outcome.ok, false);
  assert.match(outcome.detail, /no evidence|failed/i);
});

test("the agent loop accepts only tool-grounded results", async () => {
  const toolset = createToolset({
    includeBrowser: false,
    search: async () => ({
      ok: true,
      backend: "fake",
      results: [{ title: "Real", url: "https://real-site.com/a", description: "d" }],
    }),
  });
  let turn = 0;
  const callModel = async () => {
    turn += 1;
    if (turn === 1) {
      return {
        ok: true,
        message: { role: "assistant", content: "", tool_calls: [{ id: "c1", function: { name: "web_search", arguments: '{"query":"x"}' } }] },
      };
    }
    return {
      ok: true,
      message: {
        role: "assistant",
        content: JSON.stringify({
          title: "Research",
          summary: "Found one real page.",
          sources: [{ title: "Real", url: "https://real-site.com/a" }],
          options: [{ name: "Real option", url: "https://real-site.com/a", why: "from the page" }],
        }),
      },
    };
  };
  const outcome = await runLimitedAgent({ system: "s", user: "u", toolset, callModel, now: () => 0 });
  assert.equal(outcome.ok, true);
  assert.deepEqual(outcome.result.sources.map((s) => s.url), ["https://real-site.com/a"]);
  assert.equal(outcome.evidence.groundedCalls, 1);
  assert.equal(outcome.evidence.toolCalls, 1);
});

test("the agent loop fails when the search backend fails and the model fabricates", async () => {
  const toolset = createToolset({ includeBrowser: false, search: async () => ({ ok: false, reason: "backend down" }) });
  let turn = 0;
  const callModel = async () => {
    turn += 1;
    if (turn === 1) {
      return { ok: true, message: { role: "assistant", content: "", tool_calls: [{ id: "c1", function: { name: "web_search", arguments: '{"query":"x"}' } }] } };
    }
    return {
      ok: true,
      message: {
        role: "assistant",
        content: JSON.stringify({ summary: "I found it", sources: [{ title: "x", url: "https://hallucinated-site.com/" }] }),
      },
    };
  };
  const outcome = await runLimitedAgent({ system: "s", user: "u", toolset, callModel, now: () => 0 });
  assert.equal(outcome.ok, false);
  assert.match(outcome.detail, /no evidence|unverified|failed/i);
});

test("the toolset exposes only read-only web tools", () => {
  const toolset = createToolset({ search: async () => ({ ok: true, results: [] }), includeBrowser: false });
  assert.deepEqual(toolset.names, ["web_search", "web_fetch"]);
  assert.equal(typeof toolset.impls.web_search, "function");
  for (const forbidden of ["terminal", "shell", "bash", "write_file", "send_message", "cron", "code_execution"]) {
    assert.equal(Object.prototype.hasOwnProperty.call(toolset.impls, forbidden), false, `${forbidden} must not exist`);
  }
});

test("evidenceSummary reports which tools were exercised", () => {
  const summary = evidenceSummary({
    toolCalls: 3,
    groundedCalls: 2,
    provenUrls: ["https://a-site.com/"],
    backends: ["parallel-keyless"],
    failed: [{ tool: "web_fetch" }],
    calls: [
      { tool: "web_search", ok: true },
      { tool: "web_fetch", ok: true },
      { tool: "web_fetch", ok: false },
    ],
  });
  assert.equal(summary.toolCalls, 3);
  assert.equal(summary.byTool.web_fetch.ok, 1);
  assert.equal(summary.byTool.web_fetch.failed, 1);
  assert.equal(summary.failed, 1);
});

test("the model client retries transient 5xx but not client errors", async () => {
  const previous = process.env.OPENCODE_GO_API_KEY;
  process.env.OPENCODE_GO_API_KEY = "test-key";
  try {
    let calls = 0;
    const flaky = async () => {
      calls += 1;
      if (calls < 3) return { ok: false, status: 500, text: async () => "boom" };
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ choices: [{ message: { role: "assistant", content: "{}" } }] }),
      };
    };
    const retried = await callModel({ messages: [], fetchImpl: flaky, timeoutMs: 5_000 });
    assert.equal(retried.ok, true);
    assert.equal(calls, 3);

    calls = 0;
    const bounded = await callModel({ messages: [], fetchImpl: flaky, timeoutMs: 5_000, maxAttempts: 2 });
    assert.equal(bounded.ok, false);
    assert.equal(calls, 2, "phone tasks stop provider retries before the wait becomes long");

    let clientCalls = 0;
    const client = async () => {
      clientCalls += 1;
      return { ok: false, status: 400, text: async () => "bad request" };
    };
    const refused = await callModel({ messages: [], fetchImpl: client, timeoutMs: 5_000 });
    assert.equal(refused.ok, false);
    assert.equal(refused.status, 400);
    assert.equal(clientCalls, 1, "client errors must not be retried");
  } finally {
    process.env.OPENCODE_GO_API_KEY = previous;
  }
});

// ── Hermes executor: crash and evidence handling ─────────────────────────────
async function writeFakeHermes(body) {
  const dir = await tmpDir();
  const file = path.join(dir, "fake-hermes");
  await fs.writeFile(file, `#!/bin/sh\n${body}\n`, "utf8");
  await fs.chmod(file, 0o755);
  return file;
}

test("Hermes tool evidence is parsed from verbose output", () => {
  const evidence = extractHermesEvidence(`
    13:10:25 - root - DEBUG - Tool call: web_search with args: {"query": "x"}...
    ... "success": true, ...
    13:10:26 - root - DEBUG - Tool call: web_fetch with args: {"urls": ["..." ]}...
    ... "success": true, ...
  `);
  assert.equal(evidence.toolCalls, 2);
  assert.equal(evidence.successes, 2);
  assert.deepEqual(evidence.tools, ["web_search", "web_fetch"]);
});

test("a non-zero Hermes exit is a failure even when it printed JSON", async () => {
  const bin = await writeFakeHermes(`echo '{"summary":"looks fine","sources":[]}'; exit 1`);
  const previous = { bin: process.env.MIRA_HERMES_BIN, key: process.env.OPENCODE_GO_API_KEY };
  process.env.MIRA_HERMES_BIN = bin;
  process.env.OPENCODE_GO_API_KEY = "test-key";
  try {
    const outcome = await runHermes({ prompt: "x", timeoutMs: 5_000 });
    assert.equal(outcome.ok, false);
    assert.match(outcome.detail, /code 1/);
  } finally {
    process.env.MIRA_HERMES_BIN = previous.bin;
    process.env.OPENCODE_GO_API_KEY = previous.key;
  }
});

test("a zero-exit Hermes run with JSON but no tool evidence is not a result", async () => {
  const bin = await writeFakeHermes(`echo '{"summary":"no tools were run","sources":[]}'; exit 0`);
  const previous = { bin: process.env.MIRA_HERMES_BIN, key: process.env.OPENCODE_GO_API_KEY };
  process.env.MIRA_HERMES_BIN = bin;
  process.env.OPENCODE_GO_API_KEY = "test-key";
  try {
    const outcome = await runHermes({ prompt: "x", timeoutMs: 5_000 });
    assert.equal(outcome.ok, false);
    assert.match(outcome.detail, /no successful tool evidence/i);
  } finally {
    process.env.MIRA_HERMES_BIN = previous.bin;
    process.env.OPENCODE_GO_API_KEY = previous.key;
  }
});

test("a zero-exit Hermes run with real tool evidence is accepted", async () => {
  const bin = await writeFakeHermes(
    `echo 'Tool call: web_search with args: {"query": "x"}'; echo '"success": true'; echo '{"summary":"Found a page.","sources":[{"title":"t","url":"https://real-site.com/a"}]}'; exit 0`
  );
  const previous = { bin: process.env.MIRA_HERMES_BIN, key: process.env.OPENCODE_GO_API_KEY };
  process.env.MIRA_HERMES_BIN = bin;
  process.env.OPENCODE_GO_API_KEY = "test-key";
  try {
    const outcome = await runHermes({ prompt: "x", timeoutMs: 5_000 });
    assert.equal(outcome.ok, true);
    assert.deepEqual(outcome.result.sources.map((s) => s.url), ["https://real-site.com/a"]);
    assert.equal(outcome.evidence.toolCalls, 1);
  } finally {
    process.env.MIRA_HERMES_BIN = previous.bin;
    process.env.OPENCODE_GO_API_KEY = previous.key;
  }
});

// ── Task routing ─────────────────────────────────────────────────────────────

test("'Find me a fly to sap paulo' is travel to São Paulo, missing departure and dates", async () => {
  const kind = detectTaskKind("Find me a fly to sap paulo");
  assert.equal(kind, "travel");
  const slots = extractSlots(kind, "Find me a fly to sap paulo");
  assert.equal(slots.destination, "Sao Paulo");

  const dir = await tmpDir();
  const service = new TaskService({ dir, autoStart: false, runner: async () => ({ ok: false, detail: "unused" }) });
  await service.load();
  const outcome = await service.handleMessage({ brand: "aurea", conversationId: "c1", message: "Find me a fly to sap paulo" });
  assert.equal(outcome.task.status, TASK_STATUS.NEEDS_INPUT);
  assert.equal(outcome.task.slots.destination, "Sao Paulo");
  assert.deepEqual(outcome.task.missing.sort(), ["dates", "origin"]);
  assert.match(outcome.task.question, /city are you flying from/i);
  assert.match(outcome.task.question, /dates/i);
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("a follow-up supplies the missing slot and the task is queued", async () => {
  const dir = await tmpDir();
  let ran = null;
  const service = new TaskService({
    dir,
    autoStart: true,
    runner: async (task) => {
      ran = task;
      return {
        ok: true,
        result: { title: "Flights", summary: "Sourced routes.", sources: [{ title: "Air", url: "https://air-line.com/lis-gru" }], options: [], blocked: [], nextStep: "Book on the airline.", limitations: "" },
        evidence: { toolCalls: 2, groundedCalls: 1, provenUrls: ["https://air-line.com/lis-gru"], byTool: { web_search: { ok: 1, failed: 0 } } },
      };
    },
  });
  await service.load();
  const first = await service.handleMessage({ brand: "orion", conversationId: "c2", message: "Find me a flight to São Paulo" });
  assert.equal(first.task.status, TASK_STATUS.NEEDS_INPUT);

  const second = await service.handleMessage({ brand: "orion", conversationId: "c2", message: "from Lisbon, 12-19 October" });
  assert.equal(second.created, false);
  assert.equal(second.task.id, first.task.id);
  assert.equal(second.task.slots.origin, "Lisbon");
  assert.match(second.task.slots.dates, /October/i);

  const done = await waitFor(() => {
    const task = service.get(first.task.id);
    return task && [TASK_STATUS.COMPLETED, TASK_STATUS.FAILED].includes(task.status) ? task : null;
  });
  assert.equal(done.status, TASK_STATUS.COMPLETED);
  assert.equal(ran.id, first.task.id);
  assert.equal(service.view(first.task.id, "orion").sources.length, 1);
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("a restaurant request with a city runs immediately and keeps optional details", async () => {
  const dir = await tmpDir();
  const service = new TaskService({ dir, autoStart: false, runner: async () => ({ ok: false, detail: "unused" }) });
  await service.load();
  const outcome = await service.handleMessage({
    brand: "aurea",
    conversationId: "c3",
    message: "Find me a restaurant in São Paulo for 4 on Friday at 8pm",
  });
  assert.equal(outcome.task.kind, "restaurant");
  assert.equal(outcome.task.status, TASK_STATUS.QUEUED);
  assert.equal(outcome.task.slots.location, "São Paulo");
  assert.equal(outcome.task.slots.partySize, "4");
  assert.equal(outcome.task.slots.time, "8pm");
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("account commands are never hijacked into a task", () => {
  assert.equal(looksLikeAccountCommand("what is my balance", {}), true);
  assert.equal(looksLikeAccountCommand("send 20 to Mira Orion", { hasCounterparty: true }), true);
  assert.equal(looksLikeAccountCommand("open card controls", {}), true);
  assert.equal(looksLikeAccountCommand("find me a restaurant in Lisbon", {}), false);
});

test("a task is scoped to one brand and one conversation", async () => {
  const dir = await tmpDir();
  const service = new TaskService({ dir, autoStart: false, runner: async () => ({ ok: false, detail: "unused" }) });
  await service.load();
  const outcome = await service.handleMessage({ brand: "aurea", conversationId: "cX", message: "Find me a restaurant in Lisbon" });
  assert.equal(service.view(outcome.task.id, "orion"), null, "another brand must not see the task");
  assert.ok(service.view(outcome.task.id, "aurea"));
  assert.equal(await service.cancel(outcome.task.id, "orion"), null, "another brand must not cancel the task");
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("a queued task can be cancelled and reports failure honestly", async () => {
  const dir = await tmpDir();
  const service = new TaskService({ dir, autoStart: false, runner: async () => ({ ok: false, detail: "unused" }) });
  await service.load();
  const outcome = await service.handleMessage({ brand: "aurea", conversationId: "c4", message: "Find me a restaurant in Lisbon" });
  const cancelled = await service.cancel(outcome.task.id, "aurea");
  assert.equal(cancelled.status, TASK_STATUS.FAILED);
  assert.match(cancelled.error, /cancelled/i);
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("a failed task can be retried on the same id: error cleared, steps reset, it runs again", async () => {
  const dir = await tmpDir();
  let runs = 0;
  const service = new TaskService({
    dir,
    autoStart: true,
    runner: async () => {
      runs += 1;
      if (runs === 1) return { ok: false, detail: "The page could not be read." };
      return {
        ok: true,
        result: {
          title: "Retried",
          summary: "Sourced on the retry.",
          sources: [{ title: "Page", url: "https://real-site.com/x" }],
          options: [],
          blocked: [],
        },
        evidence: { toolCalls: 1, groundedCalls: 1, provenUrls: ["https://real-site.com/x"], byTool: {} },
      };
    },
  });
  await service.load();
  const created = await service.handleMessage({
    brand: "aurea",
    conversationId: "retry-1",
    message: "Find me a restaurant in Lisbon",
  });
  const failed = await waitFor(() => {
    const task = service.get(created.task.id);
    return task && task.status === TASK_STATUS.FAILED ? task : null;
  });
  assert.match(failed.error, /could not be read/i);

  // Hold the queue so the retry's own shape can be read before the worker
  // picks it up.
  service.autoStart = false;
  const retried = await service.retry(created.task.id, "aurea");
  assert.ok(retried);
  assert.equal(retried.id, created.task.id, "the retry is the same task, never a second one");
  assert.equal(retried.status, TASK_STATUS.QUEUED);
  assert.equal(retried.error, null);
  assert.equal(retried.steps[0].status, "done");
  assert.equal(retried.steps.slice(1).every((step) => step.status === "pending"), true);
  assert.equal(service.get(created.task.id).transientRetries, 0);
  assert.equal(service.get(created.task.id).attempts, 0);
  assert.equal(service.tasks.size, 1);

  service.autoStart = true;
  service.enqueue(created.task.id);
  const done = await waitFor(() => {
    const task = service.get(created.task.id);
    return task && task.status === TASK_STATUS.COMPLETED ? task : null;
  });
  assert.equal(done.status, TASK_STATUS.COMPLETED);
  assert.equal(runs, 2);
  assert.equal(service.tasks.size, 1);
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("retrying a completed task is a no-op: same view, no second run", async () => {
  const dir = await tmpDir();
  let runs = 0;
  const service = new TaskService({
    dir,
    autoStart: true,
    runner: async () => {
      runs += 1;
      return {
        ok: true,
        result: { title: "Result", summary: "s", sources: [], options: [], blocked: [] },
        evidence: { toolCalls: 1, groundedCalls: 1, provenUrls: [], byTool: {} },
      };
    },
  });
  await service.load();
  const created = await service.handleMessage({
    brand: "orion",
    conversationId: "retry-2",
    message: "Find me a restaurant in Lisbon",
  });
  const done = await waitFor(() => {
    const task = service.get(created.task.id);
    return task && task.status === TASK_STATUS.COMPLETED ? task : null;
  });
  const again = await service.retry(created.task.id, "orion");
  assert.equal(again.status, TASK_STATUS.COMPLETED);
  assert.equal(again.summary, done.summary);
  await new Promise((resolve) => setTimeout(resolve, 150));
  assert.equal(runs, 1, "a completed task is never run a second time");
  assert.equal(service.queue.includes(created.task.id), false, "nothing is queued");
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("a task can only be retried by the brand that owns it", async () => {
  const dir = await tmpDir();
  let runs = 0;
  const service = new TaskService({
    dir,
    autoStart: true,
    runner: async () => {
      runs += 1;
      return { ok: false, detail: "The page could not be read." };
    },
  });
  await service.load();
  const created = await service.handleMessage({
    brand: "aurea",
    conversationId: "retry-3",
    message: "Find me a restaurant in Lisbon",
  });
  await waitFor(() => {
    const task = service.get(created.task.id);
    return task && task.status === TASK_STATUS.FAILED ? task : null;
  });

  assert.equal(await service.retry(created.task.id, "orion"), null, "another brand must not retry the task");
  assert.equal(await service.retry("task_00000000000000000000000000000000", "aurea"), null, "an unknown id is refused");
  assert.equal(runs, 1, "a refused retry never runs anything");
  assert.equal(service.get(created.task.id).status, TASK_STATUS.FAILED, "a refused retry leaves the task failed");
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("a failing runner produces a failed task with a reason, never a fake success", async () => {
  const dir = await tmpDir();
  const service = new TaskService({
    dir,
    autoStart: true,
    runner: async () => ({ ok: false, detail: "Every tool call failed or returned nothing." }),
  });
  await service.load();
  const outcome = await service.handleMessage({ brand: "orion", conversationId: "c5", message: "Find me a restaurant in Lisbon" });
  const task = await waitFor(() => {
    const current = service.get(outcome.task.id);
    return current && current.status === TASK_STATUS.FAILED ? current : null;
  });
  assert.match(task.error, /Every tool call failed/);
  assert.equal(service.view(task.id, "orion").status, TASK_STATUS.FAILED);
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("cancelling a running task aborts it and frees the queue for the next task", async () => {
  const dir = await tmpDir();
  let firstStarted = false;
  const service = new TaskService({
    dir,
    autoStart: true,
    concurrency: 1,
    runner: async (task, { signal }) => {
      if (task.slots.location === "Lisbon") {
        firstStarted = true;
        return new Promise((resolve) => {
          const timer = setTimeout(
            () =>
              resolve({
                ok: true,
                result: { title: "late", summary: "late", sources: [], options: [], blocked: [], nextStep: "", limitations: "" },
                evidence: { toolCalls: 1, groundedCalls: 1, provenUrls: [], byTool: {} },
              }),
            5_000
          );
          signal.addEventListener("abort", () => {
            clearTimeout(timer);
            resolve({ ok: false, detail: "cancelled" });
          });
        });
      }
      return {
        ok: true,
        result: { title: "Porto", summary: "s", sources: [], options: [], blocked: [], nextStep: "", limitations: "" },
        evidence: { toolCalls: 1, groundedCalls: 1, provenUrls: [], byTool: {} },
      };
    },
  });
  await service.load();
  const first = await service.handleMessage({ brand: "aurea", conversationId: "ab1", message: "Find me a restaurant in Lisbon" });
  await waitFor(() => (firstStarted ? true : null));
  const second = await service.handleMessage({ brand: "aurea", conversationId: "ab2", message: "Find me a restaurant in Porto" });
  assert.equal(second.task.status, TASK_STATUS.QUEUED);

  const cancelled = await service.cancel(first.task.id, "aurea");
  assert.equal(cancelled.status, TASK_STATUS.FAILED);
  assert.match(cancelled.error, /cancelled/i);

  const done = await waitFor(() => {
    const task = service.get(second.task.id);
    return task && task.status === TASK_STATUS.COMPLETED ? task : null;
  });
  assert.equal(done.status, TASK_STATUS.COMPLETED);

  // The aborted runner resolves later (with a fake "late" result) and must not
  // resurrect the cancelled task.
  await new Promise((resolve) => setTimeout(resolve, 120));
  assert.equal(service.get(first.task.id).status, TASK_STATUS.FAILED);
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("the public view keeps the contract shape with empty collections by default", async () => {
  const dir = await tmpDir();
  const service = new TaskService({ dir, autoStart: false, runner: async () => ({ ok: false, detail: "unused" }) });
  await service.load();
  const outcome = await service.handleMessage({ brand: "aurea", conversationId: "c6", message: "Find me a fly to sap paulo" });
  const view = service.view(outcome.task.id, "aurea");
  assert.deepEqual(Object.keys(view).sort(), [
    "artifacts",
    "brand",
    "caveat",
    "error",
    "id",
    "kind",
    "layout",
    "nextStep",
    "options",
    "question",
    "slots",
    "sources",
    "status",
    "steps",
    "summary",
    "title",
    "watch",
  ]);
  assert.deepEqual(view.sources, []);
  assert.deepEqual(view.artifacts, []);
  // Additive fields a client can ignore: the answer's choices, its next step,
  // and the single caveat.
  assert.deepEqual(view.options, []);
  assert.equal(view.nextStep, null);
  assert.equal(view.caveat, null);
  assert.equal(view.error, null);
  assert.match(view.id, /^task_[a-f0-9]{32}$/);
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("a task that was running when the process died is recovered on load", async () => {
  const dir = await tmpDir();
  await fs.writeFile(
    path.join(dir, "tasks.json"),
    JSON.stringify({
      version: 1,
      tasks: [
        {
          id: "task_0123456789abcdef0123456789abcdef",
          brand: "aurea",
          conversationId: "c7",
          kind: "research",
          title: "Research: x",
          status: "running",
          summary: "",
          slots: { topic: "x" },
          steps: [{ label: "a", status: "done" }, { label: "b", status: "running" }],
          sources: [],
          artifacts: [],
          attempts: 1,
        },
      ],
    }),
    "utf8"
  );
  const service = new TaskService({ dir, autoStart: false, runner: async () => ({ ok: false, detail: "unused" }) });
  await service.load();
  const view = service.view("task_0123456789abcdef0123456789abcdef", "aurea");
  assert.equal(view.status, TASK_STATUS.QUEUED);
  assert.equal(view.steps[1].status, "pending");
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("artifact files are written per task and cannot be read outside their owner", async () => {
  const dir = await tmpDir();
  const service = new TaskService({
    dir,
    autoStart: true,
    runner: async () => ({
      ok: true,
      result: { title: "Result", summary: "s", sources: [], options: [], blocked: [], nextStep: "", limitations: "" },
      evidence: { toolCalls: 1, groundedCalls: 1, provenUrls: ["https://a-site.com/"], byTool: { web_search: { ok: 1, failed: 0 } } },
    }),
  });
  await service.load();
  const outcome = await service.handleMessage({ brand: "aurea", conversationId: "c8", message: "Research the best espresso machines" });
  const task = await waitFor(() => {
    const current = service.get(outcome.task.id);
    return current && current.status === TASK_STATUS.COMPLETED ? current : null;
  });
  assert.equal(task.artifacts.length, 1);
  const name = task.artifacts[0].name;
  assert.ok(service.artifactPath(task.id, "aurea", name));
  assert.equal(service.artifactPath(task.id, "orion", name), null);
  assert.equal(service.artifactPath(task.id, "aurea", "../tasks.json"), null);
  assert.equal(service.artifactPath(task.id, "aurea", "tasks.json"), null, "only registered artifacts are readable");
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("health capability states do not claim a connected vendor", () => {
  const states = getCapability("restaurant");
  assert.equal(states.connector, null);
});

test("health reports the limited runtime as the executor, with Hermes only optional", () => {
  const status = runtimeStatus();
  assert.equal(status.runtime, "limited");
  assert.equal(status.defaultRuntime, "limited");
  assert.equal(status.executors.limited, true);
  assert.equal(status.executors.hermes, false);
  assert.equal(status.hermesOptional.active, false);
  assert.equal(status.tools.web_fetch.guard, "dns-pinned+redirect-validated");
  assert.equal(typeof status.tools.browser_read.available, "boolean");
  assert.match(status.tools.browser_read.mode, /guarded-proxy/);
});

async function waitFor(predicate, { timeoutMs = 4_000, intervalMs = 10 } = {}) {
  const started = Date.now();
  for (;;) {
    const value = predicate();
    if (value) return value;
    if (Date.now() - started > timeoutMs) throw new Error("timed out waiting for condition");
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}

test("a meal to buy asks delivery or eating there first, then where, then runs", async () => {
  const dir = await tmpDir();
  let ran = null;
  const service = new TaskService({
    dir,
    autoStart: false,
    runner: async (task) => {
      ran = task;
      return { ok: false, detail: "unused" };
    },
  });
  await service.load();

  // "I need to buy lunch" — the owner's request. One question, and it is the
  // one that changes the search: is it coming to them, or are they going there.
  const first = await service.handleMessage({
    brand: "aurea",
    conversationId: "meal-1",
    message: "I need to buy lunch",
  });
  assert.equal(first.task.kind, "restaurant");
  assert.equal(first.task.status, TASK_STATUS.NEEDS_INPUT);
  assert.match(first.task.question, /delivery, or eating there\?/i);

  // "delivery" answers it, and the next question is about the place — asked the
  // way a delivery asks it, not the way a table does.
  const second = await service.handleMessage({
    brand: "aurea",
    conversationId: "meal-1",
    message: "delivery",
  });
  assert.equal(second.created, false);
  assert.equal(second.task.id, first.task.id);
  assert.equal(second.task.slots.mode, "delivery");
  assert.equal(second.task.status, TASK_STATUS.NEEDS_INPUT);
  assert.match(second.task.question, /where should it be delivered\?/i);

  // The place arrives, and the task is ready to run.
  const third = await service.handleMessage({
    brand: "aurea",
    conversationId: "meal-1",
    message: "Canasvieiras",
  });
  assert.equal(third.task.slots.location, "Canasvieiras");
  assert.equal(third.task.status, TASK_STATUS.QUEUED);
  assert.equal(third.task.question, null);
  assert.match(third.task.title, /^Delivery/);

  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("a delivered meal answers both questions at once when the answer carries both", async () => {
  const dir = await tmpDir();
  const service = new TaskService({ dir, autoStart: false, runner: async () => ({ ok: false, detail: "unused" }) });
  await service.load();

  const first = await service.handleMessage({
    brand: "orion",
    conversationId: "meal-2",
    message: "I need to order dinner",
  });
  assert.equal(first.task.status, TASK_STATUS.NEEDS_INPUT);
  assert.match(first.task.question, /delivery, or eating there\?/i);

  const second = await service.handleMessage({
    brand: "orion",
    conversationId: "meal-2",
    message: "delivery to Pinheiros",
  });
  assert.equal(second.task.slots.mode, "delivery");
  assert.equal(second.task.slots.location, "Pinheiros");
  assert.equal(second.task.status, TASK_STATUS.QUEUED);

  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("the delivery brief asks for dishes; the dine-in brief asks for venues", () => {
  const capability = getCapability("restaurant");
  const delivery = capability.prompt({ slots: { mode: "delivery", location: "Canasvieiras" }, message: "lunch" });
  assert.match(delivery, /delivery platforms/i);
  assert.match(delivery, /ONE dish/i);
  assert.match(delivery, /never a home page/i);

  const dineIn = capability.prompt({ slots: { mode: "dine-in", location: "Lisbon" }, message: "dinner" });
  assert.match(dineIn, /currently-open restaurants/i);
  assert.doesNotMatch(dineIn, /ONE dish/i);
});

// ── Standing watches ─────────────────────────────────────────────────────────

test("a watch records each check, runs on schedule, and stops on request", async () => {
  const dir = await tmpDir();
  let runs = 0;
  const service = new TaskService({
    dir,
    autoStart: true,
    runner: async () => {
      runs += 1;
      return {
        ok: true,
        result: {
          title: "Watching: Brooks Ghost 15",
          summary: `Check ${runs}: the lowest price seen is USD 110.00 at Running Warehouse.`,
          options: [{ name: "Brooks Ghost 15 — Running Warehouse", url: null, why: "", priceNote: "USD 110.00" }],
          sources: [{ title: "Running Warehouse", url: "https://running.example/ghost-15" }],
        },
        evidence: {
          toolCalls: 1,
          groundedCalls: 1,
          provenUrls: ["https://running.example/ghost-15"],
          byTool: {},
        },
      };
    },
  });
  await service.load();

  const created = await service.handleMessage({
    brand: "aurea",
    conversationId: "watch-1",
    message: "watch the price of the Brooks Ghost 15 under 100 dollars every day",
  });
  assert.equal(created.task.kind, "watch");
  assert.equal(created.task.slots.subject, "Brooks Ghost 15");
  assert.equal(created.task.slots.target, "USD 100");
  assert.equal(created.task.slots.cadence, "daily");

  const done = await waitFor(() => {
    const task = service.get(created.task.id);
    return task && task.status === TASK_STATUS.COMPLETED && task.watch ? task : null;
  });
  const view = service.view(done.id, "aurea");
  assert.equal(view.watch.checkCount, 1);
  assert.equal(view.watch.active, true);
  assert.equal(view.watch.cadence, "daily");
  assert.equal(view.watch.lastPrice, "USD 110.00");
  assert.match(view.watch.lastSummary, /USD 110/);
  assert.ok(view.watch.nextCheckAt > Date.now());

  // The timer finds it due and re-queues it, with no user message involved.
  const task = service.get(done.id);
  task.watch.nextCheckAt = Date.now() - 1000;
  const due = await service.tickWatches();
  assert.equal(due, 1);
  const twice = await waitFor(() => {
    const current = service.get(done.id);
    return current && current.watch?.checkCount === 2 && !["queued", "running"].includes(current.status)
      ? current
      : null;
  });
  assert.equal(twice.watch.checkCount, 2);

  // Stopping keeps the last check and ends the schedule.
  const stopped = await service.stopWatch(done.id, "aurea");
  assert.equal(stopped.watch.active, false);
  assert.equal(stopped.watch.nextCheckAt, null);
  assert.equal(stopped.watch.checkCount, 2);

  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("a watch that failed to check still schedules the next one", async () => {
  const dir = await tmpDir();
  const service = new TaskService({
    dir,
    autoStart: true,
    // A definite failure, not a provider flake: this test is about the check
    // being recorded and rescheduled, not about the retry behaviour.
    runner: async () => ({ ok: false, detail: "The page could not be read." }),
  });
  await service.load();
  const created = await service.handleMessage({
    brand: "orion",
    conversationId: "watch-fail",
    message: "keep an eye on the Pegasus 41 price daily",
  });
  assert.equal(created.task.kind, "watch");

  const failed = await waitFor(() => {
    const task = service.get(created.task.id);
    return task && task.watch && task.watch.checkCount === 1 ? task : null;
  });
  const view = service.view(failed.id, "orion");
  // A failed check is recorded as a failed check; the watch stays alive.
  assert.equal(view.watch.active, true);
  assert.equal(view.watch.lastOk, false);
  assert.ok(view.watch.nextCheckAt > Date.now());
  assert.match(view.watch.lastSummary, /failed|could not/i);

  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("a search looks where the person lives when the message names no place", async () => {
  const dir = await tmpDir();
  const service = new TaskService({ dir, autoStart: false, runner: async () => ({ ok: false, detail: "unused" }) });
  await service.load();
  // The app sends the saved city; the task must use it rather than searching
  // whichever country answers first.
  const local = await service.handleMessage({
    brand: "aurea",
    conversationId: "place-1",
    message: "buy cat food",
    place: "Florianopolis, Brazil",
  });
  assert.equal(local.task.kind, "shopping");
  assert.equal(local.task.slots.location, "Florianopolis, Brazil");

  // A place named in the message wins over the saved one.
  const named = await service.handleMessage({
    brand: "aurea",
    conversationId: "place-2",
    message: "buy cat food in Lisbon",
    place: "Florianopolis, Brazil",
  });
  assert.equal(named.task.slots.location, "Lisbon");

  // A trip is not a local search: the saved city must not become a destination.
  const trip = await service.handleMessage({
    brand: "aurea",
    conversationId: "place-3",
    message: "find me flights to Lisbon in October",
    place: "Florianopolis, Brazil",
  });
  assert.equal(trip.task.slots.destination, "Lisbon");
  assert.notEqual(trip.task.slots.destination, "Florianopolis, Brazil");

  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("a provider flake on a task run is retried, and the person never sees it", async () => {
  const dir = await tmpDir();
  let runs = 0;
  const service = new TaskService({
    dir,
    autoStart: true,
    runner: async () => {
      runs += 1;
      if (runs < 2) return { ok: false, detail: "The model failed to generate a response." };
      return {
        ok: true,
        result: {
          title: "Socks",
          summary: "Answered on the second run.",
          options: [],
          sources: [{ title: "Shop", url: "https://shop.example/socks" }],
        },
        evidence: { toolCalls: 1, groundedCalls: 1, provenUrls: ["https://shop.example/socks"], byTool: {} },
      };
    },
  });
  await service.load();
  const created = await service.handleMessage({ brand: "aurea", conversationId: "flake-1", message: "find me socks" });
  const done = await waitFor(
    () => {
      const task = service.get(created.task.id);
      return task && task.status === TASK_STATUS.COMPLETED ? task : null;
    },
    { timeoutMs: 15_000 }
  );
  assert.equal(done.status, TASK_STATUS.COMPLETED);
  assert.ok(runs >= 2);
  assert.equal(done.error, null);
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});

test("a run that keeps failing stops after the bounded retries and says how many", async () => {
  const dir = await tmpDir();
  let runs = 0;
  const service = new TaskService({
    dir,
    autoStart: true,
    runner: async () => {
      runs += 1;
      return { ok: false, detail: "server_error: The model failed to generate a response." };
    },
  });
  await service.load();
  const created = await service.handleMessage({ brand: "aurea", conversationId: "flake-2", message: "find me socks" });
  const done = await waitFor(
    () => {
      const task = service.get(created.task.id);
      return task && task.status === TASK_STATUS.FAILED ? task : null;
    },
    { timeoutMs: 20_000 }
  );
  assert.equal(runs, 3); // the first run plus two retries
  assert.match(done.error, /tried 3 times/i);
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
});
