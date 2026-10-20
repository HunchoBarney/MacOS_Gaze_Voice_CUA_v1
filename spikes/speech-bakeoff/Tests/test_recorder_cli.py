#!/usr/bin/env python3
"""Exercise the actual recorder through a PTY; microphone files stay local."""
import hashlib
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import wave


PACKAGE = Path(__file__).resolve().parents[1]
BINARY = PACKAGE / os.environ.get("JARVIS_RECORDER_BINARY", ".build/debug/bakeoff")
CORPUS = PACKAGE / "corpus"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    for args, expected in [
        (["record"], "interactive terminal"),
        (["record", "--only"], "record [--only p01]"),
        (["record", "--bad"], "record [--only p01]"),
        (["mic-check", "--bad"], "mic-check takes no arguments"),
    ]:
        result = subprocess.run(
            [str(BINARY), *args], stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=10,
        )
        assert result.returncode == 1, result
        assert expected in result.stderr, result
        print("PASS clean error:", " ".join(args))

    protected = list((CORPUS / "recordings").glob("*.wav"))
    if (CORPUS / "manifest.json").exists():
        protected.append(CORPUS / "manifest.json")
    before = {p: digest(p) for p in protected}
    existing_files = set((CORPUS / "recordings").glob("*.wav"))
    master, slave = pty.openpty()
    output = bytearray()
    with tempfile.TemporaryDirectory() as cwd:
        # Launch away from the repo root, as people often do in a terminal.
        process = subprocess.Popen(
            [str(BINARY), "record", "--only", "p01"],
            stdin=slave, stdout=slave, stderr=slave, cwd=cwd, start_new_session=True,
        )
        os.close(slave)

        def until(markers, timeout):
            deadline = time.monotonic() + timeout
            start = len(output)
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        chunk = os.read(master, 8192)
                    except OSError:
                        chunk = b""
                    if not chunk:
                        raise AssertionError("recorder exited early:\n" + output.decode(errors="replace"))
                    output.extend(chunk)
                    for marker in markers:
                        if marker in output[start:]:
                            return marker
                if process.poll() is not None:
                    break
            raise AssertionError("recorder stalled:\n" + output.decode(errors="replace"))

        try:
            until([b"Enter when ready"], 10)
            os.write(master, b"\n")
            started = time.monotonic()
            until([b"REC "], 10)
            # Deliberately type buffered Enters during capture. They must not
            # truncate it, approve it, or start another clip.
            os.write(master, b"\n\n\n")
            until([b"Finished the phrase correctly?", b"Too quiet to accept."], 15)
            assert time.monotonic() - started >= 5.5, "capture ended too early"
            assert process.poll() is None, "buffered keys approved a clip"
            os.write(master, b"q\n")
            assert process.wait(timeout=5) == 0
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)
            os.close(master)

    print(output.decode(errors="replace"))
    assert before == {p: digest(p) for p in protected}, "existing corpus changed"
    new_files = set((CORPUS / "recordings").glob("*.wav")) - existing_files
    normalized = [p for p in new_files if not p.name.endswith("-native.wav")]
    assert len(normalized) == 1, new_files
    with wave.open(str(normalized[0])) as wav:
        duration = wav.getnframes() / wav.getframerate()
        assert wav.getframerate() == 16000
        assert abs(duration - 6) < 0.25, duration
    print("PASS PTY capture: full 6s WAV, buffered keys ignored, quit leaves original files and manifest unchanged")


if __name__ == "__main__":
    main()
