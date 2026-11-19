import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { createRequire } from "node:module";
import { describe, expect, it } from "vitest";

const local = createRequire(import.meta.url);
const main = fs.readFileSync(new URL("./main.cjs", import.meta.url), "utf8");

async function exercise(args, profile) {
  const calls = [], effects = [], handlers = {};
  const frame = {}, contents = {
    mainFrame: frame, send: (_channel, payload) => effects.push(payload.type)
  };
  const app = { on() {}, commandLine: { appendSwitch() {} }, requestSingleInstanceLock: () => true, whenReady: () => new Promise(() => {}) };
  const modules = {
    electron: { app, ipcMain: { on: (k, fn) => { handlers[k] = fn; }, handle() {} } },
    "@nut-tree-fork/nut-js": {
      mouse: { setPosition: () => calls.push("move"), pressButton: () => calls.push("press"), releaseButton: () => calls.push("release") },
      Point: class {}, Button: { LEFT: 1 }
    },
    path, fs: {}, "./externalApi.cjs": {}, "./hostWatchdog.cjs": {}, "./assetCopy.cjs": {},
    "./externalStore.cjs": local("./externalStore.cjs"), "./lipClickController.cjs": local("./lipClickController.cjs"),
    "./releaseProfile.cjs": local("./releaseProfile.cjs"), "../package.json": { jevTrackerProfile: profile }
  };
  const require = key => { if (!(key in modules)) throw Error(key); return modules[key]; };
  require.resolve = () => "/fixture/wasm";
  const ctx = vm.createContext({
    __dirname: "/fixture", require, process: { argv: ["electron", ".", ...args], platform: "darwin",
      env: { VITE_DEV_SERVER_URL: "http://unused.invalid" }, on() {} }, contents,
    console: { warn() {}, log() {}, error() {} }
  });
  vm.runInContext(main, ctx);
  if (profile) expect(vm.runInContext("useDevServer()", ctx)).toBe(false);
  vm.runInContext(`
    mainWindow = { webContents: contents, isDestroyed: () => false };
    rendererFrame = contents.mainFrame;
    rendererReady = true;
    configureLipClickController(cliArgs(), { x: 0, y: 0, width: 800, height: 600 });
  `, ctx);
  const captured = Date.now() - 10;
  handlers["publish-backend-message"]({ sender: contents, senderFrame: frame }, {
    type: "gaze", x_norm: 0.4, y_norm: 0.5, captured_at_ms: captured, mouth_detected: true, mouth_open: true
  });
  await vm.runInContext("lipClickController?.idle()", ctx);
  expect(vm.runInContext('gazeStateStore.getSlice("gaze")', ctx)).toMatchObject({ x_norm: 0.4, y_norm: 0.5, captured_at_ms: captured });
  return { calls, effects };
}

describe("hosted lip pointer boundary", () => {
  const optIn = ["--enable-lip-motion", "--detector", "yolo"];
  it.each([
    ["ordinary", ["--no-tray", "--host-pid", "123"]],
    ["explicit", ["--no-tray", "--host-pid", "123", ...optIn]],
    ["conflicts", [...optIn, "--no-tray=false", "--tray", "--detector=retinaface", "--no-tray", "--host-pid=0", "--enable-lip-motion"]],
    ["duplicates", ["--host-pid", "123", "--no-tray", ...optIn, "--host-pid", "0", "--no-tray", "--detector", "retinaface"]]
  ])("%s hosted launch leaves gaze intact without moving, pressing or flashing", async (_name, args) => {
    expect(await exercise(args)).toEqual({ calls: [], effects: [] });
  });
  it("preserves standalone explicit opt-in and standalone default-off", async () => {
    expect(await exercise(optIn)).toEqual({ calls: ["move", "press", "release"], effects: ["lip_click_effect"] });
    expect(await exercise(["--detector", "yolo"])).toEqual({ calls: [], effects: [] });
  });
  it("rejects a developer renderer even at the marked main entry", async () => {
    expect(await exercise(["--no-tray"], "retinaface-v1")).toEqual({ calls: [], effects: [] });
  });
});
