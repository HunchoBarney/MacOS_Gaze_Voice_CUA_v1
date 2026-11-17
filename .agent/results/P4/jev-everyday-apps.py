import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
from urllib.parse import urlsplit


def select_new_window(before, after, pid):
    if any("layer" not in row for row in before + after if row["pid"] == pid):
        raise RuntimeError("native_window_layer_unknown")
    old = {row["window_id"] for row in before if row["pid"] == pid and row["layer"] == 0}
    current = [row for row in after if row["pid"] == pid and row["layer"] == 0]
    fresh = [row for row in current if row["window_id"] not in old]
    if not old.issubset({row["window_id"] for row in current}) or len(fresh) != 1:
        raise RuntimeError("new_owned_window_unverified")
    return fresh[0]


def browser_outcome(state, rows, target):
    if any(state.get(key) != target[key] for key in ("pid", "window_id")):
        return False
    windows = [row for row in rows if all(row.get(key) == target[key] for key in ("pid", "window_id"))]
    if len(windows) != 1 or "wikipedia" not in windows[0].get("title", "").lower():
        return False
    for field in state.get("elements", []):
        if field.get("role", "").lower() not in {"axcombobox", "axtextfield", "axsearchfield"}:
            continue
        value = field.get("value")
        if not isinstance(value, str):
            continue
        parsed = urlsplit(value if "://" in value else "https://" + value)
        if parsed.hostname in {"www.wikipedia.org", "wikipedia.org"} and parsed.path in {"", "/"}:
            return True
    return False


def state_for(session, target, timeout_ms=None):
    arguments = dict(target, include_screenshot=False, tree_format="both", max_elements=2000)
    if timeout_ms is not None:
        arguments["timeout_ms"] = timeout_ms
    state = session.call("get_window_state", arguments)
    if any(state.get(key) != target[key] for key in ("pid", "window_id")):
        raise RuntimeError("native_observation_subject_changed")
    return state


def visible_window(session, app, wait, allow_launch=True):
    if allow_launch:
        launched = session.call("launch_app", {"name": app, "creates_new_application_instance": False})
        pid = launched["pid"]
    else:
        apps = [row for row in session.call("list_apps", {}).get("apps", [])
                if row.get("bundle_id", "").lower() == app.lower()]
        if len(apps) != 1:
            raise RuntimeError("ordinary_existing_app_unverified")
        pid = apps[0]["pid"]
    def ready():
        rows = [row for row in session.windows(pid=pid)
                if row.get("layer") == 0 and row.get("is_on_screen") is not False]
        if len(rows) > 1:
            raise RuntimeError("ordinary_app_window_ambiguous")
        return rows[0] if len(rows) == 1 else None
    row = wait(ready, 10, "ordinary app visible window")
    return {"pid": pid, "window_id": row["window_id"]}


def screenshot(session, target, name):
    raw = session.raw_call("get_window_state", dict(target, include_screenshot=True,
                           tree_format="elements", max_elements=2000))
    state = raw.get("structuredContent", {})
    if any(state.get(key) != target[key] for key in ("pid", "window_id")):
        raise RuntimeError("native_capture_subject_changed")
    images = [item for item in raw.get("content", [])
              if item.get("type") == "image" and item.get("mimeType") == "image/png"]
    if len(images) != 1:
        raise RuntimeError("scoped_screenshot_missing")
    image = base64.b64decode(images[0]["data"], validate=True)
    if not image.startswith(b"\x89PNG\r\n\x1a\n"):
        raise RuntimeError("scoped_screenshot_invalid")
    (session.directory / name).write_bytes(image)
    return name


def browser(session, app, wait):
    launched = session.call("launch_app", {"name": app, "creates_new_application_instance": False})
    pid = launched["pid"]
    def startup():
        rows = [row for row in session.windows(pid=pid) if row.get("layer") == 0]
        return rows if any(row.get("is_on_screen") is not False for row in rows) else None
    old = wait(startup, 10, "browser startup visible normal window")
    def inventory(rows):
        return [{key: row[key] for key in ("pid", "window_id", "layer", "bounds", "is_on_screen") if key in row}
                for row in rows]
    session.metadata["browser_setup_before"] = inventory(old)
    host = next(row for row in old if row.get("is_on_screen") is not False)
    session.invoke_window_menu({"pid": pid, "window_id": host["window_id"]}, ["File", "New Window"])
    def created():
        after = session.windows(pid=pid)
        session.metadata["browser_setup_latest"] = inventory(after)
        if {row["window_id"] for row in after if row.get("layer") == 0} == {row["window_id"] for row in old}:
            return None
        try:
            return select_new_window(old, after, pid)
        except RuntimeError as error:
            if str(error) == "new_owned_window_unverified":
                return None
            raise
    row = wait(created, 10, "one fresh browser window")
    target = {"pid": pid, "window_id": row["window_id"]}
    session.metadata["browser_fixture"] = {
        "app": app, "window": target, "preexisting_windows_retained": [row["window_id"] for row in old],
        "setup": "ordinary File/New Window; no flags, CDP or new permissions",
        "retained": True,
    }
    def oracle():
        state = state_for(session, target)
        rows = session.windows(pid=pid)
        return {"loaded_title_and_native_url": browser_outcome(state, rows, target)}, browser_outcome(state, rows, target)
    if oracle()[1]:
        raise RuntimeError("browser_oracle_negative_control_failed")
    session.drive({"id": app + ".public-navigation", "app": app, "window_id": target["window_id"],
                   "goal": "Open https://www.wikipedia.org in this window.",
                   "values": {"text": "https://www.wikipedia.org"}}, oracle)
    session.metadata["screenshot"] = screenshot(session, target, "browser-after.png")


def calculator_static_values(state):
    values = []
    for line in (state.get("tree_markdown") or "").splitlines():
        match = re.fullmatch(r'\s*-\s+(?:\[\d+\]\s+)?AXStaticText\s*=\s*("(?:[^"\\]|\\.)*")', line)
        if not match:
            continue
        try:
            value = json.loads(match[1]).translate({0x200E: None, 0x200F: None}).strip()
        except ValueError:
            return None
        values.append(value)
    return values


def calculator_display(state):
    if state.get("truncated") is True:
        return None
    static_values = calculator_static_values(state)
    if static_values is None:
        return None
    values = [value for value in static_values if re.fullmatch(r"-?\d+(?:\.\d+)?", value)]
    if len(values) == 1:
        return values[0]
    # Multiple numeric statics — a "last expression" row under the
    # readout or residual history text. The primary display is the
    # largest-font numeric static; a tie stays ambiguous rather than
    # guessing.
    candidates = []
    for field in state.get("elements", []):
        if field.get("role", "").lower() not in {"axstatictext", "axtextfield"}:
            continue
        value = field.get("value") or field.get("label")
        if isinstance(value, str) and re.fullmatch(r"-?\d+(?:\.\d+)?", value.strip()):
            frame = field.get("frame") or {}
            candidates.append((frame.get("height") or 0, value.strip()))
    if candidates:
        candidates.sort(reverse=True)
        tallest = candidates[0][0]
        winners = [value for height, value in candidates if height == tallest]
        return winners[0] if tallest and len(winners) == 1 else None
    return None


def calculator_seed(session, target, observation_timeout_ms=None, post_action_wait=None, wait=None):
    record = {"presses": [], "verified": False, "maximum_presses": 6,
              "observation_timeout_ms": observation_timeout_ms}
    session.metadata["calculator_seed"] = record

    def observe():
        state = state_for(session, target, timeout_ms=observation_timeout_ms)
        record.setdefault("observations", []).append(state)
        if state.get("truncated") is not False:
            return None
        if any(row.get("role") in {"AXSheet", "AXDialog"} for row in state.get("elements", [])):
            raise RuntimeError("calculator_seed_modal")
        return state

    def read():
        if wait is not None:
            return wait(observe, 10, "complete native Calculator setup observation")
        state = observe()
        if state is None:
            raise RuntimeError("calculator_seed_incomplete")
        return state

    def press(labels):
        if len(record["presses"]) >= 6:
            raise RuntimeError("calculator_seed_budget")
        try:
            state = read()
        except RuntimeError as error:
            raise RuntimeError("calculator_seed_scope_or_state") from error
        rows = [row for row in state.get("elements", [])
                if row.get("role") == "AXButton" and row.get("label") in labels]
        if len(rows) != 1 or rows[0].get("enabled") is not True or "AXPress" not in rows[0].get("actions", []):
            raise RuntimeError("calculator_seed_control")
        row = rows[0]
        snapshot, token = state.get("snapshot_id"), row.get("element_token")
        if (not isinstance(snapshot, str) or not re.fullmatch(r"s[0-9a-f]{8}", snapshot)
                or not isinstance(token, str) or not re.fullmatch(re.escape(snapshot) + r":\d+", token)
                or token != f"{snapshot}:{row.get('element_index')}"):
            raise RuntimeError("calculator_seed_token")
        try:
            session.complete_native_window_state(target, state.get("window_title", ""), control=row)
        except RuntimeError as error:
            raise RuntimeError("calculator_seed_native_identity") from error
        arguments = dict(target, element_token=token, delivery_mode="background")
        if post_action_wait is not None:
            arguments["post_action_wait"] = post_action_wait
        entry = dict(label=row["label"], arguments=arguments)
        record["presses"].append(entry)
        started = time.perf_counter()
        try:
            reply = session.raw_call("click", arguments)
        finally:
            entry["driver_wall_ms"] = (time.perf_counter() - started) * 1000
        entry["reply"] = reply
        if reply.get("isError") is True or reply.get("structuredContent", {}).get("success") is False:
            raise RuntimeError("calculator_seed_tool_refused")
        return row["label"]

    if press({"All Clear", "Clear"}) == "Clear":
        press({"All Clear"})
    for label in ("2", "Add", "3", "Equals"):
        press({label})
    state = read()
    try:
        session.complete_native_window_state(target, state.get("window_title", ""))
    except RuntimeError as error:
        raise RuntimeError("calculator_seed_native_final_scope") from error
    values = calculator_static_values(state)
    record.update(final_observation=state, display=calculator_display(state),
                  expression_present=values is not None and "2+3" in values,
                  target=dict(target))
    if record["display"] != "5" or not record["expression_present"]:
        raise RuntimeError("calculator_seed_initial_state")
    record["verified"] = True


def calculator(session, wait, actor=None, timing_kind=None):
    target = visible_window(session, "com.apple.calculator", wait,
                            allow_launch=not session.metadata.get("matched_calculator"))
    if session.metadata.get("matched_calculator"):
        setup_started = time.perf_counter()
        try:
            calculator_seed(session, target, observation_timeout_ms=5000, wait=wait)
        except BaseException as error:
            session.metadata["calculator_seed"]["error"] = dict(type=type(error).__name__, message=str(error))
            session.metadata["calculator_seed"]["error_cause"] = str(error.__cause__) if error.__cause__ else None
            raise
        finally:
            session.metadata["calculator_seed"]["setup_wall_ms"] = (time.perf_counter() - setup_started) * 1000
            seed_name = f"calculator-{timing_kind}-seed.json" if timing_kind else "calculator-seed.json"
            (session.directory / seed_name).write_text(
                json.dumps(session.metadata["calculator_seed"], indent=2) + "\n")
    def ready():
        state = state_for(session, target)
        value = calculator_display(state)
        session.metadata["calculator_readiness"] = {
            "truncated": state.get("truncated"), "tree_available": bool(state.get("tree_markdown")),
            "element_count": len(state.get("elements", [])), "display_available": value is not None,
        }
        return (state, value) if value is not None else None
    state, initial = wait(ready, 10, "unambiguous native calculator display")
    session.metadata["calculator_display_candidates"] = [
        {key: row[key] for key in ("role", "label", "value") if key in row}
        for row in state.get("elements", [])
        if row.get("role", "").lower() in {"axstatictext", "axtextfield"}
    ]
    if initial is None:
        session.metadata["screenshot"] = screenshot(session, target, "calculator-before.png")
        raise RuntimeError("calculator_display_oracle_unavailable")
    left, right = (2, 3) if initial != "5" else (3, 4)
    expected = str(left + right)
    def oracle():
        value = calculator_display(state_for(session, target))
        return {"display": value, "expected": expected, "display_evidence_available": value is not None}, value == expected
    if oracle()[1]:
        raise RuntimeError("calculator_oracle_negative_control_failed")
    case = {"id": f"calculator.{timing_kind}" if timing_kind else "calculator.add",
            "app": "com.apple.calculator", "window_id": target["window_id"],
            "goal": f"Calculate {left} plus {right} and show the result.", "values": {}}
    if timing_kind:
        case["kind"] = timing_kind
    row = session.drive(case, oracle, actor=actor) if actor is not None else session.drive(case, oracle)
    image_name = f"calculator-{timing_kind}-after.png" if timing_kind else "calculator-after.png"
    session.metadata["screenshot"] = screenshot(session, target, image_name)
    return row


def calculator_keys(session, wait):
    """press_key on a real app: Escape clears Calculator's display."""
    target = visible_window(session, "com.apple.calculator", wait)
    state = wait(lambda: state_for(session, target), 10, "calculator keys seed state")
    rows = [row for row in state.get("elements", [])
            if row.get("role") == "AXButton" and row.get("label") == "7"]
    if len(rows) != 1:
        raise RuntimeError("calculator_keys_seed_control")
    reply = session.raw_call("click", dict(target, element_token=rows[0]["element_token"],
                                           delivery_mode="background"))
    if reply.get("isError") is True:
        raise RuntimeError("calculator_keys_seed_refused")
    def oracle():
        value = calculator_display(state_for(session, target))
        return {"display": value, "expected": "0",
                "display_evidence_available": value is not None}, value == "0"
    if oracle()[1]:
        raise RuntimeError("calculator_keys_oracle_negative_control_failed")
    case = {"id": "calculator.escape", "app": "com.apple.calculator",
            "window_id": target["window_id"],
            "goal": "Clear the calculator display to zero using the escape key.",
            "success_contains": ["0"], "values": {}}
    row = session.drive(case, oracle)
    session.metadata["screenshot"] = screenshot(session, target, "calculator-keys-after.png")
    return row


def calculator_menu(session, wait):
    """invoke_menu through the drive lane: View > Scientific adds controls;
    View > Basic restores them. Two real menu drives, net state restored."""
    target = visible_window(session, "com.apple.calculator", wait)
    scientific = {"sine", "cosine", "tangent", "logarithm", "natural logarithm",
                  "x squared", "x to the power of y", "factorial", "2nd"}
    def labels_in(state):
        return {str(row.get("description") or row.get("label") or "").lower()
                for row in state.get("elements", [])}
    def mode_present(state):
        labels = labels_in(state)
        return labels & scientific, len(state.get("elements", []))
    def to_scientific():
        hits, count = mode_present(state_for(session, target))
        return {"scientific_labels": sorted(hits), "element_count": count}, bool(hits)
    if to_scientific()[1]:
        raise RuntimeError("calculator_menu_oracle_negative_control_failed")
    row = session.drive({"id": "calculator.menu-scientific", "app": "com.apple.calculator",
                         "window_id": target["window_id"],
                         "goal": "Switch the calculator to Scientific mode using menu View > Scientific.",
                         "success_contains": ["Mode: scientific"], "values": {}}, to_scientific)
    session.metadata["screenshot"] = screenshot(session, target, "calculator-menu-after.png")
    def to_basic():
        hits, count = mode_present(state_for(session, target))
        return {"scientific_labels": sorted(hits), "element_count": count}, not hits
    session.drive({"id": "calculator.menu-basic", "app": "com.apple.calculator",
                   "window_id": target["window_id"],
                   "goal": "Switch the calculator to Basic mode using menu View > Basic.",
                   "success_contains": ["Mode: basic"], "values": {}}, to_basic)
    session.metadata["screenshot_restore"] = screenshot(session, target, "calculator-menu-restored.png")
    return row


def scroll(session, wait):
    """scroll-and-seek in Safari on a bounded fixture page. The marker is a
    link label: links carry AXPress, so the marker can never become an AX fact
    or satisfy success_contains — only the pixel lane can confirm it actually
    rendered on screen. The scrollbar value is the independent oracle."""
    launched = session.call("launch_app", {"name": "com.apple.Safari",
                                           "creates_new_application_instance": False})
    pid = launched["pid"]
    marker = "SEEK-MARKER-77"
    fixture = session.directory / "scroll-fixture.html"
    lines = "\n".join(f"<p>fill line {i:03d} {'x' * 70}</p>" for i in range(45))
    fixture.write_text(
        "<html><head><title>Scroll Fixture</title></head><body>"
        f"<h1>Scroll fixture</h1>{lines}"
        f"<p><a href='#{marker}'>{marker}</a></p>"
        f"<p id='{marker}'>end of page</p></body></html>")
    subprocess.run(["open", "-b", "com.apple.Safari", str(fixture)],
                   check=True, timeout=10)
    def loaded_window():
        rows = [row for row in session.windows(pid=pid)
                if row.get("layer") == 0 and row.get("is_on_screen") is not False
                and "scroll fixture" in str(row.get("title", row.get("window_title", ""))).lower()]
        return rows[0] if len(rows) == 1 else None
    row = wait(loaded_window, 15, "scroll fixture window")
    target = {"pid": pid, "window_id": row["window_id"]}
    def bars_in(state):
        return [row.get("value") for row in state.get("elements", [])
                if "scrollbar" in str(row.get("role", "")).lower()
                and row.get("value") is not None]
    def loaded():
        try:
            state = state_for(session, target)
        except Exception:
            return None
        elements = state.get("elements", [])
        if elements and any("fill line 000" in str(element.get("value")
                            or element.get("label") or "")
                            for element in elements):
            return state
        return None
    state = wait(loaded, 15, "scroll fixture render")
    before_bars = bars_in(state)
    if not before_bars:
        raise RuntimeError("scroll_fixture_scrollbar_missing")
    def oracle():
        bars = bars_in(state_for(session, target))
        moved = False
        try:
            moved = bool(bars) and max(float(b) for b in bars) > max(
                float(b) for b in before_bars)
        except (TypeError, ValueError):
            moved = False
        return {"bar_before": before_bars, "bar_after": bars}, moved
    row = session.drive({"id": "safari.scroll", "app": "com.apple.Safari",
                         "window_id": target["window_id"],
                         "caller_deadline_seconds": 45,
                         "goal": (f"Keep scrolling down the page until the link "
                                  f"'{marker}' is visibly rendered on screen — it "
                                  "starts off-screen, so scrolling is the only way "
                                  "to reveal it."),
                         "values": {}}, oracle)
    session.metadata["screenshot"] = screenshot(session, target, "scroll-after.png")
    # Owned cleanup: `open` leaves the fixture in a new tab each rep —
    # close tabs that loaded this rep's fixture path so stale pages stop
    # accumulating element noise across runs.
    try:
        subprocess.run(["osascript", "-e",
            'tell application "Safari" to repeat with w in windows\n'
            'repeat with t in tabs of w\n'
            f'if URL of t contains "{fixture}" then close t\n'
            'end repeat\nend repeat'],
            timeout=10)
    except Exception:
        pass
    return row


def calculator_pilot(session, wait):
    session.metadata["matched_calculator"] = True
    actor = session.start_actor()
    session.metadata["warm_scope_proof"] = {
        "actor_pid": actor.proc.pid,
        "method": "same owned MCP client and agent process; both goals recorded; no forced reconnect",
        "limitation": "driver transport generation and session epoch are not exported by the product",
    }
    for timing_kind in ("cold", "warm"):
        row = calculator(session, wait, actor=actor, timing_kind=timing_kind)
        if not row["strict_success"]:
            session.metadata["warm_pilot_stopped_after"] = timing_kind
            break


def spotify_outcome(state, query):
    rows = state.get("elements", [])
    fields = [row for row in rows if row.get("role", "").lower() in {"axsearchfield", "axtextfield"}
              and "search" in row.get("label", "").lower()]
    if not fields:
        return {"native_search_evidence_available": False}, None
    matches = [row for row in fields if (row.get("value") or "").casefold() == query.casefold()]
    results = [row for row in rows if row not in fields and query.casefold() in row.get("label", "").casefold()
               and row.get("role", "").lower() in {"axstatictext", "axbutton", "axlink"}]
    return {"native_search_evidence_available": True, "query_matches": len(matches) == 1,
            "matching_result_count": len(results)}, len(matches) == 1 and bool(results)


def spotify(session, wait, native):
    target = visible_window(session, "com.spotify.client", wait)
    command = subprocess.run(["ps", "-p", str(target["pid"]), "-o", "command="],
                             capture_output=True, text=True, check=True, timeout=3).stdout
    state = state_for(session, target)
    query = next((name for name in ("Mozart", "Debussy", "Bach")
                  if spotify_outcome(state, name)[1] is not True), None)
    if query is None:
        raise RuntimeError("spotify_oracle_negative_control_unavailable")
    def playback():
        return native.applescript('''
tell application "Spotify"
    set currentState to player state as text
    try
        set currentID to id of current track
    on error
        set currentID to ""
    end try
    return currentState & "|" & currentID
end tell
''')
    previous = playback()
    session.metadata["spotify_playback_scope"] = {
        "playback_test": "skipped", "reason": "Local device routing has not been independently proven",
        "baseline_playback_fingerprint": hashlib.sha256(previous.encode()).hexdigest(),
        "setup": "normal launch, no restart or flags",
        "existing_diagnostic_accessibility_flag": "--force-renderer-accessibility" in command,
    }
    def oracle():
        details, verified = spotify_outcome(state_for(session, target), query)
        details["playback_unchanged"] = playback() == previous
        return details, verified is True and details["playback_unchanged"]
    session.drive({"id": "spotify.search", "app": "com.spotify.client", "window_id": target["window_id"],
                   "goal": f"Show the search results for {query}. Do not start or stop playback.",
                   "values": {"text": query},
                   "deny": ["Play", "Pause", "Space", "Next Track", "Previous Track", "Shuffle"]}, oracle)
    row = session.metadata["rows"][-1]
    if not row["actual_state"]["playback_unchanged"]:
        raise RuntimeError("spotify_playback_changed_stop_qualification")
    if not row["actual_state"]["native_search_evidence_available"]:
        row["verification_status"] = "unavailable"
        row["unverified_done"] = row["status"] in ("done", "already")
        row["false_done"] = None if row["unverified_done"] else False
    session.metadata["screenshot"] = screenshot(session, target, "spotify-after.png")


def observe(session):
    known = {"com.google.chrome", "com.apple.safari", "com.apple.notes",
             "com.spotify.client", "com.apple.calculator"}
    session.metadata["observations"] = []
    for app in session.call("list_apps", {}).get("apps", []):
        bundle = app.get("bundle_id", "").lower()
        if bundle not in known:
            continue
        rows = session.windows(pid=app["pid"])
        entry = {"app": bundle, "windows": [
            {key: row[key] for key in ("pid", "window_id", "layer", "bounds", "is_on_screen") if key in row}
            for row in rows
        ], "captures": []}
        session.metadata["observations"].append(entry)
        normal = [row for row in rows if row.get("layer") == 0]
        if bundle == "com.apple.notes":
            marker = json.loads(Path(__file__).with_name("jev-realapps-owned-note.json").read_text())["marker"]
            normal = [row for row in normal if marker in row.get("title", "")]
        if bundle not in {"com.apple.notes", "com.spotify.client", "com.apple.calculator"} or len(normal) != 1:
            continue
        target = {"pid": app["pid"], "window_id": normal[0]["window_id"]}
        try:
            state = state_for(session, target)
            capture = {"window": target, "element_count": len(state.get("elements", [])),
                       "degraded": state.get("degraded"), "screenshot": screenshot(
                           session, target, bundle + "-" + str(target["window_id"]) + ".png")}
            if bundle == "com.apple.calculator":
                capture["state_keys"] = sorted(state)
                capture["truncated"] = state.get("truncated")
                capture["native_tree_markdown"] = state.get("tree_markdown")
                capture["display_candidates"] = [
                    {key: row[key] for key in ("role", "label", "value") if key in row}
                    for row in state.get("elements", [])
                    if row.get("role", "").lower() in {"axstatictext", "axtextfield"}
                ]
            entry["captures"].append(capture)
        except (RuntimeError, ValueError) as error:
            entry["observation_error"] = type(error).__name__


def run(session, case, wait, native):
    session.metadata["everyday_case"] = case
    session.metadata["qualification_scope"] = "safe ordinary apps; no flags or changed app settings"
    if case == "inspect":
        observe(session)
    elif case in ("chrome", "safari"):
        browser(session, "com.google.Chrome" if case == "chrome" else "com.apple.Safari", wait)
    elif case == "notes":
        if not json.loads(Path(native.__file__).with_name("jev-realapps-owned-note.json").read_text()).get("note_id"):
            raise RuntimeError("only_the_existing_approved_test_note_may_be_used")
        native.notes(session, wait)
    elif case == "spotify":
        spotify(session, wait, native)
    elif case == "calculator":
        calculator(session, wait)
    elif case == "keys":
        calculator_keys(session, wait)
    elif case == "menu":
        calculator_menu(session, wait)
    elif case == "scroll":
        scroll(session, wait)
    else:
        raise ValueError("unsupported everyday qualification case")
