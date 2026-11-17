import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid


def spotify_prepare(session, wait, restart=False):
    launched = session.call("launch_app", {
        "name": "/Applications/Spotify.app", "creates_new_application_instance": False,
    })
    pid = launched["pid"]
    def ready():
        windows = [row for row in session.windows(pid=pid)
                   if row.get("is_on_screen") is not False]
        return max(windows, key=lambda row: row.get("z_index", -1)) if windows else None
    target = wait(ready, 12, "Spotify window readiness")
    window = {"pid": pid, "window_id": target["window_id"]}
    state = session.call("get_window_state", dict(window, include_screenshot=False,
                                                  tree_format="elements", max_elements=2000))
    def has_body(snapshot):
        return any(row.get("role") in {"AXWebArea", "AXTextField", "AXTextArea", "AXSearchField"}
                   for row in snapshot.get("elements", []))
    if restart and not has_body(state):
        checkpoint = Path(__file__).with_name("jev-realapps-spotify-restart.json")
        if checkpoint.exists():
            raise RuntimeError("The one approved Spotify accessibility restart was already attempted")
        playback = applescript('tell application "Spotify" to return player state as text')
        if playback not in {"paused", "stopped"}:
            raise RuntimeError("Spotify is playing; the approved paused-only restart is not allowed")
        applications = session.call("list_apps", {}).get("apps", [])
        live = [app["pid"] for app in applications if app.get("bundle_id") == "com.spotify.client"]
        if live != [pid]:
            raise RuntimeError("Spotify process changed before the approved restart")
        receipt = {"authorization": "User approved one paused/stopped accessibility restart",
                   "old_pid": pid, "observed_playback": playback, "started": True,
                   "flag": "--force-renderer-accessibility", "playback_mutated": False}
        checkpoint.write_text(json.dumps(receipt, indent=2) + "\n")
        checkpoint.chmod(0o600)
        applescript('''
tell application "Spotify"
    if player state is playing then error "Playback started; do not quit"
    quit
end tell
''')
        wait(lambda: not any(app.get("pid") == pid for app in session.call("list_apps", {}).get("apps", [])),
             12, "paused Spotify graceful shutdown")
        launched = session.call("launch_app", {
            "name": "/Applications/Spotify.app", "creates_new_application_instance": False,
            "additional_arguments": ["--force-renderer-accessibility"],
        })
        pid = launched["pid"]
        target = wait(ready, 12, "restarted Spotify window")
        window = {"pid": pid, "window_id": target["window_id"]}
        def body_ready():
            current = session.call("get_window_state", dict(window, include_screenshot=False,
                                    tree_format="elements", max_elements=2000))
            return current if has_body(current) else None
        state = wait(body_ready, 15, "Spotify accessible renderer readiness")
        receipt.update(new_pid=pid, completed=True, accessible_body=True)
        checkpoint.write_text(json.dumps(receipt, indent=2) + "\n")
        session.metadata["spotify_accessibility_restart"] = receipt
    roles = {}
    controls = []
    allowed = {"search", "play", "pause", "connect to a device", "connect to device",
               "this computer", "this mac", "current device", "devices available"}
    for row in state.get("elements", []):
        role = row.get("role", "")
        roles[role] = roles.get(role, 0) + 1
        label = row.get("label", row.get("title", ""))
        if label.lower().strip() in allowed:
            controls.append({key: row.get(key) for key in
                             ["element_index", "element_token", "role", "label", "title", "actions", "states", "value"]})
    session.metadata["spotify_preflight"] = {
        "window": window, "role_counts": roles, "public_controls": controls,
        "playback_mutated": False, "local_device_attested": False,
    }
    print(json.dumps(session.metadata["spotify_preflight"], indent=2))


def spotify_accessibility(session, wait):
    return spotify_prepare(session, wait, restart=True)


def applescript(script, *arguments):
    result = subprocess.run(["osascript", "-", *map(str, arguments)], input=script,
                            capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError("Native scripting failed: " + result.stderr.strip())
    return result.stdout.rstrip("\n")


def notes(session, wait):
    checkpoint = Path(__file__).with_name("jev-realapps-owned-note.json")
    if checkpoint.exists():
        owned = json.loads(checkpoint.read_text())
    else:
        marker = uuid.uuid4().hex[:12]
        owned = {"marker": marker, "title": "Jev Test - Native Qualification " + marker,
                 "note_id": None, "creation_started": False}
        checkpoint.write_text(json.dumps(owned, indent=2) + "\n")
        checkpoint.chmod(0o600)
    if owned["note_id"] is None:
        if owned["creation_started"]:
            raise RuntimeError("Prior note creation outcome is uncertain; do not create another note")
        owned["creation_started"] = True
        checkpoint.write_text(json.dumps(owned, indent=2) + "\n")
        owned["note_id"] = applescript('''
on run argv
    tell application "Notes"
        set ownedNote to make new note at default folder of default account with properties {body:"<h1>" & item 1 of argv & "</h1>"}
        return id of ownedNote
    end tell
end run
''', owned["title"])
        checkpoint.write_text(json.dumps(owned, indent=2) + "\n")
    def plaintext():
        return applescript('''
on run argv
    tell application "Notes"
        set ownedNote to note id (item 1 of argv)
        if name of ownedNote is not item 2 of argv then error "Owned note name changed"
        if shared of ownedNote or password protected of ownedNote then error "Owned note scope changed"
        return plaintext of ownedNote
    end tell
end run
''', owned["note_id"], owned["title"])
    initial = plaintext()
    if any(line and line != owned["title"] and not line.startswith("Jev native note entry ")
           for line in initial.splitlines()):
        raise RuntimeError("Test note contains non-harness text; no editing authorized")
    applescript('''
on run argv
    tell application "Notes"
        show note id (item 1 of argv) separately true
    end tell
end run
''', owned["note_id"])
    roster = session.call("list_apps", {}).get("apps", [])
    apps = [app for app in roster if app.get("bundle_id", "").lower() == "com.apple.notes"]
    if len(apps) != 1:
        raise RuntimeError("Notes process identity is ambiguous")
    pid = apps[0]["pid"]
    def detached():
        windows = [row for row in session.windows(pid=pid)
                   if owned["marker"] in row.get("title", "")]
        return windows[0] if len(windows) == 1 else None
    target = wait(detached, 12, "owned detached Notes window")
    session.metadata["notes_fixture"] = {
        "checkpoint": checkpoint.name, "created_by": "harness, not Jev",
        "retained": True, "window_id": target["window_id"], "title": owned["title"],
    }
    value = "Jev native note entry " + uuid.uuid4().hex[:10] + "."
    if value in initial:
        raise RuntimeError("Notes oracle negative control failed")
    def oracle():
        current = plaintext()
        valid = current.startswith(owned["title"]) and current.count(value) == 1
        return {"title_preserved": current.startswith(owned["title"]),
                "requested_paragraph_count": current.count(value)}, valid
    return session.drive({
        "id": "notes.append.paragraph", "app": "Notes", "window_id": target["window_id"],
        "goal": "Add " + value + " as a new paragraph at the end of this note. Keep its existing title and text.",
        "values": {"text": "\n" + value},
    }, oracle)


def owned_conflict_save_target(state, window, marker, path):
    failure = "owned_fixture_conflict_target_unverified"
    if (state.get("pid") != window["pid"] or state.get("window_id") != window["window_id"]
            or marker not in str(state.get("window_title", ""))
            or not isinstance(state.get("capture_id"), str) or not state["capture_id"]):
        raise RuntimeError(failure)
    rows = state.get("elements", [])
    indexed = {row.get("element_index"): row for row in rows}
    sheets = [row for row in rows if row.get("role") == "AXSheet"]
    roots = [row for row in rows if row.get("role") == "AXWindow"
             and row.get("parent_index") is None]
    if len(indexed) != len(rows) or len(sheets) != 1 or len(roots) != 1:
        raise RuntimeError(failure)
    sheet = sheets[0]["element_index"]

    def inside(row, ancestor=sheet):
        seen = set()
        parent = row.get("parent_index")
        while parent in indexed and parent not in seen:
            if parent == ancestor:
                return True
            seen.add(parent)
            parent = indexed[parent].get("parent_index")
        return False

    if not inside(sheets[0], roots[0]["element_index"]):
        raise RuntimeError(failure)
    scoped = [row for row in rows if inside(row)]
    warning = any(row.get("role") == "AXStaticText"
                  and path.name in row.get("label", "")
                  and "could not be autosaved" in row["label"]
                  and "changed by another application" in row["label"] for row in scoped)
    buttons = [row for row in scoped if row.get("role") == "AXButton"
               and row.get("label") == "Save Anyway"]
    if not warning or len(buttons) != 1:
        raise RuntimeError(failure)
    button = buttons[0]
    if (not button.get("element_token")
            or not any(str(action).lower().removeprefix("ax") == "press"
                       for action in button.get("actions", []))):
        raise RuntimeError(failure)
    return dict(window, capture_id=state["capture_id"], element_token=button["element_token"],
                action="press", delivery_mode="background")


def unrelated_windows_to_retain(lease, native):
    sheets = native.get("modal_sheets")
    ids = native.get("owned_sheet_window_ids")
    other = set(lease["other_windows_retained"])
    if (type(sheets) is not int or sheets < 1 or not isinstance(ids, list)
            or any(type(value) is not int or value < 1 for value in ids)
            or len(ids) != sheets or len(set(ids)) != sheets
            or not set(ids).issubset(other | {lease["window"]["window_id"]})):
        raise RuntimeError("owned_fixture_sheet_window_identity_unverified")
    return other - set(ids)


def resolve_owned_conflict(session, case_receipt, real):
    if os.environ.get("JARVIS_P4_FIXTURE_CONFLICT_SAVE") != "approved-once":
        raise RuntimeError("owned_fixture_conflict_save_not_approved")
    if session.variant != "after":
        raise RuntimeError("owned_fixture_capture_bound_native_driver_required")
    fixture = session.adopt_document_fixture(case_receipt)
    window, marker, path = fixture["window"], fixture["marker"], fixture["path"]
    known = [fixture["baseline"], fixture["value"]]
    evidence = {"qualification": False, "status": "preflight", "input_attempts": 0,
                "window": window, "borrowed_window_retained": True}
    session.metadata["fixture_conflict_save"] = evidence
    state = session.call("get_window_state", dict(window, include_screenshot=True,
        include_accessibility_tree=True, tree_format="elements",
        max_elements=600, max_depth=20, max_image_dimension=1568))
    target = owned_conflict_save_target(state, window, marker, path)
    native = session.native_window_state(window, state.get("window_title", ""))
    body = real.owned_document_body(state, window, marker, known, path, native)
    if (native.get("modal_sheets") != 1 or native.get("role_read_failures") != 0
            or native.get("children_read_failures") != 0):
        raise RuntimeError("owned_fixture_conflict_native_scope_unverified")
    siblings = unrelated_windows_to_retain(session.metadata["fixture_lease"], native)
    before = path.read_bytes()
    if (path.is_symlink() or path.stat().st_uid != os.getuid()
            or before != body.encode("utf-8")):
        raise RuntimeError("owned_fixture_conflict_disk_live_mismatch")
    evidence.update(native_before=native, disk_live_sha256=hashlib.sha256(before).hexdigest(),
                    capture_id=target["capture_id"], press_dispatch_intent_recorded=True,
                    status="press_requested", unrelated_windows_expected=sorted(siblings),
                    owned_sheet_window_ids=native["owned_sheet_window_ids"])
    before_calls = session.metadata.get("local_tool_calls", {}).get("click", 0)
    try:
        response = session.raw_call("click", target)
    finally:
        evidence["input_attempts"] = session.metadata.get("local_tool_calls", {}).get("click", 0) - before_calls
    evidence["driver_reported_error"] = bool(response.get("isError"))
    if response.get("isError"):
        raise RuntimeError("owned_fixture_conflict_native_press_refused")
    evidence["status"] = "native_press_accepted"

    def cleared():
        current = session.read_owned_document(window, marker, path, known)
        proof = session.metadata["owned_document_reads"][-1]["native"]
        if type(proof.get("modal_sheets")) is int and proof["modal_sheets"] > 0:
            return False
        require_owned_document_ready(session, window)
        if current.encode("utf-8") != before or path.read_bytes() != before:
            raise RuntimeError("owned_fixture_conflict_content_changed")
        return True

    real.wait_for(cleared, 5, "owned synthetic autosave conflict resolution")
    evidence.update(status="content_verified",
                    native_after=session.metadata["owned_document_reads"][-1]["native"],
                    disk_after_sha256=real.digest(path),
                    jev_drive_requests=session.metadata["drive_requests"])
    remaining = {row["window_id"] for row in session.windows(pid=window["pid"])}
    evidence["window_ids_after"] = sorted(remaining)
    if window["window_id"] not in remaining or not siblings.issubset(remaining):
        raise RuntimeError("owned_fixture_conflict_window_lifecycle_changed")
    evidence.update(status="verified", unrelated_windows_retained=sorted(siblings),
                    native_after=session.metadata["owned_document_reads"][-1]["native"],
                    disk_after_sha256=real.digest(path),
                    jev_drive_requests=session.metadata["drive_requests"])


def require_owned_document_ready(session, window):
    records = session.metadata.get("owned_document_reads", [])
    record = records[-1] if records else {}
    native = record.get("native", {})
    sheets = native.get("modal_sheets")
    if type(sheets) is int and sheets > 0:
        raise RuntimeError("owned_fixture_blocked_by_sheet")
    counters = [native.get(key) for key in (
        "modal_sheets", "role_read_failures", "children_read_failures")]
    if record.get("expected_window") != window or any(type(value) is not int or value != 0 for value in counters):
        raise RuntimeError("owned_fixture_readiness_unverified")


def textedit_owned(session, case_receipt):
    fixture = session.adopt_document_fixture(case_receipt)
    window, marker, path = fixture["window"], fixture["marker"], fixture["path"]
    baseline, value = fixture["baseline"], fixture["value"]
    known = [baseline, value]
    current = session.read_owned_document(window, marker, path, known)
    require_owned_document_ready(session, window)
    if current != baseline:
        state = session.call("get_window_state", dict(window, include_screenshot=False,
                                                      tree_format="elements", max_elements=500))
        if state.get("pid") != window["pid"] or state.get("window_id") != window["window_id"]:
            raise RuntimeError("owned_fixture_reset_target_unverified")
        fields = [row for row in state.get("elements", [])
                  if row.get("role", "").lower() in {"axtextarea", "textarea"}]
        if len(fields) != 1 or not fields[0].get("element_token"):
            raise RuntimeError("owned_fixture_reset_field_unverified")
        session.call("set_value", {"element_token": fields[0]["element_token"], "value": baseline})
    if session.read_owned_document(window, marker, path, known) != baseline:
        raise RuntimeError("owned_fixture_baseline_unverified")
    session.metadata["fixture_retained_for_matched_replay"] = True
    session.metadata["textedit_targeting"] = "exact synthetic window; restored sibling untouched"

    def oracle():
        try:
            body = session.read_owned_document(window, marker, path, known)
        except RuntimeError as error:
            return {"document_body_matches": False, "native_exact_value_verified": False,
                    "code": str(error)}, False
        return {"document_body_matches": body == value, "baseline_body_matches": body == baseline,
                "native_exact_value_verified": True}, body == value

    assert oracle()[1] is False
    require_owned_document_ready(session, window)
    session.drive({
        "id": "textedit.replace.body", "kind": "native-text-entry",
        "app": "com.apple.TextEdit", "window_id": window["window_id"],
        "goal": "Replace all text in the current document with: " + value,
        "values": {"text": value},
    }, oracle)


def textedit(session, wait, marker=None):
    marker = marker or uuid.uuid4().hex[:10]
    directory = session.directory if session.variant is not None else session.runtime
    path = directory / ("Jev-Test-Document-" + marker + ".txt")
    baseline = "Jev native document baseline " + marker + "."
    path.write_text(baseline + "\n")
    existing = set(map(int, subprocess.run(["pgrep", "-x", "TextEdit"], capture_output=True,
                                          text=True, timeout=3).stdout.split()))
    session.metadata["textedit_launch_requested"] = True
    launched = session.call("launch_app", {
        "name": "/System/Applications/TextEdit.app",
        "creates_new_application_instance": True, "urls": [str(path)],
        "additional_arguments": ["-ApplePersistenceIgnoreState", "YES"],
    })
    pid = launched.get("pid")
    if not isinstance(pid, int) or pid <= 0:
        raise RuntimeError("TextEdit did not provide a process identity")
    session.metadata["textedit_launch_pid"] = pid
    session.metadata["textedit_reuses_existing_app"] = pid in existing
    if pid in existing:
        session.metadata["unclaimed_document_pid"] = pid
        raise RuntimeError("TextEdit reused a process; no shared-instance input authorized")
    session.own_document_process(pid, "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit")
    def document():
        windows = session.windows(pid=pid)
        matching = {row["window_id"]: row for row in windows
                    if marker in str(row.get("title", row.get("window_title", "")))}
        session.metadata["textedit_prepared_window_count"] = len(windows)
        return next(iter(matching.values()), None) if len(matching) == 1 else None
    target = wait(document, 12, "new TextEdit synthetic document readiness")
    window = {"pid": pid, "window_id": target["window_id"]}
    value = "Jev real app text entry " + marker + "."
    session.owned_documents.append((window, marker))
    session.owned_document_content[window["window_id"]] = {
        "path": str(path), "known_bodies": [baseline + "\n", value],
    }
    session.metadata["owned_document"] = {
        "window": window, "marker": marker, "path": str(path),
        "known_bodies": [baseline + "\n", value],
    }
    session.owned_document_processes[pid]["windows"][window["window_id"]] = marker
    initial = session.windows(pid=pid)
    initial_windows = {row["window_id"] for row in initial}
    for row in initial:
        if row["window_id"] != window["window_id"]:
            session.close_startup_blank(row, initial_windows)
    if any(row["window_id"] != window["window_id"] for row in session.windows(pid=pid)):
        raise RuntimeError("new TextEdit instance still contains an unowned window")
    session.metadata["textedit_requested_delivery"] = "background"
    roster = session.call("list_apps", {}).get("apps", [])
    matching = [row for row in roster if row.get("bundle_id", "").lower() == "com.apple.textedit"]
    session.metadata["textedit_roster_pids"] = [row.get("pid") for row in matching]
    if not any(row.get("pid") == pid for row in matching):
        raise RuntimeError("owned foreground TextEdit process is absent from the roster")
    session.metadata["textedit_targeting"] = "exact-window API, not highest sibling"
    def oracle():
        try:
            body = session.read_owned_document(window, marker, path, [baseline + "\n", value])
        except RuntimeError as error:
            return {"document_body_matches": False, "baseline_body_matches": False,
                    "native_exact_value_verified": False, "code": str(error)}, False
        return {"document_body_matches": body == value, "baseline_body_matches": body == baseline + "\n",
                "native_exact_value_verified": True}, body == value
    initial, correct = oracle()
    if correct or not initial["baseline_body_matches"]:
        raise RuntimeError("new document body did not match the owned synthetic baseline")
    session.metadata["textedit_oracle_negative_control"] = True
    return session.drive({
        "id": "textedit.replace.body", "app": "TextEdit", "window_id": window["window_id"],
        "values": {"text": value},
        "goal": "Replace all text in this document with " + value,
    }, oracle)
