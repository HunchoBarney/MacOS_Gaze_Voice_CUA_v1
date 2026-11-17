import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import uuid

FIXTURE_V1 = "b1a36c17eae5137efb1ada3abfe60ee80ad9887719f24d9f87208bbdc894c7d8"


def strict_run_success(record):
    count = record.get("expected_rows")
    rows = record.get("rows")
    return (record.get("resources_clean") is True
            and type(count) is int and count > 0
            and isinstance(rows, list) and len(rows) == count
            and all(isinstance(row, dict)
                    and row.get("strict_success") is True
                    and row.get("status") in ("done", "already")
                    and row.get("verified") is True
                    and row.get("is_error") is False
                    and row.get("cancelled_by_harness") is False
                    and row.get("false_done") is False for row in rows))


def verified(state, case):
    if state.get("kind") != case["kind"] or state.get("cancelled") or state.get("completed") is not True:
        return False
    expected = case["expected"]
    if case["kind"] != "calculator":
        return all(state.get(key) == value for key, value in expected.items())
    try:
        a, b = float(state["left"]), float(state["right"])
        result = state["result"]
        if isinstance(result, bool) or not isinstance(result, (int, float)):
            return False
        if not all(math.isfinite(value) for value in (a, b, result)):
            return False
        if sorted([a, b]) != expected["operands"]:
            return False
        possible = [op for op, value in (("+", a + b), ("*", a * b))
                    if math.isclose(value, result, abs_tol=1e-9)]
        operation = state.get("operation")
        if operation is None:
            if len(possible) != 1:
                return False
            operation = possible[0]
        return (operation == expected["operation"] and operation in possible
                and math.isclose(result, expected["result"], abs_tol=1e-9))
    except (KeyError, ValueError, TypeError, OverflowError):
        return False


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("records", nargs="+", type=Path)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    source = here / "JevWorkflowFixture.swift"
    if digest(source) != FIXTURE_V1:
        raise SystemExit("original fixture changed; inference provenance no longer valid")
    spec = importlib.util.spec_from_file_location("frozen_native", here / "jev-native-proof-frozen-primary.py")
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    cases = {case["id"]: case for case in native.scenarios()}
    entries = []
    for path in args.records:
        raw = json.loads(path.read_text())
        if raw["fixture_source_sha256"] != FIXTURE_V1:
            raise SystemExit("offline correction is restricted to the exact original fixture")
        rows = []
        for row in raw["rows"]:
            actual = verified(row.get("actual_state", {}), cases[row["case"]])
            done = row["status"] in ("done", "already")
            strict = done and actual and not row.get("is_error") and not row.get("cancelled_by_harness")
            rows.append(dict(case=row["case"], trial=row["trial"], verified=actual,
                             strict_success=strict, false_done=done and not actual))
        entries.append(dict(
            original=str(path), original_sha256=digest(path), rows=rows,
            raw_strict_success=sum(row["strict_success"] for row in raw["rows"]),
            corrected_strict_success=sum(row["strict_success"] for row in rows),
            raw_false_done=sum(row["false_done"] for row in raw["rows"]),
            corrected_false_done=sum(row["false_done"] for row in rows),
            total=len(rows), resources_clean=raw["resources_clean"],
        ))
    output = here / ("jev-native-verifier-correction-" + uuid.uuid4().hex + ".json")
    output.write_text(json.dumps(dict(
        kind="Offline verifier correction, not a fresh desktop run",
        fixture_source_sha256=FIXTURE_V1, implementation_sha256=digest(__file__),
        rationale="Fixture v1 serializes operands/result/completed but omits operation. "
                  "Its source computes results only on Equals using + or *. "
                  "Missing operation is accepted only when those operations are unambiguous.",
        entries=entries,
    ), indent=2) + "\n")
    for entry in entries:
        print(entry["original"], entry["corrected_strict_success"], "/", entry["total"],
              "false_done", entry["corrected_false_done"])
    print(output)


if __name__ == "__main__":
    main()
