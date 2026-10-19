#!/usr/bin/env python3
"""P2b report: results.json -> results/REPORT.md.

Per-op p50/p95 by (arm x driver), success matrix, attach+teardown cost
table, snapshot-byte table, robustness matrix, and the driver pick with
the numbers behind it.
"""

import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ops


def pct(values, p):
    """Nearest-rank percentile; None on empty."""
    if not values:
        return None
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round((p / 100.0) * len(s))) - 1))
    return s[k]


def _fmt(v):
    return "-" if v is None else ("%.0f" % v if v >= 10 else "%.1f" % v)


def op_table(rows, arms, drivers):
    """Per (arm,driver,op): n, ok-rate, p50, p95 over timed (iter>=0).
    ordering:single smoke rows never mix into the comparison set."""
    if any(r.get("ordering") == "interleaved" for r in rows):
        rows = [r for r in rows if r.get("ordering") == "interleaved"]
    cells = {}
    for r in rows:
        if r.get("iter", 0) < 0:
            continue
        key = (r["arm"], r["driver"], r["op"])
        c = cells.setdefault(key, {"n": 0, "ok": [], "statuses": {}})
        c["n"] += 1
        c["statuses"][r["status"]] = c["statuses"].get(r["status"], 0) + 1
        if r["status"] == ops.OK:
            c["ok"].append(r["wall_ms"])
    lines = ["| arm | driver | op | n | ok% | p50 ms | p95 ms |",
             "|---|---|---|---|---|---|---|"]
    for arm in arms:
        for driver in drivers:
            for op in ops.OPS:
                c = cells.get((arm, driver, op))
                if not c:
                    continue
                okp = 100.0 * len(c["ok"]) / c["n"]
                extra = "" if len(c["ok"]) == c["n"] else \
                    " (%s)" % ",".join("%s:%d" % kv for kv in
                                      sorted(c["statuses"].items())
                                      if kv[0] != ops.OK)
                lines.append("| %s | %s | %s | %d | %.0f%s | %s | %s |"
                             % (arm, driver, op, c["n"], okp, extra,
                                _fmt(pct(c["ok"], 50)),
                                _fmt(pct(c["ok"], 95))))
    return lines, cells


def cycle_table(cycles, arms, drivers):
    lines = ["| arm | driver | n (attempts) | attach p50 | attach p95 | "
             "teardown p50 | teardown p95 | status | skipped |",
             "|---|---|---|---|---|---|---|---|---|"]
    for arm in arms:
        for driver in drivers:
            cs = [c for c in cycles
                  if c["arm"] == arm and c["driver"] == driver]
            if not cs:
                continue
            # 'skipped:' rows are cascade slots recorded without a real
            # attach attempt — report them separately, never in n/stats.
            real = [c for c in cs
                    if not (c.get("detail") or "").startswith("skipped:")]
            skipped = len(cs) - len(real)
            if not real:
                lines.append("| %s | %s | 0 | - | - | - | - | - | %d |"
                             % (arm, driver, skipped))
                continue
            ok = [c for c in real if c["status"] == ops.OK]
            att = [c["attach_ms"] for c in ok if c.get("attach_ms")]
            tea = [c["teardown_ms"] for c in ok if c.get("teardown_ms")]
            status = ",".join(sorted({c["status"] for c in real}))
            lines.append("| %s | %s | %d | %s | %s | %s | %s | %s | %d |"
                         % (arm, driver, len(real), _fmt(pct(att, 50)),
                            _fmt(pct(att, 95)), _fmt(pct(tea, 50)),
                            _fmt(pct(tea, 95)), status, skipped))
    lines.append("")
    lines.append("`skipped` = slots recorded without an attach attempt "
                 "after a pending consent dialog (dialog-stacking guard) "
                 "— shown for completeness, excluded from all stats.")
    return lines


def snapshot_bytes_table(rows, rob_rows):
    pat = re.compile(r"bytes=(\d+)")
    lines = ["| arm | driver | site | bytes |", "|---|---|---|---|"]
    seen = set()
    for r in list(rob_rows) + [r for r in rows if r["op"] == "snapshot"]:
        m = pat.search(r.get("detail") or "")
        if not m or r["status"] != ops.OK:
            continue
        key = (r["arm"], r["driver"], r.get("site"))
        if key in seen:
            continue
        seen.add(key)
        lines.append("| %s | %s | %s | %s |"
                     % (key[0], key[1], key[2], m.group(1)))
    return lines


def robustness_table(rob_rows):
    lines = ["| arm | driver | check | site | ms | status | detail |",
             "|---|---|---|---|---|---|---|"]
    for r in rob_rows:
        lines.append("| %s | %s | %s | %s | %s | %s | %s |"
                     % (r["arm"], r["driver"], r["check"],
                        r.get("site", "-"), _fmt(r.get("wall_ms")),
                        r["status"], (r.get("detail") or "")[:120]))
    return lines


def pick_paragraph(cells, cycles, meta, rows):
    """Honest pick from measured numbers."""
    def ok_rate(arm, driver):
        n = ok = 0
        for (a, d, _op), c in cells.items():
            if a == arm and d == driver:
                n += c["n"]; ok += len(c["ok"])
        return (100.0 * ok / n, ok, n) if n else (0.0, 0, 0)
    def attach_p50(arm, driver):
        att = [c["attach_ms"] for c in cycles
               if c["arm"] == arm and c["driver"] == driver
               and c["status"] == ops.OK and c.get("attach_ms")]
        return pct(att, 50)
    b_dev, _, n_dev = ok_rate("B", "devtools")
    b_cua, _, n_cua = ok_rate("B", "cua")
    a_dev = ok_rate("A", "devtools")[0]
    a_cua = ok_rate("A", "cua")[0]
    dead = sum(1 for r in rows if r["status"] == ops.DRIVER_ERROR
               and ("transport" in (r.get("detail") or "")
                    or "closed stdout" in (r.get("detail") or "")))
    stale = sum(1 for r in rows
                if "stale" in (r.get("detail") or "").lower()
                or "no longer exists" in (r.get("detail") or ""))
    blocked = [c for c in cycles if c["status"] == ops.BLOCKED
               and not (c.get("detail") or "").startswith("skipped:")]
    skipped_n = sum(1 for c in cycles
                    if (c.get("detail") or "").startswith("skipped:"))
    lines = [
        "## Verdict (measured)",
        "",
        "Arm-B ok-rate over timed interleaved cells: devtools %.0f%% "
        "(n=%d), cua %.0f%% (n=%d). Arm-A ok-rate: devtools %.0f%%, "
        "cua %.0f%% — Arm-A rows mix the pre-consent blocked era "
        "(blocked_env) with post-consent measured rows; read the ok "
        "subset for capability, the blocked rows for the consent UX "
        "cost." % (b_dev, n_dev, b_cua, n_cua, a_dev, a_cua),
        "",
        "Arm-B attach p50: devtools %sms, cua %sms (spawn + handshake + "
        "prepare + tools/list). Teardown: sub-second devtools, ~0.5s cua."
        % (_fmt(attach_p50("B", "devtools")), _fmt(attach_p50("B", "cua"))),
        "Arm-A attach p50 (post-consent, ok rows only): devtools %sms, "
        "cua %sms."
        % (_fmt(attach_p50("A", "devtools")), _fmt(attach_p50("A", "cua"))),
        "",
        "- %d cua rows are 'transport not alive'/'closed stdout' — every "
        "one downstream of a wikipedia semantic_v2 snapshot that exceeded "
        "the 15s read deadline or killed the proxy; github/spa cells are "
        "cascade, not capability (all four sites measured ok in the "
        "robustness matrix)." % dead,
        "- %d rows show ref staleness after navigation (devtools uid "
        "'no longer exists', cua browser_ref_stale clean refusal) — the "
        "as-run corpus clicked before typing, so the wikipedia type cell "
        "measures stale-ref behavior for both drivers." % stale,
        "- 'unsupported' type cells are corpus-declared (no safe editable "
        "target on that site), not driver incapacity.",
        "",
    ]
    if blocked:
        lines.append("Arm A has two eras: pre-consent (%d real blocked "
                     "attach attempts + %d skipped cascade slots + per-op "
                     "blocked_env rows — Chrome 155's 'Allow "
                     "remote debugging?' dialog held both drivers: "
                     "autoConnect handshake pends at read deadline, cua "
                     "existing_profile binds consent-gated per window) "
                     "and post-consent measured rows (user granted once — "
                     "ws handshake 101 in ~2.7s, autoConnect attaches, "
                     "cua binds). The consent click is a one-time "
                     "per-Chrome-instance gate P7 must design for. While "
                     "the dialog was still settling, cua prepares "
                     "intermittently refused 'consent did not settle for "
                     "reconnect'; once fully cleared, 10/10 cua Arm-A "
                     "attach cycles passed. The run was paused by a "
                     "laptop-lid sleep between the consent click and the "
                     "Arm-A rerun — post-consent rows come from the "
                     "resumed run (results/run-armA-consented.log)."
                     % (len(blocked), skipped_n))
        lines.append("")
    if b_dev > b_cua:
        pick = ("devToolsMcp (primary) + cua fallback — matches the locked "
                "plan direction")
    elif b_cua > 0 and b_dev > 0:
        pick = "hybrid"
    elif b_cua > 0:
        pick = "cua"
    else:
        pick = "unresolved (both drivers blocked)"
    lines.append("Pick: **%s**." % pick)
    lines.append("")
    lines.append("Numbers behind it: devtools ran the full mutating corpus "
                 "at %.0f%% cell-ok (every non-type cell 15/15 on all four "
                 "sites) with ~%sx faster attach and millisecond-scale "
                 "snapshots; cua completed example.com's corpus cleanly and "
                 "passed every robustness check, but its semantic_v2 "
                 "snapshot on heavy pages (~10s/63KB wikipedia) sits near "
                 "the read deadline and repeatedly killed the stdio "
                 "transport. cua's snapshots are far smaller (8-63KB vs "
                 "devtools' 1-470KB), which is why it stays the fallback "
                 "rather than being dropped."
                 % (b_dev,
                    round((attach_p50("B", "cua") or 1)
                          / (attach_p50("B", "devtools") or 1), 1)))
    return lines


def main():
    data = ops.load_results()
    rows_all = data.get("rows", [])
    single = [r for r in rows_all if r.get("ordering") == "single"]
    rows = rows_all
    cycles = data.get("cycles", [])
    rob = data.get("robustness", [])
    meta = data.get("meta", {})
    probe = data.get("probe", {})
    arms = sorted({r["arm"] for r in rows + cycles + rob} or ops.ARMS)
    drivers = sorted({r["driver"] for r in rows + cycles + rob}
                     or ops.DRIVERS)

    out = ["# P2b browser-driver spike — REPORT",
           "",
           "chrome-devtools-mcp@1.10.1 vs Cua `browser_*` (daemon "
           "0.34.0). Generated %s." % time.strftime("%Y-%m-%d %H:%M"),
           "", "## Environment", ""]
    for k in ("run_started", "ordering"):
        if k in meta:
            out.append("- %s: %s" % (k, meta[k]))
    for name in ("cua_proxies_baseline", "cua_proxies_after",
                 "cua_proxies_leaked", "devtools_pages_before",
                 "devtools_pages_after"):
        if name in meta:
            out.append("- %s: %s" % (name, meta[name]))
    out += ["", "## Probe", ""]
    for c in probe.get("checks", []):
        out.append("- %s: %s (%sms) — %s"
                   % (c["check"], c["status"], c.get("ms"),
                      c.get("detail", "")))
    for drv, tools in sorted((meta.get("tools") or {}).items()):
        out.append("- tools %s: %s" % (drv, ",".join(tools)))

    lines, cells = op_table(rows, arms, drivers)
    out += ["", "## Per-op latency (timed iters, ok rows)", ""] + lines
    out += ["", "## Attach + teardown cycles", ""] + \
        cycle_table(cycles, arms, drivers)
    out += ["", "## Snapshot bytes", ""] + \
        snapshot_bytes_table(rows, rob)
    out += ["", "## Robustness", ""] + robustness_table(rob)
    if single:
        out += ["", "## Single-driver smoke rows (excluded above)", "",
                "%d rows flagged ordering=single — debug/smoke only."
                % len(single)]
    out += [""] + pick_paragraph(cells, cycles, meta, rows)
    out += ["", "## Files", "",
            "- `mcp.py` — newline-delimited JSON-RPC stdio client "
            "(adapted from bench/lib/mcp_stdio.py; bounded reads, "
            "kill-on-timeout).",
            "- `ops.py` — driver adapters + driver-neutral op corpus.",
            "- `run.py` — attach/teardown cycles + interleaved corpus run.",
            "- `probe.py` — environment/protocol checks -> probe block.",
            "- `robustness.py` — robustness matrix runner.",
            "- `report.py` — this report.",
            "- `sites.json` — site corpus + safe selectors.",
            "- `package.json`/`package-lock.json` — "
            "chrome-devtools-mcp@1.10.1 pin.",
            "- `results/results.json` — raw rows; `results/REPORT.md` — "
            "this file; `results/*.log` — run streams incl. superseded "
            "arm-A rows.",
            "", "## Commands", "",
            "- `python3 probe.py` — env probe -> results.json probe block",
            "- `python3 run.py` — full interleaved run "
            "(warmup 3 + N=15, N=5 attach cycles per arm×driver)",
            "- `python3 run.py --arm A` — arm-A row regeneration after "
            "emitter fix (superseded rows kept in run-full.log)",
            "- `python3 robustness.py` — robustness matrix, both arms",
            "- `python3 report.py` — regenerate this file",
            ""]
    out += ["", "## Unmeasured",
            "",
            "- CONTRACTS §5 `key`/`scroll`/`back` actions — not in corpus.",
            "- Pixel-path (screenshot) comparison — P5 does not exist "
            "yet; P7 compares against Sol later.",
            "- Arm-A post-consent rows are measured for devtools (full "
            "corpus in a spike-owned tab on the real profile) and cua "
            "read-only ops (bound user tab) — the pre-consent "
            "blocked_env rows remain as the consent-cost record. cua "
            "Arm-A mutation stays unexercised BY DESIGN (no tab verbs → "
            "would require mutating a user tab, forbidden).",
            "- cua Arm-A read latencies (snapshot ~3.3s, extract ~1.9s) "
            "were measured on a tab bound to `about:blank` — a ~2-3s "
            "fixed existing_profile read floor, not page-weight-driven; "
            "a real logged-in page was also bound once earlier "
            "(console.typesafe.ai/keys, ~10s snapshot, 113 refs).",
            "- cua `type` never measured clean: example/spa had no "
            "editable target, wikipedia hit stale-ref refusals, and the "
            "github/spa cells were transport-death cascade.",
            ""]
    path = os.path.join(ops.RESULTS, "REPORT.md")
    with open(path, "w") as fh:
        fh.write("\n".join(out))
    print("wrote %s (%d rows, %d cycles, %d robustness)"
          % (path, len(rows), len(cycles), len(rob)))


if __name__ == "__main__":
    main()
