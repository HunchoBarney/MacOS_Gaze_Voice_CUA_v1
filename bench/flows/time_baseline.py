"""Time your own mouse-and-keyboard baseline for the Phase 0 flows.

Run it in a Terminal you can see: python3 bench/flows/time_baseline.py
For each flow it prints the task, waits for Return to start, and stops on
the next Return once the end state is on screen. Do a practice run first;
JARA-41 asks for three timed runs per flow. Only flow names and seconds are
written, to bench/results/baseline-<UTC>.jsonl. Nothing is automated: you
move the mouse and press the keys yourself.
"""
import json
import pathlib
import sys
import time

TASKS = {
    "open_app": "Open Calculator the way you normally would.",
    "click_named": "Click the Reply button in a Mail message.",
    "show_names": "Find out the names of three unlabelled toolbar icons.",
    "lost_window": "Bring back a window that is minimized or on another desktop.",
    "switch_desktop": "Go to the next desktop.",
}


def main() -> int:
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    out = pathlib.Path(__file__).resolve().parent.parent / "results"
    out.mkdir(exist_ok=True)
    path = out / time.strftime("baseline-%Y%m%dT%H%M%SZ.jsonl", time.gmtime())
    with path.open("w") as f:
        for flow, task in TASKS.items():
            for run in range(runs):
                input(f"\n[{flow} {run + 1}/{runs}] {task}\nPress Return to start.")
                start = time.monotonic()
                input("Press Return when it's done.")
                seconds = time.monotonic() - start
                f.write(json.dumps({"v": 1, "flow": flow, "run": run, "seconds": round(seconds, 3)}) + "\n")
                print(f"{seconds:.2f} s")
    print(f"\nwrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
