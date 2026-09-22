/**
 * Controlled artifact writer.
 *
 * Tasks can produce a user-facing document (a comparison, a plan, a
 * checklist). The agent never writes files itself — it only returns JSON —
 * and the server writes one Markdown file per task inside the task store's
 * own directory. Names are slugged to a conservative allowlist and reads are
 * confined to that directory, so a task cannot name its way into the
 * filesystem.
 */

import fs from "node:fs/promises";
import path from "node:path";
import { safeArtifactName, resolveWithin } from "./url-safety.mjs";

export function slugify(value) {
  return String(value || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);
}

/**
 * Write the artifact and return the app-facing descriptor.
 * `artifactDir` is created if missing.
 */
export async function writeArtifact(artifactDir, taskId, { title, markdown }) {
  await fs.mkdir(artifactDir, { recursive: true });
  const safeTask = slugify(taskId) || "task";
  const safeTitle = slugify(title) || "result";
  const name = `${safeTask}-${safeTitle}.md`;
  const target = resolveWithin(artifactDir, name);
  if (!target) throw new Error("artifact path escaped its workspace");
  await fs.writeFile(target, String(markdown || ""), "utf8");
  return {
    title: String(title || "Prepared result").slice(0, 200),
    name,
    url: `/v1/artifacts/${encodeURIComponent(taskId)}/${encodeURIComponent(name)}`,
    mimeType: "text/markdown",
    bytes: Buffer.byteLength(String(markdown || ""), "utf8"),
  };
}

/** Resolve a stored artifact for download, or null when unsafe/absent. */
export function resolveArtifact(artifactDir, taskId, name) {
  const safeName = safeArtifactName(name);
  if (!safeName) return null;
  return resolveWithin(artifactDir, safeName);
}

export async function readArtifact(artifactDir, taskId, name) {
  const target = resolveArtifact(artifactDir, taskId, name);
  if (!target) return null;
  try {
    const body = await fs.readFile(target, "utf8");
    return { path: target, body };
  } catch {
    return null;
  }
}

export function artifactDirFor(baseDir) {
  return path.join(baseDir, "artifacts");
}
