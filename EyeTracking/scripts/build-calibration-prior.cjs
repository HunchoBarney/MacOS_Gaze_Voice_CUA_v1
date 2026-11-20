#!/usr/bin/env node
// Builds the starting map a new user's tracker fits before any personal
// label arrives (main.cjs readCalibrationPrior, Calibration.seedPrior).
// Input: one or more MediaPipe calibration files (.gaze_calibration.json),
// e.g. the owner's own and later consenting volunteers'. Only the labelled
// feature vectors and their screen targets are copied: no images, no fit
// state, no file paths.
//
//   node scripts/build-calibration-prior.cjs <calibration.json>... [--out public/priors/mediapipe-prior.json]
const fs = require("fs");
const path = require("path");

const args = process.argv.slice(2);
const outIndex = args.indexOf("--out");
const output = outIndex >= 0 ? args[outIndex + 1] : path.join(__dirname, "..", "public", "priors", "mediapipe-prior.json");
const inputs = outIndex >= 0 ? args.filter((_, index) => index !== outIndex && index !== outIndex + 1) : args;
if (inputs.length === 0 || !output) {
  console.error("usage: build-calibration-prior.cjs <calibration.json>... [--out <prior.json>]");
  process.exit(2);
}

const round = (value) => (typeof value === "number" ? Number(value.toFixed(5)) : value);
const roundDeep = (value) =>
  Array.isArray(value)
    ? value.map(roundDeep)
    : value && typeof value === "object"
      ? Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, roundDeep(entry)]))
      : round(value);

let featureVersion = null;
const samples = [];
for (const input of inputs) {
  const calibration = JSON.parse(fs.readFileSync(input, "utf8"));
  // Field 12 of the context fingerprint names the detector; the legacy ONNX
  // pipeline's feature space doesn't transfer.
  const detector = String(calibration.context_fingerprint ?? "").split("|")[12];
  if (detector !== "mediapipe") {
    console.error(`${input}: not a MediaPipe calibration (detector ${detector ?? "unknown"})`);
    process.exit(1);
  }
  if (featureVersion !== null && calibration.feature_version !== featureVersion) {
    console.error(`${input}: feature schema v${calibration.feature_version} differs from v${featureVersion}`);
    process.exit(1);
  }
  featureVersion = calibration.feature_version;
  const usable = (calibration.feature_samples ?? []).filter(
    (entry) =>
      Array.isArray(entry?.feature?.point) &&
      entry.feature.point.every(Number.isFinite) &&
      Array.isArray(entry.target) &&
      entry.target.length === 2 &&
      entry.target.every((v) => Number.isFinite(v) && v >= 0 && v <= 1)
  );
  samples.push(...usable.map((entry) => ({ feature: roundDeep(entry.feature), target: roundDeep(entry.target) })));
  console.log(`${path.basename(input)}: ${usable.length} samples`);
}

fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(
  output,
  `${JSON.stringify({ detector: "mediapipe", feature_version: featureVersion, created_at: new Date().toISOString(), people: inputs.length, samples })}\n`
);
console.log(`wrote ${samples.length} samples from ${inputs.length} calibration(s) to ${output}`);
