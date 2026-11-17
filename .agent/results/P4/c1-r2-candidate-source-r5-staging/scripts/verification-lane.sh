#!/usr/bin/env bash
# The one serialized verification runner (PLANS.md §4). Writers never
# build a half-frozen tree — every build/test goes through this script,
# in order, failing on the first red step.
#
# Usage: scripts/verification-lane.sh [swift|p3|p3-speech-report|p3-release|p3-evidence|eyes|speech|speech-release|all]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

scope="${1:-all}"
p3_filter='VoiceTurnTests|VoiceTurnEvidenceTests|VoiceAccuracyTests|VoiceOneBrainTests|VoiceSemanticTests|VoiceCommandTraceTests|VoiceTrialReportTests|SemanticRequestBudgetTests|FocusedTextTargetTests|MicrophoneInputTests|LocalSpeechTests|IntelligenceCommand|IntelligenceChooserTests|VoiceTaskCoordinatorLaneTests|UXConfigDefaultsTests|FastLaneTests|FastLaneExecutorTests|DriveLoopTests|VoiceLaneAuditTests|RealtimeVoiceLaneTests'

run_p3_evidence() {
  PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/test_verifier.py
}

run_swift() {
  echo "== [1/3] swift test =="
  swift test --disable-automatic-resolution
  run_p3_evidence
}

run_eyes() {
  echo "== [2/3] EyeTracking typecheck =="
  (cd EyeTracking && npm run typecheck)
  echo "== [3/3] EyeTracking vitest =="
  (cd EyeTracking && npx --no-install vitest run)
}

case "$scope" in
  c1-lifecycle|c1-payload|c1-scroll|c1-r1|c1-conversation|c1-r2)
    if [[ ! -d .build/debug/JevVoicePackageTests.xctest || ! -d .build/debug/ModuleCache ]]; then
      echo "The incremental lifecycle check requires an existing debug build." >&2
      exit 75
    fi
    c1_filter='VoiceLaneAuditTests.testC1'
    if [[ "$scope" == c1-payload ]]; then c1_filter='JevChooserTests.testC1'; fi
    if [[ "$scope" == c1-scroll ]]; then c1_filter='FastLaneExecutorTests.testC1|JevObservedGoalTests'; fi
    if [[ "$scope" == c1-r1 ]]; then
      c1_filter='VoiceLaneAuditTests|RealtimeVoiceLaneTests|VoiceTurnEvidenceTests|VoiceTaskCoordinatorLaneTests|JevChooserTests|JevObservedGoalTests|JevExactReplacementTests|JevAdaptiveTests|JevDeciderTests|FastLaneExecutorTests'
    fi
    if [[ "$scope" == c1-conversation ]]; then c1_filter='LocalSpeechTests.testConversation'; fi
    if [[ "$scope" == c1-r2 ]]; then
      c1_filter='LocalSpeechTests|MicrophoneInputTests|RealtimeVoiceLaneTests|VoiceLaneAuditTests|VoiceSemanticTests|VoiceTurnTests|VoiceTurnEvidenceTests|VoiceOneBrainTests|VoiceToolResultTests|FnInputStateTests|FnInputMonitorReleaseTests|UXConfigDefaultsTests|UXOnboardingTests|FastLaneExecutorTests|VoiceTaskCoordinatorLaneTests'
    fi
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" \
      --minimum-free-gib 3 -- \
      swift test --disable-automatic-resolution --filter "$c1_filter"
    ;;
  p12)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- \
      swift test --disable-automatic-resolution --filter 'CuaDependencyPinTests|DriverDaemonHostTests|TrackerHostTests|LedgerSpendTests'
    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .agent/results/P12 -p 'test_c1_manifest.py'
    ;;
  p12-resources)
    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .agent/results/P12 -p 'test_c1_manifest.py'
    ;;
  c1-native)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- \
      swift test --disable-automatic-resolution --filter 'FastLaneTests|FastLaneExecutorTests|VoiceTaskCoordinatorLaneTests|FocusedTextTargetTests'
    ;;
  c1-permissions)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- \
      swift test --disable-automatic-resolution --filter 'LocalSpeechTests|MicrophoneInputTests|VoiceLaneAuditTests|VoiceNormalQualificationTests'
    ;;
  c1-authority)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- \
      swift test --disable-automatic-resolution --filter 'JevVisionTests.testC1|JevVisionTests.testNativePolicyFailure|JevVisionTests.testOpenReferentPickBinds|DwellPolicyTests|GazeDwellTests|EyeSettingsFlowTests.testDwellMode'
    ;;
  p11)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- \
      swift test --disable-automatic-resolution --filter 'DwellPolicyTests|GazeDwellTests|GazeServiceTests|TrackerControlFlowTests|EyesMenuFlowTests|TrackerCommandFlowTests|TrackerEnableFlowTests|EyeSettingsFlowTests|UXConfigDefaultsTests'
    ;;
  p4-explicit-decision-regressions)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- \
      swift test --disable-automatic-resolution --filter 'JevChooserTests.testD16|JevVisionTests.testD16'
    ;;
  p4-explicit-decision-consumers)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- \
      swift test --disable-automatic-resolution --filter 'JevChooserTests|JevDeciderTests|JevVisionTests|JevAdaptiveTests|JevObservedGoalTests|JevExactReplacementTests|JevEditableValueTests|JevNativeObservationTests|TaskLoopTests|DriveLoopTests|VoiceTaskCoordinatorLaneTests|CuaDriveServerTests|CuaDriveSessionTests|JevIntegrationTests'
    ;;
  p4-vision-build-space)
    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .agent/results/P4 -p 'test_jev_build_guard.py'
    ;;
  p4-vision-driver-045-fetch|p4-vision-driver-045-node-deps|p4-vision-driver-045-generator-bootstrap|p4-vision-driver-045-core|p4-vision-driver-045-contract|p4-vision-driver-045-macos|p4-vision-driver-045-sdk|p4-vision-driver-045-build|p4-vision-driver-045-generate|p4-vision-driver-045-parity|p4-vision-driver-045-stage-sdk|p4-vision-driver-045-python-tests-bootstrap|p4-vision-driver-045-consumers)
    driver_root="/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/cua-upstream-0.45.4"
    [[ "$(git -C "$driver_root" rev-parse HEAD)" == "d96e1bc359b2cc638c7a406aad01a7276b1b416f" ]] || exit 2
    driver_manifest="$driver_root/libs/cua-driver/rust/Cargo.toml"
    export RUSTUP_TOOLCHAIN=1.97.1
    export CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0 CARGO_INCREMENTAL=0
    export CARGO_BUILD_JOBS=2
    export CARGO_TARGET_DIR="/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/build/vision-capture-045"
    export CARGO_HOME="/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/build/cargo-045"
    export TMPDIR="$CARGO_TARGET_DIR/tmp"
    mkdir -p "$TMPDIR"
    export DO_NOT_TRACK=1 CUA_TELEMETRY=0 CUA_DRIVER_RS_TELEMETRY_ENABLED=0
    guarded_045() {
      python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$CARGO_TARGET_DIR" -- "$@"
    }
    case "$scope" in
      p4-vision-driver-045-generator-bootstrap)
        generator_root="$driver_root/libs/cua-driver/typescript/node_modules/uniffi-bindgen-react-native"
        generator_lock="$PWD/.agent/results/P4/jev-vision-ubrn-0.31.0-3-Cargo.lock.txt"
        if [[ -f "$generator_lock" ]]; then
          if [[ ! -f "$generator_root/Cargo.lock" ]]; then
            cp "$generator_lock" "$generator_root/Cargo.lock"
          fi
          cmp "$generator_root/Cargo.lock" "$generator_lock"
        else
          guarded_045 cargo generate-lockfile --manifest-path "$generator_root/Cargo.toml"
          cp "$generator_root/Cargo.lock" "$generator_lock"
        fi
        guarded_045 cargo fetch --locked --manifest-path "$generator_root/Cargo.toml"
        guarded_045 cargo build --offline --locked --manifest-path "$generator_root/crates/ubrn_cli/Cargo.toml"
        ;;
      p4-vision-driver-045-node-deps)
        export npm_config_cache="$CARGO_TARGET_DIR/npm-cache"
        export npm_config_userconfig="$TMPDIR/npm-user-config-empty" npm_config_globalconfig=/dev/null
        export ELECTRON_SKIP_BINARY_DOWNLOAD=1
        guarded_045 npm ci --prefix "$driver_root/libs/cua-driver/typescript" --ignore-scripts --no-audit --no-fund --registry=https://registry.npmjs.org
        ;;
      p4-vision-driver-045-fetch)
        guarded_045 cargo fetch --locked --manifest-path "$driver_manifest"
        ;;
      p4-vision-driver-045-core)
        guarded_045 cargo test --offline --locked --manifest-path "$driver_manifest" -p cua-driver-core
        ;;
      p4-vision-driver-045-contract)
        guarded_045 cargo test --offline --locked --manifest-path "$driver_manifest" -p cua-driver-contract
        ;;
      p4-vision-driver-045-macos)
        guarded_045 cargo test --offline --locked --manifest-path "$driver_manifest" -p platform-macos
        ;;
      p4-vision-driver-045-sdk)
        guarded_045 cargo test --offline --locked --manifest-path "$driver_manifest" -p cua-driver-sdk
        ;;
      p4-vision-driver-045-build)
        guarded_045 cargo build --offline --locked --release --manifest-path "$driver_manifest" -p cua-driver -p cua-driver-sdk
        ;;
      p4-vision-driver-045-generate)
        generator_lock="$driver_root/libs/cua-driver/typescript/node_modules/uniffi-bindgen-react-native/Cargo.lock"
        cmp "$generator_lock" "$PWD/.agent/results/P4/jev-vision-ubrn-0.31.0-3-Cargo.lock.txt"
        guarded_045 cargo run --offline --locked --manifest-path "$driver_manifest" -p cua-driver-contract --bin cua-contract-gen -- all
        CARGO_NET_OFFLINE=true guarded_045 node "$driver_root/libs/cua-driver/scripts/generate-uniffi-bindings.mjs"
        cmp "$generator_lock" "$PWD/.agent/results/P4/jev-vision-ubrn-0.31.0-3-Cargo.lock.txt"
        ;;
      p4-vision-driver-045-parity)
        generator_lock="$driver_root/libs/cua-driver/typescript/node_modules/uniffi-bindgen-react-native/Cargo.lock"
        cmp "$generator_lock" "$PWD/.agent/results/P4/jev-vision-ubrn-0.31.0-3-Cargo.lock.txt"
        guarded_045 cargo run --offline --locked --manifest-path "$driver_manifest" -p cua-driver-contract --bin cua-contract-gen -- all --check
        CARGO_NET_OFFLINE=true guarded_045 node "$driver_root/libs/cua-driver/scripts/generate-uniffi-bindings.mjs" --check
        cmp "$generator_lock" "$PWD/.agent/results/P4/jev-vision-ubrn-0.31.0-3-Cargo.lock.txt"
        ;;
      p4-vision-driver-045-stage-sdk)
        cmp "$driver_root/libs/cua-driver/typescript/node_modules/uniffi-bindgen-react-native/Cargo.lock" "$PWD/.agent/results/P4/jev-vision-ubrn-0.31.0-3-Cargo.lock.txt"
        CARGO_NET_OFFLINE=true guarded_045 node "$driver_root/libs/cua-driver/scripts/stage-uniffi-library.mjs"
        ;;
      p4-vision-driver-045-python-tests-bootstrap)
        export UV_CACHE_DIR="$CARGO_TARGET_DIR/uv-cache" UV_PYTHON_DOWNLOADS=never UV_NO_CONFIG=1
        python_lock="$PWD/.agent/results/P4/jev-sdk-test-requirements.lock"
        if [[ ! -f "$python_lock" ]]; then
          guarded_045 uv pip compile --python-version 3.12 --default-index https://pypi.org/simple --only-binary :all: --generate-hashes --output-file "$python_lock" "$PWD/.agent/results/P4/jev-sdk-test-requirements.in"
        fi
        if [[ ! -d "$CARGO_TARGET_DIR/python-sdk-env" ]]; then
          guarded_045 uv venv --offline --python "$(command -v python3.12)" "$CARGO_TARGET_DIR/python-sdk-env"
        fi
        guarded_045 uv pip sync --python "$CARGO_TARGET_DIR/python-sdk-env/bin/python" --default-index https://pypi.org/simple --only-binary :all: --require-hashes "$python_lock"
        ;;
      p4-vision-driver-045-consumers)
        export HOME="$CARGO_TARGET_DIR/tmp/sdk-test-home"
        mkdir -p "$HOME"
        export CUA_HOME="$HOME/.cua" XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
        CUA_DRIVER_REQUIRE_UNIFFI=1 guarded_045 npm --prefix "$driver_root/libs/cua-driver/typescript" run typecheck
        CUA_DRIVER_REQUIRE_UNIFFI=1 guarded_045 npm --prefix "$driver_root/libs/cua-driver/typescript" test
        PYTHONPATH="$driver_root/libs/cua-driver/python/src" CUA_DRIVER_REQUIRE_UNIFFI=1 PYTHONDONTWRITEBYTECODE=1 guarded_045 "$CARGO_TARGET_DIR/python-sdk-env/bin/python" -m pytest -c "$driver_root/libs/cua-driver/python/pyproject.toml" -p no:cacheprovider "$driver_root/libs/cua-driver/python/tests"
        ;;
    esac
    ;;
  p4-vision-driver-capture|p4-vision-driver-contract|p4-vision-driver-macos|p4-vision-driver-build)
    driver_workspace="/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver"
    driver_manifest="$driver_workspace/development/JevVoice/cua-source/libs/cua-driver/rust/Cargo.toml"
    export CARGO_TARGET_DIR="$driver_workspace/development/JevVoice/build/vision-capture"
    case "$scope" in
      p4-vision-driver-capture)
        cargo test --offline --locked --manifest-path "$driver_manifest" -p cua-driver-core --lib capture_
        ;;
      p4-vision-driver-contract)
        cargo test --offline --locked --manifest-path "$driver_manifest" -p cua-driver-contract --lib
        ;;
      p4-vision-driver-macos)
        cargo test --offline --locked --manifest-path "$driver_manifest" -p platform-macos --lib capture
        ;;
      p4-vision-driver-build)
        cargo build --offline --locked --release --manifest-path "$driver_manifest" -p cua-driver -p cua-driver-sdk
        ;;
    esac
    ;;
  p4-vision-probe-tests)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- xcrun swiftc -typecheck -module-cache-path "$PWD/.build/arm64-apple-macosx/release/ModuleCache" .agent/results/P4/jev-native-field-probe.swift
    python3 .agent/results/P4/test_jev_vision_probe.py
    ;;
  p4-vision-driver-host)
    swift test --disable-automatic-resolution --disable-index-store -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/arm64-apple-macosx/release/ModuleCache" --filter DriverDaemonHostTests
    ;;
  p4-vision-capture)
    swift test --disable-automatic-resolution --disable-index-store -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/arm64-apple-macosx/release/ModuleCache" --filter 'JevVisionTests|TaskLoopTests|JevNativeObservationTests'
    ;;
  p4-vision-decisions)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- swift test --jobs 2 --disable-automatic-resolution --disable-index-store -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/arm64-apple-macosx/release/ModuleCache" --filter JevVisionTests
    ;;
  p4-vision-authority)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- swift test --jobs 2 --disable-automatic-resolution --disable-index-store -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/arm64-apple-macosx/release/ModuleCache" --filter 'JevVisionTests|TaskLoopTests|DriveLoopTests|JevDeciderTests|DriverConnectionTests|DriverConnectionPoolTests|JevNativeObservationTests|JevObservedGoalTests|JevExactReplacementTests|VoiceTaskCoordinatorLaneTests|VoiceTaskCoordinatorOverlayTests|CuaDriveServerTests|JevChooserTests|JevClientTests|JevModelsTests'
    ;;
  p4-native-dispatch-tests)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- swift test --jobs 2 --disable-automatic-resolution --disable-index-store -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/arm64-apple-macosx/release/ModuleCache" --filter 'DriverConnectionTests|DriverConnectionPoolTests|DriveLoopTests|DriveSessionCursorTests|CuaDriveSessionTests|CuaDriveServerTests|FastLaneExecutorTests|FastLaneTests|JevVisionTests|JevDeciderTests|JevNativeObservationTests|JevObservedGoalTests|TaskLoopTests|VoiceTaskCoordinatorOverlayTests'
    ;;
  p4-native-dispatch-owner-tests)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- swift test --jobs 2 --disable-automatic-resolution --disable-index-store -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/arm64-apple-macosx/release/ModuleCache" --filter 'DriverConnectionTests|DriveLoopTests.testNativeTokenLoopRequestsReportDeferralAndStillObservesBeforeDone|DriveLoopTests.testLegacyElementLoopDoesNotRequestReportDeferral'
    ;;
  p4-native-trace-tests)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- swift test --jobs 2 --disable-automatic-resolution --disable-index-store -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/arm64-apple-macosx/release/ModuleCache" --filter 'JevChooserTests|JevNativeObservationTests|CuaDriveServerTests|DriveLoopTests.testPinnedOwnerPreviewUsesSameExactProcessBinding'
    ;;
  p4-native-preview-tests)
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P4/test_jev_native_decision_preview.py
    ;;
  p4-native-decision-preview)
    [[ "${JARVIS_P4_REAL_APPS:-}" == "approved" ]] || exit 2
    PYTHONDONTWRITEBYTECODE=1 python3 scripts/with-desktop-lock.py python3 .agent/results/P4/jev-native-decision-preview.py "${@:2}"
    ;;
  p4-native-dispatch-cancellation)
    PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import importlib.util
from pathlib import Path
import signal
import sys
spec = importlib.util.spec_from_file_location("build_guard", ".agent/results/P4/jev-build-guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
signal.signal(signal.SIGALRM, guard.interrupted)
signal.alarm(60)
try:
    sys.exit(guard.run(["swift", "test", "--disable-automatic-resolution", "--skip-build",
                       "--filter", "VoiceTaskCoordinatorLaneTests.testCancelAllRunningStopsTasksAndAgents"],
                      Path.cwd(), minimum=5, stop=1))
except KeyboardInterrupt:
    print("Cancellation regression exceeded its 60-second bound.", file=sys.stderr)
    sys.exit(124)
finally:
    signal.alarm(0)
PY
    ;;
  p4-delivered-effect-tests)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- swift test --jobs 2 --disable-automatic-resolution --disable-index-store -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/arm64-apple-macosx/release/ModuleCache" --filter JevExactReplacementTests
    ;;
  p4-native-choice-capture-tests)
    python3 .agent/results/P4/jev-native-choice-capture.py --help
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- swift test --jobs 2 --disable-automatic-resolution --disable-index-store -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/arm64-apple-macosx/release/ModuleCache" --filter JevNativeChoiceDiagnosticTests
    ;;
  p4-native-choice-capture)
    [[ "${JARVIS_P4_REAL_APPS:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py python3 .agent/results/P4/jev-native-choice-capture.py "${@:2}"
    ;;
  p4-everyday-choice-capture)
    [[ "${JARVIS_P4_REAL_APPS:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py python3 .agent/results/P4/jev-everyday-choice-capture.py "${@:2}"
    ;;
  p4-native-ui-readonly-regression)
    [[ "${JARVIS_P4_REAL_APPS:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py swift test --skip-build --filter 'JevNativeChoiceDiagnosticTests.testReadOnlyNativeValueAdmissionAndFreshIdentity|JevNativeChoiceDiagnosticTests.testDerivedNativeOutcomeUsesFreshExactEvidence'
    ;;
  p4-native-ui-fixture)
    [[ "${JARVIS_P4_REAL_APPS:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py python3 .agent/results/P4/jev-native-ui-fixture.py "${@:2}"
    ;;
  p4-native-outcome-contract-probe)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    python3 .agent/results/P4/jev-native-outcome-contract-probe.py "${@:2}"
    ;;
  p4-native-outcome-state-probe)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    python3 .agent/results/P4/jev-native-outcome-state-probe.py "${@:2}"
    ;;
  p4-native-subject-contract-probe)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    python3 .agent/results/P4/jev-native-subject-contract-probe.py "${@:2}"
    ;;
  p4-next-step-support-probe)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    python3 .agent/results/P4/jev-next-step-support-probe.py "${@:2}"
    ;;
  p4-native-step-validity-probe)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    python3 .agent/results/P4/jev-native-step-validity-probe.py "${@:2}"
    ;;
  p4-native-validity-model-tests)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- swift test --jobs 2 --disable-automatic-resolution --disable-index-store -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/arm64-apple-macosx/release/ModuleCache" --filter 'JevNativeChoiceDiagnosticTests.testPreparationCannotAuthorizeSubjectSwitchesThroughProductionCandidates'
    ;;
  p4-native-kind-boundary-probe)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    python3 .agent/results/P4/jev-native-kind-boundary-probe.py "${@:2}"
    ;;
  p4-native-signature-tests)
    [[ "${JARVIS_P4_REAL_APPS:-}" == "approved" ]] || exit 2
    python3 .agent/results/P4/test_jev_native_fixture_signing.py
    ;;
  p4-native-readonly-window)
    [[ "${JARVIS_P4_REAL_APPS:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py swift -module-cache-path "$PWD/.build/arm64-apple-macosx/release/ModuleCache" .agent/results/P4/jev-native-field-probe.swift "${@:2}"
    ;;
  p4-calculator-readonly)
    [[ "${JARVIS_P4_REAL_APPS:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py python3 .agent/results/P4/jev-calculator-readonly.py "${@:2}"
    ;;
  p4-calculator-report-tests)
    python3 .agent/results/P4/test_jev_calculator_report.py "${@:2}"
    ;;
  p4-calculator-report)
    python3 .agent/results/P4/jev-calculator-comparison-report.py "${@:2}"
    ;;
  p4-native-dispatch-report-tests)
    python3 .agent/results/P4/test_jev_native_dispatch_report.py "${@:2}"
    ;;
  p4-native-dispatch-report)
    python3 .agent/results/P4/jev-native-dispatch-report.py "${@:2}"
    ;;
  p4-native-latency-probe)
    [[ "${JARVIS_P4_REAL_APPS:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py python3 .agent/results/P4/jev-native-latency-probe.py "${@:2}"
    ;;
  p4-calculator-comparison-tests)
    python3 .agent/results/P4/test_jev_calculator_comparison.py
    ;;
  p4-visual-choice-capture-tests)
    python3 .agent/results/P4/jev-visual-choice-capture.py --help
    python3 -m unittest discover -s .agent/results/P4 -p 'test_jev_vision_probe.py'
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- swift test --jobs 2 --disable-automatic-resolution --disable-index-store -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/arm64-apple-macosx/release/ModuleCache" --filter 'JevNativeChoiceDiagnosticTests|JevVisualChoiceDiagnosticTests'
    ;;
  p4-visual-choice-capture)
    [[ "${JARVIS_P4_REAL_APPS:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py python3 .agent/results/P4/jev-visual-choice-capture.py "${@:2}"
    ;;
  p4-native-picture-provenance-probe)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    python3 .agent/results/P4/jev-native-picture-provenance-probe.py "${@:2}"
    ;;
  p4-completion-state-probe)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    python3 .agent/results/P4/jev-completion-state-probe.py "${@:2}"
    ;;
  p4-visual-native-outcome-probe)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    python3 .agent/results/P4/jev-visual-native-outcome-probe.py "${@:2}"
    ;;
  p4-visual-model-probe)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- python3 .agent/results/P4/jev-visual-model-probe.py "${@:2}"
    ;;
  p4-visual-model-probe-tests)
    python3 .agent/results/P4/jev-visual-model-probe.py --help
    python3 .agent/results/P4/jev-visual-native-choice-probe.py --help
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- xcrun swiftc -typecheck -module-cache-path "$PWD/.build/arm64-apple-macosx/release/ModuleCache" .agent/results/P4/jev-visual-mark.swift
    if [[ "$#" -gt 1 ]]; then
      python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- swift -module-cache-path "$PWD/.build/arm64-apple-macosx/release/ModuleCache" .agent/results/P4/jev-visual-mark.swift "${@:2}"
    fi
    ;;
  p4-visual-native-choice-probe)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- python3 .agent/results/P4/jev-visual-native-choice-probe.py "${@:2}"
    ;;
  p4-vision-transport)
    swift test --disable-automatic-resolution --disable-index-store -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/arm64-apple-macosx/release/ModuleCache" --filter 'JevModelsTests|JevClientTests|JevSelectionTests'
    ;;
  p4-vision-report)
    python3 .agent/results/P4/jev-vision-report.py "${@:2}"
    ;;
  p4-vision-model-probe)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    python3 .agent/results/P4/jev-vision-probe.py judge "${@:2}"
    ;;
  p4-vision-readonly)
    [[ "${JARVIS_P4_REAL_APPS:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py python3 .agent/results/P4/jev-vision-probe.py "${@:2}"
    ;;
  p4-clean-approved-debug-caches)
    [[ "${JARVIS_P4_DEBUG_CACHE_CLEAN:-}" == "approved-once" ]] || exit 2
    python3 - <<'PY'
import os
from pathlib import Path
import shutil
root = Path.cwd() / ".build/arm64-apple-macosx/debug"
for name in ("index", "ModuleCache"):
    path = root / name
    if path.is_symlink() or root.is_symlink() or path.stat().st_uid != os.getuid():
        raise SystemExit("unexpected compiler cache ownership or symlink")
    shutil.rmtree(path)
    print("Removed approved disposable cache:", path)
PY
    df -h /
    ;;
  p4-realapps)
    [[ "${JARVIS_P4_REAL_APPS:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py python3 .agent/results/P4/jev-realapps.py "${@:2}"
    ;;
  p4-native-field-probe)
    [[ "${JARVIS_P4_REAL_APPS:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py swift -module-cache-path "$PWD/.build/arm64-apple-macosx/release/ModuleCache" .agent/results/P4/jev-native-field-probe.swift "${@:2}"
    ;;
  p4-jev-goal-probe)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    python3 .agent/results/P4/jev-goal-prompt-probe.py "${@:2}"
    ;;
  p4-native-source-tests)
    swift test --filter 'JevEditableValueTests|JevNativeObservationTests|JevObservedGoalTests|DriveLoopTests|BrowserActuationTests|JevAdaptiveWorkflowTests'
    ;;
  p4-native-text-mutations)
    swift test --disable-automatic-resolution --filter 'JevDeciderTests|JevIntegrationTests|JevAdaptiveTests|DriveLoopTests|BrowserActuationTests'
    ;;
  p4-window-scope-tests)
    swift test --disable-automatic-resolution --disable-index-store -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/arm64-apple-macosx/release/ModuleCache" --filter 'CuaDriveServerTests|CuaDriveSessionTests|DriveLoopTests|JevDeciderTests|JevEditableValueTests|JevObservedGoalTests|BrowserActuationTests|JevAdaptiveTests|JevIntegrationTests'
    ;;
  p4-native-verifier-tests)
    python3 .agent/results/P4/jev-native-verifier-regression.py "${@:2}"
    python3 .agent/results/P4/jev-native-corpus-regression.py
    ;;
  p4-native-report)
    python3 .agent/results/P4/jev-p4-audit-report.py "${@:2}"
    ;;
  p4-current-evidence-report)
    python3 .agent/results/P4/jev-current-evidence-report.py "${@:2}"
    ;;
  p4-native-v2-build)
    python3 .agent/results/P4/jev-native-v2.py build
    ;;
  p4-native-v2-proof)
    [[ "${JARVIS_P4_NATIVE:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py python3 .agent/results/P4/jev-native-v2.py run "${@:2}"
    ;;
  p4-native-corrected-score)
    python3 .agent/results/P4/jev-native-verifier.py "${@:2}"
    ;;
  p4-clone-stage)
    python3 .agent/results/P4/jev-clone-stage.py "${@:2}"
    ;;
  p4-native-diagnose)
    [[ "${JARVIS_P4_NATIVE:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py python3 .agent/results/P4/jev-native-diagnose.py
    ;;
  p4-jev-observed-goal)
    swift test --disable-automatic-resolution --filter JevObservedGoalTests
    ;;
  p4-native-frozen-proof)
    [[ "${JARVIS_P4_NATIVE:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py python3 .agent/results/P4/jev-native-proof-frozen-primary.py run "${@:2}"
    ;;
  p4-jev-grounding-regressions)
    swift test --disable-automatic-resolution --filter JevDeciderTests.testObservedBoundsAreKnownOrExplicitlyUnknown
    ;;
  p4-stage-candidate|p12-stage)
    JARVIS_VERIFICATION_LANE_HELD=1 python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- \
      python3 .agent/results/P4/jev-stage-candidate.py "${@:2}"
    ;;
  c1-package-release)
    [[ -f .build/release/JevVoice && -d .build/release/FluidAudio.build &&
       -f .build/release/Modules/FluidAudio.swiftmodule ]] || exit 2
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" --minimum-free-gib 3 -- \
      swift build -c release --jobs 1 --disable-automatic-resolution
    ;;
  c1-chooser-release-tests)
    [[ -n "${2:-}" && -d .build/release/FluidAudio.build &&
       -f .build/release/Modules/FluidAudio.swiftmodule ]] || exit 2
    c1_command=(swift test -c release --jobs 1 --disable-automatic-resolution --disable-build-manifest-caching --filter "$2")
    if [[ "${3:-}" == "--skip-build" ]]; then
      c1_command+=(--skip-build)
    elif [[ -n "${3:-}" ]]; then
      exit 2
    fi
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" --minimum-free-gib 3 -- \
      "${c1_command[@]}"
    ;;
  c1-package-stage)
    [[ -f .build/release/JevVoice && "${2:-}" == "--label" &&
       ( "${3:-}" == "final-r3" || "${3:-}" == "final-r4" || "${3:-}" == "final-r5" ) ]] || exit 2
    JARVIS_VERIFICATION_LANE_HELD=1 python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" --minimum-free-gib 2.75 -- \
      python3 .agent/results/P4/jev-stage-candidate.py "${@:2}"
    ;;
  p4-vision-stage)
    python3 "$PWD/.agent/results/P4/jev-build-guard.py" --directory "$PWD" -- python3 "$PWD/.agent/results/P4/jev-vision-stage.py" "${@:2}"
    ;;
  p4-vision-qualification)
    [[ "${JARVIS_P4_REAL_APPS:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py python3 .agent/results/P4/jev-vision-qualification.py "${@:2}"
    ;;
  p4-native-build)
    python3 .agent/results/P4/jev-native-proof.py build
    ;;
  p4-native-proof)
    [[ "${JARVIS_P4_NATIVE:-}" == "approved" ]] || exit 2
    python3 scripts/with-desktop-lock.py python3 .agent/results/P4/jev-native-proof.py run "${@:2}"
    ;;
  p4-jev-model-regressions)
    swift test --disable-automatic-resolution --filter 'JevModelsTests.testNoulCriteria|JevDeciderTests.testCallerLiteralComparison|JevAdaptiveTests.testCandidatesBeyondFirstThreeRemainEligible'
    ;;
  p4-jev-refinement-regression)
    swift test --disable-automatic-resolution --filter JevAdaptiveTests.testCandidatesBeyondFirstThreeRemainEligible
    ;;
  p4-jev-progress-live)
    [[ "${JARVIS_P4_JEV_PROGRESS:-}" == "approved" ]] || exit 2
    swift test --disable-automatic-resolution --skip-build --filter JevProgressLiveTests
    ;;
  p4-jev-frontdoor-regressions)
    swift test --disable-automatic-resolution --filter 'CuaDriveSessionTests.testTaskArguments|CuaDriveSessionTests.testLegacyTaskArguments|TaskLoopTests.testBlankCriteriaAndAvailableButtonsAreNotGoalEvidence'
    ;;
  p4-jev-progress-privacy)
    swift test --disable-automatic-resolution --filter JevDeciderTests.testTextQuestionDoesNotExposeSecureCurrentValue
    ;;
  p4-jev-progress-regressions)
    swift test --disable-automatic-resolution --filter 'DriveLoopTests.testDefaultContinuesPastFourVerifiedSteps|JevDeciderTests.testBlankFieldAndCompleteHistoryReachJudgment|JevDeciderTests.testAllSnapshotControlsRemainAvailableByDefault|JevDeciderTests.testAnsweredQuestionDoesNotBlockAnotherField|JevDeciderTests.testParkedFieldRejectsAnotherQuestionsAnswer|TaskLoopTests.testExpiredWallBudgetReportsActualZeroRounds|TaskLoopTests.testUnbounded|TaskLoopTests.testCancellationAfterConsentNeverDispatches'
    ;;
  p4-jev-adaptive-regressions)
    swift test --disable-automatic-resolution --filter 'JevAdaptiveTests|JevAdaptiveWorkflowTests.testActualLoop|JevAdaptiveWorkflowTests.testSecondStep'
    ;;
  p4-jev-boundary-probe)
    python3 .agent/results/P4/jev-adaptive-boundary-probe.py
    ;;
  p4-jev-install-proof)
    python3 .agent/results/P4/jev-adaptive-install-proof.py
    ;;
  p4-jev-adaptive-live)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || {
      echo "BLOCKED: explicit additional synthetic API approval required" >&2
      exit 2
    }
    swift test --disable-automatic-resolution --skip-build --filter JevAdaptiveLiveTests
    ;;
  p4-jev-adaptive-workflows)
    [[ "${JARVIS_P4_JEV_ADAPTIVE:-}" == "approved-additional" ]] || exit 2
    swift test --disable-automatic-resolution --skip-build --filter JevAdaptiveWorkflowTests.testMeasureRealJevThroughProductionLoop
    ;;
  p4-local)
    [[ "${JARVIS_P4_INSTALL:-}" == "approved" ]] || {
      echo "BLOCKED: replacing and restarting the installed app requires approval" >&2
      exit 2
    }
    python3 - <<'PY'
import hashlib
import json
from pathlib import Path

pins = json.loads(Path("ThirdParty/Cua/source-manifest.json").read_text())["vendored_binaries"]
for name, path in [("cua-driver", Path("build/vendor/cua-driver")),
                   ("codex", Path("build/vendor/CodexRuntime/codex"))]:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != pins[name]["sha256"]:
        raise SystemExit("BLOCKED: cached pinned runtime differs; no downloads or installation attempted")
print("Existing pinned runtimes verified; no dependency downloads needed")
PY
    security find-identity -v -p codesigning | rg -q '"Jev Voice Local Dev"' || {
      echo "BLOCKED: existing signing identity required; no new identity will be minted" >&2
      exit 2
    }
    SKIP_TRACKER_DEPS=1 make local
    ;;
  p4-jev-replay)
    JARVIS_P4_JEV_REPLAY=1 swift test --disable-automatic-resolution --skip-build --filter JevLiveIntegrationTests.testRecordedJudgmentsReplayThroughCurrentDecider
    ;;
  p4-jev-live)
    [[ "${JARVIS_P4_JEV_LIVE:-}" == "approved-30" ]] || {
      echo "BLOCKED: capped synthetic TypeSafe authorization required" >&2
      exit 2
    }
    swift test --disable-automatic-resolution --skip-build --filter JevLiveIntegrationTests
    ;;
  p4-jev)
    swift test --disable-automatic-resolution --filter 'JevIntegrationTests|JevChooserTests|JevSelectionTests|JevModelsTests|JevDeciderTests|TaskLoopTests|DriveLoopTests|CuaDriveSessionTests|BrowserActuationTests|VoiceTaskCoordinatorLaneTests|FastLaneExecutorTests'
    ;;
  p3-semantic-stages)
    swift test --disable-automatic-resolution --filter 'VoiceSemanticTests.testExpiredSemanticHopReportsDeadlineCategoryAndMeasuredWall|VoiceSemanticTests.testTransportFailuresReportTransportCategoryWithoutWaitingOnTheWall|VoiceSemanticTests.testExhaustedReservationReportsBudgetCategoryDistinctFromTransport|VoiceSemanticTests.testCancelledInterpretationReportsCancellationNotDeadlineAndCreatesNoWork|VoiceSemanticTests.testSemanticProposalRecordsReserveInferenceAndFreshContextDurations|VoiceOneBrainTests.testSemanticStageTelemetryIsNumericAndAddsNoTrafficOrTextLeak'
    ;;
  p3-chat-conductor)
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_chat_conductor.py
    ;;
  p3-current-replay)
    output=".agent/results/P3/native-current-replay.json"
    [[ ! -e "$output" ]] || { echo "Refusing to overwrite prior replay" >&2; exit 2; }
    python3 scripts/verify-p3.py replay --recordings-root .agent/results/P3/audio --out "$output"
    ;;
  p3-normal-closeout)
    run_swift
    run_eyes
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_normal_evidence.py
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_normal_report.py
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_routing_runner.py
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_live_approval.py
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_chat_conductor.py
    swift build -c release --disable-automatic-resolution
    python3 scripts/verify-p3.py record-build
    python3 scripts/verify-p3.py frontdoor
    ;;
  p3-normal-protocol)
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_normal_evidence.py
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_normal_report.py
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_chat_conductor.py
    ;;
  p3-native-restore-trace)
    swift test --disable-automatic-resolution --filter 'FastLaneTests.testShowHiddenRunningAppRestoresWindowBeforeRaising|VoiceNormalQualificationTests.testMutationMarks|VoiceCommandTraceTests.testNativeUnhide'
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_normal_evidence.py
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_normal_report.py
    ;;
  p3-normal-qualification)
    swift test --disable-automatic-resolution --filter 'VoiceNormalQualificationTests|VoiceTurnEvidenceTests|VoiceTaskCoordinatorLaneTests.testSemanticCreation'
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_normal_evidence.py
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_normal_report.py
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_routing_runner.py
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_live_approval.py
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/normal-voice-qualification/test_chat_conductor.py
    ;;
  p3-microphone)
    swift test --disable-automatic-resolution --filter 'MicrophoneInputTests|LocalSpeechTests.testTrial'
    ;;
  p3-speech-report)
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/speech-evidence/test_report.py
    ;;
  p3-remote-safety)
    swift test --disable-automatic-resolution --filter VoiceRemoteTrialTests
    ;;
  p3-native-tail-report)
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/speech-evidence/test_native_tail_report.py
    ;;
  p3-native-tail)
    swift test -c release --disable-automatic-resolution --filter NativeSpeechTailReplayTests
    ;;
  p3-driver-prewarm)
    swift test --disable-automatic-resolution --filter 'VoiceTaskCoordinatorLaneTests|DriverConnectionTests|DriverConnectionPoolTests|DriverDaemonHostTests'
    ;;
  p3-native-fresh-proof)
    swift test --disable-automatic-resolution --filter 'FastLaneExecutorTests.testExactNativeForegroundProof|FastLaneExecutorTests.testNativeActivationFailure|FastLaneExecutorTests.testNativeSemanticFocus|FastLaneExecutorTests.testNativeProofCannot|FastLaneExecutorTests.testNativeForegroundValidator|FastLaneExecutorTests.testNativeForegroundProbe|FastLaneExecutorTests.testNativeForegroundShortcut|FastLaneExecutorTests.testVerifiedNativeForeground|FastLaneExecutorTests.testNativeForegroundSettles'
    ;;
  p3-window-order-probe)
    xcrun swiftc -O -swift-version 6 .agent/results/P3/speech-evidence/window-order-probe.swift \
      -o .agent/results/P3/speech-evidence/window-order-probe
    ;;
  p3-native-focus-snapshot)
    xcrun swiftc -O -swift-version 6 .agent/results/P3/speech-evidence/foreground-snapshot.swift \
      -o .agent/results/P3/speech-evidence/foreground-snapshot
    ;;
  p3-fn-release)
    swift test --disable-automatic-resolution --filter 'FnInputStateTests|FnInputMonitorReleaseTests'
    ;;
  p3-speech-evidence)
    swift test --disable-automatic-resolution --filter VoiceTurnEvidenceTests
    PYTHONDONTWRITEBYTECODE=1 python3 .agent/results/P3/speech-evidence/test_report.py
    ;;
  p3-typing-package)
    swift build -c release --disable-automatic-resolution
    ;;
  p3-typing-repair)
    swift test --disable-automatic-resolution --filter 'FastLaneTests.testCanonicalBundle|FocusedTextTargetTests|VoiceSemanticTests.testNormalLocalControllerUsesOneLiteral|VoiceSemanticTests.testSpeechLiteralSlot|DriveSessionCursorTests|FastLaneExecutorTests.testBound|VoiceCommandTraceTests.testNativeTextTrace'
    ;;
  swift) run_swift ;;
  p3-evidence) run_p3_evidence ;;
  p3-final-priority)
    swift test --disable-automatic-resolution --filter LocalSpeechTests.testWholeHoldFinalAndNextCaptureNeverJoinBlockedProvisionalWork
    ;;
  p3-native-compute)
    swift test --disable-automatic-resolution --filter LocalSpeechTests.testRealNativeOverlapComputePlacement
    ;;
  p3-voice-activity)
    swift test --disable-automatic-resolution --filter LocalSpeechTests.testRealVoiceActivityIsOwnedThroughFinalCancelAndStaleCompletion
    ;;
  p3-bound-type)
    swift test --disable-automatic-resolution --filter 'FastLaneExecutorTests.testBound'
    ;;
  p3-quoted-literal)
    swift test --disable-automatic-resolution --filter 'FastLaneTests.testFullyQuotedTypePreservesPayloadBytes|FastLaneExecutorTests.testBoundQuotedLiteralRetainsWhitespaceAndQuotes'
    ;;
  p3-cua-pin)
    swift test --disable-automatic-resolution --filter CuaDependencyPinTests
    python3 .agent/results/P3/closeout02/cua-upgrade/check-schemas.py
    ;;
  p3-cua-snapshot)
    swift test --disable-automatic-resolution --filter 'DriverConnectionTests.testWindowSnapshot|FastLaneExecutorTests.testBound'
    ;;
  p3-audit-settlement)
    swift test --disable-automatic-resolution --filter VoiceCommandTraceTests.testAuditSettlement
    ;;
  p3-ax-coordinates)
    swift test --disable-automatic-resolution --filter 'GazeCandidateFeedTests|VoiceTaskCoordinatorLaneTests.testHaloUsesNativeScreenPoints|FastLaneExecutorTests.testOverlayVerbDispatchesConvertedTargets|FastLaneExecutorTests.testDescribeNativeScreenFrame|DriveLoopTests.testGazeAnnotatesElementUnderEyes'
    ;;
  p3-gaze-stream-fixture)
    swift test --disable-automatic-resolution --filter GazeStreamTests
    ;;
  p3-natural-apps)
    swift test --disable-automatic-resolution --filter 'VoiceSemanticTests.testUnresolvedApp|VoiceSemanticTests.testBare'
    ;;
  p3-live-controls-harness)
    swift test --disable-automatic-resolution --filter LiveWorkflowTests.testMinimizeHarnessReadinessAndCleanupOwnership
    ;;
  p3-captured-window)
    swift test --disable-automatic-resolution --filter VoiceSemanticTests.testNormalLocalControllerPreservesCapturedWindowWithoutAuditBinding
    ;;
  p3-focused-input)
    swift test --disable-automatic-resolution --filter 'FocusedTextTargetTests|VoiceSemanticTests.testNormalLocalControllerPreservesCapturedWindow|VoiceSemanticTests.testCapturedWindowGetter'
    ;;
  p3-focused-native)
    swift test --disable-automatic-resolution --filter FocusedTextTargetTests.testNativeOwnedBrowserFocusReadOnly
    ;;
  p3-window-observation)
    bash -n .agent/results/P3/window-observation/run-terminal-diagnostic.command
    swift test --disable-automatic-resolution --filter 'FastLaneExecutorTests.testForegroundUntitledOffscreenWindow|FastLaneExecutorTests.testForegroundUnknownNativeWindow|FastLaneExecutorTests.testPinnedOrNamedOpenNever|VoiceCommandTraceTests.testPhysicalTrialFailure'
    ;;
  p3-native-foreground)
    bash -n .agent/results/P3/native-foreground-settle/run-terminal-diagnostic.command
    bash -n .agent/results/P3/native-foreground-settle/settled/run-terminal-diagnostic.command
    swift test --disable-automatic-resolution --filter 'FastLaneExecutorTests.testVerifiedNativeForegroundEffect|FastLaneExecutorTests.testNativeForegroundShortcut|FastLaneExecutorTests.testNativeForegroundSettles'
    ;;
  p3-harness-coverage)
    swift test --disable-automatic-resolution --filter 'VoiceTrialReportTests|VoiceSemanticTests.testNormalSemanticRouteDoesNot'
    run_p3_evidence
    ;;
  p3-literal-verify)
    swift test --disable-automatic-resolution --filter FastLaneExecutorTests.testBoundLiteralMissingOrWrongCaseReadbackNeverClaimsDone
    ;;
  p3-audit-safety)
    python3 bench/selftest.py
    ;;
  p3-audit-native)
    swift test --disable-automatic-resolution --filter 'FastLaneExecutorTests.testCold|FastLaneExecutorTests.testNativeLaunchError|FastLaneExecutorTests.testForegroundNativeLaunch'
    ;;
  p3-audit-production)
    swift test --disable-automatic-resolution --filter 'FastLaneExecutorTests.testNativeLaunchCancelled|VoiceTaskCoordinatorLaneTests.testProductionNativeSelection|VoiceTaskCoordinatorLaneTests.testCoordinatorWorkActually'
    ;;
  p3-safe-bench)
    python3 bench/selftest.py
    python3 .agent/results/P3/probe-legacy-reset.py
    ;;
  p3-contact-probe)
    python3 .agent/results/P3/read-self-contact.py
    ;;
  p3-semantic-live)
    [[ "${JARVIS_P3_SEMANTIC_LIVE:-}" == "approved-50" ]] || {
      echo "BLOCKED: explicit capped semantic API authorization required" >&2
      exit 2
    }
    swift test --disable-automatic-resolution --filter VoiceSemanticLiveTests
    ;;
  p3)
    export JARVIS_P3_RUN_ID="$(uuidgen)"
    JARVIS_P3_EVIDENCE_DIR="$(pwd)/.agent/results/P3" swift test --disable-automatic-resolution --filter "$p3_filter"
    run_p3_evidence
    ;;
  p3-package)
    # Production-only packaging after current debug verification. This avoids
    # toggling testability flags on unchanged Core/FluidAudio dependencies.
    swift build -c release --disable-automatic-resolution
    python3 scripts/verify-p3.py record-build
    python3 scripts/verify-p3.py frontdoor
    ;;
  p3-release)
    export JARVIS_P3_RUN_ID="$(uuidgen)"
    # Testable release modules and production modules use different flags.
    # Build the final CLI explicitly after tests, then bind that artifact.
    JARVIS_P3_EVIDENCE_DIR="$(pwd)/.agent/results/P3" swift test -c release --disable-automatic-resolution --filter "$p3_filter"
    run_p3_evidence
    swift build -c release --disable-automatic-resolution
    python3 scripts/verify-p3.py record-build
    python3 scripts/verify-p3.py frontdoor
    ;;
  speech)
    swift test --package-path spikes/speech-bakeoff --disable-automatic-resolution
    if [[ "${JARVIS_RECORDER_LIVE:-0}" == "1" ]]; then
      python3 spikes/speech-bakeoff/Tests/test_recorder_cli.py
    fi
    ;;
  speech-release)
    swift test -c release --package-path spikes/speech-bakeoff --disable-automatic-resolution
    python3 -m unittest discover -s spikes/speech-bakeoff/Tests -p test_metrics.py
    if [[ "${JARVIS_RECORDER_LIVE:-0}" == "1" ]]; then
      JARVIS_RECORDER_BINARY=.build/release/bakeoff python3 spikes/speech-bakeoff/Tests/test_recorder_cli.py
    fi
    ;;
  eyes) run_eyes ;;
  all) run_swift; run_eyes ;;
  *) echo "usage: $0 [swift|p3|p3-speech-report|p3-release|p3-evidence|eyes|speech|speech-release|all]" >&2; exit 2 ;;
esac

echo "verification lane green"
