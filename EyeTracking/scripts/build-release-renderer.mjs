import { mkdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build, version } from "../node_modules/vite/dist/node/index.js";

const root = fileURLToPath(new URL("../", import.meta.url));
const outDir = path.resolve(process.argv[2]);
const pkg = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"));
if (version !== pkg.dependencies.vite) throw new Error("Vite does not match the pinned build tool");
await mkdir(outDir);
await build({ root, envFile: false, build: { outDir, copyPublicDir: false, emptyOutDir: false } });
await readFile(path.join(outDir, ".vite/manifest.json"));
