"use strict";

const fs = require("node:fs");

// Startup copies a dozen multi-MB model/wasm blobs into the renderer static
// dir every launch, and nearly every one is a byte-identical repeat of the
// last boot. A copy is skipped only when the target already proves it
// carries the source: same size AND a target mtime at or after the
// source's — copyFileSync stamps the copy fresh, so a previous successful
// copy satisfies this while an older/restored target still re-copies.
// Returns true when bytes actually moved.
function copyIfStale(source, target) {
  const sourceStat = fs.statSync(source);
  let targetStat = null;
  try {
    targetStat = fs.statSync(target);
  } catch {
    targetStat = null;
  }
  if (targetStat !== null && targetStat.size === sourceStat.size && targetStat.mtimeMs >= sourceStat.mtimeMs) {
    return false;
  }
  fs.copyFileSync(source, target);
  return true;
}

module.exports = { copyIfStale };
