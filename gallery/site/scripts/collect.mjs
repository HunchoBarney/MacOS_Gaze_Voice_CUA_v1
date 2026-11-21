#!/usr/bin/env node
// Merges render manifest fragments and audit findings into public/renders/gallery.json,
// copies the renders beside it and writes small thumbnails for grid and card views. Usage:
//   node scripts/collect.mjs --renders <OUT dir> --findings <findings.json> [--out <dir>]
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, cpSync, existsSync, mkdirSync, openSync, readFileSync, readSync, closeSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const siteRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, arg, i, all) => (arg.startsWith("--") ? [...pairs, [arg.slice(2), all[i + 1]]] : pairs), []),
);
const rendersDir = resolve(args.renders ?? join(siteRoot, "sample/renders"));
const findingsPath = resolve(args.findings ?? join(siteRoot, "sample/findings.json"));
const outDir = resolve(args.out ?? join(siteRoot, "public/renders"));

const AREAS = ["Voice", "Gaze", "Guide", "Agents", "Proactive", "Menu bar", "Windows", "Onboarding", "Eye tracker"];
const SEVERITIES = ["P0", "P1", "P2", "P3"];
const THUMB_MAX = 960;
const THUMB_DIR = "_thumbs";
const CACHE_DIR = join(siteRoot, "node_modules/.cache/gallery-thumbs");
const warnings = [];
const warn = (message) => warnings.push(message);

if (!existsSync(rendersDir)) {
  console.error("collect: renders directory not found: " + rendersDir);
  process.exit(1);
}

const isRedesign = (name) => /^manifest\.redesign\.[^.]+\.json$/.test(name);
const fragments = readdirSync(rendersDir)
  .filter((name) => /^manifest\..+\.json$/.test(name) && !isRedesign(name))
  .sort()
  .map((name) => ({ name, ...JSON.parse(readFileSync(join(rendersDir, name), "utf8")) }));
if (fragments.length === 0) warn("no manifest.*.json fragments in " + rendersDir);

const components = new Map();
const scenes = new Map();
const assetExists = (rel) => typeof rel === "string" && existsSync(join(rendersDir, rel));

for (const fragment of fragments) {
  for (const component of fragment.components ?? []) {
    if (!AREAS.includes(component.area)) warn(component.id + ": unknown area " + JSON.stringify(component.area));
    for (const state of component.states ?? []) {
      for (const variant of state.variants ?? []) if (!assetExists(variant.image)) warn(component.id + "/" + state.id + ": missing image " + variant.image);
      for (const clip of state.clips ?? []) {
        if (!assetExists(clip.video)) warn(component.id + "/" + state.id + ": missing clip " + clip.video);
        if (!assetExists(clip.poster)) warn(component.id + "/" + state.id + ": missing poster " + clip.poster);
      }
    }
    const existing = components.get(component.id);
    if (!existing) {
      components.set(component.id, { ...component, producer: fragment.producer, states: [...(component.states ?? [])] });
      continue;
    }
    const known = new Set(existing.states.map((s) => s.id));
    for (const state of component.states ?? []) {
      if (known.has(state.id)) warn(component.id + ": state " + state.id + " defined twice; keeping the first");
      else existing.states.push(state);
    }
    existing.sources = [...new Set([...(existing.sources ?? []), ...(component.sources ?? [])])];
    existing.owner ??= component.owner;
  }
  for (const scene of fragment.scenes ?? []) {
    if (!assetExists(scene.image)) warn("scene " + scene.id + ": missing image " + scene.image);
    if (scene.clip && !assetExists(scene.clip.video)) warn("scene " + scene.id + ": missing clip " + scene.clip.video);
    if (scenes.has(scene.id)) warn("scene " + scene.id + " defined twice; keeping the first");
    else scenes.set(scene.id, scene);
  }
}

// The native harness renders each scene twice: <id> in dark and <id>-light. Fold each pair into one
// scene with a variant per appearance, the way component states carry light and dark variants.
const sceneVariant = (scene, scheme) => ({
  scheme,
  image: scene.image,
  width: scene.width,
  height: scene.height,
  ...(scene.clip ? { clip: scene.clip } : {}),
});
let mergedPairs = 0;
for (const [id, light] of [...scenes]) {
  if (!id.endsWith("-light")) continue;
  const dark = scenes.get(id.slice(0, -"-light".length));
  if (!dark) continue;
  dark.variants = [sceneVariant(dark, "dark"), sceneVariant(light, "light")];
  dark.components = [...new Set([...(dark.components ?? []), ...(light.components ?? [])])];
  dark.superseded ??= light.superseded;
  scenes.delete(id);
  mergedPairs += 1;
}

let findings = { generatedAt: null, skills: [], findings: [] };
if (existsSync(findingsPath)) findings = JSON.parse(readFileSync(findingsPath, "utf8"));
else warn("findings file not found: " + findingsPath + " (the audit page will be empty)");

const seenFindings = new Set();
for (const finding of findings.findings) {
  if (seenFindings.has(finding.id)) warn("finding " + finding.id + " appears twice");
  seenFindings.add(finding.id);
  if (!SEVERITIES.includes(finding.severity)) warn("finding " + finding.id + ": unknown severity " + finding.severity);
  const component = components.get(finding.component);
  if (!component) warn("finding " + finding.id + ": unknown component " + finding.component);
  else if (finding.proposedState && !component.states.some((s) => s.id === finding.proposedState))
    warn("finding " + finding.id + ": proposedState " + finding.proposedState + " not found on " + finding.component);
}
for (const scene of scenes.values())
  for (const id of scene.components ?? []) if (!components.has(id)) warn("scene " + scene.id + ": unknown component " + id);

// Redesign fragments (manifest.redesign.<producer>.json): components with directions A/B/C and
// combined scenes. Media paths are relative to the renders directory, like everything else.
const MEDIA_KEYS = ["dark", "light", "dark-rm", "light-rm"];
const redesignFragments = readdirSync(rendersDir)
  .filter(isRedesign)
  .sort()
  .map((name) => ({ name, producer: name.split(".")[2], ...JSON.parse(readFileSync(join(rendersDir, name), "utf8")) }));
const redesignComponents = new Map();
const redesignScenes = new Map();
function checkMediaSet(where, set) {
  if (!set) return;
  for (const [key, media] of Object.entries(set)) {
    if (!MEDIA_KEYS.includes(key)) warn(where + ": unknown media key " + key);
    if (!assetExists(media?.src)) warn(where + ": missing " + (media?.kind ?? "media") + " " + media?.src);
    if (media?.poster && !assetExists(media.poster)) warn(where + ": missing poster " + media.poster);
    if (!(media?.width > 0 && media?.height > 0)) warn(where + ": " + key + " has no width and height");
  }
}
for (const fragment of redesignFragments) {
  for (const component of fragment.components ?? []) {
    if (![1, 2, 3].includes(component.batch)) warn("redesign " + component.id + ": unknown batch " + component.batch);
    for (const id of component.current?.componentIds ?? [])
      if (!components.has(id)) warn("redesign " + component.id + ": current component " + id + " is not in the gallery");
    for (const direction of component.directions ?? []) {
      const where = "redesign " + component.id + "/" + direction.id;
      for (const state of direction.states ?? []) checkMediaSet(where + "/" + state.id, state.media);
      checkMediaSet(where + "/flow", direction.flow);
    }
    const existing = redesignComponents.get(component.id);
    if (!existing) {
      redesignComponents.set(component.id, { ...component, directions: [...(component.directions ?? [])] });
      continue;
    }
    const known = new Set(existing.directions.map((d) => d.id));
    for (const direction of component.directions ?? []) {
      if (known.has(direction.id)) warn("redesign " + component.id + ": direction " + direction.id + " defined twice; keeping the first");
      else existing.directions.push(direction);
    }
  }
  for (const scene of fragment.scenes ?? []) {
    checkMediaSet("redesign scene " + scene.id, scene.media);
    if (redesignScenes.has(scene.id)) warn("redesign scene " + scene.id + " defined twice; keeping the first");
    else redesignScenes.set(scene.id, scene);
  }
}
for (const scene of redesignScenes.values())
  for (const [id, pick] of Object.entries(scene.picks ?? {}))
    if (!redesignComponents.get(id)?.directions.some((d) => d.id === pick)) warn("redesign scene " + scene.id + ": picks " + id + " " + pick + ", which doesn't exist");
for (const component of redesignComponents.values()) component.directions.sort((a, b) => a.id.localeCompare(b.id));

rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });
cpSync(rendersDir, outDir, {
  recursive: true,
  filter: (src) => !src.endsWith(".frames") && !/manifest\.[^/]+\.json$/.test(src),
});

// Thumbnails: grids, cards and contact sheets load these; the stage and 1x/2x zoom keep the full PNG.
// Opaque renders become JPEG; transparent overlays stay PNG so the checkerboard shows through.
// Uses sips (macOS); elsewhere the site falls back to the full images.
function pngSize(file) {
  const fd = openSync(file, "r");
  const header = Buffer.alloc(24);
  readSync(fd, header, 0, 24, 0);
  closeSync(fd);
  if (header.toString("latin1", 1, 4) !== "PNG") return undefined;
  return { width: header.readUInt32BE(16), height: header.readUInt32BE(20) };
}

const hasSips = await run("sips", ["--help"]).then(() => true, () => false);
if (!hasSips) warn("sips not found; skipping thumbnails, so cards load the full renders");
const thumbJobs = new Map();

function thumb(rel, transparent) {
  if (!hasSips || typeof rel !== "string" || !rel.toLowerCase().endsWith(".png")) return undefined;
  const source = join(rendersDir, rel);
  if (!existsSync(source)) return undefined;
  const stat = statSync(source);
  const size = pngSize(source);
  if (!size || (Math.max(size.width, size.height) <= THUMB_MAX && stat.size <= 160_000)) return undefined;
  const ext = transparent ? "png" : "jpg";
  const target = THUMB_DIR + "/" + rel.replace(/\.png$/i, "." + ext);
  if (!thumbJobs.has(target)) {
    const key = createHash("sha1").update([rel, stat.size, stat.mtimeMs, THUMB_MAX, ext].join("|")).digest("hex");
    thumbJobs.set(target, { source, cached: join(CACHE_DIR, key + "." + ext), ext });
  }
  return target;
}

for (const component of components.values())
  for (const state of component.states)
    for (const variant of state.variants ?? []) {
      const t = thumb(variant.image, (variant.backdrop ?? "transparent") === "transparent");
      if (t) variant.thumb = t;
    }
for (const scene of scenes.values()) {
  const t = thumb(scene.image, false);
  if (t) scene.thumb = t;
  for (const variant of scene.variants ?? []) {
    const vt = thumb(variant.image, false);
    if (vt) variant.thumb = vt;
  }
}

mkdirSync(CACHE_DIR, { recursive: true });
const jobs = [...thumbJobs.entries()];
let made = 0;
async function worker() {
  for (let job = jobs.shift(); job; job = jobs.shift()) {
    const [target, { source, cached, ext }] = job;
    if (!existsSync(cached)) {
      const format = ext === "png" ? ["-s", "format", "png"] : ["-s", "format", "jpeg", "-s", "formatOptions", "82"];
      await run("sips", ["-Z", String(THUMB_MAX), ...format, source, "--out", cached]);
      made += 1;
    }
    mkdirSync(dirname(join(outDir, target)), { recursive: true });
    copyFileSync(cached, join(outDir, target));
  }
}
const thumbCount = thumbJobs.size;
await Promise.all(Array.from({ length: 3 }, worker));

const gallery = {
  generatedAt: new Date().toISOString(),
  producers: fragments.map(({ producer, commit, generatedAt }) => ({ producer, commit, generatedAt })),
  skills: findings.skills ?? [],
  findingsGeneratedAt: findings.generatedAt ?? null,
  components: [...components.values()].sort((a, b) => AREAS.indexOf(a.area) - AREAS.indexOf(b.area) || a.title.localeCompare(b.title)),
  scenes: [...scenes.values()],
  findings: findings.findings,
  ...(redesignFragments.length > 0 && {
    redesign: {
      generatedAt: redesignFragments.map((f) => f.generatedAt).sort().at(-1),
      producers: redesignFragments.map(({ producer, commit, generatedAt }) => ({ producer, commit, generatedAt })),
      components: [...redesignComponents.values()].sort((a, b) => a.batch - b.batch),
      scenes: [...redesignScenes.values()],
    },
  }),
};
writeFileSync(join(outDir, "gallery.json"), JSON.stringify(gallery));

for (const message of warnings) console.warn("collect: warning: " + message);
console.log(
  "collect: " + gallery.components.length + " components, " + gallery.scenes.length + " scenes (" + mergedPairs + " light/dark pairs merged), " +
    gallery.findings.length + " findings, " + redesignComponents.size + " redesign components, " + redesignScenes.size + " redesign scenes, " + thumbCount + " thumbnails (" + made + " new) from " + [...fragments, ...redesignFragments].map((f) => f.name).join(", ") + " -> " + outDir,
);
