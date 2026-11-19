import { createReadStream, existsSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";

// The MediaPipe landmarker loads its wasm loader + binary by URL from inside
// the inference worker. The build emits them into dist/runtime-assets/
// mediapipe/ (what electron/main.cjs points prod and bundled runs at) and
// the dev server serves the same path straight from node_modules.
function mediapipeWasmAssets(): Plugin {
  const wasmDir = path.dirname(createRequire(import.meta.url).resolve("@mediapipe/tasks-vision/vision_wasm_internal.wasm"));
  const files = ["vision_wasm_internal.js", "vision_wasm_internal.wasm"];
  return {
    name: "mediapipe-wasm-assets",
    configureServer(server) {
      server.middlewares.use("/runtime-assets/mediapipe", (req, res, next) => {
        const name = path.basename((req.url ?? "").split("?")[0]);
        if (!files.includes(name)) {
          next();
          return;
        }
        res.setHeader("Content-Type", name.endsWith(".wasm") ? "application/wasm" : "text/javascript");
        res.setHeader("Cross-Origin-Resource-Policy", "same-origin");
        createReadStream(path.join(wasmDir, name)).pipe(res);
      });
    },
    generateBundle() {
      for (const name of files) {
        this.emitFile({ type: "asset", fileName: `runtime-assets/mediapipe/${name}`, source: readFileSync(path.join(wasmDir, name)) });
      }
    }
  };
}

// The legacy ONNX weights carry no license grant: a checkout that fetched
// them for the --legacy-models A/B keeps them in public/models, but the
// build (and so the bundled app) never ships them. The A/B still works from
// a checkout — electron/main.cjs copies the requested model out of public/
// at boot.
function dropLegacyWeights(): Plugin {
  let outDir = "dist";
  return {
    name: "drop-legacy-weights",
    apply: "build",
    configResolved(config) {
      outDir = path.resolve(config.root, config.build.outDir);
    },
    closeBundle() {
      const models = path.join(outDir, "models");
      if (!existsSync(models)) return;
      for (const name of readdirSync(models)) {
        if (name.endsWith(".onnx")) rmSync(path.join(models, name));
      }
    }
  };
}

export default defineConfig({
  plugins: [react(), mediapipeWasmAssets(), dropLegacyWeights()],
  // Electron's production path loads dist/index.html over file:// — the
  // default "/" base emits /assets/* URLs that 404 there. Relative base
  // resolves bundles beside index.html; dev server handles it fine.
  base: "./",
  server: {
    headers: {
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp"
    }
  },
  experimental: {
    bundledDev: true
  },
  worker: {
    format: "iife"
  },
  build: {
    manifest: true,
    outDir: "dist",
    emptyOutDir: true
  }
});
