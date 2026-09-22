/** Extract the last balanced JSON object from free text. Shared by the runtimes. */
export function extractJsonObject(text) {
  if (typeof text !== "string") return null;
  const candidates = [];
  for (let start = 0; start < text.length; start += 1) {
    if (text[start] !== "{") continue;
    let depth = 0;
    let inString = false;
    let escaped = false;
    for (let i = start; i < text.length; i += 1) {
      const c = text[i];
      if (inString) {
        if (escaped) escaped = false;
        else if (c === "\\") escaped = true;
        else if (c === '"') inString = false;
        continue;
      }
      if (c === '"') inString = true;
      else if (c === "{") depth += 1;
      else if (c === "}") {
        depth -= 1;
        if (depth === 0) {
          try {
            candidates.push(JSON.parse(text.slice(start, i + 1)));
          } catch {
            /* not valid JSON at this boundary */
          }
          break;
        }
      }
    }
  }
  for (let i = candidates.length - 1; i >= 0; i -= 1) {
    const candidate = candidates[i];
    if (
      candidate &&
      typeof candidate === "object" &&
      ("summary" in candidate || "options" in candidate || "sources" in candidate || "question" in candidate)
    ) {
      return candidate;
    }
  }
  return candidates.length ? candidates[candidates.length - 1] : null;
}
