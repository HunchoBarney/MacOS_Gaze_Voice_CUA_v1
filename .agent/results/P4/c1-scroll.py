import argparse
import importlib.util
import json
from pathlib import Path
import re
import socket
import subprocess
import time
import uuid


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def apple(script):
    value = subprocess.check_output(["osascript", "-"], input=script, text=True, timeout=20)
    if not value:
        return ""
    assert value.endswith("\n")
    return value[:-1]


def body(path):
    return apple(f'''tell application "TextEdit"
        set ownedDoc to first document whose path is {json.dumps(str(path))}
        return text of ownedDoc
    end tell''')


def viewport(path, pid, window_id, reset=False):
    script = """function run(argv) {
        ObjC.import('Cocoa');
        ObjC.bindFunction('AXUIElementCreateApplication', ['id', ['int']]);
        ObjC.bindFunction('AXUIElementCopyAttributeValue', ['int', ['id', 'id', 'id *']]);
        ObjC.bindFunction('AXUIElementSetAttributeValue', ['int', ['id', 'id', 'id']]);
        ObjC.bindFunction('_AXUIElementGetWindow', ['int', ['id', 'unsigned int *']]);
        ObjC.bindFunction('CFEqual', ['unsigned char', ['id', 'id']]);
        function attribute(element, name) {
            const value = Ref();
            return $.AXUIElementCopyAttributeValue(element, $(name), value) === 0 ? value[0] : null;
        }
        const windows = attribute($.AXUIElementCreateApplication(Number(argv[2])), 'AXWindows');
        if (!windows) throw Error('owned process windows unavailable');
        const roots = [];
        for (let i = 0; i < Number(windows.count); i++) {
            const window = windows.objectAtIndex(i), number = Ref();
            if ($._AXUIElementGetWindow(window, number) !== 0 || Number(number[0]) !== Number(argv[3])) continue;
            if (ObjC.unwrap(attribute(window, 'AXDocument')) !== argv[0]) throw Error('pinned window document changed');
            if (!roots.some(root => $.CFEqual(root, window))) roots.push(window);
        }
        if (roots.length !== 1) throw Error('pinned owned document window unavailable');
        const pending = [roots[0]], seen = [], bars = [];
        while (pending.length && seen.length < 1024) {
            const element = pending.pop();
            if (seen.some(other => $.CFEqual(other, element))) continue;
            seen.push(element);
            if (ObjC.unwrap(attribute(element, 'AXRole')) === 'AXScrollBar' &&
                ObjC.unwrap(attribute(element, 'AXOrientation')) === 'AXVerticalOrientation') bars.push(element);
            const children = attribute(element, 'AXChildren');
            if (children) for (let i = 0; i < Number(children.count); i++) pending.push(children.objectAtIndex(i));
        }
        if (pending.length) throw Error('owned viewport scan exceeded its bound');
        if (bars.length !== 1) throw Error('owned vertical viewport unavailable');
        if (argv[1] === 'reset' &&
            $.AXUIElementSetAttributeValue(bars[0], $('AXValue'), $.NSNumber.numberWithDouble(0)) !== 0) {
            throw Error('owned viewport reset failed');
        }
        return Number(ObjC.unwrap(attribute(bars[0], 'AXValue')));
    }"""
    value = subprocess.check_output(
        ["osascript", "-l", "JavaScript", "-", path.as_uri(), "reset" if reset else "read",
         str(pid), str(window_id)],
        input=script, text=True, timeout=20)
    result = float(value)
    assert 0 <= result <= 1
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--label", required=True)
    args = parser.parse_args()
    assert re.fullmatch("[a-z0-9-]{1,12}", args.label)
    real = load("c1_scroll_real", HERE / "jev-realapps.py")
    stage = load("c1_scroll_stage", HERE / "jev-clone-stage.py")
    cleanup = load("c1_scroll_cleanup", ROOT / ".agent/results/P3/physical-20261105/run-focus-window-density.py")
    directory = HERE / f"c1-scroll-{args.label}"
    directory.mkdir(mode=0o700)
    cleanup.BACKUP = directory / "fixture-backups"
    original = json.loads(args.receipt.read_text())
    candidate = dict(original)
    candidate["source_sha256"] = {p: h for p, h in original["source_sha256"].items()
                                   if p != "Package.resolved"}
    candidate["driver_sha256"] = original["driver"]["signed_sha256"]
    adapter = directory / "candidate.json"
    real.write_json(adapter, {"original_receipt": str(args.receipt.resolve()),
                             "original_receipt_sha256": real.digest(args.receipt),
                             "candidates": {"c1": candidate}})
    current = stage.sources()
    delta = {p: {"before": candidate["source_sha256"].get(p), "after": current.get(p)}
             for p in set(current) | set(candidate["source_sha256"])
             if candidate["source_sha256"].get(p) != current.get(p)}
    fixtures = ROOT / (".agent/results/P3/user-audit-c1scroll-" + args.label + "-" + uuid.uuid4().hex[:8])
    fixtures.mkdir(mode=0o700)
    target, decoy = fixtures / "owned-scroll.txt", fixtures / "owned-decoy.txt"
    text = "\n".join(f"Jev owned scrolling fixture line {index:04d}" for index in range(300))
    target.write_text(text)
    decoy.write_text("Owned decoy must remain unchanged.\n" + text)
    count, _ = cleanup.inventory()
    report = {"status": "running", "physical_input": False, "human_confirmed": False,
              "entry": "signed packaged MCP drive_until; production DriveLoop and bundled Cua",
              "clock": "MCP request to response; independent AX witness completion reported separately",
              "gaze": "controlled unavailable endpoint; bound-window control",
              "jev_limit": None, "billed_provider_calls": 0,
              "binary_sha256": original["binary_sha256"], "harness_sha256": real.digest(__file__),
              "rows": [], "documents_before": count}
    real.write_json(directory / "comparison.json", report)
    try:
        with socket.socket() as unavailable, real.Session(
                directory, adapter, variant="c1", approved_source_delta=delta or None) as session:
            unavailable.bind(("127.0.0.1", 0))
            session.environment["JARVIS_GAZE_URL"] = f"http://127.0.0.1:{unavailable.getsockname()[1]}"
            actor = session.start_actor()
            owned_windows = {}
            front_document = 'tell application "System Events" to tell application process "TextEdit" to return value of attribute "AXDocument" of front window'
            for file in [decoy, target]:
                apple(f'tell application "TextEdit" to open POSIX file {json.dumps(str(file))}')
                apple('tell application "TextEdit" to activate')
                assert apple(front_document) == file.as_uri()
                owned_windows[file] = int(apple('tell application "TextEdit" to return id of front window'))
            real.wait_for(lambda: body(target) == text, 8, "owned document readiness")
            pid = int(apple('tell application "System Events" to return unix id of first application process whose bundle identifier is "com.apple.TextEdit"'))
            assert apple(front_document) == target.as_uri()
            window = int(apple('tell application "TextEdit" to return id of front window'))
            assert window == owned_windows[target] and window != owned_windows[decoy]
            assert apple(front_document) == target.as_uri()
            target_row = [r for r in session.windows(pid=pid) if r["window_id"] == window]
            assert len(target_row) == 1 and target.stem in target_row[0].get("title", target_row[0].get("window_title", ""))
            before_body, before_decoy = body(target), body(decoy)
            decoy_view = viewport(decoy, pid, owned_windows[decoy])
            for index in range(3):
                viewport(target, pid, window, reset=True)
                before = viewport(target, pid, window)
                assert before == 0
                start = time.perf_counter()

                def oracle():
                    value = viewport(target, pid, window)
                    decoy_unchanged = viewport(decoy, pid, owned_windows[decoy]) == decoy_view and body(decoy) == before_decoy
                    content_unchanged = body(target) == before_body
                    result = {"scroll_before": before, "scroll_after": value,
                              "decoy_unchanged": decoy_unchanged, "content_unchanged": content_unchanged,
                              "verified_elapsed_ms": (time.perf_counter() - start) * 1000}
                    return result, value > before and decoy_unchanged and content_unchanged

                assert oracle()[1] is False
                start = time.perf_counter()
                session.drive({"id": f"c1-owned-scroll-{index}", "goal": "scroll down",
                               "app": "com.apple.TextEdit", "window_id": window}, oracle, actor=actor)
                row = session.metadata["rows"][-1]
                report["rows"].append(row)
                real.write_json(directory / "comparison.json", report)
                assert row["strict_success"] and not row["false_done"]
            report["status"] = "passed"
    except Exception as error:
        report["status"] = "blocked_or_failed"
        report["error_type"] = type(error).__name__
        report["error"] = str(error)[:400]
        raise
    finally:
        owned = sorted(set(cleanup.inventory()[1]) & {target, decoy})
        if owned:
            cleanup.close_owned(owned)
        report["documents_after"] = cleanup.inventory()[0]
        report["documents_restored"] = report["documents_after"] == count
        real.write_json(directory / "comparison.json", report)
    assert report["documents_restored"]
    print(json.dumps({"result": str(directory / "comparison.json"),
                      "times_ms": [row["wall_ms"] for row in report["rows"]]}))


if __name__ == "__main__":
    main()
