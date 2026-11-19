"use strict";

function retinafaceRelease(profile, args) {
  if (profile === undefined) return false;
  if (profile !== "retinaface-v1") throw new Error("Unknown tracker release profile");
  const flags = new Set(["--external-api", "--no-tray"]);
  const values = new Set(["--host-pid", "--display-size-inch", "--camera-fov", "--gaze-projection-mode",
    "--wasm-threads", "--gaze-max-fps", "--calibration-file", "--web-accelerator", "--detector"]);
  const seen = new Set();
  for (let i = 0; i < args.length; i++) {
    const split = args[i].indexOf("=");
    const key = split < 0 ? args[i] : args[i].slice(0, split);
    if (seen.has(key)) throw new Error("Repeated release argument");
    seen.add(key);
    if (flags.has(key) && split < 0) continue;
    if (!values.has(key)) throw new Error("Unsupported release argument");
    const value = split < 0 ? args[++i] : args[i].slice(split + 1);
    if (!value || value.startsWith("--") || (key === "--detector" && value !== "retinaface") ||
        (key === "--web-accelerator" && !["auto", "webgpu", "wasm"].includes(value))) {
      throw new Error("Unsupported release argument value");
    }
  }
  return true;
}

module.exports = { retinafaceRelease };
