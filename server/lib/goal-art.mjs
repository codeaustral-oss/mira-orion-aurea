/**
 * Live goal art: the picture for a dream the person just named.
 *
 * WHY this file exists: "What are you saving for?" deserves a card, not an
 * error. The person types a few words, the proxy turns them into one image,
 * and the app polls a small status surface while the card shows a drawing
 * state.
 *
 * Two backends draw that image, chosen by whether a Fal key is present:
 *
 *   · On a hosted server (`FAL_KEY` set) the picture comes from Fal's queue:
 *     `meta/muse-image/text-to-image` draws it on a plain white field, then
 *     `fal-ai/imageutils/rembg` restores the genuine alpha the curated
 *     collection ships with. A failed cutout is not a failed drawing — the raw
 *     render stands in, with one log line saying so.
 *   · On a local Mac (no key) it comes from `scripts/gen-image.sh`, the exact
 *     pipeline the static art ships from, unchanged.
 *
 * Either way the bytes land through the same part-file contract, so a crash
 * never leaves a half-written PNG looking ready, and `/health` names the
 * backend in use.
 *
 * INTEGRATION FACT: the iOS app falls back to its own local library matcher on
 * ANY failure here — a 4xx, a 5xx, an unreachable proxy, a poll that never
 * settles. Errors must therefore be honest and fast: a "ready" that is not true
 * is worse than a "failed" the app can route around, and a request that cannot
 * succeed says so immediately instead of holding the drawing state open.
 *
 * Three rules make the surface small and restart-proof:
 *
 *   · The state of a job is the file. `art/goals/generated/<id>.png` is the
 *     only durable record, so a restart never loses a finished image.
 *   · The id is stable: brand + slug + a short hash of the words. The same ask
 *     resolves to the same id, and a second ask is instant because the file
 *     already exists. A file that exists is never written again.
 *   · One generation runs at a time. Image generation is expensive and there
 *     is one person in front of the demo; a second ask joins the queue rather
 *     than starting a competing process.
 *
 * The prompt comes from `art/goals/style.json` — the single source of truth
 * for live prompts (docs/demo-cast.md §0.4). When the file or a brand's block
 * is missing, a compact built-in template in the same art direction is used,
 * so the feature works from a clean checkout.
 */

import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

/** The brands the cast actually has, and the only two this surface serves. */
export const GOAL_ART_BRANDS = ["orion", "aurea"];

export const GOAL_ART_WORDS_MIN = 3;
export const GOAL_ART_WORDS_MAX = 120;
export const GOAL_ART_NAME_MAX = 60;

/** Image generation is slow; the app shows a drawing state, not a spinner. */
export const GOAL_ART_DEFAULT_TIMEOUT_MS = 240_000;

/** One image, whatever the run produced. */
const QUALITY = "high";

/** The hosted live path: Fal's queue for the render, then a cutout for alpha. */
const FAL_QUEUE_BASE = "https://queue.fal.run";
const FAL_MUSE_MODEL = "meta/muse-image/text-to-image";
const FAL_CUTOUT_MODEL = "fal-ai/imageutils/rembg";
const FAL_POLL_INTERVAL_MS = 1750;

/**
 * The compact built-in style, used when `art/goals/style.json` or a brand's
 * block is missing. It follows the same art direction as the static sets: the
 * Orion isometric diorama and the Aurea vintage postcard, both on a genuine
 * alpha channel with no lettering anywhere.
 */
const FALLBACK_STYLE = {
  orion: {
    scene_style:
      "A soft matte studio render of one miniature object, chunky simplified forms with clean geometry, " +
      "gentle ambient occlusion, one clear subject per scene, isometric three-quarter camera near top-down, " +
      "a soft contact shadow, matte materials only, palette of soft black, warm white and silver grey with " +
      "one restrained pastel accent, centred with generous margin, consistent upper-left light.",
    subject_template: "The dream is {subject}, kept for {name}. Build it as a shelf-sized miniature diorama of {subject}.",
    avoid:
      "no text, lettering, numbers, logos, people, hands, screens with UI, chrome, neon, glossy plastic, " +
      "gradients or busy backgrounds",
  },
  aurea: {
    scene_style:
      "A single aged vintage postcard on a genuine alpha channel, tilted two to four degrees with a soft " +
      "contact shadow: cream paper with visible fibres and a faint patina, a perforated stamp corner with a " +
      "small engraved stamp, a few abstract cancellation marks with no lettering, and on the postcard a small " +
      "luminous Renaissance oil vignette with a thin printed border and quiet margins, warm daylight, broad " +
      "economical brushwork, aged varnish, muted and reverent, never muddy or black.",
    subject_template: "The dream is {subject}, kept for {name}. Paint it as the postcard's vignette: {subject}.",
    avoid:
      "no text, lettering, numbers, signatures, watermarks, figures with recognisable faces, modern objects, " +
      "neon or HDR",
  },
};

/** The hard rule every live prompt ends with, whatever the style file says. */
const CRAFT_LINE =
  "One image only. No text, lettering, numbers, logos or watermarks anywhere. " +
  "Subject centred with a generous margin; output a single square PNG on a genuine alpha channel.";

/**
 * The extra instruction the Fal path appends after the craft line: muse paints
 * a background of its own choosing, so it is asked for a flat white field the
 * cutout can key out. The curated collection was drawn without this line (its
 * alpha is genuine); this is a live-path addition, and `rembg` restores the
 * alpha the craft line promises. Exported so the tests pin the exact words.
 */
export const CUTOUT_BACKGROUND_LINE =
  "Render the subject isolated on a plain, uniform pure-white background, " +
  "no shadow cast onto the background, no frame, centred with generous margin.";

// ── The id ───────────────────────────────────────────────────────────────────

/**
 * A slug a filename can carry: lowercase ASCII, words joined by dashes.
 * Words in another script slugify to an empty string (the hash still tells
 * them apart), which is why the caller falls back to "dream".
 */
export function slugifyWords(words) {
  return String(words ?? "")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48)
    .replace(/-+$/g, "");
}

/** FNV-1a, 64-bit, as hex. Short, stable, and no dependency. */
function fnv1a(text) {
  let hash = 0xcbf29ce484222325n;
  const prime = 0x100000001b3n;
  for (const char of String(text)) {
    hash ^= BigInt(char.codePointAt(0));
    hash = (hash * prime) & 0xffffffffffffffffn;
  }
  return hash.toString(16).padStart(16, "0");
}

function canonicalWords(words) {
  return String(words ?? "").trim().replace(/\s+/g, " ").toLowerCase();
}

function canonicalName(name) {
  return String(name ?? "").trim().replace(/\s+/g, " ").toLowerCase();
}

/**
 * The id for a dream, from the brand and the words.
 *
 * The slug is for a human reading a directory listing; the hash is what makes
 * the id exact — two word sets that slugify the same ("a month in Tokyo" and
 * "a-month-in-tokyo!") must never share a file. The display name joins the
 * hash because it joins the prompt: the same words for two people are two
 * pictures, and serving one person the other's card would be a quiet lie.
 *
 * @param {{brand:string, words:string, name?:string}} input
 * @returns {string} e.g. `aurea-a-month-in-tokyo-1f2e3d4c5b`
 */
export function goalArtId({ brand, words, name = "" } = {}) {
  const slug = slugifyWords(words) || "dream";
  const hash = fnv1a(`${brand}\u0000${canonicalWords(words)}\u0000${canonicalName(name)}`).slice(0, 10);
  return `${brand}-${slug}-${hash}`;
}

/** True for the only shape an id may have: never a path, never a dotfile. */
export function isGoalArtId(value) {
  return (
    typeof value === "string" &&
    value.length <= 80 &&
    /^(?:orion|aurea)-[a-z0-9]+(?:-[a-z0-9]+)*$/.test(value)
  );
}

/** The URL the app polls and fetches; the id is the whole path component. */
export function goalArtUrl(id) {
  return `/v1/goal-art/${id}/image`;
}

// ── Validation ───────────────────────────────────────────────────────────────

function invalid(error, detail) {
  return { ok: false, status: 400, error, detail };
}

/**
 * The request contract of `POST /v1/goal-art`, in one place so the route and
 * the module tests read the same rules:
 *
 *   brand  exactly "orion" or "aurea" — never defaulted;
 *   words  a string, 3 to 120 characters after trimming;
 *   name   optional, a string of at most 60 characters.
 *
 * @returns {{ok:true, brand:string, words:string, name:string}
 *          | {ok:false, status:number, error:string, detail:string}}
 */
export function validateGoalArtRequest(payload) {
  const body = payload && typeof payload === "object" ? payload : {};

  if (!GOAL_ART_BRANDS.includes(body.brand)) {
    return invalid("brand_required", "brand must be aurea or orion.");
  }

  if (typeof body.words !== "string") {
    return invalid("words_required", "Provide the dream in a few words.");
  }
  const words = body.words.trim().replace(/\s+/g, " ");
  if (words.length < GOAL_ART_WORDS_MIN) {
    return invalid("words_too_short", `Describe the dream in at least ${GOAL_ART_WORDS_MIN} characters.`);
  }
  if (words.length > GOAL_ART_WORDS_MAX) {
    return invalid("words_too_long", `Keep the dream under ${GOAL_ART_WORDS_MAX} characters.`);
  }

  let name = "";
  if (body.name !== undefined && body.name !== null) {
    if (typeof body.name !== "string") {
      return invalid("name_invalid", "The name must be text.");
    }
    name = body.name.trim().replace(/\s+/g, " ");
    if (name.length > GOAL_ART_NAME_MAX) {
      return invalid("name_too_long", `Keep the name under ${GOAL_ART_NAME_MAX} characters.`);
    }
  }

  return { ok: true, brand: body.brand, words, name };
}

// ── The prompt ───────────────────────────────────────────────────────────────

function text(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

/** Tidy the seams a filled template can leave behind. */
function tidy(value) {
  return String(value)
    .replace(/\(\s*(?:for\s*)?\)/gi, "")
    .replace(/\s+([,.;:!?])/g, "$1")
    .replace(/\s{2,}/g, " ")
    .trim();
}

/**
 * Remove the clause that carried a name nobody gave — a parenthetical, a
 * bracket, or a comma-separated phrase — so "The dream is X, kept for Y."
 * becomes "The dream is X." rather than a sentence with a hole in it.
 */
function stripNameClauses(value) {
  return String(value)
    .replace(/\s*\([^()]*\{name\}[^()]*\)/g, "")
    .replace(/\s*\[[^\[\]]*\{name\}[^\[\]]*\]/g, "")
    .replace(/,\s*[^,.!?;:]*\{name\}[^,.!?;:]*/g, "")
    .trim();
}

/**
 * Fill `subject_template` with the person's words and display name.
 *
 * Placeholders: `{subject}` (the words; `{words}` is the same thing),
 * `{brief}` (the words, and whose dream they are) and `{name}`. A template
 * with no placeholder is read as a lead-in and the words are appended. A
 * `{name}` in the template when the person gave no name is not filled with an
 * invention: the clause that used it is dropped, or the sentence that needed
 * it, never left as a hole.
 */
export function renderSubject(template, { words, name = "" } = {}) {
  const source = String(template ?? "").trim();
  const brief = name ? `${words} (a dream of ${name})` : words;
  if (!source) return brief;

  let filled = source
    .replace(/\{subject\}/g, words)
    .replace(/\{words\}/g, words)
    .replace(/\{brief\}/g, brief);
  if (name) {
    filled = filled.replace(/\{name\}/g, name);
  } else if (filled.includes("{name}")) {
    filled = stripNameClauses(filled);
    if (filled.includes("{name}")) {
      // The sentence itself needs a name; it goes rather than reads broken.
      filled = filled
        .split(/(?<=[.!?])\s+/)
        .filter((sentence) => !sentence.includes("{name}"))
        .join(" ");
    }
    filled = filled.replace(/\{name\}/g, "");
  }

  filled = tidy(filled);
  if (!filled) return brief;
  if (/\{(?:subject|words|brief|name)\}/.test(source)) return filled;
  return `${filled.replace(/[.:;,\s]+$/, "")}: ${brief}.`;
}

/**
 * The style block for one brand, from `art/goals/style.json`. A file that is
 * missing, unreadable, not JSON, or without that brand's substance is not a
 * style — the built-in template answers instead, so a half-written style file
 * can never produce a half-written prompt.
 */
async function readBrandStyle(brand, stylePath) {
  const fallback = FALLBACK_STYLE[brand] ?? FALLBACK_STYLE.orion;
  let parsed = null;
  try {
    parsed = JSON.parse(await fs.readFile(stylePath, "utf8"));
  } catch {
    return fallback;
  }
  const block = parsed && typeof parsed === "object" ? parsed[brand] : null;
  if (!block || typeof block !== "object") return fallback;
  const sceneStyle = text(block.scene_style);
  const subjectTemplate = text(block.subject_template);
  if (!sceneStyle || !subjectTemplate) return fallback;
  return {
    scene_style: sceneStyle,
    subject_template: subjectTemplate,
    avoid: text(block.avoid) || fallback.avoid,
  };
}

/**
 * The prompt for one dream: the brand's scene style, the subject filled with
 * the words and the name, the avoid list, and the shared craft line.
 *
 * `cutout: true` is the Fal path: it appends the flat-white-background
 * instruction the cutout step needs. The script path keeps the exact prompt
 * the curated collection was drawn with.
 *
 * @param {{brand:string, words:string, name?:string}} input
 * @param {{stylePath?:string, cutout?:boolean}} [options]
 * @returns {Promise<string>}
 */
export async function composePrompt(
  { brand, words, name = "" } = {},
  { stylePath = defaultStylePath(), cutout = false } = {}
) {
  const style = await readBrandStyle(brand, stylePath);
  const parts = [style.scene_style, renderSubject(style.subject_template, { words, name })];
  if (style.avoid) parts.push(`Avoid: ${/[.!?]$/.test(style.avoid) ? style.avoid : `${style.avoid}.`}`);
  parts.push(CRAFT_LINE);
  if (cutout) parts.push(CUTOUT_BACKGROUND_LINE);
  return parts.join("\n\n");
}

function defaultStylePath() {
  return path.join(REPO_ROOT, "art", "goals", "style.json");
}

// ── The service ──────────────────────────────────────────────────────────────

async function exists(file) {
  try {
    await fs.stat(file);
    return true;
  } catch {
    return false;
  }
}

/** The last few lines of a failure, which is what a person debugging needs. */
function tail(value, lines = 12, cap = 1600) {
  const trimmed = String(value ?? "").trim();
  if (!trimmed) return "";
  return trimmed.split("\n").slice(-lines).join("\n").slice(-cap);
}

/** Fal error bodies are JSON of any shape; a diagnosis starts with the text. */
function renderDetail(value) {
  if (value == null) return "";
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

/** The first image URL a muse response carries, or an honest failure. */
function firstImageUrl(payload) {
  const images = Array.isArray(payload?.images) ? payload.images : [];
  const url = images.find((image) => typeof image?.url === "string" && image.url.trim())?.url;
  if (!url) throw new Error(`Fal returned no image. ${tail(renderDetail(payload))}`.trim());
  return url;
}

/**
 * One live-art service: the queue, the ids and the file rules, with the
 * generator injectable so the tests can stand in for codex and for Fal.
 *
 * The backend follows the key: `FAL_KEY` in the environment (or `options.falKey`)
 * draws through Fal's queue, and no key keeps the local `scripts/gen-image.sh`
 * path exactly as it was. The HTTP layer is injectable for the same reason —
 * every test stubs `options.fetchImpl`, never the real queue.
 *
 * @param {{
 *   root?:string, dir?:string, stylePath?:string, script?:string,
 *   quality?:string, timeoutMs?:number, spawnImpl?:Function,
 *   falKey?:string, fetchImpl?:Function, pollIntervalMs?:number,
 * }} [options]
 */
export function createGoalArt(options = {}) {
  const root = options.root ? path.resolve(options.root) : REPO_ROOT;
  const dir = options.dir ? path.resolve(options.dir) : path.join(root, "art", "goals", "generated");
  const stylePath = options.stylePath ? path.resolve(options.stylePath) : defaultStylePath();
  const scriptPath = options.script ? path.resolve(options.script) : path.join(root, "scripts", "gen-image.sh");
  const quality = options.quality || QUALITY;
  const spawnImpl = options.spawnImpl || spawn;
  const timeoutMs =
    Number.isFinite(Number(options.timeoutMs)) && Number(options.timeoutMs) > 0
      ? Number(options.timeoutMs)
      : GOAL_ART_DEFAULT_TIMEOUT_MS;
  const falKey = String(options.falKey ?? process.env.FAL_KEY ?? "").trim();
  const backend = falKey ? "fal" : "script";
  const fetchImpl = typeof options.fetchImpl === "function" ? options.fetchImpl : fetch;
  const pollIntervalMs =
    Number.isFinite(Number(options.pollIntervalMs)) && Number(options.pollIntervalMs) >= 0
      ? Number(options.pollIntervalMs)
      : FAL_POLL_INTERVAL_MS;

  /** id → the job's promise, while it is running. */
  const generating = new Map();
  /** id → { detail, at } for the last failure. In memory only: a restart retries. */
  const failures = new Map();
  const FAILURE_LIMIT = 25;

  /** One generation at a time; the chain keeps the order the asks arrived in. */
  let chain = Promise.resolve();
  function enqueue(work) {
    const run = chain.then(work, work);
    chain = run.then(
      () => undefined,
      () => undefined
    );
    return run;
  }

  function fileFor(id) {
    return path.join(dir, `${id}.png`);
  }

  function partFor(id) {
    return path.join(dir, `.${id}.part.png`);
  }

  function recordFailure(id, detail) {
    failures.set(id, { detail, at: Date.now() });
    while (failures.size > FAILURE_LIMIT) {
      const oldest = failures.keys().next().value;
      failures.delete(oldest);
    }
  }

  /**
   * Run `scripts/gen-image.sh <out> <prompt> high` from the repo root, with a
   * hard deadline. The tail of its output is the failure detail; nothing is
   * invented when the child never starts.
   */
  function runGenerator(outPath, prompt) {
    return new Promise((resolve) => {
      let child;
      try {
        child = spawnImpl(scriptPath, [outPath, prompt, quality], {
          cwd: root,
          stdio: ["ignore", "pipe", "pipe"],
        });
      } catch (err) {
        resolve({ ok: false, detail: `Could not start the image generator: ${err?.message || err}` });
        return;
      }

      let output = "";
      let settled = false;
      const capture = (chunk) => {
        output += chunk.toString();
        if (output.length > 8000) output = output.slice(-4000);
      };
      const finish = (result) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(result);
      };

      const timer = setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch {
          /* already gone */
        }
        finish({
          ok: false,
          detail: `The image generator did not finish within ${Math.round(timeoutMs / 1000)}s. ${tail(output)}`.trim(),
        });
      }, timeoutMs);

      child.stdout?.on("data", capture);
      child.stderr?.on("data", capture);
      child.on("error", (err) => finish({ ok: false, detail: `Could not start the image generator: ${err?.message || err}` }));
      child.on("close", (code) => {
        if (code === 0) finish({ ok: true });
        else finish({ ok: false, detail: `The image generator exited with code ${code}. ${tail(output)}`.trim() });
      });
    });
  }

  /**
   * One authorized call to Fal's queue. The key is written in exactly one
   * place, and the queue's error body is kept as the diagnosis.
   */
  async function falFetch(url, { method = "GET", body, signal } = {}) {
    const response = await fetchImpl(url, {
      method,
      headers: {
        authorization: `Key ${falKey}`,
        ...(body === undefined ? {} : { "content-type": "application/json" }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal,
    });
    if (!response?.ok) throw await falFailure(response, method, url);
    return response;
  }

  /** Fal's error body is the diagnosis; keep it, truncated to a line. */
  async function falFailure(response, method, url) {
    let detail = "";
    try {
      detail = renderDetail(await response.json());
    } catch {
      try {
        detail = await response.text();
      } catch {
        /* a body that cannot be read says nothing */
      }
    }
    return new Error(`Fal refused ${method} ${url} (HTTP ${response?.status ?? "?"}). ${tail(detail)}`.trim());
  }

  /**
   * Draw one dream through Fal's queue, into the caller's part file.
   *
   * The flow is the documented one: submit to the model endpoint, poll the
   * status URL until the job COMPLETEs, read the result from the response URL,
   * run the cutout that restores the alpha, then download the bytes. One
   * deadline, the same `MIRA_GOAL_ART_TIMEOUT_MS` budget the script path uses,
   * covers the whole flow; nothing is left queued when it expires.
   *
   * The cutout is required for transparent artwork. A failure never publishes
   * the opaque Muse render; the app retains its existing transparent artwork.
   */
  function runFalGenerator(outPath, prompt) {
    const controller = new AbortController();
    const deadline = Date.now() + timeoutMs;
    let expired = false;
    const timer = setTimeout(() => {
      expired = true;
      controller.abort();
    }, timeoutMs);
    const signal = controller.signal;

    const timeoutDetail = () =>
      `The image generator did not finish within ${Math.round(timeoutMs / 1000)}s. Fal did not return an image in time.`;
    const throwTimeout = () => {
      expired = true;
      controller.abort();
      throw new Error(timeoutDetail());
    };
    const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    /** Submit one model and wait until its result is ready to read. */
    async function runModel(model, payload, label) {
      let job = await (await falFetch(`${FAL_QUEUE_BASE}/${model}`, { method: "POST", body: payload, signal })).json();
      for (;;) {
        if (job?.status === "COMPLETED") {
          if (typeof job.response_url !== "string" || !job.response_url.trim()) {
            throw new Error(`Fal completed ${label} without a response URL.`);
          }
          return job.response_url;
        }
        if (job?.status !== "IN_QUEUE" && job?.status !== "IN_PROGRESS") {
          throw new Error(`Fal reported "${job?.status ?? "no status"}" for ${label}. ${tail(renderDetail(job))}`.trim());
        }
        if (typeof job.status_url !== "string" || !job.status_url.trim()) {
          throw new Error(`Fal queued ${label} without a status URL.`);
        }
        if (Date.now() >= deadline) throwTimeout();
        await pause(Math.min(pollIntervalMs, Math.max(0, deadline - Date.now())));
        if (expired) throwTimeout();
        job = { ...job, ...await (await falFetch(job.status_url, { signal })).json() };
      }
    }

    /** The cutout step: muse render in, alpha PNG out. */
    async function cutout(imageUrl) {
      const responseUrl = await runModel(FAL_CUTOUT_MODEL, { image_url: imageUrl, crop_to_bbox: true }, "rembg");
      const payload = await (await falFetch(responseUrl, { signal })).json();
      const url = payload?.image?.url;
      if (typeof url !== "string" || !url.trim()) {
        throw new Error(`Fal returned no cutout. ${tail(renderDetail(payload))}`.trim());
      }
      return url;
    }

    /**
     * The finished image's bytes. The URL comes from Fal's own response; it is
     * a public media file, so the key is not sent to it — the queue is the
     * only surface that authenticates.
     */
    async function download(url) {
      const response = await fetchImpl(url, { signal });
      if (!response?.ok) throw new Error(`Could not download the image (HTTP ${response?.status ?? "?"}).`);
      const bytes = Buffer.from(await response.arrayBuffer());
      if (!bytes.length) throw new Error("Fal produced an empty image.");
      return bytes;
    }

    const work = (async () => {
      const museResultUrl = await runModel(
        FAL_MUSE_MODEL,
        { prompt, aspect_ratio: "1:1", num_images: 1, output_format: "png" },
        "muse-image"
      );
      const musePayload = await (await falFetch(museResultUrl, { signal })).json();
      const museUrl = firstImageUrl(musePayload);
      // Transparent artwork is required: never publish the opaque render if cutout fails.
      const chosenUrl = await cutout(museUrl);
      await fs.writeFile(outPath, await download(chosenUrl));
    })();

    return work
      .then(() => ({ ok: true }))
      .catch((err) => ({
        ok: false,
        detail: expired ? timeoutDetail() : tail(err?.detail || err?.message || err),
      }))
      .finally(() => clearTimeout(timer));
  }

  /**
   * Draw one dream, into a part file first so a crash never leaves a
   * half-written PNG looking ready. A file that is already there wins.
   */
  async function generate({ id, brand, words, name }) {
    const finalPath = fileFor(id);
    const partPath = partFor(id);
    try {
      await fs.mkdir(dir, { recursive: true });
      if (await exists(finalPath)) return { ok: true, ready: true };

      const prompt = await composePrompt({ brand, words, name }, { stylePath, cutout: backend === "fal" });
      await fs.rm(partPath, { force: true });
      const outcome =
        backend === "fal" ? await runFalGenerator(partPath, prompt) : await runGenerator(partPath, prompt);
      if (!outcome.ok) throw new Error(outcome.detail || "The image generator failed.");

      const stat = await fs.stat(partPath);
      if (!stat.size) throw new Error("The image generator produced an empty image.");

      // Another process may have finished the same dream; its file stands.
      if (await exists(finalPath)) return { ok: true, ready: true };
      await fs.rename(partPath, finalPath);
      failures.delete(id);
      return { ok: true, ready: true };
    } catch (err) {
      const detail = tail(err?.detail || err?.message || err);
      recordFailure(id, detail);
      console.error(`goal-art: ${id} failed: ${detail.replace(/\s+/g, " ").slice(0, 400)}`);
      return { ok: false, detail };
    } finally {
      await fs.rm(partPath, { force: true }).catch(() => {});
    }
  }

  /**
   * The status of one id, judged from the file first so a restart is
   * invisible: ready when the PNG exists, generating while it runs, failed
   * after an honest error, and null for an id this service never drew.
   */
  async function view(id) {
    if (!isGoalArtId(id)) return null;
    if (await exists(fileFor(id))) return { id, status: "ready", url: goalArtUrl(id) };
    if (generating.has(id)) return { id, status: "generating" };
    const failure = failures.get(id);
    if (failure) return { id, status: "failed", detail: failure.detail };
    return null;
  }

  /**
   * Ask for a drawing. Ready is instant; an id already drawing joins it; a
   * fresh id is queued. An explicit new ask retries an earlier failure — the
   * app only asks again when the person did.
   */
  async function request({ brand, words, name = "" }) {
    const id = goalArtId({ brand, words, name });
    if (await exists(fileFor(id))) return { id, status: "ready", url: goalArtUrl(id) };
    if (generating.has(id)) return { id, status: "generating" };

    failures.delete(id);
    const job = enqueue(() => generate({ id, brand, words, name }));
    generating.set(id, job);
    const forget = () => {
      if (generating.get(id) === job) generating.delete(id);
    };
    job.then(forget, forget);
    return { id, status: "generating" };
  }

  /**
   * The filesystem path for an id's image, or null when the id is not the
   * exact shape this service writes. The path is the only thing the image
   * route serves; nothing outside the output directory can ever match.
   */
  function imagePath(id) {
    if (!isGoalArtId(id)) return null;
    const file = path.join(dir, `${id}.png`);
    const base = dir.endsWith(path.sep) ? dir : `${dir}${path.sep}`;
    return file.startsWith(base) ? file : null;
  }

  /** The output directory, created up front so the first drawing never fails on it. */
  async function ensureDir() {
    await fs.mkdir(dir, { recursive: true });
    return dir;
  }

  /**
   * What /health can say without a secret: where art lands, from where the
   * style came, and which backend draws the pictures. Never the key itself.
   */
  async function info() {
    const stylePresent = await exists(stylePath);
    return {
      storage: "generated-png",
      backend,
      dir,
      styleFile: stylePath,
      styleSource: stylePresent ? "file" : "built-in",
      generating: generating.size,
      failures: failures.size,
      timeoutMs,
    };
  }

  return { dir, stylePath, scriptPath, timeoutMs, backend, request, view, imagePath, ensureDir, info };
}
