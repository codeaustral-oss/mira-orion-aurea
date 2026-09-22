/**
 * OpenCode Go credentials, and how the server picks one.
 *
 * Three accounts are configured, because one account's rate limit should not be
 * the assistant's rate limit: the first key that works becomes the preferred
 * one, and a 429 / 5xx / timeout on the preferred key moves the next call to the
 * next key rather than failing.
 *
 * Keys are read from the process environment only. They are never logged, never
 * returned in a response, and never written to a file. The one thing this module
 * exposes to the rest of the server is a count.
 *
 * Accepted shapes:
 *   OPENCODE_GO_API_KEY        the primary key
 *   OPENCODE_GO_API_KEY_2..N   further accounts
 *   OPENCODE_GO_API_KEYS       a comma- or whitespace-separated list, appended
 */

function parseKeys() {
  const raw = [];
  const push = (value) => {
    if (!value) return;
    for (const piece of String(value).split(/[\s,]+/)) {
      const key = piece.trim();
      if (key) raw.push(key);
    }
  };

  push(process.env.OPENCODE_GO_API_KEY);
  push(process.env.OPENCODE_GO_API_KEYS);
  for (let index = 2; index <= 9; index += 1) push(process.env[`OPENCODE_GO_API_KEY_${index}`]);

  // Deduplicate without printing anything.
  return [...new Set(raw)];
}

let KEYS = parseKeys();
let preferred = 0;
/**
 * Accounts the provider refused outright (401/403: the wrong region, or no
 * access to this model). A refusal is not a rate limit, and retrying it just
 * burns the run, so it is remembered for the life of the process.
 */
const refused = new Set();

/**
 * Read the environment fresh rather than freezing it at import: the server
 * loads configuration around module import time, and tests set credentials on
 * the process after importing this module.
 */
function keys() {
  KEYS = parseKeys();
  return KEYS;
}

/** How many credentials the server holds. Never which ones. */
export function keyCount() {
  return keys().length;
}

export function keysConfigured() {
  return keys().length > 0;
}

/** The key to try first. */
export function currentKey() {
  return keys()[preferred] || "";
}

/**
 * The keys in the order they should be attempted: the preferred key first, then
 * the rest, so one working account keeps working.
 */
export function orderedKeys() {
  const list = keys();
  if (list.length === 0) return [];
  const order = [];
  for (let offset = 0; offset < list.length; offset += 1) {
    const index = (preferred + offset) % list.length;
    if (refused.has(index) && refused.size < list.length) continue;
    order.push({ key: list[index], index });
  }
  // If every account has been refused at some point, clear the slate rather
  // than returning nothing: a refusal may have been temporary or model-specific.
  if (order.length === 0) {
    refused.clear();
    for (let index = 0; index < list.length; index += 1) order.push({ key: list[index], index });
  }
  return order;
}

/** An account the provider refused for this model. Skipped from now on. */
export function noteKeyRefused(index) {
  if (Number.isInteger(index) && index >= 0 && index < keys().length) refused.add(index);
}

/** Remember the account that just answered, so the next call starts there. */
export function noteKeyWorked(index) {
  if (Number.isInteger(index) && index >= 0 && index < KEYS.length) preferred = index;
}

/** Test seam: pretend nothing has been learned yet. */
export function resetKeyPreference() {
  preferred = 0;
}
