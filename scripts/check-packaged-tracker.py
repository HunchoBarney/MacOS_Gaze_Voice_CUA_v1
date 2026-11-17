"""Verify the shipped layout, never a checkout, app-support install or system Node."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def verify(app):
    app = app.resolve(strict=True)
    root = app / "Contents/Resources/EyeTracker"
    if root.resolve(strict=True) != root or (root.parent / "EyeTracking").resolve(strict=True) != root:
        raise ValueError("tracker or its runtime alias does not resolve inside the app")
    for link in root.rglob("*"):
        if link.is_symlink() and (os.path.isabs(os.readlink(link))
                                  or not link.resolve(strict=True).is_relative_to(root)):
            raise ValueError(f"non-relocatable tracker symlink: {link}")

    def require(name, executable=False):
        path = root / name
        if (not path.resolve().is_relative_to(root) or not path.is_file() or not path.stat().st_size
                or (executable and not os.access(path, os.X_OK))):
            raise ValueError(f"missing or unusable tracker payload: {name}")
        return path

    for name in ("bin/node", "node_modules/.bin/electron",
                 "node_modules/electron/dist/Electron.app/Contents/MacOS/Electron"):
        require(name, executable=True)
    for name in ("TRACKER_BUNDLE.json", "scripts/start-prod.cjs", "electron/main.cjs",
                 "node_modules/electron/cli.js", "dist/index.html"):
        require(name)
    assets = re.findall(r'(?:src|href)="(\./assets/[^"]+)"', (root / "dist/index.html").read_text())
    if not any(name.endswith(".js") for name in assets):
        raise ValueError("renderer index has no bundled script")
    for asset in assets:
        require("dist/" + asset)
    for variant in ("", "jsep.", "asyncify.", "jspi."):
        for ext in ("mjs", "wasm"):
            require(f"dist/runtime-assets/onnxruntime-web/ort-wasm-simd-threaded.{variant}{ext}")
    manifest = Path(__file__).resolve().parents[1] / "EyeTracking/scripts/required-models.sha256"
    if (root / "public/models").resolve(strict=True) != root / "dist/models":
        raise ValueError("model source alias must point at the bundled dist/models")
    subprocess.run(["shasum", "-a", "256", "-c", str(manifest)], cwd=root / "dist/models", check=True)
    metadata = json.loads(require("package.json").read_text())
    if require("node_modules/electron/path.txt").read_text() != "Electron.app/Contents/MacOS/Electron":
        raise ValueError("Electron launcher points at a different executable")
    if metadata["dependencies"]["electron"] != json.loads(require("node_modules/electron/package.json").read_text())["version"]:
        raise ValueError("packaged Electron does not match its pin")
    subprocess.run([str(root / "bin/node"), "-e", """
        const path = require('node:path');
        for (const id of ['electron', 'ws', '@nut-tree-fork/nut-js', 'onnxruntime-web/wasm']) {
          if (!require.resolve(id).startsWith(process.cwd() + path.sep)) throw Error(id);
        }
    """], cwd=root, env={"PATH": "/usr/bin:/bin"}, check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    try:
        verify(parser.parse_args().app)
    except (ValueError, OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"invalid packaged tracker: {exc}\n")
