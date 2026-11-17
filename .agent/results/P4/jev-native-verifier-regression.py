import argparse
import copy
import importlib.util
from pathlib import Path


def load(path):
    spec = importlib.util.spec_from_file_location("native_verifier_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--implementation", required=True)
    args = parser.parse_args()
    implementation = load(Path(args.implementation))
    online = load(Path(__file__).with_name("jev-native-proof.py"))
    cases = load(Path(__file__).with_name("jev-native-proof-frozen-primary.py")).scenarios()
    checks = 0
    for case in cases:
        if case["kind"] != "calculator":
            continue
        expected = case["expected"]
        a, b = expected["operands"]
        state = dict(kind="calculator", completed=True, cancelled=False,
                     left=str(a), right=str(b), result=expected["result"])
        assert implementation.verified(state, case), "fixture v1 omits operation, not its actual calculation"
        assert online.verified(state, case), "online and offline verification must agree"
        for change in (
            {"completed": False}, {"cancelled": True}, {"left": "999"},
            {"result": expected["result"] + 1}, {"result": float("inf")},
            {"left": "nan"}, {"operation": "+" if expected["operation"] == "*" else "*"},
        ):
            assert not implementation.verified(dict(state, **change), case), change
            checks += 1
        checks += 1
    ambiguous = dict(kind="calculator", completed=True, cancelled=False, left="0", right="0", result=0)
    case = dict(kind="calculator", expected=dict(operands=[0, 0], operation="*", result=0))
    assert not implementation.verified(ambiguous, case), "ambiguous missing operation must fail closed"
    print(f"{checks + 1} verifier checks passed")
    successful = dict(resources_clean=True, expected_rows=1, rows=[
        dict(status="done", verified=True, strict_success=True, is_error=False,
             cancelled_by_harness=False, false_done=False),
    ])
    assert implementation.strict_run_success(successful)
    for change in (
        {"status": "cancelled"}, {"verified": False}, {"is_error": True},
        {"cancelled_by_harness": True}, {"false_done": True}, {"strict_success": False},
    ):
        record = copy.deepcopy(successful)
        record["rows"][0].update(change)
        assert not implementation.strict_run_success(record), change
    for change in (
        {"rows": []}, {"expected_rows": 2}, {"expected_rows": True},
        {"resources_clean": False}, {"expected_rows": "1"},
    ):
        assert not implementation.strict_run_success(dict(successful, **change)), change
    assert not implementation.strict_run_success({})
    print("13 strict run checks passed")


if __name__ == "__main__":
    main()
