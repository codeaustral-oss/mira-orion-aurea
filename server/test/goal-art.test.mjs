/**
 * Live goal art: the prompt, the id, the queue and the wire.
 *
 * The Piggy Banks screen draws a card for "a month in Tokyo" and the app polls
 * the proxy while it does. What is pinned here:
 *
 *   · the prompt comes from `art/goals/style.json` when it exists, and from the
 *     built-in art direction when it does not;
 *   · the same words always resolve to the same id, and a ready file wins;
 *   · the request contract (brand, 3–120 characters, name ≤ 60) is refused in
 *     the server's own error shape;
 *   · with a Fal key the live path submits to Fal's queue, polls, cuts out the
 *     alpha and writes the bytes to the caller's part path — and a failed
 *     cutout falls back to the raw render;
 *   · without a key the local `scripts/gen-image.sh` path is exactly what it
 *     always was, and `/health` names the backend in use;
 *   · one generation at a time — a second ask while drawing never starts a
 *     second process, and an explicit new ask retries an earlier failure;
 *   · a failure or a timeout is honest (status `failed`, with the tail of the
 *     error) and never leaves a half-written file that reads as ready;
 *   · the image route serves only ids of its own shape, and nothing outside the
 *     output directory.
 *
 * The generators are stubbed everywhere: these tests never run codex and never
 * touch the real Fal queue (`options.fetchImpl` answers instead), and every
 * service under test points at a temp output directory, so the real
 * `art/goals/generated/` is never touched.
 */

import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import fs from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  CUTOUT_BACKGROUND_LINE,
  GOAL_ART_NAME_MAX,
  GOAL_ART_WORDS_MAX,
  GOAL_ART_WORDS_MIN,
  composePrompt,
  createGoalArt,
  goalArtId,
  isGoalArtId,
  renderSubject,
  slugifyWords,
  validateGoalArtRequest,
} from "../lib/goal-art.mjs";

const ROOT = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));

/**
 * The backend is chosen by FAL_KEY. No test here may reach the real Fal queue,
 * so the ambient key is removed for the whole file; the tests that are about
 * the Fal path inject their own key and their own stubbed fetch.
 */
delete process.env.FAL_KEY;

/** An image-shaped byte string; the routes never decode it. */
const PNG = Buffer.from("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489", "hex");

/** The cutout's bytes, distinguishable from the raw render's. */
const CUTOUT_PNG = Buffer.concat([PNG, Buffer.from([0x2f, 0xc0])]);

// The exact Fal surface the module speaks to, spelled out so a change to any
// URL, field or header fails a test rather than reaching the queue.
const FAL_QUEUE = "https://queue.fal.run";
const FAL_MUSE_MODEL = "meta/muse-image/text-to-image";
const FAL_REMBG_MODEL = "fal-ai/imageutils/rembg";
const MUSE_IMAGE_URL = "https://fal.media/files/muse-render.png";
const CUTOUT_IMAGE_URL = "https://fal.media/files/muse-cutout.png";

async function tempDir(prefix = "mira-goal-art-") {
  return fs.mkdtemp(path.join(os.tmpdir(), prefix));
}

async function fileExists(file) {
  try {
    await fs.stat(file);
    return true;
  } catch {
    return false;
  }
}

/**
 * A stand-in for `scripts/gen-image.sh`. It records every spawn, then answers
 * on the next tick: write a PNG and exit 0, fail with output, or hang — which
 * is how the timeout is reached without waiting two minutes.
 */
function stubGenerator({ mode = "success", delayMs = 5, code = 1, stderr = "FAIL out.png (codex exec error)" } = {}) {
  const calls = [];
  const spawnImpl = (command, args, options = {}) => {
    const child = new EventEmitter();
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    child.kill = (signal) => {
      child.killed = signal;
    };
    calls.push({ command, args, options, child });
    if (mode === "hang") return child;

    setTimeout(async () => {
      // A failed test may have removed the output directory already; a write
      // that cannot land is a failed run, never an unhandled rejection.
      if (mode === "success" || mode === "fail-after-writing") {
        try {
          await fs.writeFile(args[0], PNG);
        } catch (err) {
          child.stderr.write(`could not write the output: ${err?.message || err}`);
          child.emit("close", code, null);
          return;
        }
      }
      if (mode === "success") {
        child.emit("close", 0, null);
        return;
      }
      child.stderr.write(stderr);
      child.emit("close", code, null);
    }, delayMs);
    return child;
  };
  return { spawnImpl, calls };
}

async function waitForStatus(art, id, wanted, timeoutMs = 3000) {
  const started = Date.now();
  for (;;) {
    const view = await art.view(id);
    if (view?.status === wanted) return view;
    if (Date.now() - started > timeoutMs) {
      throw new Error(`status for ${id} stayed "${view?.status}", wanted "${wanted}"`);
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

/** Wait for a condition the queue reaches asynchronously, like a spawn. */
async function waitFor(condition, label, timeoutMs = 3000) {
  const started = Date.now();
  for (;;) {
    if (condition()) return;
    if (Date.now() - started > timeoutMs) throw new Error(`condition never became true: ${label}`);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

/**
 * A stand-in for Fal's queue. It records every call and answers in the
 * documented shapes: the render queues and completes, the result carries one
 * image URL, the cutout wraps that URL, and the media downloads return bytes
 * the test can tell apart.
 *
 * `cutout` is how the cutout answers — "ok", "http-error" or "status-failed".
 * `forever` makes the render's status never leave IN_PROGRESS, which is how a
 * timeout is reached without waiting minutes.
 */
function stubFal({ cutout = "ok", forever = false, renderPolls = ["IN_QUEUE", "IN_PROGRESS"] } = {}) {
  const calls = [];
  const pending = [...renderPolls];
  const statusUrl = (model, id) => `${FAL_QUEUE}/${model}/requests/${id}/status`;
  const resultUrl = (model, id) => `${FAL_QUEUE}/${model}/requests/${id}`;
  const museStatus = statusUrl(FAL_MUSE_MODEL, "req-muse");
  const museResult = resultUrl(FAL_MUSE_MODEL, "req-muse");
  const rembgStatus = statusUrl(FAL_REMBG_MODEL, "req-cutout");
  const rembgResult = resultUrl(FAL_REMBG_MODEL, "req-cutout");

  const json = (payload, status = 200) => ({
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return payload;
    },
  });
  const bytes = (buffer) => ({
    ok: true,
    status: 200,
    async arrayBuffer() {
      return buffer;
    },
  });

  const fetchImpl = async (url, options = {}) => {
    const href = String(url);
    const method = options.method || "GET";
    calls.push({
      url: href,
      method,
      headers: options.headers ?? {},
      body: options.body === undefined ? undefined : JSON.parse(options.body),
    });

    if (method === "POST" && href === `${FAL_QUEUE}/${FAL_MUSE_MODEL}`) {
      return json({ status: "IN_QUEUE", request_id: "req-muse", status_url: museStatus, response_url: museResult });
    }
    if (method === "GET" && href === museStatus) {
      if (forever) return json({ status: "IN_PROGRESS", status_url: museStatus, response_url: museResult });
      const status = pending.shift() ?? "COMPLETED";
      return json({ status });
    }
    if (method === "GET" && href === museResult) {
      return json({ images: [{ url: MUSE_IMAGE_URL, content_type: "image/png", width: 1024, height: 1024 }] });
    }
    if (method === "POST" && href === `${FAL_QUEUE}/${FAL_REMBG_MODEL}`) {
      if (cutout === "http-error") return json({ detail: [{ msg: "rembg could not read the image" }] }, 500);
      if (cutout === "status-failed") return json({ status: "FAILED", detail: "rembg queue error" });
      return json({
        status: "IN_QUEUE",
        request_id: "req-cutout",
        status_url: rembgStatus,
        response_url: rembgResult,
      });
    }
    if (method === "GET" && href === rembgStatus) {
      return json({ status: "COMPLETED" });
    }
    if (method === "GET" && href === rembgResult) {
      return json({ image: { url: CUTOUT_IMAGE_URL } });
    }
    if (method === "GET" && href === MUSE_IMAGE_URL) return bytes(PNG);
    if (method === "GET" && href === CUTOUT_IMAGE_URL) return bytes(CUTOUT_PNG);
    throw new Error(`stubFal: unexpected ${method} ${href}`);
  };
  return { calls, fetchImpl };
}

/** Capture what a fallback logs, without letting it reach the test output. */
function captureErrors() {
  const lines = [];
  const original = console.error;
  console.error = (...args) => lines.push(args.join(" "));
  return {
    lines,
    restore() {
      console.error = original;
    },
  };
}

/** Run `fn` with FAL_KEY unset, and put the ambient value back afterwards. */
async function withoutFalKey(fn) {
  const prior = process.env.FAL_KEY;
  delete process.env.FAL_KEY;
  try {
    return await fn();
  } finally {
    if (prior === undefined) delete process.env.FAL_KEY;
    else process.env.FAL_KEY = prior;
  }
}

// ── The id ───────────────────────────────────────────────────────────────────

test("the id is stable for the same words, whatever the case or the spacing", () => {
  const first = goalArtId({ brand: "orion", words: "A month in Tokyo" });
  assert.equal(goalArtId({ brand: "orion", words: "  a month   in tokyo " }), first);
  assert.equal(goalArtId({ brand: "orion", words: "A MONTH IN TOKYO" }), first);
  assert.match(first, /^orion-a-month-in-tokyo-[0-9a-f]{10}$/);
  assert.equal(isGoalArtId(first), true);
});

test("different words, brands or names are different ids", () => {
  const base = goalArtId({ brand: "orion", words: "A month in Tokyo" });
  assert.notEqual(goalArtId({ brand: "aurea", words: "A month in Tokyo" }), base);
  assert.notEqual(goalArtId({ brand: "orion", words: "A month in Kyoto" }), base);
  // The name is part of the prompt, so it is part of the id: two people asking
  // for the same words get their own drawing, never each other's.
  assert.notEqual(goalArtId({ brand: "orion", words: "A month in Tokyo", name: "Helena" }), base);
  assert.equal(
    goalArtId({ brand: "orion", words: "A month in Tokyo", name: "Helena" }),
    goalArtId({ brand: "orion", words: "A month in Tokyo", name: "Helena" })
  );
});

test("word sets that slugify the same still get distinct ids", () => {
  const a = goalArtId({ brand: "orion", words: "a month in Tokyo" });
  const b = goalArtId({ brand: "orion", words: "a-month-in-tokyo!" });
  assert.equal(slugifyWords("a month in Tokyo"), slugifyWords("a-month-in-tokyo!"));
  assert.notEqual(a, b);
  // Words with no slug at all still produce a servable id.
  const cjk = goalArtId({ brand: "aurea", words: "京都の一ヶ月" });
  assert.equal(isGoalArtId(cjk), true);
  assert.match(cjk, /^aurea-dream-[0-9a-f]{10}$/);
});

// ── The prompt ───────────────────────────────────────────────────────────────

test("the prompt comes from style.json when the file carries the brand", async () => {
  const dir = await tempDir();
  try {
    const stylePath = path.join(dir, "style.json");
    await fs.writeFile(
      stylePath,
      JSON.stringify({
        orion: { scene_style: "SCENE-ORION", subject_template: "Draw {brief}", avoid: "AVOID-ORION" },
        aurea: { scene_style: "SCENE-AUREA", subject_template: "A vignette of {subject} for {name}", avoid: "AVOID-AUREA" },
      })
    );

    const orion = await composePrompt(
      { brand: "orion", words: "a month in Tokyo", name: "Helena" },
      { stylePath }
    );
    assert.match(orion, /SCENE-ORION/);
    assert.match(orion, /Draw a month in Tokyo \(a dream of Helena\)/);
    assert.match(orion, /AVOID-ORION/);

    const aurea = await composePrompt(
      { brand: "aurea", words: "the chapel fresco", name: "Helena" },
      { stylePath }
    );
    assert.match(aurea, /SCENE-AUREA/);
    assert.match(aurea, /A vignette of the chapel fresco for Helena/);
    assert.match(aurea, /AVOID-AUREA/);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("the style file the art direction ships is what the prompt says", async () => {
  // Read the real `art/goals/style.json` when it exists: its contract is
  // brand -> { scene_style, subject_template, avoid } with {subject} and
  // {name} in the template, and no placeholder may survive into the prompt.
  const stylePath = path.join(ROOT, "art", "goals", "style.json");
  if (!(await fileExists(stylePath))) return; // a clean checkout uses the fallback
  for (const brand of ["orion", "aurea"]) {
    const prompt = await composePrompt({ brand, words: "a month in Tokyo", name: "Helena" }, { stylePath });
    assert.doesNotMatch(prompt, /\{(?:subject|words|brief|name)\}/, `${brand} prompt has no unfilled placeholder`);
    assert.match(prompt, /a month in Tokyo/);
    assert.match(prompt, /Helena/);
    assert.match(prompt, /no text/i);
    // The avoid line ends once, even though the style file ends it itself.
    const avoidLine = prompt.split("\n\n").find((part) => part.startsWith("Avoid: "));
    assert.match(avoidLine, /[.!?]$/);
    assert.doesNotMatch(avoidLine, /\.\.$/);
  }
  // Without a name the prompt is still a whole prompt, never a hole.
  const unnamed = await composePrompt({ brand: "orion", words: "a month in Tokyo" }, { stylePath });
  assert.doesNotMatch(unnamed, /\{(?:subject|words|brief|name)\}|\(\s*\)/);
  assert.match(unnamed, /a month in Tokyo/);
});

test("a missing or unusable style file falls back to the built-in art direction", async () => {
  const dir = await tempDir();
  try {
    const missing = path.join(dir, "no-such-style.json");
    const orion = await composePrompt({ brand: "orion", words: "a bike" }, { stylePath: missing });
    assert.match(orion, /isometric/i);
    assert.match(orion, /diorama/i);
    assert.match(orion, /a bike/);
    assert.match(orion, /no text/i);

    const aurea = await composePrompt({ brand: "aurea", words: "a fine cello" }, { stylePath: missing });
    assert.match(aurea, /postcard/i);
    assert.match(aurea, /Renaissance/i);
    assert.match(aurea, /a fine cello/);
    assert.match(aurea, /no text/i);

    // Unreadable JSON, and a block without its substance, are not a style.
    const broken = path.join(dir, "broken.json");
    await fs.writeFile(broken, "{ not json");
    assert.match(await composePrompt({ brand: "orion", words: "a bike" }, { stylePath: broken }), /isometric/i);

    const partial = path.join(dir, "partial.json");
    await fs.writeFile(partial, JSON.stringify({ orion: { scene_style: "only-a-scene" } }));
    const fromPartial = await composePrompt({ brand: "orion", words: "a bike" }, { stylePath: partial });
    assert.doesNotMatch(fromPartial, /only-a-scene/);
    assert.match(fromPartial, /isometric/i);
    // The brand the file does carry is still not read from a half a block.
    assert.match(await composePrompt({ brand: "aurea", words: "a cello" }, { stylePath: partial }), /postcard/i);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("a template fills what it names, and invents no name when none was given", () => {
  assert.equal(
    renderSubject("A diorama of {words}", { words: "a bike", name: "" }),
    "A diorama of a bike"
  );
  assert.equal(
    renderSubject("The dream is {subject}, kept for {name}.", { words: "a bike", name: "Mateo" }),
    "The dream is a bike, kept for Mateo."
  );
  // The art direction writes {subject} twice; both are the person's words.
  assert.equal(
    renderSubject("The dream is {subject}, kept for {name}. Build {subject}.", {
      words: "a fine cello",
      name: "Rafael",
    }),
    "The dream is a fine cello, kept for Rafael. Build a fine cello."
  );
  assert.equal(
    renderSubject("The dream of {name}: {words}", { words: "a bike", name: "Mateo" }),
    "The dream of Mateo: a bike"
  );
  // No placeholders: the template is a lead-in for the words.
  assert.equal(
    renderSubject("An isometric diorama on a plinth", { words: "a bike", name: "" }),
    "An isometric diorama on a plinth: a bike."
  );
  // A name nobody gave is never invented: the clause that needed it goes.
  assert.equal(
    renderSubject("The dream is {subject}, kept for {name}. Build it.", { words: "a bike", name: "" }),
    "The dream is a bike. Build it."
  );
  // A whole sentence that needs the missing name goes; the words still stand.
  assert.equal(renderSubject("A card for {name} ({subject}).", { words: "a bike", name: "" }), "a bike");
  assert.equal(renderSubject("A card for {name}", { words: "a bike", name: "" }), "a bike");
  assert.doesNotMatch(renderSubject("A card for {name}", { words: "a bike", name: "" }), /undefined|\(\s*\)/);
});

// ── The request contract ─────────────────────────────────────────────────────

test("the request contract is brand, 3–120 characters of words and an optional name", () => {
  assert.deepEqual(validateGoalArtRequest({ brand: "orion", words: " a bike ", name: " Mateo " }), {
    ok: true,
    brand: "orion",
    words: "a bike",
    name: "Mateo",
  });
  assert.deepEqual(validateGoalArtRequest({ brand: "aurea", words: "a".repeat(3) }).ok, true);
  assert.equal(validateGoalArtRequest({ brand: "aurea", words: "x".repeat(GOAL_ART_WORDS_MAX) }).ok, true);

  const cases = [
    [{ words: "a bike" }, "brand_required"],
    [{ brand: "aurora", words: "a bike" }, "brand_required"],
    [{ brand: "orion" }, "words_required"],
    [{ brand: "orion", words: 42 }, "words_required"],
    [{ brand: "orion", words: "hi" }, "words_too_short"],
    [{ brand: "orion", words: " ".repeat(20) }, "words_too_short"],
    [{ brand: "orion", words: "x".repeat(GOAL_ART_WORDS_MAX + 1) }, "words_too_long"],
    [{ brand: "orion", words: "a bike", name: "n".repeat(GOAL_ART_NAME_MAX + 1) }, "name_too_long"],
    [{ brand: "orion", words: "a bike", name: 7 }, "name_invalid"],
  ];
  for (const [payload, error] of cases) {
    const result = validateGoalArtRequest(payload);
    assert.equal(result.ok, false, error);
    assert.equal(result.status, 400, error);
    assert.equal(result.error, error);
    assert.ok(result.detail, `${error} carries a detail`);
  }
  // The boundaries themselves are fine.
  assert.equal(validateGoalArtRequest({ brand: "orion", words: "a".repeat(GOAL_ART_WORDS_MIN) }).ok, true);
  assert.equal(
    validateGoalArtRequest({ brand: "orion", words: "a bike", name: "n".repeat(GOAL_ART_NAME_MAX) }).ok,
    true
  );
  // A missing name is an empty name; nothing is invented.
  assert.equal(validateGoalArtRequest({ brand: "orion", words: "a bike" }).name, "");
});

// ── The lifecycle, with a stubbed generator ──────────────────────────────────

test("an ask draws once through the real script contract, and the same words are ready twice", async () => {
  const dir = await tempDir();
  try {
    const gen = stubGenerator();
    const art = createGoalArt({ dir, stylePath: path.join(dir, "style.json"), spawnImpl: gen.spawnImpl });

    const first = await art.request({ brand: "orion", words: "A month in Tokyo", name: "Helena" });
    assert.equal(first.status, "generating");
    await waitFor(() => gen.calls.length === 1, "the first spawn");
    assert.equal(gen.calls[0].command, path.join(ROOT, "scripts", "gen-image.sh"));
    assert.equal(gen.calls[0].args[2], "high", "quality is fixed at high");
    assert.equal(gen.calls[0].options.cwd, ROOT, "the generator runs from the repo root");
    assert.ok(gen.calls[0].args[0].startsWith(dir + path.sep), "the output lands in the art directory");
    assert.match(gen.calls[0].args[1], /A month in Tokyo/);

    const view = await waitForStatus(art, first.id, "ready");
    assert.equal(view.url, `/v1/goal-art/${first.id}/image`);
    assert.equal(await fileExists(path.join(dir, `${first.id}.png`)), true);

    // The second ask is instant: the file is the job state.
    const second = await art.request({ brand: "orion", words: "a month in tokyo", name: "helena" });
    assert.equal(second.status, "ready");
    assert.equal(second.id, first.id);
    assert.equal(gen.calls.length, 1, "a ready dream never spawns again");
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("one generation at a time: a second ask while drawing waits its turn", async () => {
  const dir = await tempDir();
  try {
    const gen = stubGenerator({ delayMs: 40 });
    const art = createGoalArt({ dir, stylePath: path.join(dir, "style.json"), spawnImpl: gen.spawnImpl });

    const a = await art.request({ brand: "orion", words: "A Rio weekend" });
    const b = await art.request({ brand: "orion", words: "A bike" });
    assert.equal(a.status, "generating");
    assert.equal(b.status, "generating");
    await waitFor(() => gen.calls.length === 1, "the first spawn");
    assert.equal(gen.calls.length, 1, "the second dream does not start a second process");

    await waitForStatus(art, a.id, "ready");
    await waitForStatus(art, b.id, "ready");
    assert.equal(gen.calls.length, 2);
    assert.notEqual(gen.calls[0].args[1], gen.calls[1].args[1], "each dream has its own prompt");
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("two simultaneous asks for the same words draw once", async () => {
  const dir = await tempDir();
  try {
    const gen = stubGenerator({ delayMs: 30 });
    const art = createGoalArt({ dir, stylePath: path.join(dir, "style.json"), spawnImpl: gen.spawnImpl });

    const [first, second] = await Promise.all([
      art.request({ brand: "orion", words: "A dog with a leash" }),
      art.request({ brand: "orion", words: "a dog with a leash" }),
    ]);
    assert.equal(first.id, second.id);
    assert.equal(first.status, "generating");
    await waitForStatus(art, first.id, "ready");
    assert.equal(gen.calls.length, 1, "a double tap is still one drawing");
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("a failure is honest: status failed, the tail of the error, and a new ask retries", async () => {
  const dir = await tempDir();
  try {
    const gen = stubGenerator({ mode: "fail", stderr: "FAIL out.png (codex exec error)\nthe provider refused" });
    const art = createGoalArt({ dir, stylePath: path.join(dir, "style.json"), spawnImpl: gen.spawnImpl });

    const asked = await art.request({ brand: "aurea", words: "The new press house" });
    const view = await waitForStatus(art, asked.id, "failed");
    assert.match(view.detail, /exited with code 1/);
    assert.match(view.detail, /the provider refused/);
    assert.equal(await fileExists(path.join(dir, `${asked.id}.png`)), false);

    // The app falls back on failed; a fresh explicit ask is a fresh attempt.
    const retry = await art.request({ brand: "aurea", words: "The new press house" });
    assert.equal(retry.status, "generating");
    await waitFor(() => gen.calls.length === 2, "the retry spawn");
    // Let the second attempt settle before the temp directory goes away.
    await waitForStatus(art, retry.id, "failed");
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("a crashed run that wrote bytes still reads as failed, and no part file survives", async () => {
  const dir = await tempDir();
  try {
    const gen = stubGenerator({ mode: "fail-after-writing" });
    const art = createGoalArt({ dir, stylePath: path.join(dir, "style.json"), spawnImpl: gen.spawnImpl });

    const asked = await art.request({ brand: "orion", words: "A dog with a leash" });
    await waitForStatus(art, asked.id, "failed");
    assert.equal(await fileExists(path.join(dir, `${asked.id}.png`)), false, "a failed run is never ready");
    const leftovers = (await fs.readdir(dir)).filter((name) => name.includes(asked.id));
    assert.deepEqual(leftovers, [], "the part file is cleaned up");
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("a generator that never finishes is killed and reported, never left drawing", async () => {
  const dir = await tempDir();
  try {
    const gen = stubGenerator({ mode: "hang" });
    const art = createGoalArt({
      dir,
      stylePath: path.join(dir, "style.json"),
      spawnImpl: gen.spawnImpl,
      timeoutMs: 40,
    });

    const asked = await art.request({ brand: "orion", words: "A sabbatical" });
    const view = await waitForStatus(art, asked.id, "failed");
    assert.match(view.detail, /did not finish/);
    assert.equal(gen.calls[0].child.killed, "SIGKILL");
    assert.equal(await fileExists(path.join(dir, `${asked.id}.png`)), false);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("a ready file is never overwritten, and a restart sees it without drawing", async () => {
  const dir = await tempDir();
  try {
    const id = goalArtId({ brand: "aurea", words: "The chapel fresco" });
    await fs.mkdir(dir, { recursive: true });
    await fs.writeFile(path.join(dir, `${id}.png`), PNG);

    const gen = stubGenerator();
    const art = createGoalArt({ dir, stylePath: path.join(dir, "style.json"), spawnImpl: gen.spawnImpl });
    const asked = await art.request({ brand: "aurea", words: "The chapel fresco" });
    assert.equal(asked.status, "ready");
    assert.equal(gen.calls.length, 0, "an existing drawing is never redrawn");
    assert.deepEqual(await fs.readFile(path.join(dir, `${id}.png`)), PNG);

    // A new server process over the same directory: the file is the state.
    const restarted = createGoalArt({
      dir,
      stylePath: path.join(dir, "style.json"),
      spawnImpl: stubGenerator().spawnImpl,
    });
    assert.deepEqual(await restarted.view(id), {
      id,
      status: "ready",
      url: `/v1/goal-art/${id}/image`,
    });
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("an id this service never drew has no view, and image paths stay inside the directory", async () => {
  const dir = await tempDir();
  try {
    const art = createGoalArt({ dir, spawnImpl: stubGenerator().spawnImpl });
    assert.equal(await art.view("orion-a-bike-0123456789"), null);
    assert.equal(await art.view("../etc/passwd"), null);
    assert.equal(await art.view("orion-a/../../b"), null);
    assert.equal(await art.view("orion-a-bike.png"), null);

    assert.equal(art.imagePath("../etc/passwd"), null);
    assert.equal(art.imagePath("orion-a/../../b"), null);
    assert.equal(art.imagePath("orion-a-bike.png"), null);
    assert.equal(art.imagePath(".orion-a-bike.part"), null);
    assert.equal(art.imagePath(""), null);
    const ok = art.imagePath(goalArtId({ brand: "orion", words: "A bike" }));
    assert.equal(ok, path.join(dir, `${goalArtId({ brand: "orion", words: "A bike" })}.png`));
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("the same words from two names are two drawings, and both are honest", async () => {
  const dir = await tempDir();
  try {
    const gen = stubGenerator({ delayMs: 20 });
    const art = createGoalArt({ dir, stylePath: path.join(dir, "style.json"), spawnImpl: gen.spawnImpl });

    const helena = await art.request({ brand: "aurea", words: "A year in Tuscany", name: "Helena" });
    const rafael = await art.request({ brand: "aurea", words: "A year in Tuscany", name: "Rafael" });
    assert.notEqual(helena.id, rafael.id);
    await waitForStatus(art, helena.id, "ready");
    await waitForStatus(art, rafael.id, "ready");
    assert.equal(gen.calls.length, 2);
    assert.match(gen.calls[0].args[1], /Helena/);
    assert.match(gen.calls[1].args[1], /Rafael/);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── The Fal path ─────────────────────────────────────────────────────────────

test("the backend follows the key: FAL_KEY or options.falKey picks Fal, no key keeps the script", async () => {
  const dir = await tempDir();
  try {
    await withoutFalKey(async () => {
      assert.equal((await createGoalArt({ dir }).info()).backend, "script", "no key in the environment");
    });

    process.env.FAL_KEY = "env-fal-key";
    try {
      assert.equal((await createGoalArt({ dir }).info()).backend, "fal");
      // The explicit option is the last word: an empty one overrides the
      // environment, which is how a caller forces the local pipeline.
      assert.equal((await createGoalArt({ dir, falKey: "" }).info()).backend, "script");
      assert.equal((await createGoalArt({ dir, falKey: "option-key" }).info()).backend, "fal");
    } finally {
      delete process.env.FAL_KEY;
    }
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("without a key the script path runs exactly as before, and no HTTP call is made", async () => {
  const dir = await tempDir();
  try {
    await withoutFalKey(async () => {
      const gen = stubGenerator();
      const art = createGoalArt({
        dir,
        stylePath: path.join(dir, "style.json"),
        spawnImpl: gen.spawnImpl,
        fetchImpl: () => {
          throw new Error("the local path must not call Fal");
        },
      });
      assert.equal(art.backend, "script");
      const asked = await art.request({ brand: "orion", words: "A month in Tokyo" });
      await waitForStatus(art, asked.id, "ready");
      assert.equal(gen.calls.length, 1, "the script drew it");
      assert.match(gen.calls[0].args[1], /A month in Tokyo/);
      // The curated recipe is unchanged: no white-background line.
      assert.doesNotMatch(gen.calls[0].args[1], /pure-white background/);
    });
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("the Fal path submits, polls, cuts out and writes the bytes to the part path", async () => {
  const dir = await tempDir();
  try {
    const fal = stubFal();
    const art = createGoalArt({
      dir,
      stylePath: path.join(dir, "style.json"),
      falKey: "test-fal-key",
      fetchImpl: fal.fetchImpl,
      pollIntervalMs: 1,
    });

    const asked = await art.request({ brand: "orion", words: "A month in Tokyo", name: "Helena" });
    assert.equal(asked.status, "generating");
    const view = await waitForStatus(art, asked.id, "ready");
    assert.equal(view.url, `/v1/goal-art/${asked.id}/image`);
    assert.equal((await art.info()).backend, "fal");
    assert.deepEqual(await fs.readFile(path.join(dir, `${asked.id}.png`)), CUTOUT_PNG);
    assert.deepEqual(
      (await fs.readdir(dir)).filter((name) => name.includes(asked.id)),
      [`${asked.id}.png`],
      "the part file is gone and only the finished PNG stands"
    );

    // The exact flow: submit, poll IN_QUEUE → IN_PROGRESS → COMPLETED, read
    // the result, submit the cutout, poll it, read it, download the cutout.
    assert.deepEqual(
      fal.calls.map((call) => `${call.method} ${call.url}`),
      [
        `POST ${FAL_QUEUE}/${FAL_MUSE_MODEL}`,
        `GET ${FAL_QUEUE}/${FAL_MUSE_MODEL}/requests/req-muse/status`,
        `GET ${FAL_QUEUE}/${FAL_MUSE_MODEL}/requests/req-muse/status`,
        `GET ${FAL_QUEUE}/${FAL_MUSE_MODEL}/requests/req-muse/status`,
        `GET ${FAL_QUEUE}/${FAL_MUSE_MODEL}/requests/req-muse`,
        `POST ${FAL_QUEUE}/${FAL_REMBG_MODEL}`,
        `GET ${FAL_QUEUE}/${FAL_REMBG_MODEL}/requests/req-cutout/status`,
        `GET ${FAL_QUEUE}/${FAL_REMBG_MODEL}/requests/req-cutout`,
        `GET ${CUTOUT_IMAGE_URL}`,
      ]
    );

    // Every queue call carries the key; the media download never does.
    for (const call of fal.calls.filter((call) => call.url.startsWith(FAL_QUEUE))) {
      assert.equal(call.headers.authorization, "Key test-fal-key", call.url);
    }
    for (const call of fal.calls.filter((call) => call.url.startsWith("https://fal.media"))) {
      assert.equal(call.headers.authorization, undefined, "the key stays with the queue");
    }

    const muse = fal.calls[0];
    assert.equal(muse.headers["content-type"], "application/json");
    assert.deepEqual(Object.keys(muse.body).sort(), ["aspect_ratio", "num_images", "output_format", "prompt"]);
    assert.equal(muse.body.aspect_ratio, "1:1");
    assert.equal(muse.body.num_images, 1);
    assert.equal(muse.body.output_format, "png");
    assert.match(muse.body.prompt, /A month in Tokyo/);
    assert.match(muse.body.prompt, /Helena/);
    assert.ok(muse.body.prompt.endsWith(CUTOUT_BACKGROUND_LINE), "the cutout line is appended last");

    const rembg = fal.calls.find((call) => call.url === `${FAL_QUEUE}/${FAL_REMBG_MODEL}`);
    assert.deepEqual(rembg.body, { image_url: MUSE_IMAGE_URL, crop_to_bbox: true });
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("a failed cutout never publishes an opaque image", async () => {
  for (const cutout of ["http-error", "status-failed"]) {
    const dir = await tempDir();
    const errors = captureErrors();
    try {
      const fal = stubFal({ cutout });
      const art = createGoalArt({
        dir,
        stylePath: path.join(dir, "style.json"),
        falKey: "test-fal-key",
        fetchImpl: fal.fetchImpl,
        pollIntervalMs: 1,
      });

      const asked = await art.request({ brand: "aurea", words: "The chapel fresco" });
      await waitForStatus(art, asked.id, "failed");
      assert.equal(await fileExists(path.join(dir, `${asked.id}.png`)), false);
      assert.equal(fal.calls.some(call => call.url === MUSE_IMAGE_URL), false);
    } finally {
      errors.restore();
      await fs.rm(dir, { recursive: true, force: true });
    }
  }
});

test("a Fal job that never finishes times out in the module's failure shape", async () => {
  const dir = await tempDir();
  try {
    const fal = stubFal({ forever: true });
    const art = createGoalArt({
      dir,
      stylePath: path.join(dir, "style.json"),
      falKey: "test-fal-key",
      fetchImpl: fal.fetchImpl,
      timeoutMs: 60,
      pollIntervalMs: 5,
    });

    const asked = await art.request({ brand: "orion", words: "A sabbatical" });
    const view = await waitForStatus(art, asked.id, "failed", 5000);
    assert.match(view.detail, /did not finish within/);
    assert.match(view.detail, /Fal did not return an image in time/);
    assert.equal(await fileExists(path.join(dir, `${asked.id}.png`)), false);
    assert.deepEqual((await fs.readdir(dir)).filter((name) => name.includes(asked.id)), []);

    // The deadline stopped the polling; nothing keeps hammering the queue.
    const statusCalls = fal.calls.filter((call) => call.url.endsWith("/status")).length;
    assert.ok(statusCalls >= 1, "the job was polled at least once");
    const settled = fal.calls.length;
    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.equal(fal.calls.length, settled, "no calls continue after the failure");

    // A fresh explicit ask is a fresh attempt, exactly like the script path.
    const retry = await art.request({ brand: "orion", words: "A sabbatical" });
    assert.equal(retry.status, "generating");
    await waitForStatus(art, retry.id, "failed", 5000);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

// ── The endpoints ────────────────────────────────────────────────────────────

async function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

/** The real proxy, on its own port and its own art directory — never 8791. */
async function startProxy(goalArtDir, stylePath, extraEnv = {}) {
  const port = await freePort();
  const stateDir = await tempDir("mira-goal-art-proxy-");
  const child = spawn(process.execPath, [path.join(ROOT, "server", "server.mjs")], {
    cwd: ROOT,
    env: {
      ...process.env,
      PORT: String(port),
      HOST: "127.0.0.1",
      TYPESAFE_API_KEY: "",
      OPENCODE_GO_API_KEY: "",
      OPENCODE_GO_API_KEYS: "",
      MIRA_TASKS_WORKER: "0",
      MIRA_RELAY_PATH: path.join(stateDir, "ledger.json"),
      MIRA_TASKS_DIR: path.join(stateDir, "tasks"),
      MIRA_GOAL_ART_DIR: goalArtDir,
      MIRA_GOAL_ART_STYLE: stylePath,
      // No proxy test may draw: without a key the local script path answers,
      // and the tests only ever serve files that are already ready.
      FAL_KEY: "",
      ...extraEnv,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", (chunk) => (output += chunk.toString()));
  child.stderr.on("data", (chunk) => (output += chunk.toString()));

  const base = `http://127.0.0.1:${port}`;
  const started = Date.now();
  try {
    for (;;) {
      try {
        const health = await fetch(`${base}/health`);
        if (health.ok) break;
      } catch {
        /* not up yet */
      }
      if (Date.now() - started > 15_000) throw new Error(`proxy did not start:\n${output}`);
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  } catch (err) {
    child.kill("SIGKILL");
    await fs.rm(stateDir, { recursive: true, force: true });
    throw err;
  }
  return {
    base,
    log: () => output,
    async stop() {
      child.kill("SIGKILL");
      await fs.rm(stateDir, { recursive: true, force: true });
    },
  };
}

test("POST /v1/goal-art validates in the server's error shape, and a ready id is instant", async () => {
  const artDir = await tempDir();
  const proxy = await startProxy(artDir, path.join(artDir, "style.json"));
  try {
    const post = (body) =>
      fetch(`${proxy.base}/v1/goal-art`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: typeof body === "string" ? body : JSON.stringify(body),
      });

    for (const [body, error] of [
      [{ words: "a month in Tokyo" }, "brand_required"],
      [{ brand: "aurora", words: "a month in Tokyo" }, "brand_required"],
      [{ brand: "orion", words: "hi" }, "words_too_short"],
      [{ brand: "orion", words: "x".repeat(200) }, "words_too_long"],
      [{ brand: "orion", words: "a bike", name: "n".repeat(61) }, "name_too_long"],
    ]) {
      const response = await post(body);
      assert.equal(response.status, 400, error);
      const payload = await response.json();
      assert.equal(payload.error, error);
      assert.ok(payload.detail);
    }

    const malformed = await post("{ not json");
    assert.equal(malformed.status, 400);
    assert.equal((await malformed.json()).error, "bad_request");

    // A finished dream is served from the file — no generator is involved.
    const id = goalArtId({ brand: "orion", words: "A month in Tokyo" });
    await fs.mkdir(artDir, { recursive: true });
    await fs.writeFile(path.join(artDir, `${id}.png`), PNG);

    const ready = await post({ brand: "orion", words: "a month in Tokyo" });
    assert.equal(ready.status, 200);
    const body = await ready.json();
    assert.deepEqual(body, { ok: true, id, status: "ready", url: `/v1/goal-art/${id}/image` });

    // Nothing was spawned for it: the directory still holds exactly one file.
    await new Promise((resolve) => setTimeout(resolve, 250));
    assert.deepEqual(await fs.readdir(artDir), [`${id}.png`]);
    assert.doesNotMatch(proxy.log(), /codex/);
  } finally {
    await proxy.stop();
    await fs.rm(artDir, { recursive: true, force: true });
  }
});

test("GET /v1/goal-art/:id reports the file-backed status", async () => {
  const artDir = await tempDir();
  const proxy = await startProxy(artDir, path.join(artDir, "style.json"));
  try {
    const id = goalArtId({ brand: "aurea", words: "Grandmother's garden" });
    await fs.mkdir(artDir, { recursive: true });
    await fs.writeFile(path.join(artDir, `${id}.png`), PNG);

    const ready = await fetch(`${proxy.base}/v1/goal-art/${id}`);
    assert.equal(ready.status, 200);
    assert.deepEqual(await ready.json(), {
      ok: true,
      id,
      status: "ready",
      url: `/v1/goal-art/${id}/image`,
    });

    // An id of the right shape that was never drawn, and one of no shape.
    for (const unknown of ["orion-a-bike-0123456789", "orion-a-bike.png", "not-an-id"]) {
      const response = await fetch(`${proxy.base}/v1/goal-art/${encodeURIComponent(unknown)}`);
      assert.equal(response.status, 404, unknown);
      assert.equal((await response.json()).error, "goal_art_not_found");
    }
  } finally {
    await proxy.stop();
    await fs.rm(artDir, { recursive: true, force: true });
  }
});

test("GET /v1/goal-art/:id/image serves the PNG and nothing outside the directory", async () => {
  const artDir = await tempDir();
  const proxy = await startProxy(artDir, path.join(artDir, "style.json"));
  try {
    const id = goalArtId({ brand: "orion", words: "One year of runway" });
    await fs.mkdir(artDir, { recursive: true });
    await fs.writeFile(path.join(artDir, `${id}.png`), PNG);
    // A file outside the art directory, and a part file inside it.
    await fs.writeFile(path.join(artDir, "secret.png"), PNG);
    await fs.writeFile(path.join(artDir, `.${id}.part.png`), PNG);

    const image = await fetch(`${proxy.base}/v1/goal-art/${id}/image`);
    assert.equal(image.status, 200);
    assert.equal(image.headers.get("content-type"), "image/png");
    assert.match(image.headers.get("cache-control"), /immutable/);
    assert.deepEqual(Buffer.from(await image.arrayBuffer()), PNG);

    // The id is the content: a repeat ask may be answered from the cache.
    const etag = image.headers.get("etag");
    const cached = await fetch(`${proxy.base}/v1/goal-art/${id}/image`, { headers: { "if-none-match": etag } });
    assert.equal(cached.status, 304);

    // Traversal, encoded traversal, dotfiles and foreign names are all refused.
    const denied = [
      `..%2F..%2Fsecret.png`,
      `%2e%2e%2fsecret.png`,
      `orion-runway%2F..%2F..%2Fsecret.png`,
      `orion-runway-0123456789.png`,
      `.${id}.part`,
      `secret`,
      `${id}%00.png`,
    ];
    for (const candidate of denied) {
      const response = await fetch(`${proxy.base}/v1/goal-art/${candidate}/image`);
      assert.equal(response.status, 404, candidate);
      assert.equal(response.headers.get("content-type"), "application/json; charset=utf-8", candidate);
    }

    // A valid id with no file yet is a clean 404, never bytes from elsewhere.
    const missing = await fetch(`${proxy.base}/v1/goal-art/orion-a-bike-0123456789/image`);
    assert.equal(missing.status, 404);
  } finally {
    await proxy.stop();
    await fs.rm(artDir, { recursive: true, force: true });
  }
});

test("health reports where art lands, whether the style file exists, and the backend", async () => {
  const artDir = await tempDir();
  const stylePath = path.join(artDir, "style.json");
  const proxy = await startProxy(artDir, stylePath);
  try {
    const before = await (await fetch(`${proxy.base}/health`)).json();
    assert.equal(before.goalArt.dir, artDir);
    assert.equal(before.goalArt.styleFile, stylePath);
    assert.equal(before.goalArt.styleSource, "built-in");
    assert.equal(before.goalArt.backend, "script");
    assert.equal(before.goalArt.generating, 0);
    assert.ok(before.goalArt.timeoutMs > 0);

    // The art direction's single source of truth, once it exists: the style is
    // read per request, never cached at boot.
    await fs.writeFile(stylePath, JSON.stringify({ orion: { scene_style: "s", subject_template: "t" } }));
    const after = await (await fetch(`${proxy.base}/health`)).json();
    assert.equal(after.goalArt.styleSource, "file");
    assert.equal(after.goalArt.backend, "script");
  } finally {
    await proxy.stop();
    await fs.rm(artDir, { recursive: true, force: true });
  }

  // A server that has a Fal key says so — without ever saying the key.
  const falArtDir = await tempDir();
  const falProxy = await startProxy(falArtDir, path.join(falArtDir, "style.json"), { FAL_KEY: "test-key-not-real" });
  try {
    const health = await (await fetch(`${falProxy.base}/health`)).json();
    assert.equal(health.goalArt.backend, "fal");
    assert.doesNotMatch(JSON.stringify(health), /test-key-not-real/, "health never carries the key");
  } finally {
    await falProxy.stop();
    await fs.rm(falArtDir, { recursive: true, force: true });
  }
});
