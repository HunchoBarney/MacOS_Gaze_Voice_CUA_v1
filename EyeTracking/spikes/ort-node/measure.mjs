// P2a spike — onnxruntime-node CoreML EP bench for the tracker model set.
// Self-contained: discovers EyeTracking/public/models/*.onnx, times each
// model per execution provider (cpu|coreml|wasm), proves CoreML binding in
// a separate profiling pass, and composes the cadence-weighted chain.
// Roles/cadences verified against EyeTracking/web/src/inference/*.ts — see
// .agent/phases/P2a-coreml-tracker.md (harness-archive-2026-11-19 tag) for the
// source-line inventory.
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  writeFileSync
} from "node:fs";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

const SPIKE_DIR = path.dirname(fileURLToPath(import.meta.url));
const MODELS_DIR = path.resolve(SPIKE_DIR, "..", "..", "public", "models");
const DEFAULT_OUT = path.join("results", "results.json");
const BAR_MS = 66.7; // 15 FPS
const SEED = 42;
const PROFILE_ITERS = 3;

// Pipeline roles read from source during M1 (inferenceWorker.ts /
// runtimes.ts / core.ts / electron/main.cjs). Cadence = runs per 15-frame
// second in production defaults; off/unused models carry cadence 0 and
// still get standalone rows.
const MODEL_ROLES = [
  {
    match: /^gaze_1x3x160x160/,
    role: "estimate",
    cadenceHz: 15,
    source: "unconditional per frame — inferenceWorker.ts:903 (models.estimate), input 'input' [1,3,160,160] runtimes.ts:227"
  },
  {
    match: /^gaze_Nx3x160x160/,
    role: "off",
    cadenceHz: 0,
    source: "unreferenced by shipped defaults — electron/main.cjs:357-371 names gaze_1x3x160x160 only; benched with N resolved to 1"
  },
  {
    match: /^mobileone_s0_gaze/,
    role: "appearance",
    cadenceHz: 5,
    source: "~5Hz via appearanceChannel.maybeRun — inferenceWorker.ts:897, APPEARANCE_PERIOD_MS=220 core.ts:811; forced wasm in prod runtimes.ts:142-146; input [1,3,448,448] core.ts:810"
  },
  {
    match: /^retinaface/,
    role: "detect",
    cadenceHz: 1,
    source: "default detector (detector=retinaface) — electron/main.cjs:354-364; <=1Hz DETECT_INTERVAL_MS=1000 inferenceWorker.ts:296,844; input 'input' [1,3,480,640]"
  },
  {
    match: /^yolomit/,
    role: "detect",
    cadenceHz: 1,
    source: "alternate detector (--detector yolo) — electron/main.cjs:360-363; same <=1Hz cadence; input session.inputNames[0] ('images') [1,3,480,640] runtimes.ts:187,201"
  },
  {
    match: /^vsdlm_l/,
    role: "lip",
    cadenceHz: 0,
    source: "off unless --enable-lip-motion && detector===yolo — electron/main.cjs:372, inferenceWorker.ts:954-957; input 'images' [1,3,30,48] runtimes.ts:191,246"
  }
];

function roleFor(file) {
  const hit = MODEL_ROLES.find((r) => r.match.test(file));
  return hit ?? { role: "off", cadenceHz: 0, source: "no pipeline mapping found (unreferenced)" };
}

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function machineInfo() {
  const sysctl = (key) => {
    try {
      return execFileSync("sysctl", ["-n", key], { encoding: "utf8" }).trim();
    } catch {
      return null;
    }
  };
  return {
    model: sysctl("hw.model") ?? "MacBookPro17,1",
    cpu: sysctl("machdep.cpu.brand_string") ?? "Apple M1",
    mem_bytes: Number(sysctl("hw.memsize") ?? 8589934592),
    arch: process.arch,
    node: process.version
  };
}

function parseArgs(argv) {
  const opts = {
    ep: null,
    iters: 100,
    warmup: 20,
    chain: false,
    profile: false,
    report: false,
    smoke: false,
    out: DEFAULT_OUT
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--ep") opts.ep = argv[++i];
    else if (arg === "--iters") opts.iters = Number(argv[++i]);
    else if (arg === "--warmup") opts.warmup = Number(argv[++i]);
    else if (arg === "--chain") opts.chain = true;
    else if (arg === "--profile") opts.profile = true;
    else if (arg === "--report") opts.report = true;
    else if (arg === "--smoke") opts.smoke = true;
    else if (arg === "--out") opts.out = argv[++i];
    else if (arg.startsWith("--ep=")) opts.ep = arg.slice(5);
    else if (arg.startsWith("--iters=")) opts.iters = Number(arg.slice(8));
    else if (arg.startsWith("--warmup=")) opts.warmup = Number(arg.slice(9));
    else if (arg.startsWith("--out=")) opts.out = arg.slice(6);
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (opts.smoke) {
    opts.iters = 8;
    opts.warmup = 2;
  }
  if (opts.ep !== null && !["cpu", "coreml", "wasm"].includes(opts.ep)) {
    throw new Error(`--ep must be cpu|coreml|wasm, got '${opts.ep}'`);
  }
  return opts;
}

function listModels() {
  return readdirSync(MODELS_DIR)
    .filter((f) => f.endsWith(".onnx"))
    .sort();
}

function resolveOutPath(out) {
  return path.isAbsolute(out) ? out : path.resolve(process.cwd(), out);
}

function loadResults(outPath) {
  if (!existsSync(outPath)) {
    return { machine: machineInfo(), seed: SEED, results: [], chains: [] };
  }
  const doc = JSON.parse(readFileSync(outPath, "utf8"));
  doc.results ??= [];
  doc.chains ??= [];
  return doc;
}

function saveResults(outPath, doc) {
  doc.generated_at = new Date().toISOString();
  doc.machine ??= machineInfo();
  mkdirSync(path.dirname(outPath), { recursive: true });
  writeFileSync(outPath, `${JSON.stringify(doc, null, 2)}\n`);
}

// Symbolic/unknown dims resolve to the production batch size: every
// inference-worker call site feeds batch 1, so N -> 1 (policy recorded
// per input in the row).
function resolveDims(dims) {
  const resolved = [];
  const mapping = {};
  for (const d of dims ?? []) {
    if (typeof d === "number" && Number.isInteger(d) && d > 0) {
      resolved.push(d);
    } else {
      const key = String(d);
      mapping[key] = 1;
      resolved.push(1);
    }
  }
  return { resolved, mapping };
}

async function getOrt(ep) {
  if (ep === "wasm") {
    const ort = await import("onnxruntime-web");
    ort.env.wasm.numThreads = 1;
    ort.env.wasm.wasmPaths = `${path.join(SPIKE_DIR, "node_modules", "onnxruntime-web", "dist")}${path.sep}`;
    if (ort.env.logLevel !== undefined) ort.env.logLevel = "error";
    return { ort, providerArg: ["wasm"], modelArg: "bytes" };
  }
  const ort = await import("onnxruntime-node");
  if (ort.env?.logLevel !== undefined) ort.env.logLevel = "error";
  return { ort, providerArg: [ep], modelArg: "path" };
}

function tensorFor(ort, meta, rng) {
  const { resolved } = resolveDims(meta.dims ?? []);
  const size = resolved.reduce((a, b) => a * b, 1);
  const dtype = meta.type ?? "float32";
  let data;
  if (dtype === "float32" || dtype === "float") {
    data = new Float32Array(size);
    for (let i = 0; i < size; i += 1) data[i] = rng();
    return { tensor: new ort.Tensor("float32", data, resolved), fill: "mulberry32(seed=42) [0,1)" };
  }
  if (dtype === "float16") {
    data = new Uint16Array(size);
    return { tensor: new ort.Tensor("float16", data, resolved), fill: "zeros (dtype float16)" };
  }
  if (dtype === "int64") {
    data = new BigInt64Array(size);
    return { tensor: new ort.Tensor("int64", data, resolved), fill: "zeros (dtype int64)" };
  }
  if (dtype === "int32") {
    data = new Int32Array(size);
    return { tensor: new ort.Tensor("int32", data, resolved), fill: "zeros (dtype int32)" };
  }
  if (dtype === "uint8" || dtype === "bool") {
    data = new Uint8Array(size);
    return { tensor: new ort.Tensor(dtype, data, resolved), fill: "zeros (dtype uint8/bool)" };
  }
  throw new Error(`unsupported input dtype '${dtype}'`);
}

// ort-node/ort-web expose inputMetadata as an array of {name, isTensor,
// type, shape}; normalize to a name -> {type, dims} map (shape dims may be
// numbers or symbolic strings like 'N').
function metaByName(session) {
  const raw = session.inputMetadata;
  const list = Array.isArray(raw) ? raw : Object.values(raw ?? {});
  const map = {};
  for (const entry of list) {
    if (!entry || typeof entry !== "object" || entry.name === undefined) continue;
    map[entry.name] = { type: entry.type ?? "float32", dims: entry.shape ?? entry.dimensions ?? entry.dims ?? [] };
  }
  for (const name of session.inputNames) {
    map[name] ??= { type: "float32", dims: [] };
  }
  return map;
}

function inputMeta(session) {
  const meta = metaByName(session);
  return session.inputNames.map((name) => {
    const m = meta[name];
    const { resolved, mapping } = resolveDims(m.dims);
    return {
      name,
      dims: m.dims.map((d) => (typeof d === "number" ? d : String(d))),
      resolved_dims: resolved,
      dtype: m.type ?? "float32",
      ...(Object.keys(mapping).length > 0 ? { symbolic_resolved: mapping } : {})
    };
  });
}

function percentile(sorted, p) {
  if (sorted.length === 0) return null;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[idx];
}

async function measureModel(file, ep, opts) {
  const role = roleFor(file);
  const modelPath = path.join(MODELS_DIR, file);
  const row = {
    model: file,
    role: role.role,
    cadence_hz: role.cadenceHz,
    role_source: role.source,
    ep
  };
  let ort;
  try {
    ({ ort } = await getOrt(ep));
  } catch (error) {
    return { ...row, status: "load_error", error: `ort backend init: ${String(error?.message ?? error)}` };
  }
  let session;
  try {
    session =
      ep === "wasm"
        ? await ort.InferenceSession.create(new Uint8Array(readFileSync(modelPath)), {
            executionProviders: ["wasm"],
            logSeverityLevel: 3
          })
        : await ort.InferenceSession.create(modelPath, {
            executionProviders: [ep],
            logSeverityLevel: 3
          });
  } catch (error) {
    return { ...row, status: "load_error", error: String(error?.message ?? error) };
  }
  row.inputs = inputMeta(session);
  const rng = mulberry32(SEED);
  const feeds = {};
  const tensors = [];
  try {
    const meta = metaByName(session);
    for (const name of session.inputNames) {
      const made = tensorFor(ort, meta[name], rng);
      feeds[name] = made.tensor;
      tensors.push(made.tensor);
    }
    for (let i = 0; i < opts.warmup; i += 1) {
      await session.run(feeds);
    }
    const times = [];
    let rss = 0;
    for (let i = 0; i < opts.iters; i += 1) {
      const t0 = performance.now();
      await session.run(feeds);
      times.push(performance.now() - t0);
      rss = Math.max(rss, process.memoryUsage().rss);
    }
    rss = Math.max(rss, process.memoryUsage().rss);
    times.sort((a, b) => a - b);
    const p50 = percentile(times, 50);
    Object.assign(row, {
      status: "ok",
      warmup: opts.warmup,
      iters: opts.iters,
      min_ms: times[0],
      median_ms: p50,
      p50_ms: p50,
      p95_ms: percentile(times, 95),
      max_ms: times[times.length - 1],
      rss_bytes: rss
    });
  } catch (error) {
    Object.assign(row, { status: "run_error", error: String(error?.message ?? error) });
  } finally {
    for (const t of tensors) {
      try {
        t.dispose();
      } catch {}
    }
    try {
      await session.release();
    } catch {}
  }
  return row;
}

// --- EP-binding proof: separate profiling pass, never on timed runs ---
function countBoundNodes(profilePath, needle) {
  const doc = JSON.parse(readFileSync(profilePath, "utf8"));
  const events = Array.isArray(doc) ? doc : doc.traceEvents ?? doc.events ?? [];
  const nodes = events.filter((e) => e && typeof e === "object" && (e.cat === "Node" || e.args?.provider !== undefined));
  const bound = nodes.filter((e) => String(e.args?.provider ?? "").includes(needle));
  return { total: nodes.length, bound: bound.length };
}

async function profileModel(file, ep) {
  const needle = ep === "coreml" ? "CoreML" : ep === "cpu" ? "CPU" : "Wasm";
  const modelPath = path.join(MODELS_DIR, file);
  const out = { model: file, ep };
  let ort;
  try {
    ({ ort } = await getOrt(ep));
    // Unique prefix per model: ORT creates the (0-byte) profile file at
    // session-create time and fills it at endProfiling/release, so a
    // name-diff against a pre-create snapshot misses it. Match on prefix.
    const stem = file.replace(/\.onnx$/, "");
    const prefix = path.join(process.cwd(), `onnxruntime_profile_${stem}_${ep}`);
    const prefixName = path.basename(prefix);
    const session =
      ep === "wasm"
        ? await ort.InferenceSession.create(new Uint8Array(readFileSync(modelPath)), {
            executionProviders: ["wasm"],
            enableProfiling: true
          })
        : await ort.InferenceSession.create(modelPath, {
            executionProviders: [ep],
            enableProfiling: true,
            profileFilePrefix: prefix
          });
    const meta = metaByName(session);
    const rng = mulberry32(SEED);
    const feeds = {};
    const tensors = [];
    for (const name of session.inputNames) {
      const made = tensorFor(ort, meta[name], rng);
      feeds[name] = made.tensor;
      tensors.push(made.tensor);
    }
    // A mid-run fault (e.g. retinaface's zero-box NMS under CoreML) must
    // not lose the partition evidence — binding is decided at create time,
    // so still endProfiling and collect the file.
    let runError = null;
    try {
      for (let i = 0; i < PROFILE_ITERS; i += 1) {
        await session.run(feeds);
      }
    } catch (error) {
      runError = String(error?.message ?? error);
    }
    if (typeof session.endProfiling === "function") {
      await session.endProfiling();
    }
    for (const t of tensors) {
      try {
        t.dispose();
      } catch {}
    }
    try {
      await session.release();
    } catch {}
    // The profile file exists early but is only filled on teardown — poll
    // for a non-empty match on our unique prefix.
    let found = null;
    for (let attempt = 0; attempt < 80 && found === null; attempt += 1) {
      const candidate = readdirSync(process.cwd())
        .filter((f) => f.startsWith(prefixName) && f.endsWith(".json"))
        .map((f) => path.join(process.cwd(), f))
        .find((f) => {
          try {
            return readFileSync(f, "utf8").trim().length > 8;
          } catch {
            return false;
          }
        });
      if (candidate) found = candidate;
      else await new Promise((r) => setTimeout(r, 50));
    }
    if (!found) {
      return { ...out, status: "profile_error", error: runError ?? "no onnxruntime_profile*.json emitted" };
    }
    const counts = countBoundNodes(found, needle);
    const dest = path.join(process.cwd(), "results", "profiles", `${stem}-${ep}.json`);
    mkdirSync(path.dirname(dest), { recursive: true });
    renameSync(found, dest);
    return {
      ...out,
      status: "ok",
      bound_nodes: counts.bound,
      total_nodes: counts.total,
      profile_file: path.relative(process.cwd(), dest),
      ...(runError ? { profile_run_error: runError } : {})
    };
  } catch (error) {
    return { ...out, status: "profile_error", error: String(error?.message ?? error) };
  }
}

function upsertRow(doc, row) {
  const idx = doc.results.findIndex((r) => r.model === row.model && r.ep === row.ep);
  if (idx >= 0) {
    if (row.status === "ok") delete doc.results[idx].error;
    doc.results[idx] = { ...doc.results[idx], ...row };
  } else {
    doc.results.push(row);
  }
}

async function runTimingPass(doc, ep, opts) {
  const models = listModels();
  for (const file of models) {
    process.stdout.write(`[${ep}] ${file} ... `);
    const row = await measureModel(file, ep, opts);
    upsertRow(doc, row);
    if (row.status === "ok") {
      process.stdout.write(`p50=${row.p50_ms.toFixed(2)}ms p95=${row.p95_ms.toFixed(2)}ms rss=${(row.rss_bytes / 1e6).toFixed(0)}MB\n`);
    } else {
      process.stdout.write(`${row.status}: ${row.error}\n`);
    }
  }
}

const PROFILE_KEYS = ["bound_nodes", "total_nodes", "profile_file", "profile_status", "profile_error", "profile_run_error", "coreml_bound", "coreml_unbound"];

async function runProfilePass(doc, ep) {
  const models = listModels();
  for (const file of models) {
    process.stdout.write(`[profile:${ep}] ${file} ... `);
    const p = await profileModel(file, ep);
    // Clear stale profile fields before merging — a re-run that now
    // succeeds must not keep an old coreml_unbound/profile_error.
    const old = doc.results.find((r) => r.model === file && r.ep === ep);
    if (old) for (const k of PROFILE_KEYS) delete old[k];
    if (p.status === "ok") {
      const flag = ep === "coreml" ? (p.bound_nodes > 0 ? { coreml_bound: true } : { coreml_unbound: true }) : {};
      upsertRow(doc, { model: file, ep, bound_nodes: p.bound_nodes, total_nodes: p.total_nodes, profile_file: p.profile_file, ...(p.profile_run_error ? { profile_run_error: p.profile_run_error } : {}), ...flag });
      process.stdout.write(`bound=${p.bound_nodes}/${p.total_nodes}${p.profile_run_error ? " (run faulted after binding — " + p.profile_run_error.slice(0, 60) + ")" : ""}\n`);
    } else {
      upsertRow(doc, { model: file, ep, profile_status: p.status, profile_error: p.error, ...(ep === "coreml" ? { coreml_unbound: true } : {}) });
      process.stdout.write(`${p.status}: ${p.error}\n`);
    }
  }
}

// --- chain composition ---
function chainFor(doc, ep) {
  const rows = doc.results.filter((r) => r.ep === ep && r.status === "ok" && typeof r.p50_ms === "number");
  const byRole = { estimate: [], detect: [], appearance: [], lip: [], off: [] };
  for (const r of rows) (byRole[r.role] ?? byRole.off).push(r);
  const sum = (xs) => xs.reduce((a, r) => a + r.p50_ms, 0);
  // effective_ms = Σ estimate.p50 + Σ detect.p50×(1/15) + Σ appearance.p50×(5/15)
  // (lip contributes 0 — off by default). Both detector variants count per
  // the literal formula; effective_ms_default uses retinaface only.
  const detectDefault = byRole.detect.filter((r) => /^retinaface/.test(r.model));
  const effective = sum(byRole.estimate) + (sum(byRole.detect) * 1) / 15 + (sum(byRole.appearance) * 5) / 15;
  const effectiveDefault = sum(byRole.estimate) + (sum(detectDefault) * 1) / 15 + (sum(byRole.appearance) * 5) / 15;
  const strict = sum(rows);
  const p95Weighted =
    byRole.estimate.reduce((a, r) => a + (r.p95_ms ?? 0), 0) +
    (byRole.detect.reduce((a, r) => a + (r.p95_ms ?? 0), 0) * 1) / 15 +
    (byRole.appearance.reduce((a, r) => a + (r.p95_ms ?? 0), 0) * 5) / 15;
  const rssMax = rows.reduce((a, r) => Math.max(a, r.rss_bytes ?? 0), 0);
  return {
    ep,
    effective_ms: effective,
    effective_ms_default_detector: effectiveDefault,
    strict_ms: strict,
    weighted_p95_ms: p95Weighted,
    fps_effective: effective > 0 ? 1000 / effective : null,
    fps_strict: strict > 0 ? 1000 / strict : null,
    rss_max_bytes: rssMax,
    models_measured: rows.length,
    missing: doc.results.filter((r) => r.ep === ep && r.status !== "ok").map((r) => `${r.model}:${r.status}`)
  };
}

async function runChain(doc, opts) {
  const eps = new Set(doc.results.map((r) => r.ep));
  if (opts.ep) {
    const have = new Set(doc.results.filter((r) => r.ep === opts.ep && r.status === "ok").map((r) => r.model));
    const missing = listModels().filter((f) => !have.has(f));
    if (missing.length > 0) {
      process.stdout.write(`measuring missing ${opts.ep} rows: ${missing.join(", ")}\n`);
      for (const file of missing) upsertRow(doc, await measureModel(file, opts.ep, opts));
    }
    eps.add(opts.ep);
  }
  doc.chains = [...eps].sort().map((ep) => chainFor(doc, ep));
  for (const c of doc.chains) {
    process.stdout.write(
      `[chain:${c.ep}] effective=${c.effective_ms.toFixed(2)}ms (${(c.fps_effective ?? 0).toFixed(1)}fps) ` +
        `default-detector=${c.effective_ms_default_detector.toFixed(2)}ms strict=${c.strict_ms.toFixed(2)}ms ` +
        `p95=${c.weighted_p95_ms.toFixed(2)}ms rss_max=${(c.rss_max_bytes / 1e6).toFixed(0)}MB` +
        (c.missing.length ? ` missing=[${c.missing.join(",")}]` : "") +
        "\n"
    );
  }
}

// --- report ---
function fmt(v, digits = 2) {
  return typeof v === "number" && Number.isFinite(v) ? v.toFixed(digits) : "—";
}

function writeReport(doc, outPath) {
  const eps = [...new Set(doc.results.map((r) => r.ep))].sort();
  const models = listModels();
  const lines = [];
  const m = doc.machine ?? {};
  lines.push("# P2a — ort-node CoreML spike report", "");
  lines.push(
    `Machine: ${m.model ?? "?"} / ${m.cpu ?? "?"} / ${((m.mem_bytes ?? 0) / 2 ** 30).toFixed(0)} GB / ${m.arch ?? "?"} / node ${m.node ?? "?"}`
  );
  lines.push(`Seed ${doc.seed}; generated ${doc.generated_at}; bar: cadence-weighted effective p50 ≤ ${BAR_MS} ms (≥15 FPS).`, "");
  lines.push("## Per-model results (ms, p50 / p95; RSS peak MB)", "");
  const head = ["model", "role", "cad_hz", ...eps.map((e) => `${e} p50/p95/RSS`)];
  lines.push(`| ${head.join(" | ")} |`, `| ${head.map(() => "---").join(" | ")} |`);
  for (const file of models) {
    const role = roleFor(file);
    const cells = [file, role.role, String(role.cadenceHz)];
    for (const ep of eps) {
      const r = doc.results.find((x) => x.model === file && x.ep === ep);
      if (!r) cells.push("—");
      else if (r.status !== "ok") cells.push(`${r.status}`);
      else {
        const flag = r.coreml_bound ? " bound" : r.coreml_unbound ? " UNBOUND" : "";
        cells.push(`${fmt(r.p50_ms)} / ${fmt(r.p95_ms)} / ${((r.rss_bytes ?? 0) / 1e6).toFixed(0)}${flag}`);
      }
    }
    lines.push(`| ${cells.join(" | ")} |`);
  }
  lines.push("", "## CoreML binding (separate --profile pass)", "");
  lines.push("| model | bound_nodes | total_nodes | profile |", "|---|---|---|---|");
  for (const file of models) {
    const r = doc.results.find((x) => x.model === file && x.ep === "coreml");
    if (r?.bound_nodes !== undefined) {
      lines.push(`| ${file} | ${r.bound_nodes} | ${r.total_nodes ?? "?"} | ${r.profile_file ?? ""} |`);
    }
  }
  lines.push("", "## Chain (cadence-weighted effective per-frame cost @15 FPS target)", "");
  lines.push(
    "| EP | effective_ms | fps | eff_ms (default det.) | strict_ms | weighted p95_ms | RSS max MB |",
    "|---|---|---|---|---|---|---|"
  );
  for (const c of doc.chains) {
    // When the default (retinaface) detector row isn't ok for this EP, its
    // weighted term is silently 0 — flag the cell so the smaller number
    // can't be misread as "chain including retinaface".
    const detMissing = doc.results.some(
      (r) => r.ep === c.ep && /^retinaface/.test(r.model) && r.status !== "ok"
    );
    const defCell = fmt(c.effective_ms_default_detector) + (detMissing ? " †" : "");
    lines.push(
      `| ${c.ep} | ${fmt(c.effective_ms)} | ${fmt(c.fps_effective, 1)} | ${defCell} | ${fmt(c.strict_ms)} | ${fmt(c.weighted_p95_ms)} | ${(c.rss_max_bytes / 1e6).toFixed(0)} |`
    );
  }
  lines.push("", `Bar: weighted effective p50 ≤ **${BAR_MS} ms** (15 FPS).`, "");
  lines.push("`eff_ms (default det.)` = estimate + retinaface-p50×(1/15) + appearance-p50×(5/15). † default detector not ok on this EP — its term is 0 in that cell; see the caveat below for the honest detector-on-CPU figure.", "");
  const coreml = doc.chains.find((c) => c.ep === "coreml");
  // Detector caveat: the default detector's CoreML run faults on zero-box
  // NMS, so the detect term above is carried by the yolo variant alone.
  // Quantify the honest fallback — detect on CPU EP instead — so the
  // verdict isn't silently built on a free detector slot.
  const coremlDetectMissing = doc.results.filter((r) => r.ep === "coreml" && r.role === "detect" && r.status !== "ok");
  const cpuDetect = doc.results.filter((r) => r.ep === "cpu" && r.role === "detect" && r.status === "ok" && /^retinaface/.test(r.model));
  if (coreml && coremlDetectMissing.length > 0 && cpuDetect.length > 0) {
    const detCpuMs = (cpuDetect[0].p50_ms * 1) / 15;
    lines.push(
      `Caveat: ${coremlDetectMissing.map((r) => r.model).join(", ")} ${coremlDetectMissing[0].status} under CoreML ` +
        `(zero-element NMS output rejected: ${String(coremlDetectMissing[0].error ?? "").slice(0, 140)}...). ` +
        `With the default detector on CPU EP instead: effective ≈ ${fmt(coreml.effective_ms_default_detector + detCpuMs)} ms ` +
        `(${fmt(1000 / (coreml.effective_ms_default_detector + detCpuMs), 1)} FPS) — verdict ${coreml.effective_ms_default_detector + detCpuMs <= BAR_MS ? "unchanged" : "FLIPS"}.`,
      ""
    );
  }
  const unbound = doc.results.filter((r) => r.ep === "coreml" && r.coreml_unbound).map((r) => r.model);
  const loadErr = doc.results.filter((r) => r.status === "load_error" || r.status === "run_error").map((r) => `${r.model}@${r.ep}`);
  let verdict;
  if (!coreml) {
    verdict = "DISCARD — no coreml chain measured.";
  } else if (coreml.effective_ms <= BAR_MS) {
    verdict = `PROMOTE — coreml weighted effective p50 ${fmt(coreml.effective_ms)} ms (${fmt(coreml.fps_effective, 1)} FPS) ≤ ${BAR_MS} ms on this machine.`;
  } else {
    verdict =
      `DISCARD — coreml weighted effective p50 ${fmt(coreml.effective_ms)} ms (${fmt(coreml.fps_effective, 1)} FPS) > ${BAR_MS} ms on this machine. ` +
      "Ranked fallbacks: (1) keep onnxruntime-web WebGPU EP + cadence cuts (prior observed 9–20 FPS); " +
      "(2) CPU-EP hybrid (detector on CPU, estimate wherever fastest); (3) reduced model set; (4) defer eyes.";
  }
  if (unbound.length) verdict += ` coreml_unbound models: ${unbound.join(", ")}.`;
  if (loadErr.length) verdict += ` load/run errors: ${loadErr.join(", ")}.`;
  lines.push(`**Verdict: ${verdict}**`, "");
  const reportPath = path.join(path.dirname(outPath), "REPORT.md");
  writeFileSync(reportPath, `${lines.join("\n")}\n`);
  return reportPath;
}

async function introspectOnly() {
  const { ort } = await getOrt("cpu");
  for (const file of listModels()) {
    const modelPath = path.join(MODELS_DIR, file);
    const role = roleFor(file);
    try {
      const session = await ort.InferenceSession.create(modelPath, { executionProviders: ["cpu"], logSeverityLevel: 3 });
      const inputs = inputMeta(session)
        .map((i) => `${i.name} ${i.dtype}[${i.resolved_dims.join("x")}]${i.symbolic_resolved ? ` (symbolic ${JSON.stringify(i.symbolic_resolved)})` : ""}`)
        .join("; ");
      process.stdout.write(`${file}\n  role=${role.role} cad=${role.cadenceHz}Hz — ${role.source}\n  inputs: ${inputs}\n`);
      await session.release();
    } catch (error) {
      process.stdout.write(`${file}\n  role=${role.role} cad=${role.cadenceHz}Hz\n  LOAD_ERROR: ${error?.message ?? error}\n`);
    }
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const outPath = resolveOutPath(opts.out);
  if (opts.report) {
    const doc = loadResults(outPath);
    const p = writeReport(doc, outPath);
    process.stdout.write(`wrote ${p}\n`);
    return;
  }
  if (!opts.ep && !opts.chain && !opts.profile) {
    await introspectOnly();
    return;
  }
  const doc = loadResults(outPath);
  if (opts.ep) {
    await runTimingPass(doc, opts.ep, opts);
  }
  if (opts.profile) {
    await runProfilePass(doc, opts.ep ?? "coreml");
  }
  if (opts.chain) {
    await runChain(doc, opts);
  }
  saveResults(outPath, doc);
}

process.stdout.on("error", (e) => {
  if (e.code === "EPIPE") process.exit(0);
  throw e;
});

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
