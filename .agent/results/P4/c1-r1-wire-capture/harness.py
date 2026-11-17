import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def main():
    if os.environ.get("JARVIS_P4_REAL_APPS") != "approved":
        raise RuntimeError("Controlled desktop approval is required")
    os.umask(0o077)
    output = HERE / "c1-r1-wire-capture"
    output.mkdir(mode=0o700)
    body = output / "request.json"
    ready = output / "debugger-ready"
    metadata = {
        "qualification": False,
        "purpose": "capture exact signed-app request before networking",
        "source": str(HERE / "c1-scroll.py"),
        "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "captured": False,
    }
    spec = importlib.util.spec_from_file_location("c1_capture_scroll", HERE / "c1-scroll.py")
    scroll = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scroll)
    original_load = scroll.load
    debuggers = []
    handles = []

    def load(name, path):
        module = original_load(name, path)
        if path.name != "jev-realapps.py":
            return module
        original_start = module.Session.start_actor

        def start_actor(session):
            actor = original_start(session)
            metadata["owned_actor_pid"] = actor.proc.pid
            condition = (
                '(BOOL)[[[(id)$x0 URL] host] isEqualToString:@"api.typesafe.ai"]'
                ' && (BOOL)[[[(id)$x0 URL] path] isEqualToString:@"/v1/systemone"]'
            )
            command = [
                "xcrun", "lldb", "--batch",
                "-O", 'settings set frame-format "frame ${frame.index}: ${frame.pc}\\n"',
                "--attach-pid", str(actor.proc.pid),
                "-o", "breakpoint set --selector setHTTPBody: --condition " + json.dumps(condition),
                "-o", "script open(" + repr(str(ready)) + ", 'x').write('ready')",
                "-o", "continue",
                "-o", 'expression -l objc -- (BOOL)[(id)$x2 writeToFile:@'
                      + json.dumps(str(body)) + " atomically:NO]",
                "-o", "process kill",
                "-o", "quit",
            ]
            handle = (output / "debugger.log").open("x")
            handles.append(handle)
            debugger = subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT)
            debuggers.append(debugger)
            deadline = time.monotonic() + 20
            while not ready.exists():
                if debugger.poll() is not None:
                    raise RuntimeError("Owned-process debugger setup failed; inspect private log")
                if time.monotonic() >= deadline:
                    raise RuntimeError("Owned-process debugger setup deadline")
                time.sleep(0.1)
            return actor

        module.Session.start_actor = start_actor
        return module

    scroll.load = load
    sys.argv = [
        str(HERE / "c1-scroll.py"), "--receipt",
        str(ROOT / ".agent/results/P12/c1-final-r4-stage.json"),
        "--label", "r2-capture",
    ]
    try:
        scroll.main()
    except Exception as error:
        metadata["harness_exit"] = type(error).__name__
    finally:
        for debugger in debuggers:
            try:
                debugger.wait(timeout=5)
            except subprocess.TimeoutExpired:
                debugger.terminate()
                debugger.wait(timeout=5)
        for handle in handles:
            handle.close()
        if body.exists():
            data = body.read_bytes()
            request = json.loads(data)
            if not {"model", "state", "questions"}.issubset(request):
                raise RuntimeError("Unexpected request shape")
            metadata.update(captured=True, bytes=len(data),
                            body_sha256=hashlib.sha256(data).hexdigest(),
                            question_count=len(request["questions"]))
        (output / "receipt.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata, indent=2))
    return 0 if metadata["captured"] else 1


if __name__ == "__main__":
    sys.exit(main())
