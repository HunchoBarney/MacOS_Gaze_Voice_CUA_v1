#!/usr/bin/env python3
"""P2c report: results/results.json -> results/REPORT.md.

Probe block, tool inventory per mechanism, activation checkpoint,
approvals matrix, scope checks, canary corpus, measurements, the verdict
computed against the PREDECLARED rule (ExecPlan), and the labeled
background/multi-user section. Stdlib only.
"""

import glob
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import appserver as A
from probe import load_results

RESULTS_DIR = os.path.join(A.HERE, "results")
DELTAS = {
    "scoped": "approval_policy=never + computer_use.default_app_access=deny"
              " + macos.bundle_ids{corpus apps: allow}",
    "never": "approval_policy=never + computer_use.default_app_access=allow",
    "auto_review": "approvals_reviewer=auto_review",
    "persistent": "computer_use.allow_persistent_approval=true",
    "default": "(none)",
    "client_allowlist": "(no config delta) client answers Sky's per-app "
                        "elicitation: accept iff it names a corpus app",
}


def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    return s[max(0, min(len(s) - 1, int(round(p / 100.0 * len(s))) - 1))]


def fmt(v):
    return "-" if v is None else "%.0f" % v


def tok(r):
    t = r.get("tokens") or {}
    return t.get("totalTokens")


def cu_tools(r):
    return ",".join(sorted({e["tool"] for e in r.get("cu_evidence") or []})) \
        or "-"


def esc(s, n=140):
    s = (s or "").replace("|", "/").replace("\n", " ")
    return s if len(s) <= n else s[:n] + "…"


def asks_cell(r):
    if "asks_declined" in r:
        return "%d declined / %d client-accepted" % (
            r["asks_declined"], r["asks_client_accepted"])
    return str(len([a for a in r.get("approvals") or []
                    if a.get("event") == "server_request"]))


def verdict(rows):
    """Mechanical application of the ExecPlan's predeclared rule."""
    tasks = [r for r in rows if r.get("kind") == "task"]
    unattended = {r["variant"] for r in tasks
                  if r.get("zero_click") and not r.get("tcc")}
    best, best_ok = None, []
    for v in unattended:
        ok = [r for r in tasks if r["variant"] == v and r["status"] == "ok"
              and r.get("cu_evidence") and r.get("zero_click")]
        if len(ok) > len(best_ok):
            best, best_ok = v, ok
    p50 = pct([r["wall_ms"] for r in best_ok], 50)
    scope = [r for r in rows if r.get("kind") == "scope"
             and r["variant"] == best]
    scope_ok = bool(scope) and all(r["status"] == "refused" for r in scope)
    transport = [r for r in rows if "EOF" in str(r.get("turn_error"))
                 or r.get("killed")]
    any_cu = any(r.get("cu_evidence") for r in rows)
    checks = [
        (">=2 canary tasks ok WITH cu_evidence under one zero-click config",
         len(best_ok) >= 2, "%d under %s: %s" % (
             len(best_ok), best, [r["task"] for r in best_ok])),
        ("p50 per-task wall <= 120s", p50 is not None and p50 <= 120000,
         "%s ms" % fmt(p50)),
        ("no unbounded actuation (scope refusal verified under that config)",
         scope_ok, "; ".join("%s:%s" % (r["task"], r["status"])
                             for r in scope) or "no scope row"),
        ("no unrecoverable transport", not transport,
         "%d rows with EOF/kill" % len(transport)),
    ]
    if all(c[1] for c in checks):
        v = "PROMOTE"
    elif not any_cu:
        v = "DISCARD"
    else:
        v = "CONDITIONAL"
    return v, checks, best, best_ok


def prior_runs():
    out = []
    for p in sorted(glob.glob(os.path.join(RESULTS_DIR, "run-*.rows.json"))):
        d = json.load(open(p))
        out.append("- `%s` — %s Rows: %s" % (
            os.path.basename(p), d.get("note", ""),
            ", ".join("%s/%s=%s" % (r["variant"], r["task"], r["status"])
                      for r in d.get("rows", []))))
    return out


def main():
    data = load_results()
    probe, meta, rows = data.get("probe", {}), data.get("meta", {}), \
        data.get("rows", [])
    v, checks, best, best_ok = verdict(rows)
    out = ["# P2c — codex app-server computer-use headless spike — REPORT",
           "", "Generated %s from `results/results.json` (run %s, log `%s`)."
           % (time.strftime("%Y-%m-%d %H:%M"), meta.get("run_started"),
              meta.get("log")), ""]
    out += ["## Verdict", "",
            "**%s** against the predeclared rule (ExecPlan §Verdict rule) — "
            "covers **THIS console session only**; it is NOT background/"
            "multi-user-session proof (see the labeled section below)." % v,
            "", "| rule clause | met | evidence |", "|---|---|---|"]
    out += ["| %s | %s | %s |" % (c, "yes" if ok else "NO", esc(e, 200))
            for c, ok, e in checks]
    out += ["", "### Caveats that qualify this verdict (read before "
            "acting on it)", "",
            "1. The zero-click config `client_allowlist` was ADDED "
            "mid-spike; it is not one of the five predeclared variants. All "
            "five predeclared variants failed to clear Sky's per-app gate "
            "(scoped/never: codex auto-declines the elicitation; auto_review/"
            "default: forwarded to the client; persistent: not settable). "
            "Zero clicks happen only because the CLIENT answers the "
            "elicitation from its own app allow-list.",
            "2. The computer tool is NOT in the vendored CodexRuntime: it is "
            "the ChatGPT desktop app's `Codex Computer Use.app`, wired in as "
            "an MCP server (`mcp_sky`) by the spike. A product lane depends "
            "on that external install.",
            "3. Autocorrect changed the typed MARK: `p2c-…` landed as "
            "`P2c-…` in TextEdit and Notes (TextEdit iCloud autosave files "
            "and the Notes title showed `P2c-59624-14`). Verifiers use "
            "AppleScript `contains`, which ignores case, so attribution to "
            "this run holds — but a STRICT exact-text check would pass only "
            "`finder.reveal`, and the ≥2 clause would NOT be met.",
            "4. `calc.compute` = ok_no_cu: Calculator restored its last "
            "display (`4+7 = 11` from the previous run) on relaunch, and the "
            "agent reported success after only reading state. The "
            "actuation requirement caught it (no false ok). The pre-snapshot "
            "could not see it because Calculator was not running.",
            "5. Side effects outside the sandbox: TextEdit autosaved 5 "
            "MARK documents into iCloud `com~apple~TextEdit/Documents` even "
            "with `close … saving no` (moved to iCloud Trash; each contained "
            "only a MARK); the Notes MARK note is in Notes' Recently "
            "Deleted.",
            "",
            "Implementer recommendation: record **CONDITIONAL**. Conditions: "
            "(a) Jarvis's client owns the per-app approval policy (answers "
            "`mcpServer/elicitation/request`); (b) the product ships or "
            "requires `Codex Computer Use.app`; (c) background-session "
            "behaviour gets verified on jevbench. The mechanical rule says "
            "PROMOTE; the orchestrator/user decides at G7."]
    out += ["", "Surface: app-server only (`thread/start` -> `turn/start`). "
            "`codex exec` (discovery step 6) was not needed and not run — "
            "no exec-surface claim is made.", ""]

    out += ["## Probe (protocol-derived)", ""]
    for k in ("codex_bin", "version_output", "features", "login_status",
              "config_requirements_read", "sol_family", "cu_host"):
        out.append("- %s: `%s`" % (k, json.dumps(probe.get(k))))
    out.append("- effective_config (fresh CODEX_HOME): `%s`"
               % json.dumps(probe.get("effective_config")))
    out += ["", "`configRequirements/read` returned `requirements: null` "
            "VERBATIM — no ComputerUseRequirements are declared on this "
            "machine (no requirements.toml / MDM / cloud requirements). "
            "Declared requirements ≠ writable `Config.computer_use` "
            "(default_app_access + macos/windows tables only).", ""]

    out += ["## Tool inventory per mechanism (zero-turn, "
            "`mcpServerStatus/list`)", ""]
    for mech, a in sorted((meta.get("activation") or {}).items()):
        inv = (a.get("effective_config") or {}).get("tool_inventory") or {}
        for srv, i in sorted(inv.items()):
            out.append("- `%s` / server `%s`: %d tools, CU tools=%s"
                       % (mech, srv, i.get("tool_count", 0),
                          i.get("cu_tools")))
        if a.get("warmup"):
            out.append("  - Sky warm-up (`mcpServer/tool/call list_apps`, "
                       "no model turn): %s" % ["%s %sms" % (
                           "ok" if w["ok"] else "fail", w["ms"])
                           for w in a["warmup"]])
    out += ["", "## Activation checkpoint", "",
            "| mechanism | status | wall ms | CU calls ok/attempted | "
            "detail |", "|---|---|---|---|---|"]
    for r in rows:
        if r.get("kind") == "activation":
            out.append("| %s | %s | %s | %d/%d | %s |" % (
                r["variant"], r["status"], fmt(r.get("wall_ms")),
                len(r.get("cu_evidence") or []),
                len(r.get("cu_attempts") or []), esc(r.get("detail"), 180)))

    out += ["", "## Unattended-approvals matrix (task `textedit.type`)", "",
            "Pinned base for every variant: `%s`. Fresh CODEX_HOME per "
            "variant; mechanism `%s`." % (json.dumps(meta.get(
                "pinned_base")), meta.get("mechanism")), "",
            "| variant | config delta | status | asks | CU tools ok | "
            "zero-click | wall ms | tokens | detail |",
            "|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        if r.get("kind") in ("variant", "scope"):
            out.append("| %s%s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                r["variant"], " (scope: Dictionary)" if r["kind"] == "scope"
                else "", esc(DELTAS.get(r["variant"], "?"), 90),
                r["status"], asks_cell(r), cu_tools(r),
                r.get("zero_click", "-"), fmt(r.get("wall_ms")),
                tok(r) or "-", esc(r.get("detail"), 160)))
    out += ["", "### Approval events (raw, from the event stream)", ""]
    seen = set()
    for r in rows:
        for a in r.get("approvals") or []:
            p = a.get("params") or {}
            key = (r["variant"], a.get("method") or a.get("event"),
                   p.get("message"))
            if key in seen:
                continue
            seen.add(key)
            out.append("- %s/%s: `%s` message=%r meta=%s -> answered %s" % (
                r["variant"], r["task"], a.get("method") or a.get("event"),
                p.get("message"), json.dumps(p.get("_meta")),
                json.dumps(a.get("answered"))))
    out.append("- CU tool errors under approval_policy=never (no request "
               "reached the client): %s" % sorted({
                   esc(e.get("error"), 160) for r in rows
                   if r.get("variant") in ("scoped", "never")
                   for e in r.get("cu_attempts") or [] if e.get("error")}))

    out += ["", "## Canary corpus (variant `%s` — %s)" % (
        meta.get("corpus_variant"), meta.get("corpus_variant_reason")), "",
        "| task | MARK | status | CU tools ok | asks | wall ms | tokens | "
        "independent verify |", "|---|---|---|---|---|---|---|---|"]
    tasks = [r for r in rows if r.get("kind") == "task"]
    for r in tasks:
        out.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
            r["task"], r.get("mark"), r["status"], cu_tools(r),
            asks_cell(r), fmt(r.get("wall_ms")), tok(r) or "-",
            esc((r.get("verify") or {}).get("detail") or r.get("detail"),
                170)))
    ok = [r for r in tasks if r["status"] == "ok"]
    out += ["", "## Measurements", "",
            "- task rows: %d; ok (CU-proven + verified): %d; statuses: %s"
            % (len(tasks), len(ok), {s: sum(1 for r in tasks
                                            if r["status"] == s)
                                     for s in sorted({r["status"]
                                                      for r in tasks})}),
            "- wall ms over ok rows: p50 %s, max %s"
            % (fmt(pct([r["wall_ms"] for r in ok], 50)),
               fmt(max([r["wall_ms"] for r in ok]) if ok else None)),
            "- total tokens over ok rows: p50 %s, max %s"
            % (fmt(pct([tok(r) for r in ok if tok(r)], 50)),
               fmt(max([tok(r) for r in ok if tok(r)] or [0]) or None)),
            "- token breakdown per ok row (input / cached input / output): %s"
            % ["%s %s/%s/%s" % (r["task"], (r.get("tokens") or {}).get(
                "inputTokens"), (r.get("tokens") or {}).get(
                "cachedInputTokens"), (r.get("tokens") or {}).get(
                "outputTokens")) for r in ok],
            "- `zero-click=True` on scoped/never rows means no ask reached a "
            "human; nothing actuated there (codex declined internally).",
            "- TCC prompts observed: %d rows; orphan check: leaked=%s"
            % (sum(1 for r in rows if r.get("tcc")),
               meta.get("procs_leaked")), ""]

    out += ["## Background / multi-user session — labeled hypotheses", "",
            "Labels: **[verified]** measured in this spike; "
            "**[documented]** read from codex's own schema/binary/plugin "
            "files; **[unverified]** hypothesis, no evidence either way.",
            "",
            "- **[verified]** Everything above ran in the logged-in console "
            "session with the user's WindowServer; apps were driven while "
            "hidden/backgrounded (Sky's `get_app_state` launches/targets "
            "apps without bringing them frontmost).",
            "- **[documented]** `allowLockedComputerUse` exists only in "
            "`ComputerUseRequirementsToml` (requirements layer: "
            "requirements.toml / MDM / cloud), next to "
            "`allowPersistentApproval`; `ComputerUseConfigToml` (user "
            "config) has 3 fields only. This machine declares "
            "`requirements: null`.",
            "- **[unverified]** Whether `allowLockedComputerUse` lets the "
            "Sky host actuate while the screen is LOCKED or in a "
            "switched-out session. The Sky bundle ships "
            "`CUALockScreenGuardian.app` **[documented: file exists]**, "
            "suggesting a locked-screen code path; behaviour not tested.",
            "- **[unverified]** Whether a fast-user-switched (non-console) "
            "session keeps a WindowServer the Sky host can actuate. "
            "Needs the `jevbench` user (`sudo "
            "scripts/bench/create-test-user.sh` — human step, not done).",
            "- **[unverified]** Whether TCC grants (Accessibility / Screen "
            "Recording held by `Codex Computer Use.app`) carry to another "
            "user: TCC databases are per-user on macOS, so a background "
            "user would most likely need its own grants — hypothesis, not "
            "measured.",
            "- **[verified]** The CU host is NOT in the vendored "
            "CodexRuntime: it is `~/.codex/computer-use/Codex Computer "
            "Use.app` installed by the ChatGPT desktop app. A jevbench user "
            "would also need that app installed + its per-app approvals.",
            "- What a jevbench run would add: actuation in a switched-out "
            "session, per-user TCC behaviour, lock-screen behaviour with "
            "and without `allowLockedComputerUse` in a requirements.toml.",
            ""]
    pr = prior_runs()
    if pr:
        out += ["## Superseded runs (kept as evidence)", ""] + pr + [""]
    out += ["## Files / commands", "",
            "- `appserver.py` — line-framed JSON-RPC client (no `jsonrpc` "
            "member), allowlist env, decline/allowlist answerers, bounded "
            "reads, group kill.",
            "- `probe.py` (`--no-auth` = negative control, exits 2 with "
            "blocked_env) -> probe block.",
            "- `run.py` — activation -> matrix -> corpus under "
            "`scripts/with-desktop-lock.py`; independent osascript/AX "
            "verifiers.",
            "- `tasks.json` — corpus + verifier specs; `report.py` — this "
            "file; `results/run-*.log` — raw event streams.", ""]
    path = os.path.join(RESULTS_DIR, "REPORT.md")
    with open(path, "w") as f:
        f.write("\n".join(out))
    print("wrote %s — verdict %s (best=%s ok=%d)" % (path, v, best,
                                                    len(best_ok)))


if __name__ == "__main__":
    main()
