/**
 * SSRF-guarded retrieval.
 *
 * The task agent's only way to touch the network is through this module (and
 * the guarded browser proxy, which reuses the same checks). Every hop is
 * checked before the request leaves the process:
 *
 *   1. structural check  — http(s) only, no credentials, no blocked host name;
 *   2. DNS check          — the name is resolved and EVERY resolved address
 *                           must be globally routable;
 *   3. IP pinning         — the connection is made to the validated address via
 *                           a custom `lookup` callback, so the transport never
 *                           re-resolves the name. A hostname that answers
 *                           publicly for the check and privately for the
 *                           connection (DNS rebinding) cannot reach the
 *                           private address. Host header and TLS SNI still use
 *                           the real host name;
 *   4. redirect check     — redirects are followed manually and every new
 *                           location goes through 1-3 again before it is
 *                           fetched.
 *
 * Only GET/HEAD, a byte cap, an allowlisted set of text content types and no
 * cookies/auth headers. The timeout covers body reading, not just headers.
 */

import dns from "node:dns/promises";
import http from "node:http";
import https from "node:https";
import net from "node:net";
import { assessUrl, isPublicIp } from "./url-safety.mjs";

export const DEFAULT_ACCEPT = "text/html,application/xhtml+xml,text/plain,application/json,text/markdown;q=0.9,*/*;q=0.1";

const TEXT_CONTENT = [
  "text/html",
  "text/plain",
  "text/markdown",
  "application/xhtml+xml",
  "application/json",
  "application/ld+json",
  "application/xml",
  "text/xml",
];

export function isTextContentType(contentType) {
  if (!contentType) return false;
  const main = String(contentType).split(";")[0].trim().toLowerCase();
  if (TEXT_CONTENT.includes(main)) return true;
  return main.startsWith("text/");
}

function bareHost(host) {
  return String(host || "").replace(/^\[|\]$/g, "").split("%")[0];
}

/** Validate a host+port pair (used by the text fetch and the browser proxy). */
export async function validateHostPort(host, port, { lookup = dns.lookup } = {}) {
  const portNumber = Number(port);
  if (!Number.isInteger(portNumber) || portNumber < 1 || portNumber > 65535) {
    return { ok: false, code: "bad_port", reason: `Port '${port}' is not allowed.` };
  }
  const bare = bareHost(host);
  if (!bare) return { ok: false, code: "empty_host", reason: "Missing host." };
  const url = `http://${net.isIP(bare) === 6 ? `[${bare}]` : bare}:${portNumber}/`;
  const assessed = assessUrl(url);
  if (!assessed.ok) return assessed;
  if (assessed.literal) return { ok: true, host: bare, port: portNumber, addresses: [bare], literal: true };
  let records;
  try {
    records = await lookup(bare, { all: true, verbatim: true });
  } catch (err) {
    return { ok: false, code: "dns_failure", reason: `Could not resolve '${bare}': ${err?.code || err?.message || "lookup failed"}.` };
  }
  const addresses = [...new Set((records || []).map((record) => record?.address).filter(Boolean))];
  if (!addresses.length) return { ok: false, code: "dns_failure", reason: `'${bare}' has no DNS records.` };
  const blocked = addresses.filter((address) => !isPublicIp(address));
  if (blocked.length) {
    return { ok: false, code: "blocked_ip", reason: `'${bare}' resolves to non-public address(es): ${blocked.join(", ")}.` };
  }
  return { ok: true, host: bare, port: portNumber, addresses, literal: false };
}

/**
 * Validate a target URL and resolve its host, refusing any name that resolves
 * to a non-public address.
 *
 * @returns {Promise<{ok:boolean, url?:URL, host?:string, addresses?:string[], code?:string, reason?:string}>}
 */
export async function validateTarget(rawUrl, { lookup = dns.lookup } = {}) {
  const assessed = assessUrl(rawUrl);
  if (!assessed.ok) return assessed;
  const { url, host, literal } = assessed;
  const port = url.port ? Number(url.port) : url.protocol === "https:" ? 443 : 80;
  const hostPort = await validateHostPort(host, port, { lookup });
  if (!hostPort.ok) return hostPort;
  return { ok: true, url, host, port, addresses: hostPort.addresses, literal: hostPort.literal };
}

/**
 * The real transport. Connects to the *validated* address (`addresses[0]`)
 * through the `lookup` option — the hostname is never resolved a second time.
 * `servername`/Host still carry the real host, so TLS and virtual hosting work.
 *
 * @returns {Promise<{status:number, headers:{get:Function}, stream:import("node:stream").Readable}>}
 */
export function pinnedHttpTransport({ url, method = "GET", headers = {}, signal, addresses = [] }) {
  return new Promise((resolve, reject) => {
    const pinned = addresses[0];
    if (!pinned) {
      reject(new Error("no validated address to connect to"));
      return;
    }
    const family = net.isIP(pinned) === 6 ? 6 : 4;
    const mod = url.protocol === "https:" ? https : http;
    // Node may ask with `all: true` (Happy Eyeballs). Either way the answer is
    // always the one validated address — never a fresh DNS lookup.
    const lookup = (_hostname, options, callback) => {
      if (options && options.all) callback(null, [{ address: pinned, family }]);
      else callback(null, pinned, family);
    };
    const options = {
      method,
      headers,
      signal,
      lookup,
      autoSelectFamily: false,
      host: pinned, // connect target; Host header below keeps the real name
      hostname: url.hostname,
      port: url.port || undefined,
      path: `${url.pathname}${url.search}`,
      setHost: true,
      ...(url.protocol === "https:" ? { servername: url.hostname } : {}),
    };
    const request = mod.request(options, (response) => {
      resolve({
        status: response.statusCode || 0,
        headers: { get: (name) => response.headers[String(name).toLowerCase()] ?? null },
        stream: response,
      });
    });
    request.on("error", reject);
    request.end();
  });
}

async function readCapped(response, maxBytes) {
  const chunks = [];
  let total = 0;
  let truncated = false;
  const stream = response.stream;
  if (stream && typeof stream[Symbol.asyncIterator] === "function") {
    try {
      for await (const chunk of stream) {
        const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        if (total + buffer.length > maxBytes) {
          chunks.push(buffer.subarray(0, Math.max(0, maxBytes - total)));
          total = maxBytes;
          truncated = true;
          stream.destroy?.();
          break;
        }
        chunks.push(buffer);
        total += buffer.length;
      }
    } catch (err) {
      if (!truncated) throw err;
    }
  } else if (response.body && typeof response.body.getReader === "function") {
    const reader = response.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      const buffer = Buffer.from(value);
      total += buffer.length;
      if (total > maxBytes) {
        truncated = true;
        await reader.cancel().catch(() => {});
        break;
      }
      chunks.push(buffer);
    }
  } else if (typeof response.text === "function") {
    const text = await response.text();
    const buffer = Buffer.from(text.slice(0, maxBytes), "utf8");
    return { text: buffer.toString("utf8"), bytes: buffer.length, truncated: text.length > maxBytes };
  }
  const body = Buffer.concat(chunks);
  return { text: body.toString("utf8"), bytes: body.length, truncated };
}

/**
 * Fetch a public text resource with a hard timeout covering headers *and* body,
 * a byte cap, IP pinning and a manual, re-validated redirect chain.
 */
export async function safeFetch(rawUrl, {
  method = "GET",
  timeoutMs = 15_000,
  maxBytes = 1_200_000,
  maxRedirects = 4,
  accept = DEFAULT_ACCEPT,
  userAgent = "MiraTaskBot/0.1 (read-only research)",
  transport = pinnedHttpTransport,
  lookup = dns.lookup,
  signal,
} = {}) {
  if (method !== "GET" && method !== "HEAD") {
    return { ok: false, code: "bad_method", reason: "Only GET and HEAD are allowed." };
  }
  const redirects = [];
  let current = String(rawUrl || "").trim();

  for (let hop = 0; hop <= maxRedirects; hop += 1) {
    const target = await validateTarget(current, { lookup });
    if (!target.ok) return { ok: false, code: target.code, reason: target.reason, redirects };

    const controller = new AbortController();
    const onExternalAbort = () => controller.abort();
    let timeout = false;
    const timer = setTimeout(() => {
      timeout = true;
      controller.abort();
    }, Math.max(1_000, timeoutMs));
    if (signal) {
      if (signal.aborted) controller.abort();
      else signal.addEventListener("abort", onExternalAbort, { once: true });
    }

    try {
      const response = await transport({
        url: target.url,
        method,
        headers: { accept, "user-agent": userAgent, "accept-encoding": "identity", host: target.url.host },
        signal: controller.signal,
        addresses: target.addresses,
      });

      const location = response.headers?.get?.("location");
      if (response.status >= 300 && response.status < 400 && location) {
        response.stream?.destroy?.();
        let next;
        try {
          next = new URL(location, target.url).toString();
        } catch {
          return { ok: false, code: "bad_redirect", reason: `Redirect from '${target.host}' had an unusable location.`, redirects };
        }
        if (redirects.length >= maxRedirects) {
          return { ok: false, code: "too_many_redirects", reason: "Too many redirects.", redirects };
        }
        redirects.push(next);
        current = next;
        continue;
      }

      if (response.status >= 400) {
        response.stream?.destroy?.();
        return {
          ok: false,
          status: response.status,
          code: "http_error",
          reason: `'${target.host}' answered HTTP ${response.status}.`,
          finalUrl: target.url.toString(),
          redirects,
        };
      }

      const contentType = response.headers?.get?.("content-type") || "";
      if (!isTextContentType(contentType)) {
        response.stream?.destroy?.();
        return {
          ok: false,
          status: response.status,
          contentType,
          code: "unsupported_content",
          reason: `'${target.host}' returned non-text content (${contentType || "unknown"}).`,
          finalUrl: target.url.toString(),
          redirects,
        };
      }

      const { text, bytes, truncated } = await readCapped(response, maxBytes);
      return {
        ok: true,
        status: response.status,
        contentType,
        body: text,
        bytes,
        truncated,
        finalUrl: target.url.toString(),
        redirects,
        addresses: target.addresses,
      };
    } catch (err) {
      const aborted = err?.name === "AbortError" || controller.signal.aborted;
      if (signal?.aborted) return { ok: false, code: "aborted", reason: "The request was cancelled.", redirects };
      return {
        ok: false,
        code: timeout || aborted ? "timeout" : "fetch_failed",
        reason: timeout || aborted ? `Request to '${target.host}' timed out.` : `Request to '${target.host}' failed: ${err?.message || err}.`,
        redirects,
      };
    } finally {
      clearTimeout(timer);
      if (signal) signal.removeEventListener("abort", onExternalAbort);
    }
  }

  return { ok: false, code: "too_many_redirects", reason: "Too many redirects.", redirects };
}
