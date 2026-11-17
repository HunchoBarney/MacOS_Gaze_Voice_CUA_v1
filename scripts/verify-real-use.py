#!/usr/bin/env python3
"""Score a P3 real-use physical evidence session.

    python3 scripts/verify-real-use.py commands.json turns.jsonl [--attestation attestation.json] [-o result.json]

Walks the scored command list against recorded turn rows in order. A row
verdict is pass / fail / not_observed / attested_fail; latency comes from
release->dispatch and release->settle on scored mutation rows. Typed or
dictation rows are reported but never count toward the physical population.
"""
import json, re, sys, unicodedata
from pathlib import Path

def norm(s):
    s = unicodedata.normalize("NFKD", s).lower()
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9 ]", " ", s)).strip()

def token_overlap(a, b):
    ta, tb = set(norm(a).split()), set(norm(b).split())
    return len(ta & tb) / len(ta) if ta else 0.0

def match_score(heard, say):
    if not heard:
        return 0.0
    nh, ns = norm(heard), norm(say)
    if nh == ns:
        return 1.0
    if nh.replace(" ", "") == ns.replace(" ", ""):
        return 0.99
    sym = max(token_overlap(heard, say), token_overlap(say, heard))
    return sym if sym >= 0.7 else 0.0

def main():
    args = sys.argv[1:]
    out = None
    attestation = {}
    if "-o" in args:
        i = args.index("-o"); out = args[i + 1]; del args[i:i + 2]
    if "--attestation" in args:
        i = args.index("--attestation"); attestation = json.load(open(args[i + 1])); del args[i:i + 2]
    commands = json.load(open(args[0]))["rows"]
    turns = [json.loads(l) for l in Path(args[1]).read_text().splitlines() if l.strip()]

    non_voice = [t for t in turns if t.get("input") not in ("voice", None)]
    voice = [t for t in turns if t.get("input") == "voice"]

    results, used, lat = [], set(), {"dispatch_ms": [], "settle_ms": []}
    for cmd in commands:
        n, say, expect = cmd["n"], cmd["say"], cmd.get("expect", {})
        scored = cmd.get("scored", True)
        row = {"n": n, "intended": say, "kind": cmd["kind"]}
        # Best unused match — real sessions reorder commands and ad-lib
        # extra turns; a used row can only satisfy one command.
        match, best, best_i = None, 0.0, None
        for i, t in enumerate(voice):
            if i in used:
                continue
            s = match_score(t.get("heard", ""), say)
            if s > best:
                match, best, best_i = t, s, i
        drift = match is not None and norm(match.get("heard", "")) != norm(say)
        if best_i is not None:
            used.add(best_i)
        if not scored:
            row.update(verdict="warmup", heard=match.get("heard") if match else None,
                       consumed=match is not None)
            results.append(row)
            continue
        att = attestation.get("rows", {}).get(str(n)) if attestation else None
        if match is None:
            row.update(verdict="not_observed", heard=None)
            results.append(row); continue
        works = match.get("works", [])
        dispatches = match.get("dispatches", 0)
        outcomes = [w.get("outcome") for w in works]
        fails = []
        if norm(match.get("heard", "")) != norm(say) and token_overlap(match.get("heard", ""), say) < 1.0:
            drift = True
        if expect.get("min_works", 0) > len(works):
            fails.append(f"works_created={len(works)} < {expect['min_works']}")
        if expect.get("max_dispatches") is not None and dispatches > expect["max_dispatches"]:
            fails.append(f"dispatches={dispatches} > {expect['max_dispatches']}")
        if expect.get("outcomes") == ["none"]:
            bad = [w for w in works if w.get("outcome") in ("done", "alreadyDone", "uncertain")]
            if bad:
                fails.append(f"unexpected mutation outcome {bad[0]['outcome']}")
        else:
            allowed = set(expect.get("outcomes", []))
            bad = [o for o in outcomes if o not in allowed]
            if bad:
                fails.append(f"outcome {bad[0]} not in {sorted(allowed)}")
        app = expect.get("app")
        if app and not any(w.get("application") == app for w in works):
            fails.append(f"no work targeted {app} (got {[w.get('application') for w in works]})")
        release = match.get("released_uptime") or match.get("submitted_uptime")
        if release and match.get("trace"):
            last = max(e["monotonic"] for e in match["trace"])
            match["effect_ms"] = (last - release) * 1000
            lat["settle_ms"].append(match["effect_ms"])
        if match.get("dispatch_ms") is not None:
            lat["dispatch_ms"].append(match["dispatch_ms"])
        verdict = "fail" if fails else "pass"
        if att is not None:
            if att.get("ok") is False and verdict == "pass":
                verdict = "attested_fail"
                fails.append(att.get("note", "user attested failure"))
            elif att.get("ok") is True and verdict == "fail":
                verdict = "attested_pass"
                fails.append("MACHINE-VERIFICATION DIVERGENCE: " + att.get("note", ""))
        row.update(verdict=verdict, heard=match.get("heard"), heard_drift=drift,
                   route=match.get("route"), terminal=match.get("terminal"),
                   works=len(works), dispatches=dispatches, outcomes=outcomes,
                   dispatch_ms=match.get("dispatch_ms"), settle_ms=match.get("settle_ms"),
                   failures=fails)
        results.append(row)

    def med(xs):
        return sorted(xs)[len(xs) // 2] if xs else None
    scored_rows = [r for r in results if r["verdict"] != "warmup"]
    summary = {
        "scored": len(scored_rows),
        "passed": sum(1 for r in scored_rows if r["verdict"] == "pass"),
        "failed": sum(1 for r in scored_rows if r["verdict"] in ("fail", "attested_fail")),
        "not_observed": sum(1 for r in scored_rows if r["verdict"] == "not_observed"),
        "heard_drift": sum(1 for r in results if r.get("heard_drift")),
        "non_voice_turns": len(non_voice),
        "voice_turns": len(voice),
        "unmatched_voice_turns": [t.get("heard") for i, t in enumerate(voice) if i not in used],
        "median_dispatch_ms": med(lat["dispatch_ms"]),
        "median_settle_ms": med(lat["settle_ms"]),
        "max_settle_ms": max(lat["settle_ms"], default=None),
    }
    print(f"{'n':>3} {'verdict':<14} {'route':<10} {'term':<14} {'heard'}")
    for r in results:
        print(f"{r['n']:>3} {r['verdict']:<14} {str(r.get('route')):<10} "
              f"{str(r.get('terminal')):<14} {r.get('heard')!r}"
              + (f"  <-- {r['failures']}" if r.get("failures") else ""))
    print(json.dumps(summary, indent=2))
    if out:
        Path(out).write_text(json.dumps({"schema_version": 1, "summary": summary,
                                         "rows": results}, indent=2))

if __name__ == "__main__":
    main()
