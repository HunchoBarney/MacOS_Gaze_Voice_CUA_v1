"""Mouse-and-keyboard baselines for the Phase 0 flows (JARA-41).

A keystroke-level model (Card, Moran and Newell 1980; Kieras's KLM guide):
deciding (M) 1.2 s, pointing (P) 1.1 s, a key (K) 0.28 s, moving a hand
between mouse and keyboard (H) 0.4 s, a click (B) 0.2 s. For users 65 and
over, JARA-41 doubles P and uses 0.6 s per key (Hertzum and Hornbaek 2010).
These are model predictions, not measurements. bench/flows/time_baseline.py
records a person's own times for the same flows.
"""

ADULT = {"M": 1.2, "P": 1.1, "K": 0.28, "H": 0.4, "B": 0.2, "T": 1.0}
OLDER = {"M": 1.2, "P": 2.2, "K": 0.6, "H": 0.4, "B": 0.2, "T": 1.0}

# Each flow is the operator sequence an expert uses without Jarvis.
# T is macOS's tooltip delay (about 1 s) while hovering an unlabelled icon.
FLOWS = {
    "open_app": {
        "how": "Spotlight: Cmd-Space, type 'calc', Return",
        "ops": "M K K K K K K K",
    },
    "click_named": {
        "how": "decide, reach for the mouse, point at Reply, click",
        "ops": "M H P B",
    },
    "show_names": {
        "how": "hover three unlabelled toolbar icons until each tooltip shows",
        "ops": "M H P T P T P T",
    },
    "lost_window": {
        "how": "Mission Control (F3), search the spaces, point, click, then Cmd-Tab check",
        "ops": "M K M P B M K K",
    },
    "switch_desktop": {
        "how": "Control-Right Arrow",
        "ops": "M K K",
    },
}


def seconds(ops: str, table: dict) -> float:
    return round(sum(table[op] for op in ops.split()), 2)


def baselines() -> dict:
    return {
        flow: {
            "how": spec["how"],
            "ops": spec["ops"],
            "adult_s": seconds(spec["ops"], ADULT),
            "older_s": seconds(spec["ops"], OLDER),
        }
        for flow, spec in FLOWS.items()
    }


if __name__ == "__main__":
    for flow, row in baselines().items():
        print(f"{flow:15} adult {row['adult_s']:5.2f} s  65+ {row['older_s']:5.2f} s  ({row['how']})")
