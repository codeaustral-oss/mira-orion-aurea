/**
 * Read-only browser page inspection.
 *
 * Uses the chromium headless shell already present on this machine (the
 * Playwright cache). It is a *reader*: it navigates to one URL and dumps the
 * DOM. It never clicks, types, submits a form, authenticates or loads a
 * profile.
 *
 * Network isolation is enforced by a local guarded proxy, not by asking
 * chromium to behave:
 *   · chromium is launched with `--proxy-server=127.0.0.1:<port>` and
 *     `--proxy-bypass-list=<-loopback>`, so every request — including
 *     IP-literal URLs and subresources — must pass through the proxy;
 *   · the proxy validates each target (host + port + DNS), refuses any
 *     non-public resolved address, and connects to the validated address
 *     directly. A redirect or a subresource to a private address is refused;
 *   · only GET/HEAD/OPTIONS are proxied, so a page cannot POST a form.
 *
 * If the binary or the proxy cannot start, the tool reports unavailable; it
 * never pretends to have browsed.
 */

import { spawn } from "node:child_process";
import fs from "node:fs";
import fsp from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { validateTarget, validateHostPort } from "./safe-fetch.mjs";
import { htmlToText, extractTitle } from "./html-text.mjs";

const CANDIDATE_ROOTS = [
  path.join(os.homedir(), "Library", "Caches", "ms-playwright"),
  path.join(os.homedir(), ".cache", "ms-playwright"),
];

const BINARY_NAMES = [
  ["chrome-headless-shell-mac-arm64", "chrome-headless-shell"],
  ["chrome-headless-shell-mac-x64", "chrome-headless-shell"],
  ["chrome-headless-shell-linux64", "chrome-headless-shell"],
];

function findBinary() {
  if (process.env.MIRA_BROWSER_BIN && fs.existsSync(process.env.MIRA_BROWSER_BIN)) {
    return process.env.MIRA_BROWSER_BIN;
  }
  for (const root of CANDIDATE_ROOTS) {
    let entries;
    try {
      entries = fs.readdirSync(root, { withFileTypes: true });
    } catch {
      continue;
    }
    const dirs = entries
      .filter((entry) => entry.isDirectory() && entry.name.startsWith("chromium_headless_shell-"))
      .map((entry) => entry.name)
      .sort()
      .reverse();
    for (const dir of dirs) {
      for (const [sub, bin] of BINARY_NAMES) {
        const candidate = path.join(root, dir, sub, bin);
        if (fs.existsSync(candidate)) return candidate;
      }
    }
  }
  return null;
}

let cachedBinary;

export function browserBinary() {
  if (cachedBinary === undefined) cachedBinary = findBinary();
  return cachedBinary;
}

export function browserAvailable() {
  return Boolean(browserBinary());
}

/** Parse `host:port` from a CONNECT line, handling `[::1]:443`. */
export function splitHostPort(value) {
  const text = String(value || "");
  const bracketed = /^\[([^\]]+)\]:(\d+)$/.exec(text);
  if (bracketed) return { host: bracketed[1], port: Number(bracketed[2]) };
  const idx = text.lastIndexOf(":");
  if (idx === -1) return { host: text, port: null };
  return { host: text.slice(0, idx), port: Number(text.slice(idx + 1)) };
}

const READ_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);
const PROXY_PORTS = new Set([80, 443]);

/**
 * Start the guarded forward proxy on an ephemeral loopback port.
 * Exported for tests of the request guard.
 */
export async function startGuardedProxy({ lookup, onBlock } = {}) {
  const sockets = new Set();
  const track = (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    return socket;
  };

  const deny = (res, reason, code = 403) => {
    onBlock?.(reason);
    res.writeHead(code, { "content-type": "text/plain; charset=utf-8", "content-length": Buffer.byteLength(reason) });
    res.end(reason);
  };

  const server = http.createServer(async (req, res) => {
    if (!READ_METHODS.has(req.method)) {
      deny(res, `blocked: method ${req.method} is not allowed in read-only browsing`, 405);
      return;
    }
    let target;
    try {
      target = new URL(req.url);
    } catch {
      deny(res, "blocked: not an absolute URL", 400);
      return;
    }
    if (target.protocol !== "http:") {
      deny(res, "blocked: only http is proxied (https uses CONNECT)", 400);
      return;
    }
    const port = target.port ? Number(target.port) : 80;
    if (!PROXY_PORTS.has(port)) {
      deny(res, `blocked: port ${port} is not allowed`);
      return;
    }
    const guard = await validateHostPort(target.hostname, port, { lookup });
    if (!guard.ok) {
      deny(res, `blocked: ${guard.reason}`);
      return;
    }
    const upstream = http.request(
      {
        host: guard.addresses[0],
        port,
        method: req.method,
        path: `${target.pathname}${target.search}`,
        headers: { ...req.headers, host: target.host },
      },
      (response) => {
        res.writeHead(response.statusCode || 502, response.headers);
        response.pipe(res);
      }
    );
    upstream.on("error", () => {
      if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
      res.end("upstream error");
    });
    req.pipe(upstream);
  });

  server.on("connect", async (req, clientSocket, head) => {
    track(clientSocket);
    const { host, port } = splitHostPort(req.url);
    const connectPort = port ?? 443;
    if (!PROXY_PORTS.has(connectPort)) {
      onBlock?.(`port ${connectPort} is not allowed`);
      clientSocket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
      clientSocket.destroy();
      return;
    }
    const guard = await validateHostPort(host, connectPort, { lookup });
    if (!guard.ok) {
      onBlock?.(guard.reason);
      clientSocket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
      clientSocket.destroy();
      return;
    }
    const upstream = net.connect(guard.port, guard.addresses[0], () => {
      clientSocket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head && head.length) upstream.write(head);
      upstream.pipe(clientSocket);
      clientSocket.pipe(upstream);
    });
    track(upstream);
    upstream.on("error", () => clientSocket.destroy());
    clientSocket.on("error", () => upstream.destroy());
  });

  server.on("connection", track);

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });

  return {
    port: server.address().port,
    close: () =>
      new Promise((resolve) => {
        for (const socket of sockets) socket.destroy();
        server.close(() => resolve());
      }),
  };
}

const CHROME_ERROR =
  /ERR_(NAME_NOT_RESOLVED|CONNECTION_REFUSED|CONNECTION_RESET|CONNECTION_CLOSED|ADDRESS_UNREACHABLE|INTERNET_DISCONNECTED|NAME_RESOLUTION_FAILED|CERT_|SSL_|BLOCKED_BY_CLIENT|EMPTY_RESPONSE|TIMED_OUT|TUNNEL_CONNECTION_FAILED|PROXY_CONNECTION_FAILED|MANDATORY_PROXY_CONFIGURATION_FAILED)/;

/**
 * Navigate to one URL and return its readable text.
 *
 * @returns {Promise<{ok:boolean, url?:string, bytes?:number, text?:string, title?:string, addresses?:string[], code?:string, reason?:string}>}
 */
export async function browserRead(rawUrl, { timeoutMs = 25_000, maxChars = 12_000, lookup, signal } = {}) {
  const bin = browserBinary();
  if (!bin) return { ok: false, code: "browser_unavailable", reason: "No chromium headless shell is installed." };
  if (signal?.aborted) return { ok: false, code: "aborted", reason: "The request was cancelled." };

  const target = await validateTarget(rawUrl, { lookup });
  if (!target.ok) return { ok: false, code: target.code, reason: target.reason };

  let proxy;
  try {
    proxy = await startGuardedProxy({ lookup });
  } catch (err) {
    return { ok: false, code: "proxy_failed", reason: `Could not start the guarded proxy: ${err.message}` };
  }

  let blocked = null;
  const profileDir = await fsp.mkdtemp(path.join(os.tmpdir(), "mira-browser-"));
  const args = [
    "--headless",
    "--disable-gpu",
    "--disable-dev-shm-usage",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-domain-reliability",
    "--disable-client-side-phishing-detection",
    "--disable-sync",
    "--disable-extensions",
    "--disable-quic",
    "--mute-audio",
    "--hide-scrollbars",
    `--user-data-dir=${profileDir}`,
    `--proxy-server=http://127.0.0.1:${proxy.port}`,
    "--proxy-bypass-list=<-loopback>",
    "--virtual-time-budget=6000",
    "--dump-dom",
    target.url.toString(),
  ];

  try {
    return await new Promise((resolve) => {
      let child;
      try {
        child = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"] });
      } catch (err) {
        resolve({ ok: false, code: "browser_failed", reason: `Could not start chromium: ${err.message}` });
        return;
      }
      let stdout = "";
      let settled = false;
      const done = (payload) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (signal) signal.removeEventListener("abort", onAbort);
        resolve(payload);
      };
      const kill = () => {
        try {
          child.kill("SIGKILL");
        } catch {
          /* gone */
        }
      };
      const onAbort = () => {
        kill();
        done({ ok: false, code: "aborted", reason: "The request was cancelled." });
      };
      const timer = setTimeout(() => {
        kill();
        done({ ok: false, code: "timeout", reason: `Chromium did not finish within ${Math.round(timeoutMs / 1000)}s.` });
      }, Math.max(3_000, timeoutMs));
      if (signal) {
        if (signal.aborted) onAbort();
        else signal.addEventListener("abort", onAbort, { once: true });
      }
      child.stdout.on("data", (chunk) => {
        if (stdout.length < maxChars * 4) stdout += chunk.toString();
      });
      child.on("error", (err) => done({ ok: false, code: "browser_failed", reason: `Chromium failed: ${err.message}` }));
      child.on("close", () => {
        if (settled) return;
        if (blocked) {
          done({ ok: false, code: "blocked_private_target", reason: `A page request was blocked: ${blocked}` });
          return;
        }
        if (CHROME_ERROR.test(stdout)) {
          const match = CHROME_ERROR.exec(stdout);
          done({ ok: false, code: "navigation_error", reason: `Chromium could not load the page (${match[1]}).` });
          return;
        }
        const body = htmlToText(stdout, { maxChars });
        if (!body || body.length < 40) {
          done({ ok: false, code: "empty_page", reason: "The page returned no readable text." });
          return;
        }
        done({
          ok: true,
          url: target.url.toString(),
          addresses: target.addresses,
          title: extractTitle(stdout),
          text: body,
          bytes: Buffer.byteLength(body, "utf8"),
        });
      });
    });
  } finally {
    await proxy.close().catch(() => {});
    fsp.rm(profileDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 20 }).catch(() => {});
  }
}
