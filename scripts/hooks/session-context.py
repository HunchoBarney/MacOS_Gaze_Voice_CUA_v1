#!/usr/bin/env python3
"""SessionStart hook: inject a one-line pointer to the .agent/ harness
so every session in this repo knows where the source of truth lives.

Prints hookSpecificOutput JSON on stdout; always exits 0.
"""
import json
import os

ctx = ("This repo runs the .agent/ harness. Read .agent/PROGRAM.md "
       "(source of truth for done) and .agent/PLANS.md (ExecPlan + gate "
       "rules) before planning or writing. Phase work follows the G1–G7 "
       "gate loop; check .agent/PROGRESS.md for the current state.")
if os.path.isdir(".agent"):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": ctx
        }
    }))
