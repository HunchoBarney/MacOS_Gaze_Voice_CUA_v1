#!/usr/bin/env python3
"""P2b robustness matrix. Rows appended to results/results.json under
"robustness": stale-ref click after navigation (error quality),
iframe-heavy snapshot, cross-origin nav, snapshot bytes per site
(token-cost proxy), re-attach after killing the spawned transport.

Default arm B (both drivers fully capable there); Arm A gets the
read-only subset and whatever attach state the env allows.
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ops
from mcp import MCPError, tool_text


def _row(sess, check, site_id, wall_ms, status, detail):
    return {"arm": sess.arm, "driver": sess.driver, "check": check,
            "site": site_id, "wall_ms": round(wall_ms, 1),
            "status": status, "detail": ops._cap(detail, 300),
            "session_label": sess.label}


def _blocked_row(arm, driver, check, detail):
    return {"arm": arm, "driver": driver, "check": check, "site": "-",
            "wall_ms": 0.0, "status": ops.BLOCKED,
            "detail": ops._cap(detail, 300), "session_label": "-"}


def _tool(sess, name, arguments, timeout):
    if sess.driver == "cua":
        return ops._cua_tool(sess, name, arguments, timeout)
    return ops._devtools_tool(sess, name, arguments, timeout)


def _snapshot_bytes(sess):
    """Navigate-free: raw snapshot size on current page."""
    t0 = time.monotonic()
    if sess.driver == "cua":
        r = _tool(sess, "get_browser_state", {
            "target_id": sess.target_id, "tab_id": sess.tab_id,
            "snapshot_format": "semantic_v2"}, 15)
        return (time.monotonic() - t0) * 1000, len(json.dumps(r)), r
    r = _tool(sess, "take_snapshot", {}, 15)
    text, _ = tool_text(r)
    return (time.monotonic() - t0) * 1000, len(text), r


def _nav(sess, url, timeout=30):
    if sess.driver == "cua":
        return _tool(sess, "browser_navigate", {
            "target_id": sess.target_id, "tab_id": sess.tab_id,
            "url": url}, timeout)
    return _tool(sess, "navigate_page", {"url": url}, timeout)


def _snapshot_op(sess):
    """One snapshot through the op layer so refs stash for click."""
    return ops._dispatch(sess, "snapshot",
                         {"id": "-", "url": ""}, 15)


def _click_ref(sess, ref):
    if sess.driver == "cua":
        return _tool(sess, "browser_click", {
            "target_id": sess.target_id, "tab_id": sess.tab_id,
            "ref": ref, "input_route": "dom_event"}, 10)
    return _tool(sess, "click", {"uid": ref}, 10)


def _first_ref(sess):
    refs = (ops._cua_refs(sess) if sess.driver == "cua"
            else ops._devtools_refs(sess))
    return refs[0]["ref"] if refs else None


def matrix(sess, sites, rob, rows):
    """Full matrix — needs a mutable session (Arm B, or devtools A)."""
    # stale-ref click after navigation: expect a clean refusal.
    t0 = time.monotonic()
    check = "stale_ref_click"
    try:
        _nav(sess, sites[0]["url"])
        _snapshot_op(sess)
        ref = _first_ref(sess)
        if ref is None:
            raise MCPError("no refs in snapshot for stale-ref check")
        _nav(sess, sites[1]["url"])
        r = _click_ref(sess, ref)
        refused, detail = ops._is_refusal(r)
        _, is_error = tool_text(r)
        status = ops.OK if (refused or is_error) else ops.DRIVER_ERROR
        detail = ("clean refusal: %s" % detail) if status == ops.OK \
            else "stale ref dispatched — no refusal!"
        rows.append(_row(sess, check, sites[1]["id"],
                         (time.monotonic() - t0) * 1000, status, detail))
    except (MCPError,) as exc:
        rows.append(_row(sess, check, sites[1]["id"],
                         (time.monotonic() - t0) * 1000,
                         ops.DRIVER_ERROR, str(exc)))

    # iframe-heavy page snapshot.
    t0 = time.monotonic()
    try:
        _nav(sess, rob["iframe_url"])
        ms, nbytes, r = _snapshot_bytes(sess)
        _, is_error = tool_text(r)
        rows.append(_row(sess, "iframe_snapshot", "mdn-iframe", ms,
                         ops.DRIVER_ERROR if is_error else ops.OK,
                         "bytes=%d" % nbytes))
    except MCPError as exc:
        rows.append(_row(sess, "iframe_snapshot", "mdn-iframe",
                         (time.monotonic() - t0) * 1000,
                         ops.DRIVER_ERROR, str(exc)))

    # cross-origin navigation.
    t0 = time.monotonic()
    try:
        _nav(sess, rob["cross_origin_url"])
        ms, nbytes, r = _snapshot_bytes(sess)
        _, is_error = tool_text(r)
        rows.append(_row(sess, "cross_origin_nav", "iana", ms,
                         ops.DRIVER_ERROR if is_error else ops.OK,
                         "bytes=%d" % nbytes))
    except MCPError as exc:
        rows.append(_row(sess, "cross_origin_nav", "iana",
                         (time.monotonic() - t0) * 1000,
                         ops.DRIVER_ERROR, str(exc)))

    # snapshot bytes per site (token-cost proxy).
    for site in sites:
        t0 = time.monotonic()
        try:
            _nav(sess, site["url"])
            ms, nbytes, r = _snapshot_bytes(sess)
            _, is_error = tool_text(r)
            rows.append(_row(sess, "snapshot_bytes", site["id"], ms,
                             ops.DRIVER_ERROR if is_error else ops.OK,
                             "bytes=%d" % nbytes))
        except MCPError as exc:
            rows.append(_row(sess, "snapshot_bytes", site["id"],
                             (time.monotonic() - t0) * 1000,
                             ops.DRIVER_ERROR, str(exc)))

    # re-attach after killing the spawned transport.
    t0 = time.monotonic()
    try:
        sess.client.proc.kill()
        sess.client.proc.wait(timeout=5)
        sess.client = None
        fresh, ms, st, detail, _label = ops.attach(sess.driver, sess.arm)
        if fresh is None:
            rows.append(_row(sess, "reattach_after_kill", "-", ms,
                             st, "reattach: %s" % detail))
        else:
            status, d = _snapshot_op(fresh)
            rows.append(_row(fresh, "reattach_after_kill", "-",
                             (time.monotonic() - t0) * 1000,
                             status, str(d)))
            ops.teardown(fresh)
    except Exception as exc:
        rows.append(_row(sess, "reattach_after_kill", "-",
                         (time.monotonic() - t0) * 1000,
                         ops.DRIVER_ERROR, "%r" % exc))


def matrix_readonly(sess, sites, rows):
    """Arm-A-safe subset: snapshot bytes on the bound tab + reattach."""
    try:
        ms, nbytes, r = _snapshot_bytes(sess)
        _, is_error = tool_text(r)
        rows.append(_row(sess, "snapshot_bytes", "bound-user-tab", ms,
                         ops.DRIVER_ERROR if is_error else ops.OK,
                         "bytes=%d url=%s" % (nbytes,
                                              ops._cap(sess.bound_url, 80))))
    except MCPError as exc:
        rows.append(_row(sess, "snapshot_bytes", "bound-user-tab", 0,
                         ops.DRIVER_ERROR, str(exc)))
    t0 = time.monotonic()
    try:
        sess.client.proc.kill()
        sess.client.proc.wait(timeout=5)
        sess.client = None
        fresh, ms, st, detail, _label = ops.attach(sess.driver, sess.arm)
        if fresh is None:
            rows.append(_row(sess, "reattach_after_kill", "-", ms,
                             st, "reattach: %s" % detail))
        else:
            ops.teardown(fresh)
            rows.append(_row(sess, "reattach_after_kill", "-",
                             (time.monotonic() - t0) * 1000, ops.OK,
                             "reattached"))
    except Exception as exc:
        rows.append(_row(sess, "reattach_after_kill", "-",
                         (time.monotonic() - t0) * 1000,
                         ops.DRIVER_ERROR, "%r" % exc))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--driver", choices=["cua", "devtools"], default=None)
    ap.add_argument("--arm", choices=["A", "B"], default=None)
    args = ap.parse_args()
    drivers = [args.driver] if args.driver else ops.DRIVERS
    arms = [args.arm] if args.arm else ops.ARMS
    data = ops.load_sites()
    sites, rob = data["sites"], data["robustness"]
    rows = []
    for arm in arms:
        for driver in drivers:
            sess, _ms, st, detail, _label = ops.attach(driver, arm)
            if sess is None:
                for check in ("stale_ref_click", "iframe_snapshot",
                              "cross_origin_nav", "snapshot_bytes",
                              "reattach_after_kill"):
                    rows.append(_blocked_row(arm, driver, check,
                                             "attach: %s" % detail))
                print("arm=%s driver=%s attach %s: %s"
                      % (arm, driver, st, ops._cap(detail, 120)),
                      flush=True)
                continue
            try:
                if arm == "A" and driver == "cua":
                    matrix_readonly(sess, sites, rows)
                else:
                    matrix(sess, sites, rob, rows)
            finally:
                ops.teardown(sess)
            for r in rows[-8:]:
                print(json.dumps(r), flush=True)
    ops.append("robustness", rows)
    print("robustness done: %d rows" % len(rows))


if __name__ == "__main__":
    main()
