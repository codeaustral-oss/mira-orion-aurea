/**
 * Minimal, dependency-free HTML to text.
 *
 * Enough for reading a page the model may cite: drop the parts that are not
 * content (scripts, styles, svg, comments), turn block boundaries into line
 * breaks, decode the common entities and collapse whitespace. It is not a
 * renderer and does not need to be.
 */

const ENTITIES = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  mdash: "—",
  ndash: "–",
  hellip: "…",
  rsquo: "’",
  lsquo: "‘",
  rdquo: "”",
  ldquo: "“",
  middot: "·",
  copy: "©",
  reg: "®",
  trade: "™",
  deg: "°",
  eacute: "é",
  atilde: "ã",
  ccedil: "ç",
  oacute: "ó",
  aacute: "á",
  iacute: "í",
  uacute: "ú",
  ecirc: "ê",
  ocirc: "ô",
  otilde: "õ",
};

export function decodeEntities(text) {
  return String(text || "").replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, (match, entity) => {
    if (entity[0] === "#") {
      const code = entity[1] === "x" || entity[1] === "X" ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
      if (Number.isFinite(code) && code > 0 && code <= 0x10ffff) {
        try {
          return String.fromCodePoint(code);
        } catch {
          return match;
        }
      }
      return match;
    }
    const key = entity.toLowerCase();
    return Object.prototype.hasOwnProperty.call(ENTITIES, key) ? ENTITIES[key] : match;
  });
}

export function extractTitle(html) {
  const match = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(String(html || ""));
  if (!match) return "";
  return decodeEntities(match[1]).replace(/\s+/g, " ").trim().slice(0, 300);
}

/** Convert an HTML document to readable plain text. */
export function htmlToText(html, { maxChars = 12_000 } = {}) {
  let text = String(html || "");
  text = text.replace(/<!--[\s\S]*?-->/g, " ");
  text = text.replace(/<(script|style|noscript|svg|template|iframe|object|canvas)\b[\s\S]*?<\/\1>/gi, " ");
  text = text.replace(/<(script|style|noscript|svg|template|iframe|object|canvas)\b[^>]*\/?>/gi, " ");
  text = text.replace(/<br\s*\/?>/gi, "\n");
  text = text.replace(/<\/(p|div|section|article|header|footer|li|tr|h[1-6]|blockquote|pre|table|ul|ol|dl|dd|dt|figure|figcaption|form|nav|main|aside)>/gi, "\n");
  text = text.replace(/<(p|div|section|article|li|tr|h[1-6]|blockquote|pre|table)\b[^>]*>/gi, "\n");
  text = text.replace(/<[^>]+>/g, " ");
  text = decodeEntities(text);
  text = text.replace(/[ \t\u00a0]+/g, " ");
  text = text.replace(/\n\s*\n\s*\n+/g, "\n\n");
  text = text
    .split("\n")
    .map((line) => line.trim())
    .filter((line, index, lines) => line || (index > 0 && lines[index - 1] !== ""))
    .join("\n")
    .trim();
  if (text.length > maxChars) text = `${text.slice(0, maxChars)}\n[truncated]`;
  return text;
}

/** Map of links found in a document, for source discovery. */
export function extractLinks(html, baseUrl, { limit = 40 } = {}) {
  const links = [];
  const seen = new Set();
  const re = /<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi;
  let match;
  while ((match = re.exec(String(html || ""))) && links.length < limit) {
    const raw = match[1].trim();
    if (!raw || raw.startsWith("#") || /^(javascript|mailto|tel|data):/i.test(raw)) continue;
    let resolved;
    try {
      resolved = new URL(raw, baseUrl).toString();
    } catch {
      continue;
    }
    if (seen.has(resolved)) continue;
    seen.add(resolved);
    links.push({ url: resolved, text: decodeEntities(match[2]).replace(/\s+/g, " ").trim().slice(0, 160) });
  }
  return links;
}

/**
 * The page's own share image, if it declares one.
 *
 * `og:image` first because it is the picture the site chose to represent itself;
 * `twitter:image` and `link rel=image_src` after that. Only absolute http(s)
 * results are returned, so a caller can never be handed something that is not a
 * fetchable URL. Returning null is normal and expected — plenty of good pages
 * have no image at all, and a source without a picture is still a source.
 */
export function extractImage(html, baseUrl) {
  if (!html || typeof html !== "string") return null;
  const head = html.slice(0, 400_000);

  const patterns = [
    /<meta[^>]+property\s*=\s*["']og:image(?::url)?["'][^>]*>/i,
    /<meta[^>]+name\s*=\s*["']twitter:image(?::src)?["'][^>]*>/i,
    /<link[^>]+rel\s*=\s*["']image_src["'][^>]*>/i,
  ];

  const candidates = [];
  for (const pattern of patterns) {
    const tag = head.match(pattern);
    if (!tag) continue;
    const content = tag[0].match(/content\s*=\s*["']([^"']+)["']/i) || tag[0].match(/href\s*=\s*["']([^"']+)["']/i);
    if (content && content[1]) candidates.push(content[1]);
  }

  for (const raw of candidates) {
    const value = decodeEntities(String(raw)).trim();
    if (!value) continue;
    let url;
    try {
      url = new URL(value, baseUrl);
    } catch {
      continue;
    }
    if (url.protocol !== "http:" && url.protocol !== "https:") continue;
    if (!url.host) continue;
    return url.toString().slice(0, 500);
  }
  return null;
}
