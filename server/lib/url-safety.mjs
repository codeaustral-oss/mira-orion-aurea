/**
 * URL and path safety for the task runtime.
 *
 * The task agent is given a live web-search/web-extract toolset, and its
 * results (sources, artifact links, blocked-page reports) flow back into the
 * app. None of that text is trusted: a model can be talked into emitting an
 * internal address, and a retrieval target can be pointed at a metadata
 * service. Everything that becomes a link the user can tap, or a path the
 * server will read, passes through here first.
 *
 * This is deliberately conservative. It is a prototype allowlist, not a
 * general-purpose network filter: only http/https, only publicly routable
 * hosts, never credentials in the URL, never a filesystem path that escapes
 * its base directory.
 */

import { isIP } from "node:net";
import path from "node:path";

const BLOCKED_EXACT = new Set([
  "localhost",
  "localhost.localdomain",
  "metadata",
  "metadata.google.internal",
  "instance-data",
  "0.0.0.0",
]);

const BLOCKED_SUFFIXES = [
  ".local",
  ".localhost",
  ".internal",
  ".intranet",
  ".lan",
  ".home",
  ".corp",
  ".test",
  ".invalid",
  ".example",
  ".onion",
];

function ipv4Blocked(host) {
  const parts = host.split(".");
  if (parts.length !== 4) return true;
  const nums = parts.map((p) => Number(p));
  if (nums.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return true;
  const [a, b] = nums;
  if (a === 0 || a === 10 || a === 127) return true; // this-host, private, loopback
  if (a === 169 && b === 254) return true; // link-local / cloud metadata
  if (a === 172 && b >= 16 && b <= 31) return true; // private
  if (a === 192 && b === 168) return true; // private
  if (a === 100 && b >= 64 && b <= 127) return true; // carrier-grade NAT
  if (a === 198 && (b === 18 || b === 19)) return true; // benchmarking
  if (a >= 224) return true; // multicast / reserved / broadcast
  return false;
}

function ipv6Blocked(host) {
  const h = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (h === "::" || h === "::1") return true; // unspecified / loopback
  if (h.startsWith("fe80") || h.startsWith("fc") || h.startsWith("fd")) return true; // link-local / ULA
  if (h.startsWith("::ffff:")) return ipv4Blocked(h.slice("::ffff:".length)); // v4-mapped
  if (h.startsWith("64:ff9b:")) return true; // NAT64 well-known
  return false;
}

/** True only for an IP literal that is globally routable (not private/loopback/link-local). */
export function isPublicIp(ip) {
  if (typeof ip !== "string" || !ip) return false;
  const bare = ip.replace(/^\[|\]$/g, "").split("%")[0];
  const kind = isIP(bare);
  if (kind === 4) return !ipv4Blocked(bare);
  if (kind === 6) return !ipv6Blocked(bare);
  return false;
}

/**
 * Structural checks that need no DNS: scheme, credentials, hostname shape and
 * IP literals. Returns a machine reason so callers can log why a target was
 * refused. DNS resolution is a separate step (see safe-fetch.mjs) because a
 * public-looking name can still resolve to a private address.
 */
export function assessUrl(raw) {
  if (typeof raw !== "string" || !raw.trim()) return { ok: false, code: "empty_url", reason: "Empty URL." };
  let url;
  try {
    url = new URL(raw.trim());
  } catch {
    return { ok: false, code: "invalid_url", reason: "Not a valid absolute URL." };
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return { ok: false, code: "bad_scheme", reason: `Scheme '${url.protocol.replace(":", "")}' is not allowed.` };
  }
  if (url.username || url.password) {
    return { ok: false, code: "credentials_in_url", reason: "URLs with embedded credentials are not allowed." };
  }
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (!host) return { ok: false, code: "empty_host", reason: "URL has no host." };
  if (BLOCKED_EXACT.has(host)) return { ok: false, code: "blocked_host", reason: `Host '${host}' is not allowed.` };
  if (BLOCKED_SUFFIXES.some((suffix) => host.endsWith(suffix))) {
    return { ok: false, code: "blocked_host", reason: `Host '${host}' is not a public host.` };
  }
  const kind = isIP(host);
  if (kind === 4 || kind === 6) {
    if (!isPublicIp(host)) return { ok: false, code: "blocked_ip", reason: `Address '${host}' is not globally routable.` };
    return { ok: true, url, host, literal: true };
  }
  if (!host.includes(".") || !/\.[a-z]{2,}$/i.test(host)) {
    return { ok: false, code: "blocked_host", reason: `Host '${host}' is not a public host name.` };
  }
  return { ok: true, url, host, literal: false };
}

/** True only for an absolute http(s) URL pointing at a public host. */
export function isSafePublicUrl(raw) {
  if (typeof raw !== "string" || !raw.trim()) return false;
  let url;
  try {
    url = new URL(raw.trim());
  } catch {
    return false;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return false;
  if (url.username || url.password) return false;
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (!host) return false;
  if (BLOCKED_EXACT.has(host)) return false;
  if (BLOCKED_SUFFIXES.some((suffix) => host.endsWith(suffix))) return false;
  const kind = isIP(host);
  if (kind === 4) return !ipv4Blocked(host);
  if (kind === 6) return !ipv6Blocked(host);
  // A public hostname needs at least one dot and a plausible TLD; a bare
  // token ("intranet", "gateway") is not a routable public name.
  if (!host.includes(".")) return false;
  if (!/\.[a-z]{2,}$/i.test(host)) return false;
  return true;
}

/** The trimmed URL when it is safe, otherwise null. */
export function safeUrlOrNull(raw) {
  return isSafePublicUrl(raw) ? String(raw).trim() : null;
}

/**
 * Accept only a single plain filename. Rejects separators, traversal,
 * control characters and names that are not a conservative allowlist.
 */
export function safeArtifactName(name) {
  if (typeof name !== "string" || !name) return null;
  if (name !== path.basename(name)) return null;
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$/.test(name)) return null;
  if (name.includes("..")) return null;
  return name;
}

/**
 * Resolve `parts` under `baseDir`, returning an absolute path only when it
 * stays inside `baseDir`. Used for artifact reads so a crafted name cannot
 * climb out of the task workspace.
 */
export function resolveWithin(baseDir, ...parts) {
  const base = path.resolve(baseDir);
  const target = path.resolve(base, ...parts);
  const rel = path.relative(base, target);
  if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) return null;
  return target;
}
