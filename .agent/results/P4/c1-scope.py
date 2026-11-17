import difflib
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    baseline = json.loads((HERE / "c1-baseline-source.json").read_text())
    contract = (HERE / "c1-implementation-contract.md").read_text()
    patterns = re.search(r"## Owned paths.*?```text\n(.*?)```", contract, re.S).group(1).splitlines()
    spec = importlib.util.spec_from_file_location("c1_owned", ROOT / "scripts/check-owned-paths.py")
    owned = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owned)
    rows, diffs, unchanged = [], [], 0
    for name, before_hash in baseline["source_sha256"].items():
        path = ROOT / name
        assert path.is_file(), f"Fingerprinted source removed: {name}"
        after = path.read_bytes()
        if digest(after) == before_hash:
            unchanged += 1
            continue
        assert owned.owned_match(name, patterns), f"Uncontracted C1 source change: {name}"
        before, origin = None, None
        for directory in ["c1-before", "c1-performance-before", "c1-performance-after-r2"]:
            candidate = HERE / directory / name
            if candidate.is_file() and digest(candidate.read_bytes()) == before_hash:
                before, origin = candidate.read_bytes(), str(candidate.relative_to(ROOT))
                break
        if before is None:
            blob = subprocess.run(["git", "show", baseline["head"] + ":" + name],
                                  cwd=ROOT, capture_output=True)
            if blob.returncode == 0 and digest(blob.stdout) == before_hash:
                before, origin = blob.stdout, "git:" + baseline["head"] + ":" + name
        row = {"path": name, "before_sha256": before_hash, "after_sha256": digest(after),
               "owned": True, "exact_before_bytes": before is not None, "before_origin": origin}
        rows.append(row)
        if before is not None:
            diffs.append("".join(difflib.unified_diff(
                before.decode().splitlines(keepends=True), after.decode().splitlines(keepends=True),
                fromfile="a/" + name, tofile="b/" + name)))
    supplementary = [
        ".agent/results/P4/c1-report.py", ".agent/results/P4/c1-focus.py",
        ".agent/results/P4/c1-scroll.py", ".agent/results/P4/c1-scope.py",
        ".agent/results/P4/jev-stage-candidate.py",
        ".agent/results/P12/c1_manifest.py", ".agent/results/P12/test_c1_manifest.py",
        ".agent/results/P12/speech-attribution.md",
    ]
    result = {
        "baseline": ".agent/results/P4/c1-baseline-source.json",
        "baseline_sha256": digest((HERE / "c1-baseline-source.json").read_bytes()),
        "head_unchanged": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                                 text=True).strip() == baseline["head"],
        "fingerprinted_files": len(baseline["source_sha256"]), "unchanged_files": unchanged,
        "modified": rows, "supplementary_artifacts": {
            name: digest((ROOT / name).read_bytes()) for name in supplementary},
        "limitation": "Exact original bytes were not retained for every initial dirty file. "
                      "The patch covers only hash-proven originals. Remaining modified paths "
                      "have before/after hashes, current frozen source, the G2 contract, and "
                      "failing-before evidence; they are not silently compared to HEAD.",
    }
    assert result["head_unchanged"]
    missing = [row["path"] for row in rows if not row["exact_before_bytes"]]
    header = "# C1 hash-proven scoped diff; see c1-scope.json for complete changed-path accounting.\n"
    header += "# Original byte copies unavailable for: " + ", ".join(missing) + "\n\n"
    (HERE / "c1-scoped-diff.patch").write_text(header + "\n".join(diffs))
    (HERE / "c1-scope.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"modified": len(rows), "unchanged": unchanged,
                      "exact_diffs": len(diffs), "missing_original_bytes": missing}, indent=2))


if __name__ == "__main__":
    main()
