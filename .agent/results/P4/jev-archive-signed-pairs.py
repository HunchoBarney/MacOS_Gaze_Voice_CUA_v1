import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
ROOTS = {
    "a1c24a0241404606bfb29bc5a8116a5c": "jev-vision-ab-w8djj8r4",
    "5ac97464769d4928aaac74028c3eff1e": "jev-vision-ab-h9y3i4ib",
}
BASE = "9b308e9f0ecd4f7084065a1cb182f4f4"
APPROVED_AFTER = {
    BASE: "jev-vision-ab-wq1v092b",
    "9c2e019c30de46c887a78321da724dc8": "jev-vision-ab-ms_48tla",
}
SUPERSEDED_STAGE_A = {
    "9c2e019c30de46c887a78321da724dc8": ("jev-vision-ab-ms_48tla", ("before",)),
    "633e8fb9c3f54b638a13cfd3aa76ba3a": ("jev-vision-ab-cq9z1o3s", ("after",)),
}
OWN_STAGE_B_V1 = {
    "82b6f09c82cc4a21a47579b65aa542b2": ("jev-vision-ab-ze3ekr4y", ("before", "after")),
}
APPROVED_633_BEFORE = {
    "633e8fb9c3f54b638a13cfd3aa76ba3a": ("jev-vision-ab-cq9z1o3s", ("before",)),
}


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def manifest(root):
    rows = {}
    for path in [root, *root.rglob("*")]:
        mode = path.lstat().st_mode
        row = {"mode": stat.S_IMODE(mode)}
        if stat.S_ISLNK(mode):
            row.update(kind="link", target=os.readlink(path))
        elif stat.S_ISREG(mode):
            row.update(kind="file", sha256=digest(path))
        elif stat.S_ISDIR(mode):
            row["kind"] = "directory"
        else:
            raise RuntimeError("unsupported archived file type")
        rows[str(path.relative_to(root))] = row
    return rows


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def signed(app):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                   check=True, capture_output=True, timeout=45)


def clone(source, target):
    subprocess.run(["cp", "-cRpP", str(source), str(target)], check=True, timeout=180)


def restore_modes_and_directories(root, expected):
    actual = manifest(root)
    for name in sorted(set(actual) - set(expected), key=lambda name: len(Path(name).parts), reverse=True):
        path = root / name
        path.rmdir() if actual[name]["kind"] == "directory" else path.unlink()
    for name in sorted(expected, key=lambda name: len(Path(name).parts)):
        path, row = root / name, expected[name]
        if row["kind"] == "directory":
            path.mkdir(exist_ok=True)
        if row["kind"] == "link":
            if path.lstat().st_mode & 0o777 != row["mode"]:
                os.lchmod(path, row["mode"])
        else:
            path.chmod(row["mode"])


def main():
    parser = argparse.ArgumentParser()
    approval = parser.add_mutually_exclusive_group(required=True)
    approval.add_argument("--approved-four", action="store_true")
    approval.add_argument("--approved-two-after", action="store_true")
    approval.add_argument("--approved-stage-a-superseded", action="store_true")
    approval.add_argument("--owned-stage-b-v1", action="store_true")
    approval.add_argument("--approved-633-before", action="store_true")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--list-targets", action="store_true")
    args = parser.parse_args()
    if args.out is None and not args.list_targets:
        parser.error("--out is required unless --list-targets is used")
    selected = APPROVED_633_BEFORE if args.approved_633_before else OWN_STAGE_B_V1 if args.owned_stage_b_v1 else SUPERSEDED_STAGE_A
    selected_labels = args.approved_633_before or args.owned_stage_b_v1 or args.approved_stage_a_superseded
    pair = args.approved_two_after or selected_labels
    roots = {key: row[0] for key, row in selected.items()} \
        if selected_labels else APPROVED_AFTER if pair else ROOTS
    labels_by_key = {key: selected[key][1] if selected_labels else
                     ("after",) if args.approved_two_after else ("before", "after") for key in roots}
    current = json.loads((HERE / "jev-vision-stage-8909322f313342eba82c860291e3ba70.json").read_text()) \
        if args.approved_633_before else None
    if args.list_targets:
        targets = []
        for key, labels in labels_by_key.items():
            receipt = json.loads((HERE / f"jev-vision-stage-{key}.json").read_text())
            targets += [receipt["candidates"][label]["app"] for label in labels]
        print(json.dumps({"targets": targets, "retained_current":
                          [row["app"] for row in current["candidates"].values()] if current else []}))
        return
    base_receipt_path = HERE / f"jev-vision-stage-{BASE}.json"
    base_receipt = json.loads(base_receipt_path.read_text())
    base = Path(base_receipt["candidates"]["before"]["app"])
    assert base.name == "before.app"
    assert base.parent.name == "jev-vision-ab-wq1v092b" and not base.is_symlink()
    base_rows = [base_receipt["candidates"]["before"]] if pair \
        else base_receipt["candidates"].values()
    for row in base_rows:
        app = Path(row["app"])
        assert digest(app / "Contents/MacOS/JevVoice") == row["binary_sha256"]
        assert digest(app / "Contents/Resources/cua-driver") == row["driver_sha256"]
        signed(app)
    base_manifest = manifest(base)
    retained = {base: base_manifest}
    if current:
        for row in current["candidates"].values():
            app = Path(row["app"]).resolve(strict=True)
            assert app.parent.name == "jev-vision-ab-wluda_20" and not Path(row["app"]).is_symlink()
            assert digest(app / "Contents/MacOS/JevVoice") == row["binary_sha256"]
            assert digest(app / "Contents/Resources/cua-driver") == row["driver_sha256"]
            signed(app)
            retained[app] = manifest(app)
    if args.owned_stage_b_v1:
        kept = json.loads((HERE / "jev-vision-stage-633e8fb9c3f54b638a13cfd3aa76ba3a.json").read_text())["candidates"]["before"]
        kept_path = Path(kept["app"]).resolve(strict=True)
        assert kept_path.parent.name == "jev-vision-ab-cq9z1o3s" and kept_path.name == "before.app"
        assert digest(kept_path / "Contents/MacOS/JevVoice") == kept["binary_sha256"]
        assert digest(kept_path / "Contents/Resources/cua-driver") == kept["driver_sha256"]
        signed(kept_path)
        retained[kept_path] = manifest(kept_path)
    candidates = []
    for key, root_name in roots.items():
        labels = labels_by_key[key]
        receipt_path = HERE / f"jev-vision-stage-{key}.json"
        receipt = json.loads(receipt_path.read_text())
        if pair and "before" not in labels:
            keep_row = receipt["candidates"]["before"]
            keep = Path(keep_row["app"])
            assert keep.name == "before.app"
            assert keep.parent.name == root_name and keep.parent.parent == base.parent.parent
            assert not keep.is_symlink()
            assert digest(keep / "Contents/MacOS/JevVoice") == keep_row["binary_sha256"]
            assert digest(keep / "Contents/Resources/cua-driver") == keep_row["driver_sha256"]
            signed(keep)
            retained[keep] = manifest(keep)
        for label in labels:
            row = receipt["candidates"][label]
            app = Path(row["app"])
            assert label in ("before", "after") and app.name == label + ".app"
            assert app.parent.name == root_name and app.parent.stat().st_uid == os.getuid()
            assert app.parent.parent == base.parent.parent
            assert not app.is_symlink() and app not in retained
            assert digest(app / "Contents/MacOS/JevVoice") == row["binary_sha256"]
            assert digest(app / "Contents/Resources/cua-driver") == row["driver_sha256"]
            signed(app)
            candidates.append((key, label, app, receipt_path, manifest(app)))
    assert len(candidates) == (1 if args.approved_633_before else 2 if pair else 4)
    processes = subprocess.check_output(["ps", "-axo", "comm="], text=True, timeout=10).splitlines()
    assert not any(line.startswith(str(app) + "/") for _, _, app, _, _ in candidates for line in processes)
    args.out.mkdir(mode=0o700)
    write(args.out / "base-manifest.json", base_manifest)
    shutil.copy2(base_receipt_path, args.out / base_receipt_path.name)
    index = {"authorization": "User approved exactly633-before; keep9b-before and both890 bundles"
             if args.approved_633_before else "Own session-generated82 v1 candidate pair superseded; keep9b-before and633-before"
             if args.owned_stage_b_v1 else "User approved exactly9c-before and633-after; keep9b-before and633-before"
             if args.approved_stage_a_superseded else "User approved these exact two after bundles in this session"
             if args.approved_two_after else "User approved these exact four bundles in this session",
             "full_base_retained": str(base), "base_manifest_sha256": digest(args.out / "base-manifest.json"),
             "retained_before_bundles": [str(path) for path in retained],
             "mechanism": "Git binary patch relative to full retained base; exact tree/modes and original signature verified",
             "archives": []}
    write(args.out / "index.json", index)
    with tempfile.TemporaryDirectory(prefix="jev-archive-verify-") as temporary:
        scratch = Path(temporary)
        anchor = scratch / "base"
        clone(base, anchor)
        assert manifest(anchor) == base_manifest
        for key, label, app, receipt_path, expected in candidates:
            entry = args.out / (key + "-" + label)
            entry.mkdir(mode=0o700)
            shutil.copy2(receipt_path, entry / receipt_path.name)
            write(entry / "manifest.json", expected)
            candidate = scratch / "candidate"
            clone(app, candidate)
            assert manifest(candidate) == expected
            patch = entry / "bundle.patch"
            with patch.open("wb") as stream:
                result = subprocess.run(["git", "-c", "core.autocrlf=false", "diff", "--no-index",
                                         "--binary", "--no-ext-diff", "--no-textconv", "--", "base", "candidate"],
                                        cwd=scratch, stdout=stream, stderr=subprocess.PIPE, timeout=180)
            assert result.returncode in (0, 1), result.stderr.decode(errors="replace")
            restored = scratch / "Restored.app"
            clone(anchor, restored)
            if patch.stat().st_size:
                subprocess.run(["git", "-c", "core.autocrlf=false", "apply", "--binary",
                                "--whitespace=nowarn", "-p2", str(patch)],
                               cwd=restored, check=True, capture_output=True, timeout=180)
            restore_modes_and_directories(restored, expected)
            assert manifest(restored) == expected, "restored bytes/links/modes differ"
            signed(restored)
            assert manifest(app) == expected, "original changed during archival"
            assert all(manifest(path) == tree for path, tree in retained.items()), "retained base changed"
            processes = subprocess.check_output(["ps", "-axo", "comm="], text=True, timeout=10).splitlines()
            assert not any(line.startswith(str(app) + "/") for line in processes)
            record = {"original_bundle": str(app), "patch": str(patch),
                      "patch_sha256": digest(patch), "manifest_sha256": digest(entry / "manifest.json"),
                      "receipt_sha256": digest(entry / receipt_path.name),
                      "exact_reconstruction_verified": True, "original_signature_verified": True,
                      "original_removed": False}
            index["archives"].append(record)
            write(args.out / "index.json", index)
            shutil.rmtree(app)
            record["original_removed"] = True
            write(args.out / "index.json", index)
            shutil.rmtree(candidate)
            shutil.rmtree(restored)
            print(key, label, "exact reconstruction and original signature verified; original archived",
                  "free GiB", shutil.disk_usage(args.out).free / 2**30, flush=True)
    assert all(manifest(path) == tree for path, tree in retained.items())
    print(args.out / "index.json", flush=True)


if __name__ == "__main__":
    main()
