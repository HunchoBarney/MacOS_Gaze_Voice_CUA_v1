"""Driver adapters + driver-neutral op corpus for the P2b spike.

Two drivers behind one op vocabulary:

- devtools: `chrome-devtools-mcp` on stdio. Arm A attaches to the running
  user Chrome via --autoConnect (the chrome://inspect toggle endpoint)
  and owns one tab it creates with new_page and closes with close_page.
  Arm B uses --isolated (temp profile, auto-cleaned).
- cua: `cua-driver mcp --embedded --socket <hint> --host-bundle-id ...`
  proxy spawned per session. Arm A binds the running Chrome via
  browser_prepare strategy.kind=existing_profile and is READ-ONLY —
  its mutating verbs emit `unsupported` rows. Arm B launches a
  driver-owned isolated Chrome via profile.mode=isolated_new and runs
  the full corpus.

Statuses: ok | driver_error | timeout | refused | unsupported |
blocked_env. A timeout is a row, not an abort.
"""

import json
import os
import re
import subprocess
import time

from mcp import MCPError, MCPStdio, MCPTimeout, tool_text

SPIKE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(SPIKE, "results")
RESULTS_JSON = os.path.join(RESULTS, "results.json")

CUA_BIN = os.path.expanduser(
    "~/jarvis-local/Jev Voice.app/Contents/Resources/cua-driver")
CUA_SOCKET_HINT = os.path.expanduser(
    "~/Library/Application Support/JevVoice/cua.socket")
HOST_BUNDLE_ID = "com.chriswozniczek.jevvoice"
DEVTOOLS_BIN = os.path.join(
    SPIKE, "node_modules", ".bin", "chrome-devtools-mcp")
DEVTOOLS_PORT_FILE = os.path.expanduser(
    "~/Library/Application Support/Google/Chrome/DevToolsActivePort")
CHROME_APP = "/Applications/Google Chrome.app"

OK = "ok"
DRIVER_ERROR = "driver_error"
TIMEOUT = "timeout"
REFUSED = "refused"
UNSUPPORTED = "unsupported"
BLOCKED = "blocked_env"

# Op order inside one site pass: navigate+settle first so snapshot sees a
# loaded page; type uses snapshot-minted refs while they're still live;
# click is allowed to navigate (invalidating refs) only after type ran;
# extract reads whatever page click left.
OPS = ["navigate", "settle", "snapshot", "type", "click", "extract"]
OP_TIMEOUTS = {"navigate": 30, "snapshot": 15}
DEFAULT_TIMEOUT = 10
# Mutating verbs Cua cannot run on a bound user tab in Arm A.
CUA_ARM_A_UNSUPPORTED = {"navigate", "settle", "click", "type"}
# Arm-A Cua never iterates the site corpus — every row describes the
# bound user tab (snapshot/extract are its only dispatched ops).
BOUND_SITES = [{"id": "bound-user-tab", "url": ""}]

DRIVERS = ["devtools", "cua"]
ARMS = ["A", "B"]

_counter = [0]


def mint_label():
    """Unique session label per spawned proxy (P1 tombstone wedge)."""
    _counter[0] += 1
    return "p2b-%d-%d" % (os.getpid(), _counter[0])


# ── results.json I/O ────────────────────────────────────────────────────

def load_results():
    if os.path.isfile(RESULTS_JSON):
        with open(RESULTS_JSON) as fh:
            return json.load(fh)
    return {"meta": {}, "probe": {}, "cycles": [], "rows": [],
            "robustness": []}


def save_results(data):
    tmp = RESULTS_JSON + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh, indent=1, sort_keys=True)
    os.rename(tmp, RESULTS_JSON)


def append(kind, entries):
    data = load_results()
    data.setdefault(kind, []).extend(entries if isinstance(entries, list)
                                     else [entries])
    save_results(data)


def load_sites():
    with open(os.path.join(SPIKE, "sites.json")) as fh:
        return json.load(fh)


def cua_proxy_pids():
    """'cua-driver mcp' proxies as {pid: ppid}. Compared by pid, not
    cmdline — the daemon re-mints rewrite the socket path, and the app
    spawns fresh proxies on the new socket (they are not spike leaks;
    a leaked spike proxy is orphaned to ppid 1 or owned by us)."""
    try:
        out = subprocess.run(
            ["ps", "-eo", "pid,ppid,command"], capture_output=True,
            text=True, timeout=10)
        return {int(m.group(1)): int(m.group(2))
                for m in (re.match(r"\s*(\d+)\s+(\d+)\s+(.*)", l)
                          for l in out.stdout.splitlines())
                if m and "cua-driver mcp" in m.group(3)
                and "serve --embedded" not in m.group(3)}
    except (OSError, subprocess.TimeoutExpired):
        return {}


def chrome_pid():
    """Pid of the running user Chrome browser process (never helpers)."""
    try:
        out = subprocess.run(["pgrep", "-x", "Google Chrome"],
                             capture_output=True, text=True, timeout=10)
        for line in out.stdout.splitlines():
            line = line.strip()
            if line.isdigit():
                return int(line)
    except (OSError, subprocess.TimeoutExpired):
        pass
    return None


def read_socket_hint():
    """The daemon re-mints rewrite this file — read it fresh."""
    with open(CUA_SOCKET_HINT) as fh:
        return fh.read().strip()


def _cap(text, n=280):
    return re.sub(r"\s+", " ", str(text))[:n]


# ── session ─────────────────────────────────────────────────────────────

class BlockedEnv(Exception):
    pass


class Session(object):
    """One attached driver session for one arm."""

    def __init__(self, driver, arm, label):
        self.driver = driver
        self.arm = arm
        self.label = label
        self.client = None
        self.tools = {}
        # cua binding
        self.target_id = None
        self.tab_id = None
        self.bound_url = None
        self.bound_window = None
        # devtools binding
        self.page_id = None
        self.pages_before = None
        self.pages_after = None
        self.dialog_note = None
        # last snapshot's parsed refs for click/type
        self.refs = []

    def alive(self):
        return (self.client is not None and self.client.proc is not None
                and self.client.proc.poll() is None)


def _structured(result):
    if isinstance(result, dict) and isinstance(result.get("structuredContent"),
                                              dict):
        return result["structuredContent"]
    return result if isinstance(result, dict) else {}


def _is_refusal(result):
    body = _structured(result)
    text, is_error = tool_text(result)
    code = (body.get("code") or body.get("error") or ""
            or (body.get("refusal") or {}).get("code", ""))
    status = str(body.get("status") or body.get("effect") or "")
    if status == "refused" or "refus" in str(code).lower():
        return True, _cap((body.get("refusal") or {}).get("message")
                          or text or code)
    if is_error:
        if "refus" in text.lower() or "requires_setup" in text.lower():
            return True, _cap(text)
        return False, _cap(text)
    return False, ""


# ── cua driver ──────────────────────────────────────────────────────────

def _cua_tool(sess, name, arguments, timeout):
    args = dict(arguments)
    args["session"] = sess.label
    return sess.client.tool_call(name, args, timeout=timeout)


def _pick_window(windows):
    visible = [w for w in windows if w.get("is_on_screen")]
    return (visible or windows or [None])[0]


def _parse_bind(result):
    """target_id + active tab_id + url out of a bind-mode state."""
    body = _structured(result)
    if "structuredContent" not in result and not body.get("target_id"):
        body = result if isinstance(result, dict) else {}
    target_id = body.get("target_id")
    tabs = body.get("tabs") or []
    tab_id = body.get("active_tab_id")
    if not tab_id:
        for t in tabs:
            if t.get("active"):
                tab_id = t.get("tab_id") or t.get("id")
                break
    if not tab_id and tabs:
        tab_id = tabs[0].get("tab_id") or tabs[0].get("id")
    url = (body.get("url") or body.get("active_url")
           or (body.get("page") or {}).get("url"))
    if not url:
        for t in tabs:
            if t.get("active") and t.get("url"):
                url = t["url"]
                break
        if not url and tabs:
            url = tabs[0].get("url")
    return target_id, tab_id, url


def _needs_setup(result):
    body = _structured(result)
    text, is_error = tool_text(result)
    hay = json.dumps(body) + text
    return ("browser_requires_setup" in hay
            or "browser_consent_required" in hay or is_error)


def _candidate_windows(windows):
    """On-screen real browser windows first; consent-dialog windows last.
    The 'Allow remote debugging?' dialogs own Chrome pids too — binding
    them can never mint a tab."""
    def rank(w):
        title = str(w.get("title") or "")
        return (1 if "remote debugging" in title.lower() else 0,
                0 if w.get("is_on_screen") else 1)
    return sorted(windows, key=rank)


def cua_attach(sess):
    """Full Arm A/Arm B Cua attach. Raises BlockedEnv/MCPError."""
    if not (os.path.isfile(CUA_BIN) and os.access(CUA_BIN, os.X_OK)):
        raise BlockedEnv("bundled cua-driver not executable")
    try:
        socket = read_socket_hint()
    except OSError as exc:
        raise BlockedEnv("cua.socket hint unreadable: %s" % exc)
    sess.client = MCPStdio(
        [CUA_BIN, "mcp", "--embedded", "--socket", socket,
         "--host-bundle-id", HOST_BUNDLE_ID],
        env=dict(os.environ), stderr=subprocess.DEVNULL)
    sess.client.start()
    sess.client.initialize()
    sess.tools = sess.client.tools_list()
    sess.client.tool_call("start_session", {"session": sess.label},
                          timeout=15)
    if sess.arm == "A":
        pid = chrome_pid()
        if pid is None:
            raise BlockedEnv("no running Google Chrome process")
        windows = _cua_tool(sess, "list_windows", {"pid": pid},
                            timeout=15)
        body = _structured(windows)
        win_list = body.get("windows") or []
        dialog_present = any(
            "remote debugging" in str(w.get("title", "")).lower()
            for w in win_list)
        if dialog_present:
            sess.dialog_note = ("Chrome 'Allow remote debugging?' consent "
                                "dialog present in window list")
        candidates = _candidate_windows(win_list)
        if not candidates:
            raise BlockedEnv("no Chrome window from list_windows")
        notes = []
        for win in candidates[:4]:
            if win.get("window_id") is None:
                continue
            bind_args = {"pid": pid, "window_id": win["window_id"]}
            state = _cua_tool(sess, "get_browser_state", bind_args,
                              timeout=30)
            target_id, tab_id, url = _parse_bind(state)
            if target_id and tab_id:
                sess.target_id, sess.tab_id, sess.bound_url = (
                    target_id, tab_id, url)
                sess.bound_window = win["window_id"]
                break
            if _needs_setup(state) and dialog_present:
                # browser_prepare's consent-reconnect loop would stack
                # another dialog on the user's Chrome and still fail —
                # record the gate, don't poke it.
                notes.append("bind w%s: consent-gated, dialog pending, "
                             "prepare skipped" % win["window_id"])
                continue
            if _needs_setup(state):
                prep = _cua_tool(sess, "browser_prepare", {
                    "pid": pid, "window_id": win["window_id"],
                    "strategy": {"kind": "existing_profile"}}, timeout=60)
                refused, detail = _is_refusal(prep)
                notes.append("prepare w%s: %s" % (win["window_id"], detail))
                if refused:
                    continue
                state = _cua_tool(sess, "get_browser_state", bind_args,
                                  timeout=30)
                target_id, tab_id, url = _parse_bind(state)
                if target_id and tab_id:
                    sess.target_id, sess.tab_id, sess.bound_url = (
                        target_id, tab_id, url)
                    sess.bound_window = win["window_id"]
                    break
                notes.append("rebind w%s: %s" % (win["window_id"],
                             _cap(json.dumps(_structured(state)), 120)))
            else:
                notes.append("bind w%s: %s" % (win["window_id"],
                             _cap(json.dumps(_structured(state)), 120)))
        if not sess.target_id:
            detail = "all %d candidate window(s) refused — %s%s" % (
                len(candidates), "; ".join(notes),
                ("; " + sess.dialog_note) if sess.dialog_note else "")
            raise BlockedEnv(detail)
    else:
        prep = _cua_tool(sess, "browser_prepare", {
            "profile": {"mode": "isolated_new"}, "allow_launch": True},
            timeout=60)
        refused, detail = _is_refusal(prep)
        if refused:
            raise BlockedEnv("isolated_new prepare refused: %s" % detail)
        pid = _structured(prep).get("prepared_pid")
        if not pid:
            raise MCPError("isolated_new prepare gave no prepared_pid")
        windows = _cua_tool(sess, "list_windows", {"pid": pid},
                            timeout=30)
        win = _pick_window(_structured(windows).get("windows"))
        if not win or win.get("window_id") is None:
            raise MCPError("isolated Chrome has no bindable window")
        state = _cua_tool(sess, "get_browser_state",
                          {"pid": pid, "window_id": win["window_id"]},
                          timeout=30)
        sess.target_id, sess.tab_id, sess.bound_url = _parse_bind(state)
        if not sess.target_id or not sess.tab_id:
            raise MCPError("isolated bind produced no target_id/tab_id")
    return sess


def cua_teardown(sess):
    try:
        if sess.alive():
            sess.client.tool_call("end_session",
                                  {"session": sess.label}, timeout=10)
    except MCPError:
        pass
    if sess.client is not None:
        sess.client.close()


def _cua_refs(sess):
    body = sess.refs  # raw structuredContent of last snapshot
    out = []
    for node in body.get("refs") or body.get("elements") or []:
        if not isinstance(node, dict) or not node.get("ref"):
            continue
        label = node.get("name") or node.get("label") or ""
        role = node.get("role") or node.get("node") or ""
        actions = [a for a in (node.get("actions") or [])
                   if isinstance(a, str)]
        states = node.get("states") or {}
        editable = ("type" in actions or bool(node.get("editable"))
                    or str(states.get("editable", "")).lower() not in
                    ("", "false"))
        if role.lower() in ("input", "textarea"):
            editable = True
        out.append({"ref": node["ref"], "role": str(role).lower(),
                    "name": str(label), "editable": editable})
    return out


def _match_ref(refs, want):
    """First ref matching declared role (+ name substring, ci)."""
    roles = want.get("role")
    if isinstance(roles, str):
        roles = [roles]
    name = (want.get("name") or "").lower()
    for ref in refs:
        if roles and ref["role"] not in [r.lower() for r in roles]:
            continue
        if name and name not in ref["name"].lower():
            continue
        return ref
    return None


# ── devtools-mcp driver ─────────────────────────────────────────────────

def _devtools_env():
    env = dict(os.environ)
    env["CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS"] = "1"
    env.setdefault("CI", "1")
    return env


def devtools_spawn(arm):
    if not os.path.isfile(DEVTOOLS_BIN):
        raise BlockedEnv("node_modules/.bin/chrome-devtools-mcp missing — "
                         "run npm install in the spike dir")
    argv = [DEVTOOLS_BIN, "--autoConnect" if arm == "A" else "--isolated"]
    log = open(os.path.join(RESULTS, "devtools-stderr.log"), "ab")
    client = MCPStdio(argv, env=_devtools_env(), stderr=log)
    client._stderr_file = log
    client.start()
    # Arm A's autoConnect ws handshake pends behind Chrome's consent
    # dialog — bound the handshake so a blocked env costs seconds, not
    # minutes. Arm B launches its own Chrome; allow real startup time.
    client.initialize(timeout=45 if arm == "A" else 90)
    return client


def _page_scoped(sess, name):
    """Does this tool take a pageId (pageIdRouting default-on)?"""
    return "pageId" in (sess.tools.get(name, {}).get("properties") or {})


def _devtools_tool(sess, name, arguments, timeout):
    args = dict(arguments)
    if _page_scoped(sess, name) and sess.page_id is not None:
        args["pageId"] = sess.page_id
    return sess.client.tool_call(name, args, timeout=timeout)


def _devtools_pages(sess):
    result = _devtools_tool(sess, "list_pages", {}, timeout=15)
    body = _structured(result)
    pages = body.get("pages")
    text, _ = tool_text(result)
    if pages is None:
        # Text shape: one "id: url (title)" per line — ids may be
        # numeric or slugs; grab the leading token before ': '.
        pages = []
        for line in text.splitlines():
            m = re.match(r"\s*([0-9A-Za-z_-]+):\s+(\S+)", line)
            if m:
                pages.append({"id": m.group(1), "url": m.group(2)})
    return pages or []


def devtools_attach(sess):
    def _pid(value):
        if value is None:
            return None
        text = str(value)
        return int(text) if text.isdigit() else text
    sess.client = devtools_spawn(sess.arm)
    sess.tools = sess.client.tools_list()
    pages = _devtools_pages(sess)
    sess.pages_before = len(pages)
    before_ids = {str(p.get("id")) for p in pages}
    if sess.arm == "A":
        _devtools_tool(sess, "new_page", {"url": "about:blank"},
                       timeout=15)
        after = _devtools_pages(sess)
        new_ids = [p.get("id") for p in after
                   if str(p.get("id")) not in before_ids]
        sess.page_id = _pid(new_ids[0] if new_ids else
                            (after[-1].get("id") if after else None))
    else:
        if not pages:
            _devtools_tool(sess, "new_page", {"url": "about:blank"},
                           timeout=15)
            pages = _devtools_pages(sess)
        sess.page_id = _pid(pages[0].get("id")) if pages else None
        sess.bound_url = pages[0].get("url") if pages else None
    if sess.page_id is None:
        raise MCPError("devtools attach produced no usable page")
    return sess


def devtools_teardown(sess):
    try:
        if sess.alive() and sess.arm == "A" and sess.page_id is not None:
            try:
                _devtools_tool(sess, "close_page",
                               {"pageId": sess.page_id}, timeout=10)
            except MCPError:
                pass
            sess.pages_after = len(_devtools_pages(sess))
    finally:
        if sess.client is not None:
            sess.client.close()
            log = getattr(sess.client, "_stderr_file", None)
            if log is not None:
                log.close()


_UID_LINE = re.compile(r'uid=([^\s]+)\s+([A-Za-z]+)\s*(?:"([^"]*)")?')


def _devtools_refs(sess):
    """uid refs parsed from the last take_snapshot text."""
    out = []
    for line in sess.refs_text.splitlines():
        m = _UID_LINE.search(line)
        if not m:
            continue
        role = m.group(2).lower()
        name = m.group(3) or ""
        editable = role in ("textbox", "searchbox", "combobox",
                            "input", "textarea")
        out.append({"ref": m.group(1), "role": role, "name": name,
                    "editable": editable})
    return out


# ── the driver-neutral op corpus ────────────────────────────────────────

def _row(sess, op, site_id, it, wall_ms, status, detail, ordering):
    return {"arm": sess.arm, "driver": sess.driver, "op": op,
            "site": site_id, "iter": it, "wall_ms": round(wall_ms, 1),
            "status": status, "detail": _cap(detail),
            "session_label": sess.label, "ordering": ordering}


def _unsupported(sess, op, site, it, ordering, detail):
    return _row(sess, op, site, it, 0.0, UNSUPPORTED, detail, ordering)


def run_op(sess, op, site, it, ordering):
    """One timed op -> one row dict. Never raises."""
    site_id = site.get("id", "?")
    if sess.driver == "cua" and sess.arm == "A":
        # The real-profile arm never iterates sites: every row describes
        # the bound user tab, unsupported/dead rows included.
        site_id = "bound-user-tab"
        if op in CUA_ARM_A_UNSUPPORTED:
            return _unsupported(
                sess, op, site_id, it, ordering,
                "cua existing_profile arm is read-only; bound tab: %s"
                % sess.bound_url)
    if not sess.alive():
        return _row(sess, op, site_id, it, 0.0, DRIVER_ERROR,
                    "transport not alive", ordering)
    timeout = OP_TIMEOUTS.get(op, DEFAULT_TIMEOUT)
    t0 = time.monotonic()
    try:
        status, detail = _dispatch(sess, op, site, timeout)
    except MCPTimeout as exc:
        return _row(sess, op, site_id, it,
                    (time.monotonic() - t0) * 1000, TIMEOUT,
                    str(exc), ordering)
    except MCPError as exc:
        return _row(sess, op, site_id, it,
                    (time.monotonic() - t0) * 1000, DRIVER_ERROR,
                    str(exc), ordering)
    except Exception as exc:  # adapter bug -> honest driver_error row
        return _row(sess, op, site_id, it,
                    (time.monotonic() - t0) * 1000, DRIVER_ERROR,
                    "adapter: %r" % exc, ordering)
    return _row(sess, op, site_id, it,
                (time.monotonic() - t0) * 1000, status, detail, ordering)


def _tool_status(result, ok_detail):
    refused, detail = _is_refusal(result)
    if refused:
        return REFUSED, detail
    _, is_error = tool_text(result)
    if is_error:
        return DRIVER_ERROR, detail or ok_detail
    return OK, ok_detail


def _dispatch(sess, op, site, timeout):
    if sess.driver == "cua":
        return _cua_op(sess, op, site, timeout)
    return _devtools_op(sess, op, site, timeout)


def _cua_op(sess, op, site, timeout):
    base = {"target_id": sess.target_id, "tab_id": sess.tab_id}
    if op == "navigate":
        args = dict(base); args["url"] = site["url"]
        r = _cua_tool(sess, "browser_navigate", args, timeout)
        return _tool_status(r, "navigated %s" % site["url"])
    if op == "settle":
        deadline = time.monotonic() + DEFAULT_TIMEOUT
        polls = 0
        while True:
            polls += 1
            r = _cua_tool(sess, "get_browser_state", dict(base), 10)
            refused, detail = _is_refusal(r)
            if refused:
                return REFUSED, detail
            url = ((_structured(r).get("page") or {}).get("url")
                   or _structured(r).get("url") or "")
            if url.startswith(site["url"].rstrip("/")):
                return OK, "settle polls=%d url=%s" % (polls, _cap(url, 80))
            if time.monotonic() >= deadline:
                return OK, "settle deadline polls=%d url=%s" % (
                    polls, _cap(url, 80))
            time.sleep(0.1)
    if op == "snapshot":
        args = dict(base); args["snapshot_format"] = "semantic_v2"
        r = _cua_tool(sess, "get_browser_state", args, timeout)
        refused, detail = _is_refusal(r)
        if refused:
            return REFUSED, detail
        _, is_error = tool_text(r)
        if is_error:
            return DRIVER_ERROR, detail
        sess.refs = _structured(r)
        if not sess.bound_url:
            sess.bound_url = (sess.refs.get("page") or {}).get("url")
        n_refs = len(_cua_refs(sess))
        return OK, "bytes=%d refs=%d url=%s" % (
            len(json.dumps(r)), n_refs, _cap(sess.bound_url, 80))
    if op == "click":
        want = site.get("click")
        if not want:
            return UNSUPPORTED, "no safe click target declared"
        ref = _match_ref(_cua_refs(sess), want)
        if not ref:
            return DRIVER_ERROR, "safe click target not found in refs"
        args = dict(base); args.update(
            {"ref": ref["ref"], "input_route": "dom_event"})
        r = _cua_tool(sess, "browser_click", args, timeout)
        return _tool_status(r, "clicked %s (%s)" % (ref["ref"], ref["name"]))
    if op == "type":
        want = site.get("type")
        if not want:
            return UNSUPPORTED, "no safe editable target declared"
        ref = _match_ref([r for r in _cua_refs(sess) if r["editable"]],
                         want)
        if not ref:
            return DRIVER_ERROR, "safe editable target not found in refs"
        args = dict(base); args.update(
            {"ref": ref["ref"], "text": want["text"], "replace": True})
        r = _cua_tool(sess, "browser_type", args, timeout)
        return _tool_status(r, "typed into %s (%s)" % (ref["ref"],
                                                       ref["name"]))
    if op == "extract":
        args = dict(base)
        args["snapshot_format"] = "semantic_v2"
        args["query"] = site.get("extract_query") or "main content"
        r = _cua_tool(sess, "get_browser_state", args, timeout)
        refused, detail = _is_refusal(r)
        if refused:
            return REFUSED, detail
        _, is_error = tool_text(r)
        if is_error:
            return DRIVER_ERROR, detail
        return OK, "bytes=%d" % len(json.dumps(r))
    return DRIVER_ERROR, "unknown op %s" % op


def _devtools_op(sess, op, site, timeout):
    if op == "navigate":
        r = _devtools_tool(sess, "navigate_page", {"url": site["url"]},
                           timeout)
        return _tool_status(r, "navigated %s" % site["url"])
    if op == "settle":
        deadline = time.monotonic() + DEFAULT_TIMEOUT
        polls = 0
        state = ""
        while True:
            polls += 1
            r = _devtools_tool(
                sess, "evaluate_script",
                {"function": "() => document.readyState"}, 10)
            text, is_error = tool_text(r)
            m = re.search(r'"(complete|interactive|loading)"', text)
            state = m.group(1) if m else state
            refused, detail = _is_refusal(r)
            if refused:
                return REFUSED, detail
            if is_error:
                return DRIVER_ERROR, detail or text
            if state == "complete" or time.monotonic() >= deadline:
                return OK, "settle polls=%d readyState=%s" % (polls, state)
            time.sleep(0.05)
    if op == "snapshot":
        r = _devtools_tool(sess, "take_snapshot", {}, timeout)
        refused, detail = _is_refusal(r)
        if refused:
            return REFUSED, detail
        text, is_error = tool_text(r)
        if is_error:
            return DRIVER_ERROR, detail
        sess.refs_text = text
        return OK, "bytes=%d refs=%d" % (len(text),
                                         len(_devtools_refs(sess)))
    if op == "click":
        want = site.get("click")
        if not want:
            return UNSUPPORTED, "no safe click target declared"
        ref = _match_ref(_devtools_refs(sess), want)
        if not ref:
            return DRIVER_ERROR, "safe click target not found in refs"
        r = _devtools_tool(sess, "click", {"uid": ref["ref"]}, timeout)
        return _tool_status(r, "clicked %s (%s)" % (ref["ref"], ref["name"]))
    if op == "type":
        want = site.get("type")
        if not want:
            return UNSUPPORTED, "no safe editable target declared"
        ref = _match_ref([r for r in _devtools_refs(sess) if r["editable"]],
                         want)
        if not ref:
            return DRIVER_ERROR, "safe editable target not found in refs"
        r = _devtools_tool(sess, "fill",
                           {"uid": ref["ref"], "value": want["text"]},
                           timeout)
        return _tool_status(r, "typed into %s (%s)" % (ref["ref"],
                                                       ref["name"]))
    if op == "extract":
        r = _devtools_tool(
            sess, "evaluate_script",
            {"function": "() => JSON.stringify({title: document.title, "
             "href: location.href, links: document.links.length})"},
            timeout)
        refused, detail = _is_refusal(r)
        if refused:
            return REFUSED, detail
        text, is_error = tool_text(r)
        if is_error:
            return DRIVER_ERROR, detail or text
        return OK, "bytes=%d %s" % (len(text), _cap(text, 120))
    return DRIVER_ERROR, "unknown op %s" % op


Session.refs_text = ""


# ── attach / teardown timing wrapper ────────────────────────────────────

def attach(driver, arm):
    """Returns (Session|None, attach_ms, status, detail, label)."""
    label = mint_label()
    sess = Session(driver, arm, label)
    t0 = time.monotonic()
    try:
        if driver == "cua":
            cua_attach(sess)
        else:
            devtools_attach(sess)
        ms = (time.monotonic() - t0) * 1000
        return sess, ms, OK, "", label
    except BlockedEnv as exc:
        if sess.client is not None:
            sess.client.close()
        return None, (time.monotonic() - t0) * 1000, BLOCKED, str(exc), label
    except MCPTimeout as exc:
        if sess.client is not None:
            sess.client.close()
        # An Arm-A devtools attach timeout is the autoConnect handshake
        # parked behind Chrome's "Allow remote debugging?" consent —
        # an environment gate, not a slow driver.
        if driver == "devtools" and arm == "A":
            return None, (time.monotonic() - t0) * 1000, BLOCKED, (
                "autoConnect attach timed out — Chrome remote-debugging "
                "consent dialog ('Allow remote debugging?') pending: %s"
                % exc), label
        return None, (time.monotonic() - t0) * 1000, TIMEOUT, str(exc), label
    except MCPError as exc:
        if sess.client is not None:
            sess.client.close()
        return None, (time.monotonic() - t0) * 1000, DRIVER_ERROR, str(exc), label


def teardown(sess):
    """close_page/end_session + transport exit. Returns teardown_ms."""
    t0 = time.monotonic()
    try:
        if sess.driver == "cua":
            cua_teardown(sess)
        else:
            devtools_teardown(sess)
    except MCPError:
        if sess.client is not None:
            sess.client.close()
    return (time.monotonic() - t0) * 1000


def attach_cycle(driver, arm, it):
    """One timed attach+teardown cycle -> cycle dict."""
    sess, attach_ms, status, detail, label = attach(driver, arm)
    cycle = {"arm": arm, "driver": driver, "iter": it,
             "attach_ms": round(attach_ms, 1), "teardown_ms": None,
             "status": status, "detail": _cap(detail),
             "session_label": label}
    if sess is not None:
        cycle["teardown_ms"] = round(teardown(sess), 1)
        if driver == "devtools" and arm == "A":
            cycle["pages_before"] = sess.pages_before
            cycle["pages_after"] = sess.pages_after
    return cycle
