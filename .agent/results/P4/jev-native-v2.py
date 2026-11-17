import copy
import hashlib
import importlib.util
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SOURCE = ROOT / "development/JevVoice/P4LocalFixture.swift"
ORIGINAL_SHA = "b1a36c17eae5137efb1ada3abfe60ee80ad9887719f24d9f87208bbdc894c7d8"


def main():
    original = (HERE / "JevWorkflowFixture.swift").read_bytes()
    if hashlib.sha256(original).hexdigest() != ORIGINAL_SHA:
        raise SystemExit("frozen original fixture changed")
    source = original.decode()
    old = 'stack.addArrangedSubview(button("Submit", tag: 1))'
    marker = '        if let result { state["result"] = result }'
    if source.count(old) != 1 or source.count(marker) != 1:
        raise SystemExit("fixture adaptation anchors changed")
    source = source.replace(old, 'stack.addArrangedSubview(button("Save locally", tag: 1))')
    source = source.replace(marker, '        if let operation { state["operation"] = operation }\n' + marker)
    if not SOURCE.parent.is_dir():
        raise SystemExit("workspace development directory missing")
    if sys.argv[1:2] == ["build"]:
        SOURCE.write_text(source)
    elif not SOURCE.is_file() or SOURCE.read_text() != source:
        raise SystemExit("build the separate local-only fixture first")
    spec = importlib.util.spec_from_file_location("local_native", HERE / "jev-native-proof.py")
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    original_cases = native.scenarios

    def scenarios():
        cases = original_cases()
        for case in cases:
            if case["kind"] == "form":
                case["id"] += "-local"
                case["goal"] = case["goal"].replace("Submit", "Save locally")
        placeholder = copy.deepcopy(next(case for case in cases if case["id"] == "profile-aster-local"))
        placeholder["id"] = "profile-placeholder-local"
        placeholder["goal"] = placeholder["goal"].replace("aster@example.test", "Email")
        placeholder["success"] = placeholder["success"].replace("aster@example.test", "Email")
        placeholder["values"] = {
            key: "Email" if value == "aster@example.test" else value
            for key, value in placeholder["values"].items()
        }
        placeholder["expected"]["email"] = "Email"
        cases.append(placeholder)
        return cases

    native.scenarios = scenarios
    native.SOURCE = SOURCE
    native.__file__ = str(Path(__file__).resolve())
    native.main()


if __name__ == "__main__":
    main()
