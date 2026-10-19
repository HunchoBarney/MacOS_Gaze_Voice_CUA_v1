#!/usr/bin/env python3
"""Validate a phase acceptance file (.agent/acceptance/P*.json).

Default-FAIL discipline: every criterion carries
id/behavior/check/expected/passes/evidence, and `passes: true` is
rejected without a non-empty `evidence` string. Only the judge's
verdict — relayed by the orchestrating agent — may set passes.

Usage:
  check-acceptance.py <file.json>   exit 0 when schema valid (any pass count)
  check-acceptance.py --green <f>   exit 0 only when every criterion passes
"""
import json
import re
import sys

REQUIRED = ("id", "behavior", "check", "expected", "passes", "evidence")
ID_RE = re.compile(r"^P[0-9]+[a-z]?-[0-9]+$")
PHASE_RE = re.compile(r"^P[0-9]+[a-z]?$")


def validate(path: str) -> tuple[list[str], int, int]:
    try:
        data = json.load(open(path))
    except (OSError, json.JSONDecodeError) as e:
        return [f"{path}: unreadable JSON — {e}"], 0, 0

    errors = []
    if not isinstance(data, dict):
        return [f"{path}: top level must be an object"], 0, 0
    extra = set(data) - {"phase", "criteria"}
    if extra:
        errors.append(f"unexpected top-level keys: {sorted(extra)}")
    phase = data.get("phase")
    if not isinstance(phase, str) or not PHASE_RE.match(phase):
        errors.append(f"phase: expected pattern P<n>[a-z], got {phase!r}")
    criteria = data.get("criteria")
    if not isinstance(criteria, list) or not criteria:
        errors.append("criteria: must be a non-empty array")
        return errors, 0, 0

    seen = set()
    passed = 0
    for i, c in enumerate(criteria):
        tag = f"criteria[{i}]"
        if not isinstance(c, dict):
            errors.append(f"{tag}: not an object")
            continue
        missing = [k for k in REQUIRED if k not in c]
        if missing:
            errors.append(f"{tag}: missing keys {missing}")
            continue
        extra = set(c) - set(REQUIRED)
        if extra:
            errors.append(f"{tag} ({c['id']}): unexpected keys {sorted(extra)}")
        if not ID_RE.match(str(c["id"])):
            errors.append(f"{tag}: id {c['id']!r} fails pattern P<n>-<m>")
        if c["id"] in seen:
            errors.append(f"{tag}: duplicate id {c['id']!r}")
        seen.add(c["id"])
        for k in ("behavior", "check", "expected"):
            if not isinstance(c[k], str) or not c[k].strip():
                errors.append(f"{tag} ({c['id']}): {k} must be non-empty")
        if not isinstance(c["passes"], bool):
            errors.append(f"{tag} ({c['id']}): passes must be boolean")
        elif c["passes"]:
            if not isinstance(c["evidence"], str) or not c["evidence"].strip():
                errors.append(
                    f"{tag} ({c['id']}): passes:true requires non-empty evidence")
            else:
                passed += 1
        elif c["evidence"] is not None and not isinstance(c["evidence"], str):
            errors.append(f"{tag} ({c['id']}): evidence must be string|null")
    return errors, passed, len(criteria)


def main() -> int:
    argv = sys.argv[1:]
    green = "--green" in argv
    argv = [a for a in argv if a != "--green"]
    if len(argv) != 1:
        print(__doc__.strip())
        return 2
    errors, passed, total = validate(argv[0])
    for e in errors:
        print(f"ERROR: {e}")
    print(f"{passed}/{total} criteria pass")
    if errors:
        return 1
    if green and passed != total:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
