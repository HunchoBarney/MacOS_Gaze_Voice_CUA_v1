import argparse
import base64
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "bench"))
from lib.mcp_stdio import MCPStdio, require_api_key, tool_text
from lib.results import classify

RECEIPT = HERE / "jev-candidate-stage-6ec2307771e34c8aaee594112231d5f5.json"
DRIVER_SHA = "b4d974a9c1c92a700cd7be7ede987aea4a1e6835e37039ce3d628b71bd5f0ca8"
HOST = "com.chriswozniczek.jevvoice"
_execution_leases = {}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    pending = path.with_suffix(".pending")
    with os.fdopen(os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
    pending.replace(path)


def wait_for(probe, seconds, message):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = probe()
        if result:
            return result
        time.sleep(0.05)
    raise TimeoutError(message)


def start_client(argv, environment):
    client = MCPStdio(argv, environment, cwd=str(ROOT))
    client.proc = subprocess.Popen(client.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=client.env, cwd=client.cwd)
    try:
        client.initialize()
        return client
    except BaseException:
        client.close()
        raise


def payload(result):
    body = result.get("structuredContent", {})
    if result.get("isError") or body.get("status") == "refused" or body.get("effect") == "refused":
        text, _ = tool_text(result)
        indicators = [word for word in (
            "approval_required", "permission", "session", "policy", "invalid",
            "unsupported", "missing", "not running", "not found", "grant", "foreground",
        ) if word in text.lower()]
        codes = {key: value for item in objects(result) for key, value in item.items()
                 if key in {"code", "error_code", "reason_code", "status"}
                 and isinstance(value, (str, int))}
        raise RuntimeError(json.dumps({"driver_error_codes": codes, "indicators": indicators}))
    if isinstance(result.get("structuredContent"), dict):
        return result["structuredContent"]
    text, _ = tool_text(result)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        raise RuntimeError("driver returned no structured state") from None


def verify_source_subject(expected, current, driver_only=False, approved_delta=None):
    matches = expected == current
    if not matches and not driver_only:
        changed = {path for path in set(expected) | set(current) if expected.get(path) != current.get(path)}
        permitted = (set(expected).issubset(current) and approved_delta
                     and changed == set(approved_delta)
                     and all(set(approved_delta[path]) == {"before", "after"}
                             and (approved_delta[path]["before"] == expected[path]
                                  and approved_delta[path]["before"] is not None
                                  if path in expected else approved_delta[path]["before"] is None)
                             and approved_delta[path].get("after") == current[path]
                             for path in changed))
        if not permitted:
            raise RuntimeError("current source differs from signed product candidate")
    return matches


def qualification_denials(case):
    extra = case.get("deny", [])
    if not isinstance(extra, list) or not all(isinstance(value, str) and value for value in extra):
        raise ValueError("case denials must be a list of nonempty strings")
    return ["Delete", "Share", "Send", "Subscribe", "Follow", "Add to playlist",
            "Sign out", "Purchase", *extra]


def matches_fingerprint(observed, value):
    return (isinstance(observed, dict) and isinstance(value, str)
            and observed.get("sha256") == hashlib.sha256(value.encode()).hexdigest()
            and observed.get("utf8_count") == len(value.encode()))


def native_window_proven(native, window, title):
    return (isinstance(native, dict) and native.get("ax_trusted") is True
            and native.get("target_found") is True and native.get("budget_exhausted") is False
            and native.get("pid") == window["pid"] and native.get("window_id") == window["window_id"]
            and matches_fingerprint(native.get("window_title"), title))


def owned_document_body(state, window, marker, known_bodies, path, native):
    if (state.get("pid") != window["pid"] or state.get("window_id") != window["window_id"]
            or marker not in str(state.get("window_title", ""))
            or state.get("degraded")
            or not native_window_proven(native, window, state["window_title"])):
        raise RuntimeError("owned_document_body_unverified")
    document = native.get("document", {})
    if (document.get("status") != "file"
            or not matches_fingerprint(document.get("path"), str(Path(path).resolve()))):
        raise RuntimeError("owned_document_body_unverified")
    fields = [row.get("value") for row in native.get("fields", [])
              if row.get("role", "").lower() in {"axtextarea", "textarea"}]
    bodies = [value for value in known_bodies if len(fields) == 1 and matches_fingerprint(fields[0], value)]
    if len(bodies) != 1:
        raise RuntimeError("owned_document_body_unverified")
    return bodies[0]


def owned_startup_blank(native, window, pid, initial_windows):
    if (window.get("pid") != pid or window.get("window_id") not in initial_windows
            or not native_window_proven(native, window, window.get("title", ""))
            or native.get("edited") is not False
            or native.get("document") != {"status": "no_value", "path": None}):
        return False
    fields = [row.get("value") for row in native.get("fields", [])
              if row.get("role", "").lower() in {"axtextarea", "textarea"}]
    return len(fields) == 1 and matches_fingerprint(fields[0], "")


def process_stamp(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart=", "-o", "comm="],
                            capture_output=True, text=True, timeout=3)
    return result.stdout.strip() if result.returncode == 0 else None


def owned_process_can_stop(lease, windows, stamp, saved_windows):
    return bool(stamp and stamp == lease["stamp"] and all(
        row.get("window_id") in lease["windows"]
        and row["window_id"] in saved_windows
        and lease["windows"][row["window_id"]] in str(row.get("title", row.get("window_title", "")))
        for row in windows))


@contextlib.contextmanager
def execution_bundle(subject, prepared_app=None):
    canonical = Path(subject["app"])
    if not subject.get("frozen_payload_verified"):
        if prepared_app is not None:
            raise RuntimeError("frozen_prepared_runtime_changed")
        yield canonical
        return
    manifest = Path(subject["manifest_path"])
    if (canonical.is_symlink() or manifest.is_symlink()
            or manifest.parent.resolve() != canonical.parent.resolve()
            or manifest.name != canonical.stem + "-manifest.json"
            or digest(manifest) != subject["manifest_sha256"]):
        raise RuntimeError("frozen_workspace_manifest_changed")
    spec = importlib.util.spec_from_file_location("execution_archive", HERE / "jev-archive-signed-pairs.py")
    archive = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(archive)
    expected = json.loads(manifest.read_text())
    if archive.manifest(canonical) != expected:
        raise RuntimeError("frozen_workspace_manifest_changed")
    if prepared_app is not None:
        app = Path(prepared_app)
        if (app.is_symlink() or app.parent.is_symlink()
                or app.name != canonical.name
                or not app.parent.name.startswith("jev-qualified-runtime-")
                or app.parent.stat().st_uid != os.getuid()
                or app.parent.stat().st_mode & 0o077
                or _execution_leases.get(app) != (
                    canonical.resolve(), subject["manifest_sha256"], app.stat().st_ino)
                or archive.manifest(app) != expected):
            raise RuntimeError("frozen_prepared_runtime_changed")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                       check=True, capture_output=True, timeout=30)
        try:
            yield app
        finally:
            if digest(manifest) != subject["manifest_sha256"] or archive.manifest(canonical) != expected:
                raise RuntimeError("frozen_workspace_manifest_changed")
            if app.is_symlink() or archive.manifest(app) != expected:
                raise RuntimeError("frozen_prepared_runtime_changed")
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                           check=True, capture_output=True, timeout=30)
        return
    with tempfile.TemporaryDirectory(prefix="jev-qualified-runtime-") as directory:
        app = Path(directory) / canonical.name
        archive.clone(canonical, app)
        subprocess.run(["xattr", "-cr", str(app)], check=True, timeout=30)
        if archive.manifest(app) != expected:
            raise RuntimeError("frozen_workspace_manifest_changed")
        _execution_leases[app] = (canonical.resolve(), subject["manifest_sha256"], app.stat().st_ino)
        try:
            yield app
        finally:
            _execution_leases.pop(app, None)


class Session:
    def __init__(self, directory, receipt, driver_only=False, variant=None, startup_diagnostics=False,
                 approved_source_delta=None, prepared_app=None):
        self.directory = directory
        self.receipt = receipt
        self.driver_only = driver_only
        self.variant = variant
        self.startup_diagnostics = startup_diagnostics
        self.approved_source_delta = approved_source_delta
        self.prepared_app = prepared_app
        self.clients = []
        self.daemon = None
        self.owned_browsers = set()
        self.owned_native_processes = set()
        self.owned_documents = []
        self.owned_document_content = {}
        self.owned_document_processes = {}
        self.adopted_document_roots = {}
        self.local_session = "realapps-local-" + uuid.uuid4().hex[:12]
        self.metadata = {
            "drive_requests": 0, "api_request_count": None,
            "gui_autospawn_proven": False, "fn_microphone_proven": False,
            "standing_grant_checked": False, "resources_clean": False,
            "daemon_window_change_timeout_ms": 100, "daemon_window_change_poll_ms": 25,
            "rows": [],
        }
        self.bundle_stack = contextlib.ExitStack()

    def __enter__(self):
        try:
            return self._enter()
        except BaseException:
            if ((self.daemon is not None and self.daemon.poll() is None)
                    or any(client.proc is not None for client in self.clients)):
                self.__exit__(None, None, None)
            else:
                self.bundle_stack.close()
            raise

    def _enter(self):
        if os.environ.get("JARVIS_P4_REAL_APPS") != "approved":
            raise RuntimeError("explicit real-app approval required")
        policy = Path.home() / "Library/Application Support/JevVoice/policy.json"
        if json.loads(policy.read_text()).get("standingGrant") is not True:
            raise RuntimeError("existing computer-use standing grant required")
        self.metadata["standing_grant_checked"] = True
        receipt = json.loads(self.receipt.read_text())
        if self.variant is not None:
            receipt = receipt["candidates"][self.variant]
            self.metadata["variant"] = self.variant
        self.metadata["template_resource_recovery"] = receipt.get("template_resource_recovery")
        app = self.bundle_stack.enter_context(execution_bundle(receipt, prepared_app=self.prepared_app))
        self.binary = app / "Contents/MacOS/JevVoice"
        self.metadata["canonical_app"] = receipt["app"]
        self.metadata["execution_app"] = str(app)
        self.metadata["prepared_execution_app"] = str(self.prepared_app) if self.prepared_app else None
        self.metadata["execution_manifest_verified"] = bool(receipt.get("frozen_payload_verified"))
        spec = importlib.util.spec_from_file_location("realapps_clone", HERE / "jev-clone-stage.py")
        clone = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(clone)
        self.metadata["source_matches_current_tree"] = verify_source_subject(
            receipt["source_sha256"], clone.sources(), driver_only=self.driver_only,
            approved_delta=self.approved_source_delta)
        if self.approved_source_delta:
            self.metadata["approved_source_delta"] = self.approved_source_delta
        self.metadata["subject"] = "pinned-driver-only" if self.driver_only else "signed-product"
        if digest(self.binary) != receipt["binary_sha256"]:
            raise RuntimeError("binary differs from signed candidate")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        self.driver = (app / "Contents/Resources/cua-driver"
                       if self.variant is not None
                       else Path("/Applications/CuaDriver.app/Contents/MacOS/cua-driver"))
        driver_sha = receipt["driver_sha256"] if self.variant is not None else DRIVER_SHA
        if digest(self.driver) != driver_sha:
            raise RuntimeError("pinned driver mismatch")
        self.metadata.update(binary_sha256=receipt["binary_sha256"], driver_sha256=driver_sha,
                             driver_inode=self.driver.stat().st_ino,
                             harness_sha256=digest(__file__), receipt_sha256=digest(self.receipt))
        self.runtime = Path(tempfile.mkdtemp(prefix="jev-r-"))
        self.sock = self.runtime / "driver.sock"
        self.environment = {key: value for key, value in os.environ.items() if key in {
            "PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "USER", "SHELL", "__CF_USER_TEXT_ENCODING"}}
        self.environment.update(DO_NOT_TRACK="1", CUA_TELEMETRY="0",
                                CUA_DRIVER_RS_TELEMETRY_ENABLED="0")
        daemon_environment = dict(self.environment, CUA_DRIVER_EMBEDDED="1",
                                  CUA_DRIVER_HOST_BUNDLE_ID=HOST,
                                  CUA_DRIVER_EMBEDDED_HOST_PID=str(os.getpid()),
                                  CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS="100",
                                  CUA_DRIVER_WINDOW_CHANGE_POLL_MS="25")
        with contextlib.ExitStack() as files:
            stderr = (files.enter_context((self.directory / "startup.stderr").open("wb"))
                      if self.startup_diagnostics else subprocess.DEVNULL)
            self.daemon = subprocess.Popen([
                str(self.driver), "serve", "--embedded", "--parent-liveness-stdio",
                "--no-permissions-gate", "--socket", str(self.sock), "--host-bundle-id", HOST,
                "--permission-mode", "standard", "--grant", "existing-profile",
            ], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=stderr,
                env=daemon_environment)
        try:
            def ready():
                if self.daemon.poll() is not None:
                    raise RuntimeError("owned standard daemon exited")
                with contextlib.closing(socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)) as connection:
                    try:
                        connection.connect(str(self.sock))
                        return True
                    except OSError:
                        return False
            wait_for(ready, 10, "owned standard daemon readiness")
            self.local = start_client([
                str(self.driver), "mcp", "--embedded", "--socket", str(self.sock),
                "--host-bundle-id", HOST,
            ], self.environment)
            self.clients.append(self.local)
            self.tools = {tool["name"]: tool for tool in self.local.call("tools/list", timeout=10)["tools"]}
            self.call("start_session", {})
            return self
        except BaseException:
            try:
                if self.startup_diagnostics and self.daemon.poll() is None:
                    subprocess.run(["sample", str(self.daemon.pid), "1", "-file",
                                    str(self.directory / "startup.stack.txt")],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
            except (OSError, subprocess.TimeoutExpired) as error:
                self.metadata["startup_sample_error"] = type(error).__name__
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *_):
        documents_left = []
        saved_windows = set()
        for window, marker in self.owned_documents:
            try:
                current = self.windows(pid=window["pid"])
                owned = next((row for row in current if row["window_id"] == window["window_id"]), None)
                if owned is None:
                    continue
                if marker not in str(owned.get("title", owned.get("window_title", ""))):
                    raise RuntimeError("owned_document_marker_changed")
                content = self.owned_document_content.get(window["window_id"], {})
                state = self.call("get_window_state", dict(window, include_screenshot=False,
                                  tree_format="elements", max_elements=500))
                path = Path(content["path"])
                native = self.native_window_state(window, state.get("window_title", ""))
                body = owned_document_body(state, window, marker, content.get("known_bodies", []), path, native)
                roots = [self.directory, getattr(self, "runtime", self.directory)]
                adopted = self.adopted_document_roots.get(window["window_id"])
                if adopted:
                    origin = Path(adopted["origin"])
                    if digest(origin) != adopted["sha256"] or path.parent.resolve() != origin.parent.resolve():
                        raise RuntimeError("owned_document_origin_changed")
                    roots.append(origin.parent)
                if path.is_symlink() or not any(path.resolve().is_relative_to(root.resolve()) for root in roots):
                    raise RuntimeError("owned_document_file_unverified")
                disk_body = path.read_text()
                if disk_body not in content["known_bodies"]:
                    raise RuntimeError("owned_document_disk_content_unverified")
                if disk_body != body:
                    self.invoke_window_menu(window, ["File", "Save"])
                    wait_for(lambda: path.read_text() == body, 4, "owned document saved bytes")
                state = self.call("get_window_state", dict(window, include_screenshot=False,
                                  tree_format="elements", max_elements=500))
                native = self.native_window_state(window, state.get("window_title", ""))
                if owned_document_body(state, window, marker, content["known_bodies"], path, native) != body:
                    raise RuntimeError("owned_document_body_changed")
                if path.read_text() != body:
                    raise RuntimeError("owned_document_disk_content_unverified")
                saved_windows.add(window["window_id"])
                self.invoke_window_menu(window, ["File", "Close"])
                wait_for(lambda: not any(row["window_id"] == window["window_id"]
                                         for row in self.windows(pid=window["pid"])),
                         4, "owned document window cleanup")
            except Exception as error:
                code = type(error).__name__
                if str(error).startswith("owned_document_"):
                    code = str(error)
                try:
                    code = json.loads(str(error)).get("driver_error_codes", {}).get("code", code)
                except (ValueError, AttributeError):
                    pass
                self.metadata.setdefault("document_cleanup_errors", []).append({
                    "window_id": window["window_id"], "code": code,
                })
                documents_left.append(window["window_id"])
        ordinary_left = []
        for pid, lease in self.owned_document_processes.items():
            try:
                stamp = process_stamp(pid)
                if stamp is not None:
                    if not owned_process_can_stop(lease, self.windows(pid=pid), stamp, saved_windows):
                        raise RuntimeError("owned_process_identity_or_content_unverified")
                    os.kill(pid, signal.SIGTERM)
                    wait_for(lambda: process_stamp(pid) is None, 4, "owned test app teardown")
                documents_left = [wid for wid in documents_left if wid not in lease["windows"]]
            except Exception as error:
                ordinary_left.append(pid)
                self.metadata.setdefault("owned_process_cleanup_errors", []).append(type(error).__name__)
        self.metadata["owned_document_processes_remaining"] = ordinary_left
        self.metadata["owned_document_windows_remaining"] = documents_left
        if self.clients and self.clients[0].proc is not None:
            try:
                self.call("end_session", {})
            except Exception:
                self.metadata["local_session_end_error"] = True
        for client in reversed(self.clients):
            client.close()
        for pid in self.owned_native_processes:
            subprocess.run(["kill", "-TERM", str(pid)], capture_output=True, timeout=3)
        if self.daemon is not None:
            self.daemon.stdin.close()
            try:
                self.daemon.wait(timeout=4)
            except subprocess.TimeoutExpired:
                self.daemon.terminate()
                self.daemon.wait(timeout=4)
        self.metadata["resources_clean"] = all(client.proc is None for client in self.clients) and (
            self.daemon is None or self.daemon.poll() is not None)
        remaining = subprocess.run(["pgrep", "-x", "Google Chrome"], capture_output=True,
                                   text=True, timeout=3).stdout.split()
        self.metadata["owned_browser_processes_remaining"] = sorted(
            self.owned_browsers.intersection(map(int, remaining)))
        self.metadata["resources_clean"] &= not self.metadata["owned_browser_processes_remaining"]
        native_left = []
        for pid in self.owned_native_processes:
            result = subprocess.run(["ps", "-p", str(pid), "-o", "comm="],
                                    capture_output=True, text=True, timeout=3)
            if result.returncode == 0:
                native_left.append(pid)
        self.metadata["owned_native_processes_remaining"] = native_left
        self.metadata["resources_clean"] &= not native_left
        self.metadata["resources_clean"] &= not documents_left
        self.metadata["resources_clean"] &= not ordinary_left
        self.metadata["resources_clean"] &= "unclaimed_document_pid" not in self.metadata
        self.metadata["resources_clean"] &= not (
            self.metadata.get("textedit_launch_requested") and not self.metadata.get("textedit_launch_pid"))
        if all(client.proc is None for client in self.clients) and (
                self.daemon is None or self.daemon.poll() is not None):
            self.bundle_stack.close()
            self.metadata["execution_lease_closed"] = True
        write_json(self.directory / "results.json", self.metadata)

    def own_document_process(self, pid, executable):
        stamp = process_stamp(pid)
        if not stamp or not stamp.endswith(executable):
            self.metadata["unclaimed_document_pid"] = pid
            raise RuntimeError("new document process identity unavailable")
        self.owned_document_processes[pid] = {"stamp": stamp, "windows": {}}
        self.metadata["owned_document_process_receipts"] = self.owned_document_processes

    def native_window_state(self, window, title):
        probe = HERE / "jev-native-field-probe.swift"
        self.metadata["native_oracle_source_sha256"] = digest(probe)
        self.metadata["native_oracle_calls"] = self.metadata.get("native_oracle_calls", 0) + 1
        result = subprocess.run([
            "swift", "-module-cache-path", str(ROOT / ".build/arm64-apple-macosx/release/ModuleCache"),
            str(probe), str(window["pid"]), str(window["window_id"]),
            "sha256:" + hashlib.sha256(title.encode()).hexdigest(),
        ], capture_output=True, text=True, timeout=75)
        write_json(self.directory / ("native-oracle-" + str(self.metadata["native_oracle_calls"]) + ".json"),
                   dict(qualification=False, input_actuations=0, window=dict(window),
                        title_sha256=hashlib.sha256(title.encode()).hexdigest(),
                        return_code=result.returncode, stdout=result.stdout, stderr=result.stderr))
        if result.returncode != 0:
            self.metadata.setdefault("native_oracle_errors", []).append(result.returncode)
            raise RuntimeError("owned_document_native_probe_unavailable")
        return json.loads(result.stdout)

    def complete_native_window_state(self, window, title, control=None):
        native = self.native_window_state(window, title)
        self.metadata.setdefault("native_complete_reads", []).append(native)
        if (not native_window_proven(native, window, title)
                or any(native.get(key) != 0 for key in (
                    "modal_sheets", "role_read_failures", "children_read_failures"))):
            raise RuntimeError("native_window_incomplete")
        if control is not None:
            frame = control.get("frame", {})
            if not all(isinstance(frame.get(key), (int, float)) for key in ("x", "y", "w", "h")):
                raise RuntimeError("native_control_frame_missing")
            matches = [row for row in native.get("controls", [])
                       if row.get("role") == control.get("role")
                       and any(matches_fingerprint(row.get(key), control.get("label"))
                               for key in ("title", "description"))
                       and all(row.get("frame", {}).get(key) == frame[other]
                               for key, other in (("x", "x"), ("y", "y"), ("width", "w"), ("height", "h")))]
            if len(matches) != 1:
                raise RuntimeError("native_control_identity_unproven")
        return native

    def read_owned_document(self, window, marker, path, known_bodies):
        state = self.call("get_window_state", dict(window, include_screenshot=False,
                          tree_format="elements", max_elements=500))
        native = self.native_window_state(window, state.get("window_title", ""))
        self.metadata.setdefault("owned_document_reads", []).append({
            "expected_window": window,
            "sdk": {key: state.get(key) for key in (
                "pid", "window_id", "truncated", "elements_complete")},
            "sdk_degraded": bool(state.get("degraded")),
            "sdk_title_has_marker": marker in str(state.get("window_title", "")),
            "native_window_proven": native_window_proven(native, window, state.get("window_title", "")),
            "native": native,
        })
        body = owned_document_body(state, window, marker, known_bodies, path, native)
        self.metadata["owned_document_reads"][-1]["sdk_partial_native_complete"] = state.get("truncated") is True
        return body

    def invoke_window_menu(self, window, path):
        self.call("bring_to_front", window)
        return self.call("invoke_menu", dict(window, path=path))

    def adopt_document_fixture(self, receipt, cleanup=False):
        receipt = Path(receipt)
        source = json.loads(receipt.read_text())
        windows = source.get("owned_document_windows_remaining", [])
        if (source.get("textedit_reuses_existing_app") is not False
                or source.get("textedit_launch_requested") is not True
                or source.get("drive_requests") != 0 or len(windows) != 1
                or not isinstance(source.get("textedit_launch_pid"), int)):
            raise RuntimeError("owned_fixture_source_unverified")
        paths = list(receipt.parent.glob("Jev-Test-Document-*.txt"))
        if len(paths) != 1 or paths[0].is_symlink() or receipt.is_symlink():
            raise RuntimeError("owned_fixture_path_unverified")
        path = paths[0]
        match = re.fullmatch(r"Jev-Test-Document-([0-9a-f]{10})\.txt", path.name)
        if (not match or path.resolve().parent != receipt.parent.resolve()
                or receipt.parent.stat().st_uid != os.getuid()):
            raise RuntimeError("owned_fixture_path_unverified")
        marker = match[1]
        baseline = "Jev native document baseline " + marker + ".\n"
        value = "Jev real app text entry " + marker + "."
        known = [baseline, value]
        if path.read_text() not in known:
            raise RuntimeError("owned_fixture_disk_content_unverified")
        window = {"pid": source["textedit_launch_pid"], "window_id": windows[0]}
        current = self.windows(pid=window["pid"])
        if not any(row["window_id"] == window["window_id"] and marker in row.get("title", "")
                   for row in current):
            raise RuntimeError("owned_fixture_window_unverified")
        stamp = process_stamp(window["pid"])
        if not stamp:
            raise RuntimeError("owned_fixture_process_unverified")
        self.read_owned_document(window, marker, path, known)
        self.metadata["fixture_lease"] = {
            "origin": str(receipt.resolve()), "origin_sha256": digest(receipt),
            "window": window, "process_stamp": stamp, "process_teardown": False,
            "other_windows_retained": [row["window_id"] for row in current
                                       if row["window_id"] != window["window_id"]],
        }
        if cleanup:
            self.owned_documents.append((window, marker))
            self.owned_document_content[window["window_id"]] = {"path": str(path), "known_bodies": known}
            self.adopted_document_roots[window["window_id"]] = {
                "origin": str(receipt), "sha256": digest(receipt),
            }
        return {"window": window, "marker": marker, "path": path, "baseline": baseline, "value": value}

    def close_startup_blank(self, row, initial_windows):
        window = {"pid": row["pid"], "window_id": row["window_id"]}
        lease = self.owned_document_processes.get(window["pid"])
        if not lease or process_stamp(window["pid"]) != lease["stamp"]:
            raise RuntimeError("owned_startup_window_identity_unverified")
        native = self.native_window_state(window, row.get("title", ""))
        if not owned_startup_blank(native, row, window["pid"], initial_windows):
            raise RuntimeError("owned_startup_window_content_unverified")
        self.metadata.setdefault("owned_startup_blank_proofs", []).append(native)
        write_json(self.directory / "results.json", self.metadata)
        self.invoke_window_menu(window, ["File", "Close"])
        wait_for(lambda: not any(item["window_id"] == window["window_id"]
                                for item in self.windows(pid=window["pid"])),
                 4, "proven empty startup window closure")

    def raw_call(self, name, arguments, timeout=20):
        arguments = dict(arguments, session=self.local_session)
        counts = self.metadata.setdefault("local_tool_calls", {})
        counts[name] = counts.get(name, 0) + 1
        return self.local.call("tools/call", {"name": name, "arguments": arguments}, timeout=timeout)

    def call(self, name, arguments):
        result = self.raw_call(name, arguments)
        if name == "bring_to_front":
            self.metadata.setdefault("foreground_attempts", []).append({
                key: value for item in objects(result) for key, value in item.items()
                if isinstance(value, (bool, int)) and any(
                    word in key for word in ("pid", "window", "activated", "accepted", "visible", "focused"))
            })
        if result.get("isError") and name == "browser_prepare" and arguments.get("profile", {}).get("mode") == "isolated_new":
            messages = [item["message"] for item in objects(result)
                        if "code" in item and isinstance(item.get("message"), str)]
            self.metadata["own_chrome_prepare_error"] = messages or [tool_text(result)[0][:2000]]
            raise RuntimeError(str(self.metadata["own_chrome_prepare_error"]))
        return payload(result)

    def windows(self, **arguments):
        state = self.call("list_windows", arguments)
        return [item for item in objects(state) if isinstance(item.get("window_id"), int)
                and isinstance(item.get("pid"), int)]

    def chrome(self):
        before = set(subprocess.run(["pgrep", "-x", "Google Chrome"], capture_output=True,
                                    text=True, timeout=3).stdout.split())
        prepared = self.call("browser_prepare", {"allow_launch": True, "profile": {"mode": "isolated_new"}})
        self.metadata["browser_prepare_keys"] = sorted(prepared)
        self.metadata["browser_prepare_status"] = prepared.get("status")
        pids = {item[key] for item in objects(prepared) for key in ("pid", "prepared_pid")
                if isinstance(item.get(key), int) and str(item[key]) not in before and item[key] > 0}
        self.owned_browsers.update(pids)
        if len(pids) != 1:
            raise RuntimeError("isolated browser preparation did not prove one new process")
        pid = next(iter(pids))
        window = wait_for(lambda: next(iter(self.windows(pid=pid)), None), 10, "owned Chrome window")
        native = {"pid": pid, "window_id": window["window_id"]}
        state = self.call("get_browser_state", native)
        tabs = state.get("tabs", [])
        tab = state.get("active_tab_id") or next(
            (item.get("tab_id", item.get("id")) for item in tabs if item.get("active")), None)
        if tab is None and len(tabs) == 1:
            tab = tabs[0].get("tab_id", tabs[0].get("id"))
        if not state.get("target_id") or not tab:
            raise RuntimeError("owned browser did not provide an exact tab binding")
        self.call("browser_navigate", {"target_id": state["target_id"], "tab_id": tab,
                                       "url": "https://example.com/"})
        def pages():
            current = self.call("get_browser_state", native)
            candidates = current.get("tabs", [])
            active = next((item for item in candidates
                           if item.get("tab_id", item.get("id")) == current.get("active_tab_id")
                           or item.get("active")), candidates[0] if len(candidates) == 1 else {})
            self.metadata["owned_browser_bind_keys"] = sorted(current)
            self.metadata["owned_active_tab_keys"] = sorted(active)
            state = [{"url": active.get("url", current.get("url", current.get("active_url", ""))),
                      "title": active.get("title", "")}]
            self.metadata["last_owned_page"] = state
            return state
        wait_for(lambda: any(page["url"].startswith("https://example.com/")
                            and "Example Domain" in page["title"] for page in pages()),
                 25, "owned public page readiness")
        self.call("bring_to_front", native)
        roster = self.call("list_apps", {}).get("apps", [])
        chrome = [item for item in roster if item.get("bundle_id", "").lower() == "com.google.chrome"]
        self.metadata["chrome_roster_pids"] = [item.get("pid") for item in chrome]
        self.metadata["prepared_chrome_pid"] = pid
        self.metadata["deictic_binding_matches_owned_pid"] = bool(chrome and chrome[0].get("pid") == pid)
        guest = start_client([
            str(self.driver), "mcp", "--embedded", "--socket", str(self.sock),
            "--host-bundle-id", HOST,
        ], self.environment)
        self.clients.append(guest)
        label = "realapps-probe-" + uuid.uuid4().hex[:12]
        try:
            def probe(name, args):
                return guest.call("tools/call", {"name": name, "arguments": dict(args, session=label)}, timeout=10)
            probe("start_session", {})
            bound = probe("get_browser_state", native)
            body = bound.get("structuredContent", {})
            self.metadata["guest_bind"] = {
                "is_error": bound.get("isError", False), "keys": sorted(body),
                "status": body.get("status"), "quality": body.get("binding_quality"),
                "refusal_code": body.get("refusal", {}).get("code") if isinstance(body.get("refusal"), dict) else body.get("refusal"),
                "next_call_name": body.get("next_call", {}).get("name") if isinstance(body.get("next_call"), dict) else None,
            }
            if body.get("target_id"):
                active = next((item for item in body.get("tabs", []) if item.get("active")), {})
                if active.get("tab_id"):
                    snap = probe("get_browser_state", {"target_id": body["target_id"], "tab_id": active["tab_id"]})
                    data = snap.get("structuredContent", {})
                    self.metadata["guest_snapshot"] = {
                        "is_error": snap.get("isError", False), "keys": sorted(data),
                        "url": data.get("url"), "title": data.get("title"),
                        "ref_count": len(data.get("refs", [])), "status": data.get("status"),
                    }
        finally:
            try:
                probe("end_session", {})
            finally:
                guest.close()
        self.chrome_native = native
        return window, pages

    def chrome_screenshot(self, name):
        state = self.call("get_browser_state", self.chrome_native)
        active = next((item for item in state.get("tabs", []) if item.get("active")), {})
        if active.get("url") not in {"https://www.wikipedia.org/", "https://example.com/"}:
            return
        result = self.local.call("tools/call", {"name": "get_browser_state", "arguments": {
            "target_id": state["target_id"], "tab_id": active["tab_id"],
            "session": self.local_session, "include_screenshot": True,
        }}, timeout=10)
        for content in result.get("content", []):
            if content.get("type") == "image" and content.get("mimeType") == "image/png":
                image = base64.b64decode(content["data"], validate=True)
                if not image.startswith(b"\x89PNG\r\n\x1a\n"):
                    raise RuntimeError("screenshot is not a PNG")
                (self.directory / name).write_bytes(image)
                self.metadata["screenshot"] = name
                return

    def start_actor(self):
        if self.driver_only:
            raise RuntimeError("driver-only probe cannot start the Jev product actor")
        key = require_api_key()
        if not key:
            raise RuntimeError("existing TypeSafe key unavailable")
        environment = dict(self.environment, TYPESAFE_API_KEY=key, JEV_CUA_SOCKET=str(self.sock))
        client = start_client([str(self.binary), "--mcp-stdio", "--agent", "realapps-" + uuid.uuid4().hex],
                              environment)
        self.clients.append(client)
        return client

    def drive(self, case, oracle, actor=None):
        if self.driver_only:
            raise RuntimeError("driver-only probe cannot start the Jev product actor")
        if actor is not None and (actor not in self.clients or actor.proc is None or actor.proc.poll() is not None):
            raise RuntimeError("retained product actor is not live and owned")
        spec = importlib.util.spec_from_file_location("realapps_native", HERE / "jev-native-proof.py")
        native = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(native)
        client = self.start_actor() if actor is None else actor
        arguments = {"goal": case["goal"], "values": case.get("values", {}),
                     "deny": qualification_denials(case)}
        if case.get("success_contains"):
            arguments["success_contains"] = case["success_contains"]
        if case.get("app"):
            arguments["app"] = case["app"]
        if case.get("window_id") is not None:
            arguments["window_id"] = case["window_id"]
        deadline = case.get("caller_deadline_seconds", 30)
        row = {
            "case": case["id"], "goal": case["goal"], "caller_deadline_seconds": deadline,
            "completion_hints_sent": False, "status": "error", "verified": False,
            "strict_success": False, "false_done": False, "cancelled_by_harness": False,
            "actor_pid": client.proc.pid,
            "kind": case.get("kind", "qualification"),
            "requested_window_id": case.get("window_id"),
        }
        self.metadata["rows"].append(row)
        self.metadata["drive_requests"] += 1
        start = time.perf_counter()
        try:
            result, cancelled = native.drive(client, arguments, deadline)
            text, is_error = tool_text(result)
            row.update(result_text=text, is_error=is_error, cancelled_by_harness=cancelled,
                       status="cancelled" if cancelled else classify(text, is_error))
        except Exception as error:
            row.update(error_type=type(error).__name__, is_error=True)
        finally:
            row["wall_ms"] = (time.perf_counter() - start) * 1000
            if actor is None:
                client.close()
        row["actual_state"], row["verified"] = oracle()
        done = row["status"] in ("done", "already")
        row["false_done"] = done and not row["verified"]
        row["strict_success"] = done and row["verified"] and not row["is_error"] and not row["cancelled_by_harness"]
        if self.variant is not None:
            trace_start = time.perf_counter()
            try:
                trace = subprocess.run([
                    "/usr/bin/log", "show", "--last", "5m", "--style", "ndjson",
                    "--predicate", f'processIdentifier == {row["actor_pid"]} AND '
                    'subsystem == "com.chriswozniczek.jevvoice" AND category == "jev-visual-decision"',
                ], capture_output=True, text=True, timeout=12)
                if trace.returncode:
                    row["visual_trace_error"] = "log_show_exit_" + str(trace.returncode)
                else:
                    events = [json.loads(line) for line in trace.stdout.splitlines() if line.strip()]
                    row["visual_trace"] = [
                        {"timestamp": event.get("timestamp"), "message": event["eventMessage"]}
                        for event in events if event.get("eventMessage", "").startswith("Visual ")
                    ]
            except (OSError, ValueError, subprocess.TimeoutExpired) as error:
                row["visual_trace_error"] = type(error).__name__
            row["visual_trace_collection_ms"] = (time.perf_counter() - trace_start) * 1000
            row["visual_trace_required"] = case.get("requires_visual_trace", False)
            row["visual_trace_complete"] = bool(row.get("visual_trace"))
            if row["visual_trace_required"] and not row["visual_trace_complete"]:
                row.setdefault("visual_trace_error", "required_visual_trace_missing")
        write_json(self.directory / "results.json", self.metadata)
        print(case["id"], row["status"], "verified=" + str(row["verified"]),
              "wall_ms=" + str(row["wall_ms"]), flush=True)
        return row


def objects(value):
    if isinstance(value, dict):
        yield value
        for item in value.values():
            yield from objects(item)
    elif isinstance(value, list):
        for item in value:
            yield from objects(item)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["preflight", "chrome-prepare", "chrome", "textedit", "notes", "spotify-prepare", "spotify-accessibility", "inspect-owned"])
    parser.add_argument("--receipt", type=Path, default=RECEIPT)
    parser.add_argument("--inspect-record", type=Path)
    args = parser.parse_args()
    directory = HERE / ("realapps-" + uuid.uuid4().hex)
    directory.mkdir(mode=0o700)
    with Session(directory, args.receipt) as session:
        if args.action == "preflight":
            wanted = {"list_apps", "list_windows", "get_window_state", "press_key", "type_text",
                      "click", "launch_app", "get_browser_state", "browser_prepare",
                      "bring_to_front", "invoke_menu", "check_permissions", "set_value"}
            session.metadata["selected_schemas"] = [tool for name, tool in session.tools.items() if name in wanted]
            session.metadata["tool_names"] = sorted(session.tools)
            guide = session.local.call("tools/call", {"name": "get_guide", "arguments": {"topic": "browser"}}, timeout=10)
            session.metadata["browser_guide"] = tool_text(guide)[0]
            print(json.dumps(session.metadata["selected_schemas"], indent=2))
        elif args.action == "inspect-owned":
            record = json.loads(args.inspect_record.read_text())
            row = next(row for row in record["rows"] if row["case"] == "textedit.replace.body")
            marker = row["goal"].split()[-1].rstrip(".")
            assert len(marker) == 10 and all(character in "0123456789abcdef" for character in marker)
            pids = record["textedit_roster_pids"]
            assert len(pids) == 1
            window = {"pid": pids[0], "window_id": row["requested_window_id"]}
            owned = next(item for item in session.windows(pid=pids[0]) if item["window_id"] == window["window_id"])
            assert marker in owned.get("title", "")
            state = session.call("get_window_state", dict(window, include_screenshot=False,
                                                           tree_format="elements", max_elements=500))
            def hashed(value):
                return {"count": len(value), "sha256": hashlib.sha256(value.encode()).hexdigest()} if isinstance(value, str) else None
            session.metadata["sdk_fields"] = [
                {"role": item["role"], "label": hashed(item.get("label")), "value": hashed(item.get("value")),
                 "frame": item.get("frame"), "bounds": item.get("bounds")}
                for item in state.get("elements", [])
                if item.get("role", "").lower() in {"axtextarea", "textarea", "axtextfield", "textfield", "axcombobox", "combobox"}
            ]
            probe = subprocess.run([
                "swift", "-module-cache-path", str(ROOT / ".build/arm64-apple-macosx/release/ModuleCache"),
                str(HERE / "jev-native-field-probe.swift"), str(window["pid"]), str(window["window_id"]), marker,
            ], capture_output=True, text=True, timeout=75)
            session.metadata["native_probe_exit"] = probe.returncode
            session.metadata["native_probe"] = json.loads(probe.stdout) if probe.returncode == 0 else {"compile_errors": probe.stderr[-2000:]}
            print(json.dumps({key: session.metadata[key] for key in ["sdk_fields", "native_probe_exit", "native_probe"]}, indent=2))
        elif args.action in {"textedit", "notes", "spotify-prepare", "spotify-accessibility"}:
            spec = importlib.util.spec_from_file_location("realapps_native_apps", HERE / "jev-realapps-native.py")
            native = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(native)
            session.metadata["native_harness_sha256"] = digest(HERE / "jev-realapps-native.py")
            getattr(native, args.action.replace("-", "_"))(session, wait_for)
        else:
            window, pages = session.chrome()
            if args.action == "chrome-prepare":
                print("Owned browser prepared; deictic PID matches:",
                      session.metadata["deictic_binding_matches_owned_pid"], flush=True)
                return
            if not session.metadata["deictic_binding_matches_owned_pid"]:
                raise RuntimeError("candidate binds first bundle PID rather than the verified foreground PID; no model capture allowed")
            case = {
                "id": "chrome.navigate.wikipedia",
                "goal": "Focus the address field in this window, replace its contents with https://www.wikipedia.org, then load that page",
                "values": {"text": "https://www.wikipedia.org"},
            }
            def oracle():
                state = [{"url": page["url"], "title": page["title"]} for page in pages()]
                return state, any(page["url"].startswith("https://www.wikipedia.org/")
                                  and "Wikipedia" in page["title"] for page in state)
            assert oracle()[1] is False
            session.metadata["oracle_negative_control"] = True
            session.drive(case, oracle)
            session.chrome_screenshot("chrome-wikipedia.png")
    print(directory / "results.json")
    return 0 if session.metadata["resources_clean"] and all(
        row["strict_success"] for row in session.metadata["rows"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
