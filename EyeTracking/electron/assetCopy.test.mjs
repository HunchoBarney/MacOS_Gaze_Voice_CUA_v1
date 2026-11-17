import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";

const require = createRequire(import.meta.url);
const { copyIfStale } = require("./assetCopy.cjs");

const tmpDirs = [];

function tmpDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "jev-assetcopy-"));
  tmpDirs.push(dir);
  return dir;
}

function write(file, bytes) {
  fs.writeFileSync(file, Buffer.alloc(bytes, 0x61));
}

afterEach(() => {
  while (tmpDirs.length > 0) {
    fs.rmSync(tmpDirs.pop(), { recursive: true, force: true });
  }
});

describe("copyIfStale", () => {
  it("copies when the target does not exist", () => {
    const dir = tmpDir();
    const source = path.join(dir, "model.onnx");
    const outDir = path.join(dir, "out");
    fs.mkdirSync(outDir);
    const target = path.join(outDir, "model.onnx");
    write(source, 1024);
    expect(copyIfStale(source, target)).toBe(true);
    expect(fs.readFileSync(target).equals(fs.readFileSync(source))).toBe(true);
  });

  it("skips the copy when the target already carries the source", () => {
    const dir = tmpDir();
    const source = path.join(dir, "model.onnx");
    const target = path.join(dir, "model-copy.onnx");
    write(source, 2048);
    expect(copyIfStale(source, target)).toBe(true);
    // Second pass: same size, target mtime >= source mtime — the boot-time
    // no-op case this helper exists for.
    expect(copyIfStale(source, target)).toBe(false);
  });

  it("re-copies when the size differs", () => {
    const dir = tmpDir();
    const source = path.join(dir, "model.onnx");
    const target = path.join(dir, "model-copy.onnx");
    write(source, 128);
    write(target, 64);
    expect(copyIfStale(source, target)).toBe(true);
    expect(fs.statSync(target).size).toBe(128);
  });

  it("re-copies when the source is newer than the target", () => {
    const dir = tmpDir();
    const source = path.join(dir, "model.onnx");
    const target = path.join(dir, "model-copy.onnx");
    write(source, 128);
    write(target, 128);
    // Same size but the source got touched after the copy — a same-size
    // model rebuild must not be masked by a stale target.
    const stale = new Date(Date.now() - 60_000);
    fs.utimesSync(target, stale, stale);
    expect(copyIfStale(source, target)).toBe(true);
  });
});
