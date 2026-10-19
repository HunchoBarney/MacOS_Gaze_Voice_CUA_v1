"""Closed-set success verifiers (CONTRACTS.md section 7).

Every verifier returns {"verdict": "pass"|"fail"|"error", "evidence": str}
— never a bare bool. `runner` is injectable for tests:
fn(argv) -> (returncode, stdout, stderr).
"""

import os
import subprocess

VERIFIER_KINDS = ("speaks_substring", "file_state", "ax_state",
                  "app_frontmost", "dom_state")

_BROWSER_URL_EXPR = {
    "Safari": 'tell application "Safari" to get URL of current tab of '
              'front window',
    "Google Chrome": 'tell application "Google Chrome" to get URL of '
                     'active tab of front window',
}


def default_runner(argv, timeout=20):
    try:
        out = subprocess.run(argv, capture_output=True, text=True,
                             timeout=timeout)
        return out.returncode, out.stdout, out.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %ss" % timeout
    except OSError as exc:
        return 127, "", str(exc)


def _osascript(script, runner):
    return (runner or default_runner)(["osascript", "-e", script])


def verify(success, result_text="", runner=None):
    """Dispatch on success.kind; a verifier bug is evidence, not a crash."""
    if not isinstance(success, dict):
        return _res("error", "success spec missing")
    fn = {"speaks_substring": _speaks_substring,
          "file_state": _file_state,
          "ax_state": _ax_state,
          "app_frontmost": _app_frontmost,
          "dom_state": _dom_state}.get(success.get("kind"))
    if fn is None:
        return _res("error", "unknown success.kind %r" % success.get("kind"))
    try:
        return fn(success.get("expect") or {}, result_text or "", runner)
    except Exception as exc:
        return _res("error", "verifier raised %r" % exc)


def _res(verdict, evidence):
    return {"verdict": verdict, "evidence": str(evidence)[:300]}


def _speaks_substring(expect, result_text, runner):
    needle = expect.get("text")
    if not needle:
        return _res("error", "expect.text missing")
    found = needle.lower() in result_text.lower()
    return _res("pass" if found else "fail",
                "result text contains %r: %s" % (needle, found))


def _file_state(expect, result_text, runner):
    path, must = expect.get("path"), expect.get("must")
    if not path or must not in ("exists", "contains", "absent"):
        return _res("error", "expect needs path + must exists|contains|absent")
    exists = os.path.exists(os.path.expanduser(path))
    if must == "absent":
        return _res("pass" if not exists else "fail",
                    "%s exists=%s" % (path, exists))
    if not exists:
        return _res("fail", "%s does not exist" % path)
    if must == "exists":
        return _res("pass", "%s exists" % path)
    needle = expect.get("text")
    if needle is None:
        return _res("error", "must=contains needs expect.text")
    try:
        with open(os.path.expanduser(path), errors="replace") as fh:
            data = fh.read()
    except OSError as exc:
        return _res("error", "cannot read %s: %s" % (path, exc))
    found = needle in data
    return _res("pass" if found else "fail",
                "%s contains %r: %s" % (path, needle, found))


def _frontmost_name(runner):
    return _osascript(
        'tell application "System Events" to get name of first '
        'application process whose frontmost is true', runner)


def _frontmost_check(app, runner):
    rc, out, err = _frontmost_name(runner)
    if rc != 0:
        return _res("error", (err or out).strip() or "osascript rc=%s" % rc)
    name = out.strip()
    return _res("pass" if name == app else "fail",
                "frontmost=%r want=%r" % (name, app))


def _ax_state(expect, result_text, runner):
    app = expect.get("app")
    if not app:
        return _res("error", "expect.app missing")
    check = expect.get("check")
    if check in ("running", "not_running"):
        rc, out, err = _osascript(
            'tell application "System Events" to get exists '
            '(process "%s")' % app, runner)
        if rc != 0:
            return _res("error",
                        (err or out).strip() or "osascript rc=%s" % rc)
        running = out.strip().lower() == "true"
        ok = running == (check == "running")
        return _res("pass" if ok else "fail",
                    "process %r running=%s" % (app, running))
    if check == "frontmost":
        return _frontmost_check(app, runner)
    queries, contains = expect.get("queries"), expect.get("contains")
    if isinstance(queries, list) and queries and contains is not None:
        last = "no queries ran"
        for q in queries:
            script = ('tell application "System Events" to tell process '
                      '"%s" to get %s' % (app, q))
            rc, out, err = _osascript(script, runner)
            if rc == 0 and contains.lower() in out.lower():
                return _res("pass", "%r -> %r" % (q, out.strip()[:200]))
            last = ("%r error: %s" % (q, (err or out).strip()[:200])) \
                if rc != 0 else "%r -> %r" % (q, out.strip()[:200])
        return _res("fail", "no query contained %r; last: %s"
                    % (contains, last))
    return _res("error", "ax_state needs check running|not_running|"
                         "frontmost or queries+contains")


def _app_frontmost(expect, result_text, runner):
    app = expect.get("app")
    if not app:
        return _res("error", "expect.app missing")
    return _frontmost_check(app, runner)


def _dom_state(expect, result_text, runner):
    browser, text = expect.get("browser"), expect.get("text")
    expr = _BROWSER_URL_EXPR.get(browser)
    if expr is None:
        return _res("error", "dom_state browser must be one of %s"
                    % sorted(_BROWSER_URL_EXPR))
    if not text:
        return _res("error", "expect.text missing")
    rc, out, err = _osascript(expr, runner)
    if rc != 0:  # e.g. Automation permission denied (-1743)
        return _res("error", (err or out).strip() or "osascript rc=%s" % rc)
    url = out.strip()
    found = text.lower() in url.lower()
    return _res("pass" if found else "fail",
                "url=%r contains %r: %s" % (url, text, found))
