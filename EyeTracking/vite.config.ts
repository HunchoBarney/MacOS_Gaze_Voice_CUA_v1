import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
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
    outDir: "dist",
    emptyOutDir: true
  }
});
