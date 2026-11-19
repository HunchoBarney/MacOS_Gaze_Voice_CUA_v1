import hashlib
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
PINS = {name: digest for digest, name in (line.split() for line in
        (ROOT / "EyeTracking/scripts/retinaface-release.sha256").read_text().splitlines())}
EXCLUDED = {digest for digest, name in (line.split() for line in
            (ROOT / "EyeTracking/scripts/required-models.sha256").read_text().splitlines()) if name not in PINS}


def digest(path):
    with path.open("rb") as stream:
        result = hashlib.sha256()
        for block in iter(lambda: stream.read(1 << 20), b""):
            result.update(block)
        return result.hexdigest()


def verify_models(tracker):
    models = tracker / "dist/models"
    if models.resolve(strict=True) != models or {p.name for p in models.iterdir()} != set(PINS):
        raise ValueError("release model inventory differs from the RetinaFace allowlist")
    for name, expected in PINS.items():
        path = models / name
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            raise ValueError(f"missing, linked or corrupt release weight: {name}")
    for path in tracker.parents[2].rglob("*"):
        if path.parent == models or path == tracker / "public/models":
            continue
        if path == tracker.parent / "EyeTracking" and path.is_symlink() and path.readlink() == Path("EyeTracker"):
            continue
        if path.is_symlink():
            target = path.resolve(strict=True)
            if target == models or models in target.parents or target in models.parents:
                raise ValueError("unexpected model alias")
        if path.suffix.lower() == ".onnx" or (path.is_file() and not path.is_symlink()
                                              and digest(path) in EXCLUDED | set(PINS.values())):
            raise ValueError("unexpected model payload outside the release allowlist")


if __name__ == "__main__":
    sys.exit("RetinaFace release held: exact weight redistribution and runtime notices are not cleared")
