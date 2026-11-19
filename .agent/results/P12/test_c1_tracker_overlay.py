import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent


def load(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


recipe = load(HERE.parent / "P4/jev-stage-candidate.py")
manifest = load(HERE / "c1_manifest.py")
overlay = recipe.tracker_overlay()
stage = recipe.helper()


def put(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)
    return stage.digest(path)


class GazeOverlayTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.frozen = self.root / "freeze"
        self.current = self.root / "source"
        self.app = self.root / "copy.app"
        self.tracker = self.app / "Contents/Resources/EyeTracker"
        self.snapshot_path = self.frozen / "snapshot.json"
        self.inputs = {"EyeTracking/" + overlay.MAIN: b"new main", "EyeTracking/" + overlay.PRODUCER: b"new producer",
                       "EyeTracking/web/src/App.tsx": b"app",
                       "EyeTracking/web/src/global.d.ts": b"types"}
        hashes = {n: put(self.frozen / n, b) for n, b in self.inputs.items()}
        outputs = {n: put(self.frozen / "renderer-output" / n, n.encode()) for n in overlay.OUTPUTS}
        for n,k in (("INPUTS", hashes), ("OUTPUTS", outputs),
                    ("PINS", {**overlay.PINS, "status":"approved-final"})):
            patch = mock.patch.object(overlay, n, k)
            patch.start()
            self.addCleanup(patch.stop)
        self.sources = hashes.copy()
        for n in ("Sources/JevVoice/Fixture.swift", "Package.swift", "Package.resolved", "Info.plist"):
            self.sources[n] = put(self.frozen / n, n.encode())
        for n in overlay.RECIPE:
            self.sources[n] = put(self.frozen / n, overlay.PINS_PATH.read_bytes() if n == overlay.PINS_SOURCE else n.encode())
        self.snapshot = {"label": recipe.GAZE, "renderer_output_sha256": outputs.copy(), "source_sha256": self.sources}
        put(self.snapshot_path, json.dumps(self.snapshot).encode())
        shutil.copytree(self.frozen, self.current)
        self.freeze_build()
        for n in [*overlay.BASE_OUTPUTS, "models/model.onnx", "runtime-assets/runtime.wasm"]:
            put(self.tracker / "dist" / n, b"base")
        put(self.tracker / "bin/node", b"fixture node", 0o755)
        put(self.tracker / "package.json", json.dumps({"main": overlay.MAIN}).encode())
        put(self.tracker / overlay.MAIN, b"old main")
        put(self.tracker / overlay.PRODUCER, b"old producer")
        put(self.tracker / "scripts/start-prod.cjs", b"fixture launcher")
        put(self.tracker / overlay.SHIM, b"PATH shim", 0o755)
        self.electron = self.tracker / overlay.ELECTRON.replace("node_modules/electron/", "node_modules/.pnpm/electron/")
        put(self.electron, b'#!/bin/sh\nprintf "%s\\n" "$@"\n', 0o755)
        (self.tracker / "node_modules/electron").symlink_to(".pnpm/electron")
        self.base = stage.resources(self.app)

    def apply(self):
        return overlay.apply_overlay(stage, self.app, self.snapshot_path, self.snapshot, self.current, self.base)

    def freeze_build(self):
        fixture_log = ("vite v8.0.16 building client environment for production...\n"
                       + "".join(f"out/{n}    1.00 kB\n" for n in overlay.OUTPUTS) + "✓ built in 39ms\n")
        self.renderer_record = {"label":recipe.GAZE,"recipe":"offline-isolated-vite-8.0.16","empty_before":True,"exit_code":0,
            "inputs_before":overlay.INPUTS,"inputs_after":overlay.INPUTS,"outputs":overlay.OUTPUTS,
            "edges":overlay.renderer_graph(overlay.OUTPUTS),"log_sha256":put(self.frozen/"renderer-build.log",fixture_log.encode()),
            "recipe_sha256":{n:put(self.frozen/"renderer-recipe"/n,n.encode()) for n in ("cohort.py","renderer-refs.cjs")}}
        overlay.PINS["renderer_build_sha256"]=put(self.frozen/"renderer-build.json",json.dumps(self.renderer_record).encode())
        compiled = {n: value for n, value in self.sources.items()
                    if n.startswith("Sources/") or n in ("Package.swift", "Package.resolved", "Info.plist")}
        self.review = {"label": recipe.GAZE, "verdict": "PASS", "reviewed_swift_inputs": compiled,
                       "reviewed_tracker_inputs": overlay.INPUTS,
                       "deleted_sources": [overlay.DELETED_REPLAY], "renderer_outputs": overlay.OUTPUTS,
                       "renderer_build_sha256":overlay.PINS["renderer_build_sha256"]}
        overlay.PINS["source_review_sha256"] = put(self.frozen / "tracker-source-review.json",
                                                   json.dumps(self.review).encode())
        log = b"Building for production...\nBuild complete! (7.24s)\nverification lane green\n"
        self.log_path = self.frozen / "release-build.log"
        unsigned = put(self.current / ".build/release/JevVoice", b"unsigned executable")
        self.snapshot["built_unsigned_main_sha256"] = unsigned
        self.build_record = {"label": recipe.GAZE, "lane": "c1-package-release", "exit_code": 0,
                             "log_sha256": put(self.log_path, log), "compiled_swift_inputs": compiled,
                             "source_review_sha256": overlay.PINS["source_review_sha256"],
                             "unsigned_main_sha256": unsigned}
        overlay.PINS["release_build_sha256"] = put(self.frozen / "release-build.json",
                                                   json.dumps(self.build_record).encode())
        put(self.snapshot_path, json.dumps(self.snapshot).encode())

    def test_clean_launch_survives_relocation_with_unusable_path(self):
        proof = self.apply()
        moved = self.root / "directory with spaces" / "test.app"
        moved.parent.mkdir()
        self.app.rename(moved)
        self.assertEqual(overlay.verify_resources(moved, stage.resources(moved), self.base), proof)
        root = moved / "Contents/Resources/EyeTracker"
        result = subprocess.run([str(root / proof["shim"]), ".", "two words"], cwd=root,
                                env={"PATH": "/nonexistent"}, check=True, capture_output=True, text=True)
        self.assertEqual(result.stdout, ".\ntwo words\n")

    def test_renderer_requires_source_bound_fresh_offline_build(self):
        for change in ({"label":"legacy"}, {"recipe":"pnpm-build"}, {"empty_before":False}, {"exit_code":1},
                       {"inputs_before":{}}, {"inputs_after":{}}, {"outputs":{}}, {"edges":{}},
                       {"log_sha256":"0"*64}, {"recipe_sha256":{}}):
            with self.subTest(change=change):
                sha=put(self.frozen/"renderer-build.json",json.dumps({**self.renderer_record, **change}).encode())
                with self.assertRaisesRegex(ValueError,"not pinned"):
                    self.apply()
                with mock.patch.dict(overlay.PINS,{"renderer_build_sha256":sha}), self.assertRaises(ValueError):
                    self.apply()
        self.freeze_build()
        log_sha=put(self.frozen/"renderer-build.log",b"vite v8.0.16 building client environment for production...\nbuilt in 1ms\n")
        sha=put(self.frozen/"renderer-build.json",json.dumps({**self.renderer_record,"log_sha256":log_sha}).encode())
        with mock.patch.dict(overlay.PINS,{"renderer_build_sha256":sha}), self.assertRaisesRegex(ValueError,"renderer build proof"):
            self.apply()

    def test_missing_reintroduced_or_unreviewed_source_in_either_tree(self):
        for root in (self.current, self.frozen):
            for n in (overlay.DELETED_REPLAY, "Sources/Added.swift", "Sources/JevVoice/Fixture.swift",
                      "Info.plist", "Package.swift", "Package.resolved"):
                with self.subTest(root=root, name=n):
                    p = root / n
                    old = p.read_bytes() if p.exists() else None
                    put(p, b"not reviewed")
                    with self.assertRaisesRegex(ValueError, "Swift source|Swift cohort"):
                        self.apply()
                    p.unlink()
                    if old is not None:
                        with self.assertRaises((ValueError, FileNotFoundError)):
                            self.apply()
                        put(p, old)
            dead = root / overlay.DELETED_REPLAY
            dead.symlink_to("missing")
            with self.assertRaisesRegex(ValueError, "deleted Swift source"):
                self.apply()
            dead.unlink()

    def test_review_content_checked_even_when_digest_matches(self):
        for change in ({"verdict": "FAIL"}, {"label": "final-r10"}, {"deleted_sources": []},
                       {"deleted_sources": [overlay.DELETED_REPLAY, "Sources/../../escape.swift"]},
                       {"reviewed_swift_inputs": {}}, {"renderer_outputs": {}}, {"reviewed_tracker_inputs": {}},
                       {"packaging_recipe_sha256": "a"*64}):
            with self.subTest(change=change):
                sha = put(self.frozen / "tracker-source-review.json", json.dumps({**self.review, **change}).encode())
                with mock.patch.dict(overlay.PINS, {"source_review_sha256": sha}), self.assertRaises(ValueError):
                    self.apply()

    def test_unsigned_binary_and_release_log_must_be_recorded_bytes(self):
        p = self.current / ".build/release/JevVoice"
        oldstat = p.stat()
        put(p, b"other unsigned executable")
        os.utime(p, ns=(oldstat.st_atime_ns, oldstat.st_mtime_ns))
        with self.assertRaisesRegex(ValueError, "unsigned release changed"):
            self.apply()
        put(p, b"unsigned executable")
        for data in (b"", b"verification lane green\n", b"Building for production...\nerror: failed",
                     b"Building for production...\nBuild complete! (0.1s)\nverification lane green\nfailed"):
            with self.subTest(log=data):
                sha = put(self.log_path, data)
                build_sha = put(self.frozen / "release-build.json", json.dumps({**self.build_record, "log_sha256":sha}).encode())
                with mock.patch.dict(overlay.PINS, {"release_build_sha256": build_sha}), self.assertRaisesRegex(ValueError, "release log"):
                    self.apply()

    def test_build_record_and_its_fields_are_bound(self):
        for change in ({"label":"final-r10"}, {"lane":"swift"}, {"exit_code": False}, {"exit_code":1},
                       {"source_review_sha256":"a"*64}, {"unsigned_main_sha256":"a"*64},
                       {"compiled_swift_inputs":{}}, {"log_sha256":"a"*64}):
            with self.subTest(change=change):
                sha = put(self.frozen / "release-build.json", json.dumps({**self.build_record, **change}).encode())
                with self.assertRaisesRegex(ValueError, "release receipt not pinned"):
                    self.apply()
                with mock.patch.dict(overlay.PINS, {"release_build_sha256":sha}), self.assertRaises(ValueError):
                    self.apply()

    def test_stale_or_extra_or_missing_input_fails_before_mutation(self):
        for where, name in [(self.current, "EyeTracking/web/src/App.tsx"),
                            (self.frozen, "EyeTracking/web/src/global.d.ts"),
                            (self.frozen, "renderer-output/index.html"),
                            (self.current, "EyeTracking/web/src/extra.ts"),
                            (self.frozen, "renderer-output/assets/stale.js")]:
            with self.subTest(path=str(where/name)):
                path = where/name
                previous = path.read_bytes() if path.exists() else None
                put(path, b"wrong")
                with self.assertRaises(ValueError):
                    self.apply()
                path.unlink()
                if previous is not None:
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        self.apply()
                    put(path, previous)
                self.assertEqual(stage.resources(self.app), self.base)

    def test_jointly_refrozen_stale_output_still_rejected(self):
        self.snapshot["renderer_output_sha256"]["index.html"] = put(self.frozen / "renderer-output/index.html", b"old")
        with self.assertRaisesRegex(ValueError, "wrong tracker freeze"):
            self.apply()

    def test_wrong_label_does_not_admit_overlay(self):
        for label in ("final-first-minute-quiet-1", "final-r10"):
            with self.subTest(label=label):
                self.snapshot["label"] = label
                with self.assertRaisesRegex(ValueError, "wrong tracker freeze"):
                    self.apply()

    def test_retired_producer_and_output_do_not_become_final_by_relabelling(self):
        retired_store = "83f85f29b14d1fc7e3b734e34f4db4137d3cfcea4c0c225a420c70a6001b9c5e"
        retired_index = "28826f49b850db4ea0683b04395d7269adc8b7652318f5147d222c5779e50b01"
        for mapping, key, value in [(overlay.INPUTS, "EyeTracking/" + overlay.PRODUCER, retired_store),
                                    (overlay.OUTPUTS, "index.html", retired_index),
                                    (overlay.PINS, "status", "draft-do-not-stage")]:
            with mock.patch.dict(mapping, {key: value}), self.assertRaisesRegex(ValueError, "superseded"):
                self.apply()

    def test_equal_content_input_symlink_still_rejected(self):
        p = self.frozen / "renderer-output/index.html"
        p.unlink()
        p.symlink_to(self.current / "renderer-output/index.html")
        with self.assertRaisesRegex(ValueError, "unexpected symlink"):
            self.apply()

    def test_preserve_every_resource_byte_link_and_mode(self):
        self.apply()
        for name in ("dist/models/model.onnx", "dist/runtime-assets/runtime.wasm", "bin/node",
                     "scripts/start-prod.cjs", overlay.SHIM, overlay.MAIN, "dist/index.html",
                     "dist/assets/stale.js", "scripts/node_modules/electron/index.js"):
            with self.subTest(name=name):
                path = self.tracker / name
                previous = (path.read_bytes(), path.stat().st_mode & 0o777) if path.exists() else None
                put(path, b"substitute")
                with self.assertRaisesRegex(ValueError, "delta"):
                    overlay.verify_resources(self.app, stage.resources(self.app), self.base)
                path.unlink()
                if previous is not None:
                    put(path, *previous)
        link = self.tracker / "node_modules/electron"
        link.unlink()
        link.symlink_to("./.pnpm/electron")
        with self.assertRaisesRegex(ValueError, "delta"):
            overlay.verify_resources(self.app, stage.resources(self.app), self.base)

    def test_rejects_unpinned_clone_and_outside_symlink(self):
        p = self.tracker / overlay.MAIN
        p.unlink()
        outside = self.root / "untouched"
        put(outside, b"untouched")
        p.symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError, "symlink escapes"):
            self.apply()
        self.assertEqual(outside.read_bytes(), b"untouched")

    def test_missing_or_substituted_base_receipt_fails(self):
        path = self.root / "base.json"
        with self.assertRaises(FileNotFoundError):
            overlay.retained_receipt(path, "0"*64, "1"*64)
        put(path, b"{}")
        with self.assertRaisesRegex(ValueError, "base receipt changed"):
            overlay.retained_receipt(path, "0"*64, "1"*64)

    def test_launcher_missing_or_not_executable_refuses_fallback(self):
        self.apply()
        for name in ("scripts/start-prod.cjs", "bin/node", overlay.SHIM, overlay.ELECTRON):
            with self.subTest(name=name):
                path = self.tracker / name
                mode = path.stat().st_mode & 0o777
                contents = path.read_bytes()
                path.unlink()
                with self.assertRaisesRegex(ValueError, "delta"):
                    overlay.verify_resources(self.app, stage.resources(self.app), self.base)
                put(path, contents, 0o600)
                with self.assertRaisesRegex(ValueError, "delta"):
                    overlay.verify_resources(self.app, stage.resources(self.app), self.base)
                path.chmod(mode)

    def test_manifest_verifies_copied_resources_without_live_app_or_credentials(self):
        package = {"pins":[{"identity":"fluidaudio"}]}
        driver_sha = "a" * 64
        vendors = {"vendored_binaries": {k: {"sha256": driver_sha, "version": "pinned"} for k in ("codex", "cua-driver")}}
        pin_file = "ThirdParty/Cua/source-manifest.json"
        dep = "Sources/JevVoice/ComputerControl/CuaDependency.swift"
        for n,b in {**{n:(manifest.ROOT/n).read_bytes() for n in overlay.RECIPE[:-1]},
                    pin_file: json.dumps(vendors).encode(), "Package.resolved":json.dumps(package).encode(),
                    dep: f'static let executableSHA256 = "{driver_sha}"'.encode()}.items():
            self.sources[n] = put(self.frozen/n,b)
            put(self.current/n,b)
        for n in manifest.REQUIRED:
            if not n.startswith("ConversationVAD/") and not (self.app/"Contents/Resources"/n).exists():
                put(self.app/"Contents/Resources"/n,n.encode())
        self.base = stage.resources(self.app)
        self.freeze_build()
        proof = self.apply()
        tool = lambda n: {"signed_sha256":self.base[n]["sha256"], "canonical_sha256":driver_sha, "version":"pinned"}
        driver, codex = tool("cua-driver"), tool("CodexRuntime/codex")
        info = {"CFBundleIdentifier":"com.chriswozniczek.jevvoice", "JevCuaDriverSHA256":driver["signed_sha256"],
                "JevVoiceInputProvider":"openai-realtime"}
        receipt = {**recipe.retained_base_metadata(), "binary_sha256":put(self.app/"Contents/MacOS/JevVoice",b"fixture"),
                   "driver":driver,"codex":codex,"source_sha256":self.review["reviewed_swift_inputs"],
                   "generated_info_sha256":put(self.app/"Contents/Info.plist",plistlib.dumps(info)),
                   "unsigned_main_sha256":self.snapshot["built_unsigned_main_sha256"],"canonical_pin_sha256":self.sources[pin_file],
                   "source_snapshot":str(self.snapshot_path),"signing_metadata":{},"designated_requirement":"fixture sign",
                   "experimental_window_images":False,"resource_manifest":stage.resources(self.app),
                   "tracker_overlay":proof,"label":recipe.GAZE,"app":str(self.root/("jev-c1-"+recipe.GAZE)/"Jev Voice.app")}
        self.snapshot["built_unsigned_main_sha256"] = receipt["unsigned_main_sha256"]
        receipt["source_snapshot_sha256"] = put(self.snapshot_path,json.dumps(self.snapshot).encode())
        for key,n in zip(("staging_helper_sha256","resource_helper_sha256","tracker_overlay_helper_sha256"),overlay.RECIPE):
            receipt[key] = self.sources[n]
        receipt["signing_helper_sha256"] = receipt["staging_helper_sha256"]
        base = {**receipt, "label":"final-r9-2","resource_manifest":self.base,"binary_sha256":recipe.RETAINED_BASE_SHA}
        pinned = self.root/"base.json"
        base_hash = put(pinned,json.dumps(base).encode())
        receipt_path = self.root/"stage.json"
        with mock.patch.object(recipe,"RETAINED_BASE_RECEIPT",pinned), mock.patch.object(recipe,"RETAINED_BASE_RECEIPT_SHA",base_hash), \
             mock.patch.object(recipe,"RETAINED_BASE_APP",self.root/"absent-rollback"/"Jev Voice.app"), \
             mock.patch.object(manifest,"candidate_staging",return_value=recipe), mock.patch.object(recipe,"tracker_overlay",return_value=overlay), \
             mock.patch.object(manifest,"staging",return_value=stage), mock.patch.object(stage,"signing_metadata",return_value={}), \
             mock.patch.object(stage,"requirement",return_value="fixture sign"), mock.patch.object(manifest,"ROOT",self.current), \
             mock.patch.object(recipe,"verify_retained_base",side_effect=AssertionError("read live rollback")), \
             mock.patch.object(subprocess,"run",return_value=subprocess.CompletedProcess([],0)) as run:
            receipt.update(recipe.retained_base_metadata())
            put(receipt_path,json.dumps(receipt).encode())
            data = manifest.create(receipt_path,self.app)
            with mock.patch.object(manifest,"ROOT",HERE.parents[2]):
                self.assertTrue(manifest.verify(data,self.app)["candidate_verified"])
                run.assert_called_once_with(["codesign","--verify","--deep","--strict",str(self.app)],
                                            capture_output=True,text=True,timeout=120)
                alias = self.root / "alias"
                alias.symlink_to(self.root)
                with self.assertRaisesRegex(ValueError, "aliased"):
                    manifest.verify(data, alias / self.app.name)
                alias.unlink()
                alias.symlink_to(self.app)
                with self.assertRaisesRegex(ValueError, "aliased"):
                    manifest.create(receipt_path, alias)
                with mock.patch.dict(receipt, {"label":"final-r10"}):
                    downgraded = {k:v for k,v in receipt.items() if k != "tracker_overlay"}
                    sha = put(receipt_path,json.dumps(downgraded).encode())
                    relabelled = {k:v for k,v in data.items() if k != "tracker_overlay"}
                    with self.assertRaisesRegex(ValueError,"relabelled"):
                        manifest.verify({**relabelled, "stage_receipt_sha256":sha}, self.app)
                put(receipt_path,json.dumps(receipt).encode())
                data["tracker_overlay"] = {**proof,"launcher":"scripts/dev.cjs"}
                with self.assertRaisesRegex(ValueError,"tracker provenance changed"):
                    manifest.verify(data,self.app)


if __name__ == "__main__":
    unittest.main()
