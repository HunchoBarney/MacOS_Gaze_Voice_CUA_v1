#!/usr/bin/env python3
"""P3 predicates. Exit 0 verified, 1 failed, 2 blocked; never implicitly deploy/capture."""
import argparse
from collections import Counter
import fnmatch
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / ".agent/results/P3"
MANIFEST = ROOT / "Tests/Fixtures/P3/manifest.json"
INTEGRATION_CASES = {
    f"-[VoiceOneBrainTests {name}]" for name in (
        "testAmbiguousMultiwordAskReplyNeverRequestsReasoning",
        "testLocalHitDoesNotNeedAKeySocketOrScreenshot",
        "testMissUsesOneResponseWithoutCloudTranscriptionOrImages",
        "testNaturalAppRequestUsesCanonicalSurfaceAndCapturedIdentityOnce",
        "testSemanticNoMatchContinuesOriginalRemoteOwnerOnce",
        "testOldResponseWithNewCallIDCannotActDuringNewMiss",
        "testOutcomeOnlyResponseHasToolsDisabledAndCannotAct",
        "testRawIncrementalAndDoneDuplicatesSpendOnlyOneExecutorPermit",
        "testRawRemoteReplyCannotSelectBetweenUnselectedCurrentAsks",
        "testRemoteArgumentMutationIsBlockedWithoutExecutorCall",
        "testResolvedTargetCannotBeSilentlyDroppedByAnUnsupportedExecutor",
        "testUnknownConfusableClarifiesWithoutReasoningOrExecution",
    )
}


class Blocked(Exception):
    pass


def read(path):
    if not path.is_file():
        raise Blocked(f"missing required artifact: {path}")
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes():
    paths = list((ROOT / "Sources").rglob("*.swift")) + [ROOT / "Package.swift", ROOT / "Package.resolved"]
    return {str(path.relative_to(ROOT)): sha(path) for path in sorted(paths) if path.is_file()}


def record_build():
    binary = ROOT / ".build/release/JevVoice"
    assert binary.is_file(), "release executable missing"
    sources = source_hashes()
    assert all((ROOT / path).stat().st_mtime <= binary.stat().st_mtime for path in sources), "source newer than artifact"
    data = {"schema_version": 1, "configuration": "release", "artifact_sha256": sha(binary),
            "artifact": str(binary), "source_hashes": sources}
    (RESULTS / "build.json").write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    print("PASS release artifact/source binding recorded")

def current_build():
    build = read(RESULTS / "build.json")
    assert build["source_hashes"] == source_hashes(), "source changed since reviewed build"
    assert sha(ROOT / ".build/release/JevVoice") == build["artifact_sha256"], "release binary changed"
    return build


def review_file_digest(path):
    if path != ROOT / ".agent/acceptance/P3.json":
        return sha(path)
    contract = read(path)
    assert isinstance(contract, dict) and isinstance(contract.get("criteria"), list), "malformed P3 acceptance contract"
    assert all(isinstance(row, dict) for row in contract["criteria"]), "malformed P3 acceptance criterion"
    contract = {**contract, "criteria": [
        {key: value for key, value in row.items() if key not in {"passes", "evidence"}}
        for row in contract["criteria"]
    ]}
    encoded = json.dumps(contract, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    return hashlib.sha256(b"p3-contract-v1\n" + encoded).hexdigest()


def review_matches(build):
    review = read(RESULTS / "review.json")
    assert review["code_delta_pass"] is True and review["artifact_sha256"] == build["artifact_sha256"]
    assert review["source_hashes"] == build["source_hashes"], "review predates source"
    assert review.get("acceptance_digest_kind") == "p3-contract-v1", "review acceptance digest is unversioned"
    files = review["reviewed_files"]
    assert {"scripts/verify-p3.py", ".agent/acceptance/P3.json"}.issubset(files)
    assert all(review_file_digest(ROOT / path) == expected for path, expected in files.items()), "reviewed contract/code changed"
    return review


def executable_uuid(binary):
    text = subprocess.check_output(["/usr/bin/dwarfdump", "--uuid", str(binary)], text=True, timeout=15)
    uuids = re.findall(r"UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)", text)
    assert uuids, "Mach-O build UUID missing"
    return sorted(uuids)


def installed_build(build):
    receipt = read(RESULTS / "install.json")
    review_matches(build)
    expected = Path.home() / "jarvis-local/Jev Voice.app"
    assert Path(receipt["bundle"]).resolve() == expected.resolve(), "unexpected installed bundle"
    binary = expected / "Contents/MacOS/JevVoice"
    assert receipt["schema_version"] == 1 and receipt["codesign_verified"]
    assert receipt["source_artifact_sha256"] == build["artifact_sha256"]
    assert receipt["source_hashes"] == build["source_hashes"], "installation source is stale"
    assert receipt["installed_artifact_sha256"] == sha(binary), "installed executable changed"
    assert receipt["review_receipt_sha256"] == sha(RESULTS / "review.json")
    assert executable_uuid(binary) == executable_uuid(ROOT / ".build/release/JevVoice"), "wrong installed build"
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(expected)],
                   check=True, capture_output=True, timeout=60)
    return receipt


def record_install():
    build = current_build()
    review_matches(build)
    bundle = Path.home() / "jarvis-local/Jev Voice.app"
    assert executable_uuid(bundle / "Contents/MacOS/JevVoice") == executable_uuid(ROOT / ".build/release/JevVoice")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)],
                   check=True, capture_output=True, timeout=60)
    data = {"schema_version": 1, "bundle": str(bundle),
            "source_artifact_sha256": build["artifact_sha256"],
            "source_hashes": build["source_hashes"], "codesign_verified": True,
            "installed_artifact_sha256": sha(bundle / "Contents/MacOS/JevVoice"),
            "review_receipt_sha256": sha(RESULTS / "review.json")}
    (RESULTS / "install.json").write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    print("PASS reviewed signed installation recorded")


def frontdoor():
    build = read(RESULTS / "build.json")
    binary = ROOT / ".build/release/JevVoice"
    assert sha(binary) == build["artifact_sha256"] and build["source_hashes"] == source_hashes()
    private = RESULTS / "audio/manifest.json"
    before = sha(private) if private.is_file() else None
    checks = [
        (["--p3-record-holdouts"], 2, "retired from this app"),
        (["--p3-voice-replay"], 2, "retired from this app"),
        (["--p3-live", "--p3-record-holdouts"], 2, "retired from this app"),
        (["--p3-live"], 1, "interactive terminal"),
        (["--p3-live", "--self-test", "--out", str(RESULTS / "live.json")], 1, "self-test.json"),
    ]
    rows = []
    for flags, code, expected in checks:
        result = subprocess.run([str(binary), *flags], cwd=ROOT, input="", text=True,
                                capture_output=True, timeout=15)
        assert result.returncode == code and expected in result.stderr, "CLI refusal did not use the headless front door"
        rows.append({"flags": flags, "exit": result.returncode, "verified": True})
    assert (sha(private) if private.is_file() else None) == before, "CLI refusal changed private recordings"
    (RESULTS / "frontdoor.json").write_text(json.dumps(
        {"schema_version": 1, "artifact_sha256": build["artifact_sha256"], "checks": rows,
         "recording_performed": False, "inference_performed": False}, indent=2) + "\n")
    print("PASS headless CLI guard front doors; no recording/inference")


def owned_patterns():
    text = (ROOT / ".agent/phases/P3-voice-one-brain.md").read_text()
    return re.search(r"## Owned paths\s+```text\s+(.*?)```", text, re.S).group(1).splitlines()


def scope():
    patterns = owned_patterns()
    owned = lambda path: any(fnmatch.fnmatchcase(path, p) for p in patterns)
    baseline = read(RESULTS / "inherited-baseline.json")
    old = {entry["path"]: entry for entry in baseline["entries"] if not owned(entry["path"])}
    raw = subprocess.check_output(["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"], cwd=ROOT)
    entries = iter(raw.split(b"\0"))
    current = set()
    for entry in entries:
        if not entry:
            continue
        status, name = entry[:2].decode(), entry[3:].decode()
        if "R" in status or "C" in status:
            next(entries)
        if not owned(name):
            current.add(name)
    assert current == old.keys(), "non-owned path set differs from inherited baseline"
    for name, entry in old.items():
        path = ROOT / name
        if "link" in entry:
            assert path.is_symlink() and str(path.readlink()) == entry["link"], name
        elif entry.get("missing"):
            assert not path.exists(), name
        else:
            assert path.is_file() and sha(path) == entry["sha256"], name
    print(f"PASS scope: {len(old)} inherited non-owned paths preserved, including untracked hashes")


def verify_integration_population(integration):
    rows = integration["cases"]
    assert Counter(row["name"] for row in rows) == Counter(INTEGRATION_CASES), \
        "missing, duplicate or unexpected production integration case"
    assert all(row["failures"] == 0 for row in rows), "production integration case failed"


def accuracy():
    manifest = read(MANIFEST)
    data = read(RESULTS / "unit-evidence.json")
    assert data["schema_version"] == 1 and data["manifest_sha256"] == sha(MANIFEST)
    expected = {}
    for group in ("clear", "negative", "boundary"):
        for case in manifest[group]:
            expected[case["id"]] = (group, case)
    rows = data["rows"]
    assert Counter(row["case_id"] for row in rows) == Counter(expected.keys()), "missing/duplicate unit case"
    for row in rows:
        group, case = expected[row["case_id"]]
        assert row["population"] == group
        route = case.get("route", manifest["clear_rules"]["route"] if group == "clear" else None)
        count = case.get("dispatch_count", 1 if group == "clear" else 0)
        assert row["actual_route"] == route and row["actual_dispatches"] == count, row["case_id"]
        if "reason" in case:
            assert row["reason"] == case["reason"], row["case_id"]
        slots = row["slots"]
        if "keys" in case:
            assert slots["keys"] == "+".join(case["keys"])
        for key, value in case.get("slots", {}).items():
            assert slots[key].lower() == str(value).lower(), row["case_id"]
    print("PASS session fixtures: 50 autonomous clear +14 negative +4 boundary decisions/counters")
    integration = read(RESULTS / "voice-integration.json")
    assert integration["schema_version"] == 1 and integration["failures"] == 0
    assert integration["run_id"] == data["run_id"], "stale integration evidence"
    verify_integration_population(integration)
    assert integration["production_decoder"] and integration["production_lane"]
    assert integration["source_sha256"] == sha(ROOT / "Sources/JevVoice/Voice/RealtimeVoiceLane.swift"), "integration evidence predates current lane source"
    print("PASS production lane/decoder integration")


def contracts():
    paths = [
        "Sources/JevVoice/Voice/RealtimeVoiceLane.swift",
        "Sources/JevVoice/Voice/RealtimeVoiceClient.swift",
        "Sources/JevVoice/Drive/VoiceTaskCoordinator.swift",
        "Sources/JevVoice/Drive/DriveLoop.swift",
        "Sources/JevVoice/main.swift",
    ]
    banned = ("localClaims", "bypassLocalClaim", "AppleFMIntentClassifier", "LocalChooserEngine", "gpt-4o")
    for relative in paths:
        text = (ROOT / relative).read_text()
        assert not any(word in text for word in banned), f"legacy path remains: {relative}"
    data = read(RESULTS / "contract-review.json")
    assert data["schema_version"] == 1 and data["tool_count"] == 9 and data["failures"] == 0
    assert set(data["consumers"]) == {"P5", "P6", "P7", "P11"}
    assert len(set(data["tools"])) == 9
    assert data["source_sha256"] == sha(ROOT / "Sources/JevVoice/Voice/RealtimeVoiceClient.swift")
    assert data["run_id"] == read(RESULTS / "unit-evidence.json")["run_id"]
    print("PASS tool schemas, retired paths and consumer review")


def hygiene():
    patterns = owned_patterns()
    known = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=ROOT, text=True).splitlines()
    candidate = [p for p in known if any(fnmatch.fnmatchcase(p, pattern) for pattern in patterns)]
    token = re.compile(r"sk-(?:proj-)?[A-Za-z0-9_-]{32,}|Bearer [A-Za-z0-9._-]{24,}")
    for relative in candidate:
        path = ROOT / relative
        assert path.suffix not in {".wav", ".pcm", ".pyc"}, "private/generated artifact would be tracked"
        if path.is_file() and not path.is_symlink():
            assert not token.search(path.read_text(errors="replace")), f"credential-shaped content, values withheld: {relative}"
    frozen = (RESULTS / "frozen-manifest.sha256").read_text().split()[0]
    assert frozen == sha(MANIFEST), "frozen manifest changed after implementation began"
    print(f"PASS hygiene/frozen manifest: {len(candidate)} owned candidate files")


def replay(args):
    raise Blocked("Local speech replay is retired from this app. Use the historical developer checkout at "
                  "073fedeb1101d50466ff46b7c007d085e08d9e15.")


def read_attempts(data):
    name = data["attempts_file"]
    assert Path(name).name == name and name == f"live-attempts-{data['run_id']}.jsonl"
    path = RESULTS / name
    assert sha(path) == data["attempts_sha256"], "attempts ledger changed"
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def validate_physical_population(data, attempts):
    assert attempts and all(r["run_id"] == data["run_id"] and r["source"] == "physical"
                            and r["artifact_sha256"] == data["artifact_sha256"] for r in attempts)
    assert all(r["wrong_critical_actions"] == 0 for r in attempts), "safety failure in any phase cannot pass"
    scored = [r for r in attempts if r["phase"] == "scored"]
    assert scored == data["rows"], "receipt omitted/reordered scored attempts"
    assert all(r["status"] == "ok" and r["attempt"] == 1 for r in scored), "failed scored trial cannot be retried into PASS"
    cold = [r for r in attempts if r["phase"] == "cold"]
    assert len(cold) == 1 and cold[0] == data["cold"] and cold[0]["status"] == "ok"
    assert cold[0]["verification"]["passed"] and cold[0]["effect_count"] == cold[0]["dispatch_count"] == 1
    assert len(data["warmups"]) == 2
    warm_attempts = [r for r in attempts if r["phase"] == "warmup"]
    for rep, warm in enumerate(data["warmups"], 1):
        assert warm in warm_attempts and warm["repetition"] == rep and warm["status"] == "ok"
        assert warm["verification"]["passed"] and warm["effect_count"] == warm["dispatch_count"] == 1
    for row in [data["cold"], *data["warmups"]]:
        proof, marks = row["verification"], row["marks"]
        assert row["case_id"] == "live-c1" and row["turn_id"] and row["generation"] > 0
        assert proof["kind"] == "frontmost_pid" and proof["app_id"] == "com.apple.calculator"
        assert proof["pid"] > 0 and proof["baseline_frontmost_pid"] != proof["pid"]
        assert marks["fn_up"] <= marks["dispatch"] <= marks["effect"]
    assert all(r["phase"] in {"cold", "warmup", "scored"} for r in attempts)


def live(args):
    path = ROOT / (args.out or ".agent/results/P3/normal-live.json")
    if not path.is_file():
        raise Blocked("normal-app physical run not supplied; user Fn qualification remains open")
    data = read(path)
    if data.get("report_kind") == "normal_app_voice_reference":
        target = (ROOT / data["run_report"]).resolve()
        assert target.is_relative_to(RESULTS / "normal-voice-qualification")
        assert sha(target) == data["report_sha256"], "physical report reference changed"
        path, data = target, read(target)
    assert data.get("report_kind") == "normal_app_voice_physical", \
        "local-only/typed/diagnostic coverage cannot satisfy normal physical acceptance"
    assert data.get("source") == "physical" and data.get("schema_version") == 1
    if not data.get("human_confirmed"):
        raise Blocked("human normal-app physical gate incomplete")
    build = current_build()
    installed = installed_build(build)
    directory = RESULTS / "normal-voice-qualification"
    spec = importlib.util.spec_from_file_location("p3_normal_report", directory / "normal_report.py")
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(directory))
    try:
        spec.loader.exec_module(module)
        summary = module.validate_report(path, build, installed,
            install_sha=sha(RESULTS / "install.json"), manifest_sha=sha(MANIFEST))
    finally:
        sys.path.pop(0)
    print("PASS normal-app physical coverage, separate local autonomy and unchanged budgets:", summary)


def validate_legacy_live_protocol(args):
    live_path = ROOT / (args.out or ".agent/results/P3/live.json")
    if not live_path.is_file():
        raise Blocked("physical run not supplied; deployment and user Fn trials require explicit authorization")
    data = read(live_path)
    assert data.get("report_kind") not in ("local_voice_trial_diagnostic", "normal_controller_typed_routing"), \
        "diagnostic coverage cannot satisfy physical acceptance"
    assert data["schema_version"] == 1 and data["source"] == "physical"
    if not data.get("human_confirmed"):
        raise Blocked("human physical gate incomplete")
    build = current_build()
    installed = installed_build(build)
    assert data["artifact_sha256"] == build["artifact_sha256"]
    assert data["executed_artifact_sha256"] == installed["installed_artifact_sha256"]
    assert data["install_receipt_sha256"] == sha(RESULTS / "install.json")
    validate_physical_population(data, read_attempts(data))
    rows = data["rows"]
    expected = {(f"live-c{case}", repetition) for case in range(1, 5) for repetition in range(1, 6)}
    expected |= {(f"live-n{case}", 1) for case in range(1, 5)}
    assert Counter((r["case_id"], r["repetition"]) for r in rows) == Counter(expected)
    dispatch_ms, effect_ms = [], []
    for row in rows:
        assert row["source"] == "physical" and row["artifact_sha256"] == data["artifact_sha256"]
        assert row["status"] == "ok" and row["wrong_critical_actions"] == 0
        assert row["turn_id"] and row["generation"] > 0
        marks = row["marks"]
        if row["case_id"].startswith("live-c"):
            assert row["dispatch_count"] == 1 and row["effect_count"] == 1
            observed = row["verification"]
            assert observed["kind"] == "frontmost_pid" and observed["passed"]
            assert observed["app_id"] == "com.apple.calculator" and observed["pid"] > 0
            assert observed["baseline_frontmost_pid"] != observed["pid"]
            assert marks["fn_up"] <= marks["dispatch"] <= marks["effect"]
            dispatch_ms.append((marks["dispatch"] - marks["fn_up"]) * 1000)
            effect_ms.append((marks["effect"] - marks["fn_up"]) * 1000)
        else:
            assert row["dispatch_count"] == 0 and row["command_effect_count"] == 0
            assert row["verification"]["passed"]
            if row["case_id"] == "live-n3":
                assert row["verification"]["kind"] == "owned_literal_delivery"
                # Dictation must deliver the transcript byte-exact — the sha of
                # what landed in the owned field equals the sha of what ASR
                # heard. Pinning the literal itself would fail honest ASR
                # casing/punctuation ("Open Calculator.").
                assert row["verification"]["delivered_sha256"] == row["transcript_sha256"]
                assert row["actual_route"] == "dictation"
                assert row["verification"]["fixture_run_id"] == data["run_id"]
            else:
                assert row["verification"]["kind"] == "no_dispatch"
    assert len(dispatch_ms) == len(effect_ms) == 20
    assert all(math.isfinite(value) for value in dispatch_ms + effect_ms)
    assert statistics.median(dispatch_ms) <= 300 and statistics.median(effect_ms) < 500
    print("PASS historical local-only protocol; NOT normal-app physical acceptance")

def validate_remote_execution(data, build):
    required = ("executed_executable", "executed_artifact_sha256", "executed_build_uuids", "source_hashes")
    assert all(key in data for key in required), "remote execution binding missing"
    binary = Path(data["executed_executable"]).resolve()
    bundle = binary.parents[2]
    local = (Path.home() / "jarvis-local").resolve()
    assert bundle.name == "Jev Voice.app" and binary == bundle / "Contents/MacOS/JevVoice"
    assert bundle.parent == local or bundle.parent.parent == local, "remote bundle outside local qualification roots"
    assert binary.is_file() and sha(binary) == data["executed_artifact_sha256"], "remote executed bytes changed"
    assert data["source_hashes"] == build["source_hashes"], "remote source binding stale"
    actual = executable_uuid(binary)
    assert actual == executable_uuid(ROOT / ".build/release/JevVoice"), "remote ran another build"
    assert data["executed_build_uuids"] == [f"{uuid} ({arch})" for uuid, arch in actual]
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)],
                   check=True, capture_output=True, timeout=60)


def validate_remote_protocol(data):
    rows = {row["case_id"]: row for row in data["rows"]}
    assert len(rows) == len(data["rows"]) == 4
    assert set(rows) == {"safe-miss", "cancel", "stale-response", "outcome-only"}
    tape = data["outbound"]
    requests = [frame for frame in tape if frame["kind"] == "response.create"]
    assert len(requests) == 5 and len({frame["request_id"] for frame in requests}) == 5
    assert Counter(frame["case_id"] for frame in requests) == Counter({
        "safe-miss": 1, "cancel": 1, "stale-response": 2, "outcome-only": 1})
    assert all(frame["text_only"] is True for frame in requests)
    for case, row in rows.items():
        stage = {"safe-miss": "safe", "cancel": "cancel", "outcome-only": "outcome", "stale-response": "new"}[case]
        request = [frame for frame in requests if frame["case_id"] == case and frame["stage"] == stage]
        assert len(request) == 1 and request[0]["request_id"] == row["request_id"]
        outputs = [frame for frame in tape if frame["kind"] == "conversation.item.create"
                   and frame.get("function_output_call_id") and frame["case_id"] == case and frame["stage"] == stage]
        expected = 1 if case in {"safe-miss", "stale-response"} else 0
        assert row["dispatch_count"] == len(outputs) == expected
        assert len({frame["function_output_call_id"] for frame in outputs}) == len(outputs)
    outcome = rows["outcome-only"]
    assert outcome["owning_turn_id"] is None and outcome["source_turn_id"] == rows["safe-miss"]["turn_id"]
    assert outcome["turn_id"] == outcome["source_turn_id"] and outcome["tools_disabled"] is True
    assert next(frame for frame in requests if frame["case_id"] == "outcome-only")["tools_disabled"] is True
    assert rows["cancel"]["cancellation_kind"] == "owning_connection_closed"
    cancel_wire = next(frame for frame in requests if frame["case_id"] == "cancel")["wire_id"]
    assert cancel_wire
    closure = [frame for frame in tape if frame["kind"] == "transport.closed" and frame["wire_id"] == cancel_wire]
    assert len(closure) == 1 and closure[0]["socket_cancel_requested"] is True
    assert closure[0]["session_invalidated"] is True
    stale = rows["stale-response"]
    assert stale["old_connection_generation"] != stale["connection_generation"]
    assert stale["old_server_response_id"] != stale["server_response_id"]
    old_request = [frame for frame in requests if frame["case_id"] == "stale-response" and frame["stage"] == "old"]
    assert len(old_request) == 1 and old_request[0]["request_id"] == stale["old_request_id"]
    assert stale["old_request_id"] != stale["request_id"] and stale["old_dispatch_count"] == 0
    assert not any(frame.get("function_output_call_id") for frame in tape
                   if frame.get("case_id") == "stale-response" and frame.get("stage") == "old")
    assert re.fullmatch(r"[a-f0-9]{64}", stale["replayed_frame_sha256"])
    assert stale["local_replay_count"] == 2 and stale["network_replay"] is False
    captured = [frame for frame in tape if frame.get("direction") == "inbound"
                and frame["kind"] == "response.function_call_arguments.done"
                and frame.get("case_id") == "stale-response" and frame.get("stage") == "old"
                and frame.get("server_response_id") == stale["old_server_response_id"]
                and frame.get("server_call_id") == stale["old_call_id"]
                and frame.get("raw_frame_sha256") == stale["replayed_frame_sha256"]]
    assert len(captured) == 1
    assert data["ingress"]["overflow"] is False
    ingress = data["ingress"]["frames"]
    created = [frame for frame in ingress if frame["kind"] == "response.created"]
    assert len(created) == len({frame["response_id"] for frame in created}) == 5
    owners = [(row["server_response_id"], row["connection_generation"]) for row in rows.values()]
    owners.append((stale["old_server_response_id"], stale["old_connection_generation"]))
    assert all(sum(frame["response_id"] == response and frame["connection_generation"] == generation
                   for frame in created) == 1 for response, generation in owners)
    for case in ("safe-miss", "outcome-only", "stale-response"):
        row = rows[case]
        assert any(frame["kind"] == "response.done" and frame.get("response_id") == row["server_response_id"]
                   and frame["connection_generation"] == row["connection_generation"] for frame in ingress)
    replay = [frame for frame in data["ingress"]["frames"]
              if frame["kind"] == "response.function_call_arguments.done"
              and frame["connection_generation"] == stale["old_connection_generation"]
              and frame["response_id"] == stale["old_server_response_id"]
              and stale["old_call_id"] in frame["call_ids"]]
    assert len(replay) == 2


def remote(args):
    path = ROOT / (args.out or ".agent/results/P3/remote.json")
    if not path.is_file():
        raise Blocked("remote server trial absent; separate explicit authorization required")
    data = read(path)
    if not data.get("remote_live_authorized"):
        raise Blocked("remote trial lacks explicit user authorization")
    build = current_build()
    assert data["schema_version"] == 1 and data["source"] == "server-live"
    assert data["artifact_sha256"] == build["artifact_sha256"]
    assert data["verification_kind"] == "production-realtime-server"
    assert data["status"] == "passed", "remote attempt failed or incomplete"
    validate_remote_execution(data, build)
    validate_remote_protocol(data)
    auth = read(RESULTS / "remote-evidence/authorization.json")
    assert auth["id"] == data["authorization_id"]
    assert auth["scope"] == "p3-openai-realtime-fixed-text-no-desktop"
    assert auth["maximum_responses"] <= 8
    assert auth["reserved_responses"] == len(auth["requests"]) <= auth["maximum_responses"]
    assert all(auth["approved_at"] <= row["reserved_at"] <= auth["expires_at"] for row in auth["requests"])
    reserved = {row["request_id"] for row in auth["requests"]}
    cases = {"safe-miss", "cancel", "stale-response", "outcome-only"}
    assert Counter(r["case_id"] for r in data["rows"]) == Counter(cases)
    for row in data["rows"]:
        assert row["request_id"] in reserved
        assert all(row[k] for k in ("request_id", "server_response_id", "turn_id", "connection_generation"))
        assert row["verification_passed"] is True
        assert row["wrong_critical_actions"] == row["duplicate_dispatches"] == 0
    print("PASS separately authorized production-server trial")


NORMAL_ROUTING_CASES = [
    ("open Calculator", "com.apple.calculator", False),
    ("show Calculator", "com.apple.calculator", False),
    ("bring Calculator to front", "com.apple.calculator", False),
    ("switch to Calculator", "com.apple.calculator", False),
    ("show Apple's plain-text editor", "com.apple.TextEdit", True),
]


def normal_routing_corpus_sha():
    payload = [dict(command=c, target=t, semantic=s) for c, t, s in NORMAL_ROUTING_CASES]
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def validate_normal_routing(data, signed_sha):
    assert data["report_kind"] == "normal_controller_typed_routing" and data["schema_version"] == 1
    assert data["status"] == "passed" and data["normal_typed_routing_gate"] == "passed"
    assert data["physical_input"] is False and data["human_confirmed"] is False
    assert data["phase_acceptance"] is False and data["local_acoustic_gate"] == "not_exercised"
    assert data["artifact_sha256"] == signed_sha and data["corpus_sha256"] == normal_routing_corpus_sha()
    rows = data["rows"]
    assert len(rows) == len(NORMAL_ROUTING_CASES)
    for row, (command, target, semantic) in zip(rows, NORMAL_ROUTING_CASES):
        assert row["command"] == command and row["observed_bundle_id"] == target
        assert row["passed"] is True and row["normal_route"] == ("semantic" if semantic else "local")
        assert row["semantic_focus"] is semantic
        assert row["scripted_confirmation"] is False and row["wrong_proposal"] is False
        assert row["false_done"] is False and row["observed_window_id"] > 0
        assert math.isfinite(row["submit_to_visible_effect_ms"]) and row["submit_to_visible_effect_ms"] >= 0
        assert row["work_count"] == 1 and len(row["works"]) == 1
        assert row["works"][0]["active"] is False and row["works"][0]["outcome"] in ("done", "alreadyDone")
        assert row["works"][0]["application"] == target
        assert row["works"][0]["capture_id"] and any(
            e["turn"] == row["works"][0]["capture_id"] for e in row["trace"])
        if not semantic:
            assert any(e["stage"] == "admissionLocal" for e in row["trace"])


def coverage(args):
    if not args.out:
        raise Blocked("supply --out for the separate normal-controller routing report")
    data = read(ROOT / args.out)
    installed = installed_build(current_build())
    validate_normal_routing(data, installed["installed_artifact_sha256"])
    batch = data["semantic_budget"]
    assert re.fullmatch(r"semantic-[A-Za-z0-9-]{1,31}", batch)
    auth = read(RESULTS / batch / "authorization.json")
    assert auth["maximumRequests"] == 1 and auth["corpusSHA256"] == normal_routing_corpus_sha()
    assert auth["scope"] == "typesafe-text-only"
    requests = [json.loads(line) for line in (RESULTS / batch / "requests.jsonl").read_text().splitlines()]
    assert len(requests) == 1 and requests[0]["subject"] == "gui-4" and requests[0]["allocation"] == "gui"
    assert requests[0]["authorization"] == auth["id"]
    assert requests[0]["reserved_at"] <= auth["expiresAt"]
    print("PASS normal typed controller routing 4 local +1 semantic; NOT acoustic/physical/server acceptance")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("scope", "accuracy", "contracts", "hygiene", "replay", "live", "remote", "coverage", "record-build", "record-install", "installation", "frontdoor"))
    parser.add_argument("--recordings-root", help=argparse.SUPPRESS)
    parser.add_argument("--out")
    args = parser.parse_args()
    try:
        if args.command == "record-build":
            record_build()
        elif args.command == "record-install":
            record_install()
        elif args.command == "installation":
            installed_build(current_build())
            print("PASS current reviewed source and signed installed build")
        elif args.command == "frontdoor":
            frontdoor()
        elif args.command in ("replay", "live", "remote", "coverage"):
            globals()[args.command](args)
        else:
            globals()[args.command]()
    except Blocked as error:
        print(f"BLOCKED: {error}"); return 2
    except (AssertionError, OSError, KeyError, ValueError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}"); return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
