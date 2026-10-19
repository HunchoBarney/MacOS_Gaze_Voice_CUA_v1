#!/usr/bin/env python3
"""P2b measured run.

No flag: N attach+teardown cycles per arm x driver, then ONE attached
session per arm x driver running warmup 3 + timed N=15 iterations,
interleaved A/B (devtools iter, then cua iter, alternating) — cancels
warm HTTP cache/DNS/TLS bias on real sites.

--driver X is smoke/debug only: rows get ordering="single" and are
never mixed into the interleaved comparison set.
"""

import argparse
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ops
from mcp import MCPError


def _blocked_rows(sess_label, arm, driver, sites, it, ordering, detail):
    """A driver that never attached still fills its matrix cells."""
    if arm == "A" and driver == "cua":
        sites = ops.BOUND_SITES
    rows = []
    for site in sites:
        for op in ops.OPS:
            status, row_detail = ops.BLOCKED, detail
            if arm == "A" and driver == "cua" \
                    and op in ops.CUA_ARM_A_UNSUPPORTED:
                # Mutating verbs are unsupported on a bound user tab no
                # matter the attach state; note the block anyway.
                status, row_detail = ops.UNSUPPORTED, \
                    "cua existing_profile arm is read-only (%s)" % detail
            rows.append({"arm": arm, "driver": driver, "op": op,
                         "site": site["id"], "iter": it,
                         "wall_ms": 0.0, "status": status,
                         "detail": ops._cap(row_detail),
                         "session_label": sess_label,
                         "ordering": ordering})
    return rows


def run_arm(arm, drivers, sites, iters, warmup, cycles, ordering, out):
    for driver in drivers:
        consent = None
        for it in range(cycles):
            if consent:
                # A consent-gated attach stacks another Chrome dialog per
                # attempt — record the remaining cycles honestly instead.
                out["cycles"].append({
                    "arm": arm, "driver": driver, "iter": it,
                    "attach_ms": 0.0, "teardown_ms": 0.0,
                    "status": ops.BLOCKED,
                    "detail": "skipped: %s" % ops._cap(consent),
                    "session_label": "-"})
                continue
            cycle = ops.attach_cycle(driver, arm, it)
            out["cycles"].append(cycle)
            print("cycle arm=%s driver=%s iter=%d attach=%sms "
                  "teardown=%sms %s" % (arm, driver, it,
                                        cycle["attach_ms"],
                                        cycle["teardown_ms"],
                                        cycle["status"]), flush=True)
            if cycle["status"] == ops.BLOCKED and \
                    "dialog pending" in cycle["detail"].lower():
                # A pending consent dialog stacks another per attempt —
                # stop. A "did not settle for reconnect" refusal does
                # NOT stack dialogs; remaining cycles stay measurable.
                consent = cycle["detail"]

    sessions = {}
    session_detail = {}
    for driver in drivers:
        sess, ms, status, detail, label = ops.attach(driver, arm)
        sessions[driver] = sess
        session_detail[driver] = detail or status
        out["cycles"].append({
            "arm": arm, "driver": driver, "iter": cycles,
            "attach_ms": round(ms, 1), "teardown_ms": None,
            "status": status, "detail": ops._cap(detail),
            "session_label": label, "purpose": "per-op-session"})
        if sess is not None:
            out["meta"].setdefault("tools", {})[
                "%s-%s" % (driver, arm)] = sorted(sess.tools.keys())
            if driver == "devtools" and arm == "A":
                out["meta"]["devtools_pages_before"] = sess.pages_before
        print("session arm=%s driver=%s attach=%sms %s %s"
              % (arm, driver, round(ms, 1), status,
                 ops._cap(detail, 120)), flush=True)

    try:
        for it in range(-warmup, iters):
            for driver in drivers:
                sess = sessions[driver]
                if sess is None:
                    out["rows"].extend(_blocked_rows(
                        "-", arm, driver, sites, it, ordering,
                        "attach failed for arm %s: %s"
                        % (arm, session_detail.get(driver, "?"))))
                    continue
                if not sess.alive() and it >= 0:
                    fresh, detail, label = None, "no attempt", "-"
                    for _try in range(2):
                        fresh, _ms, st, detail, label = ops.attach(
                            driver, arm)
                        if fresh is not None:
                            break
                        time.sleep(3)
                    sessions[driver] = fresh or sess
                    if fresh is None:
                        out["rows"].extend(_blocked_rows(
                            label, arm, driver, sites, it, ordering,
                            "reattach failed x2: %s" % detail))
                        continue
                    sess = fresh
                run_sites = (ops.BOUND_SITES
                             if arm == "A" and driver == "cua" else sites)
                for site in run_sites:
                    for op in ops.OPS:
                        row = ops.run_op(sess, op, site, it, ordering)
                        out["rows"].append(row)
                        if it >= 0:
                            print("row %s" % json.dumps(row), flush=True)
    finally:
        for driver in drivers:
            sess = sessions.get(driver)
            if sess is not None:
                ms = ops.teardown(sess)
                for c in reversed(out["cycles"]):
                    if c.get("purpose") == "per-op-session" \
                            and c["session_label"] == sess.label \
                            and c["teardown_ms"] is None:
                        c["teardown_ms"] = round(ms, 1)
                        break
                if driver == "devtools" and arm == "A":
                    out["meta"]["devtools_pages_after"] = sess.pages_after


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--driver", choices=["cua", "devtools"], default=None)
    ap.add_argument("--arm", choices=["A", "B"], default=None)
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--iters", type=int, default=15)
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--cycles", type=int, default=5)
    args = ap.parse_args()

    iters = 2 if args.smoke else args.iters
    warmup = 1 if args.smoke else args.warmup
    cycles = 1 if args.smoke else args.cycles
    drivers = [args.driver] if args.driver else ops.DRIVERS
    ordering = "single" if args.driver else "interleaved"
    arms = [args.arm] if args.arm else ops.ARMS
    sites = ops.load_sites()["sites"]

    data = ops.load_results()
    meta = data.setdefault("meta", {})
    meta.setdefault("run_started", time.strftime("%Y-%m-%dT%H:%M:%S"))
    if "cua_proxies_baseline" not in meta:
        meta["cua_proxies_baseline"] = sorted(ops.cua_proxy_pids())
        meta["cua_proxies_baseline_ppid"] = {
            str(p): ppid for p, ppid in ops.cua_proxy_pids().items()}
    elif "cua_proxies_baseline_ppid" not in meta:
        # Legacy baseline: processes are dead so live ppids are gone,
        # but each entry's --socket name jev-cua-<apppid>-*.sock encodes
        # the spawning app's pid — record the derived ownership proof.
        derived = {}
        for e in meta["cua_proxies_baseline"]:
            m = re.search(r"jev-cua-(\d+)-", e)
            if m:
                derived[e.split()[0]] = "%s (from socket name)" \
                    % m.group(1)
        meta["cua_proxies_baseline_ppid"] = derived
    meta["daemon_socket_hint"] = ops.read_socket_hint() \
        if os.path.isfile(ops.CUA_SOCKET_HINT) else None
    out = {"meta": meta, "cycles": [], "rows": []}

    for arm in arms:
        run_arm(arm, drivers, sites, iters, warmup, cycles, ordering, out)

    after = ops.cua_proxy_pids()
    baseline = set(meta.get("cua_proxies_baseline") or [])
    # A leaked spike proxy is owned by this run's pid or orphaned to
    # launchd (ppid 1). App-spawned proxies on a re-minted socket are
    # production churn, not leaks.
    leaked = sorted(p for p, ppid in after.items()
                    if p not in baseline and ppid in (1, os.getpid()))
    meta["cua_proxies_after"] = sorted(after)
    # Persist the pid->ppid observation so the leak verdict is
    # independently recheckable (app-owned proxies have ppid=app pid).
    meta["cua_proxies_after_ppid"] = {
        str(p): ppid for p, ppid in after.items()}
    meta["cua_proxies_leaked"] = leaked
    print("leak-check: baseline=%s after=%s leaked=%s (after pid->ppid: %s)"
          % (meta["cua_proxies_baseline"], meta["cua_proxies_after"],
             leaked, meta["cua_proxies_after_ppid"]), flush=True)
    meta["daemon_socket_after"] = ops.read_socket_hint() \
        if os.path.isfile(ops.CUA_SOCKET_HINT) else None
    meta["ordering"] = ordering
    data["cycles"].extend(out["cycles"])
    data["rows"].extend(out["rows"])
    ops.save_results(data)
    print("run done: %d rows, %d cycles, leaked proxies: %s"
          % (len(out["rows"]), len(out["cycles"]),
             meta["cua_proxies_leaked"]))


if __name__ == "__main__":
    main()
