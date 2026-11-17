import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("retained_scroll", HERE / "c1-scroll.py")
scroll = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scroll)


def main():
    real = scroll.load("inspect_real", HERE / "jev-realapps.py")
    cleanup = scroll.load("inspect_cleanup", scroll.ROOT / ".agent/results/P3/physical-20261105/run-focus-window-density.py")
    directory = HERE / "c1-r7-token-scroll-probe"
    directory.mkdir(mode=0o700)
    cleanup.BACKUP = directory / "fixture-backups"
    target = directory / "owned-scroll.txt"
    text = "\n".join(f"Jev owned scrolling fixture line {index:04d}" for index in range(300))
    target.write_text(text)
    count, _ = cleanup.inventory()
    report = {"qualification": False, "input_actuations": 0, "documents_before": count}
    try:
        with real.Session(directory, HERE / "c1-scroll-r7-native/candidate.json", variant="c1") as session:
            scroll.apple(f'tell application "TextEdit" to open POSIX file {json.dumps(str(target))}')
            scroll.apple('tell application "TextEdit" to activate')
            real.wait_for(lambda: scroll.body(target) == text, 8, "owned document")
            front_document = 'tell application "System Events" to tell application process "TextEdit" to return value of attribute "AXDocument" of front window'
            real.wait_for(lambda: scroll.apple(front_document) == target.as_uri(), 8, "owned front document")
            pid = int(scroll.apple('tell application "System Events" to return unix id of first application process whose bundle identifier is "com.apple.TextEdit"'))
            window = int(scroll.apple('tell application "TextEdit" to return id of front window'))
            identity = {"pid": pid, "window_id": window}
            rows = real.wait_for(lambda: [row for row in session.windows(pid=pid)
                if row["window_id"] == window and target.stem in row.get("title", row.get("window_title", ""))],
                8, "owned window inventory")
            assert len(rows) == 1 and target.stem in rows[0].get("title", rows[0].get("window_title", ""))
            assert scroll.apple('tell application "System Events" to tell application process "TextEdit" to return value of attribute "AXDocument" of front window') == target.as_uri()
            result = session.raw_call("get_window_state", dict(identity, include_screenshot=False,
                max_elements=600, max_depth=20, tree_format="both"))
            real.write_json(directory / "snapshot.json", result)
            assert not result.get("isError")
            state = real.payload(result)
            areas = [row for row in state.get("elements", [])
                     if row.get("role") == "AXTextArea" and row.get("value") == text and row.get("element_token")]
            assert len(areas) == 1
            assert scroll.body(target) == text
            before = scroll.viewport(target)
            assert before == 0
            arguments = dict(identity, element_token=areas[0]["element_token"], direction="down", by="line", amount=3)
            real.write_json(directory / "scroll-request.json", arguments)
            result = session.raw_call("scroll", arguments)
            report["input_actuations"] = 1
            real.write_json(directory / "scroll-response.json", result)
            report.update(identity=identity, snapshot_keys=list(state),
                          elements=[{key: row[key] for key in ("role", "element_token", "element_index", "frame", "actions") if key in row}
                                    for row in state.get("elements", [])],
                          viewport_before=before, viewport=scroll.viewport(target), body_unchanged=scroll.body(target) == text)
    finally:
        owned = sorted(set(cleanup.inventory()[1]) & {target})
        if owned:
            cleanup.close_owned(owned)
        report["documents_after"] = cleanup.inventory()[0]
        report["documents_restored"] = report["documents_after"] == count
        real.write_json(directory / "inspection.json", report)
    assert report["documents_restored"] and report["body_unchanged"] and report["viewport"] > report["viewport_before"]
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
