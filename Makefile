.DEFAULT_GOAL := release

APP = build/Jarvis.app
VENDOR = build/vendor
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
COMMIT := $(shell git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
ZIP = build/Jarvis-$(VERSION)-$(COMMIT).zip
KEEP_ZIPS = 3
LOCAL_APP = $(HOME)/jarvis-local/Jarvis.app

# PUBLIC=1 is the public-distribution path. It stays held until the app is
# signed with Developer ID and notarized (RELEASE.md). The default private
# build is for the owner's Mac and testers.
PUBLIC ?= 0

# Local CI: a launchd agent runs scripts/local-ci.sh poll every 5 minutes.
LOCAL_CI_HOME ?= $(HOME)/.capy/work/local-ci
LOCAL_CI_LABEL = com.karanvirkang.jarvis.local-ci
LOCAL_CI_PLIST = $(HOME)/Library/LaunchAgents/$(LOCAL_CI_LABEL).plist
LOCAL_CI_JOB = gui/$(shell id -u)/$(LOCAL_CI_LABEL)

.PHONY: setup build test tracker release install local run clean bench-flows
.PHONY: local-ci-install local-ci-pause local-ci-resume local-ci-uninstall
.PHONY: e2e e2e-install e2e-uninstall

setup:
	@test "$$(sw_vers -productVersion | cut -d. -f1)" -ge 26 || (echo "macOS 26 or newer is required" >&2; exit 1)
	@test "$$(xcrun --sdk macosx --show-sdk-version | cut -d. -f1)" -ge 26 || (echo "macOS 26 SDK or newer is required" >&2; exit 1)
	@command -v node >/dev/null || (echo "node is required for the eye tracker (brew install node)" >&2; exit 1)

build:
	swift build -c release

test:
	scripts/test-local-ci.sh
	ThirdParty/Vosk/fetch.sh "$(VENDOR)/Vosk"
	python3 -I ThirdParty/WebRTC/fetch.py "$(VENDOR)/WebRTC"
	swift test --parallel --manifest-cache none
	cd EyeTracking && corepack pnpm install --frozen-lockfile --ignore-scripts
	cd EyeTracking && corepack pnpm run typecheck
	cd EyeTracking && corepack pnpm test
	cd CredentialService && corepack pnpm install --frozen-lockfile --ignore-scripts
	cd CredentialService && corepack pnpm run typecheck
	cd CredentialService && corepack pnpm test

# Build the eye tracker from source: dependencies, Electron, pinned models,
# the renderer bundle, and the camera usage strings Electron needs.
tracker: setup
	cd EyeTracking && corepack pnpm install --frozen-lockfile --ignore-scripts
	cd EyeTracking && (unset ELECTRON_OVERRIDE_DIST_PATH ELECTRON_SKIP_BINARY_DOWNLOAD; node node_modules/electron/install.js)
	cd EyeTracking && bash scripts/fetch-models.sh
	cd EyeTracking && corepack pnpm build
	cd EyeTracking && bash scripts/patch-electron-app.sh

ifeq ($(PUBLIC),1)
release:
	@echo "release: public distribution is held until Developer ID signing and notarization (see RELEASE.md)" >&2
	@exit 1
else
# One build from source: pinned runtimes, release Swift binary, tracker,
# stage, sign, zip and checksum. build/Jarvis.app is overwritten every
# time and only the newest $(KEEP_ZIPS) zips are kept.
release: setup tracker
	python3 -I ThirdParty/WebRTC/fetch.py "$(VENDOR)/WebRTC"
	swift build -c release --manifest-cache none
	ThirdParty/Cua/fetch-embedded-binaries.sh "$(VENDOR)"
	ThirdParty/Vosk/fetch.sh "$(VENDOR)/Vosk"
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources/ThirdParty/CuaDriver" "$(APP)/Contents/Resources/ThirdParty/SileroVAD" "$(APP)/Contents/Resources/ThirdParty/Vosk"
	cp .build/release/Jarvis "$(APP)/Contents/MacOS/Jarvis"
	cp Info.plist "$(APP)/Contents/Info.plist"
	cp "$(VENDOR)/cua-driver" "$(APP)/Contents/Resources/cua-driver"
	ditto "$(VENDOR)/CodexRuntime" "$(APP)/Contents/Resources/CodexRuntime"
	cp ThirdParty/Cua/LICENSE.md ThirdParty/Cua/THIRD_PARTY_NOTICES.md "$(APP)/Contents/Resources/ThirdParty/CuaDriver/"
	ditto ThirdParty/SileroVAD/silero-vad-unified-256ms-v6.2.1.mlmodelc "$(APP)/Contents/Resources/SileroVAD/silero-vad-unified-256ms-v6.2.1.mlmodelc"
	cp ThirdParty/SileroVAD/LICENSE ThirdParty/SileroVAD/README.md "$(APP)/Contents/Resources/ThirdParty/SileroVAD/"
	mkdir -p "$(APP)/Contents/Resources/Vosk"
	cp "$(VENDOR)/Vosk/libvosk.dylib" "$(APP)/Contents/Resources/Vosk/libvosk.dylib"
	ditto "$(VENDOR)/Vosk/model" "$(APP)/Contents/Resources/Vosk/model"
	cp ThirdParty/Vosk/LICENSE ThirdParty/Vosk/README.md "$(APP)/Contents/Resources/ThirdParty/Vosk/"
	mkdir -p "$(APP)/Contents/Frameworks" "$(APP)/Contents/Resources/ThirdParty/WebRTC"
	ditto "$(VENDOR)/WebRTC/LiveKitWebRTC.xcframework/macos-arm64_x86_64/LiveKitWebRTC.framework" "$(APP)/Contents/Frameworks/LiveKitWebRTC.framework"
	install_name_tool -add_rpath @executable_path/../Frameworks "$(APP)/Contents/MacOS/Jarvis"
	cp "$(VENDOR)/WebRTC/LiveKitWebRTC.xcframework/LICENSE" "$(APP)/Contents/Resources/ThirdParty/WebRTC/LICENSE"
	cp ThirdParty/WebRTC/README.md "$(APP)/Contents/Resources/ThirdParty/WebRTC/"
	scripts/bundle-tracker.sh "$(APP)"
	python3 scripts/check-packaged-tracker.py "$(APP)"
	scripts/sign-app.sh "$(APP)"
	rm -f "$(ZIP)" "$(ZIP).sha256"
	ditto -c -k --keepParent "$(APP)" "$(ZIP)"
	cd build && shasum -a 256 "$(notdir $(ZIP))" > "$(notdir $(ZIP)).sha256"
	@ls -t build/Jarvis-*.zip | tail -n +$$(($(KEEP_ZIPS) + 1)) | while read -r old; do rm -f "$$old" "$$old.sha256"; done
	@du -sh "$(APP)" "$(ZIP)"
	@cat "$(ZIP).sha256"
endif

# Copy the release build to ~/jarvis-local without launching it.
install: release
	mkdir -p "$(dir $(LOCAL_APP))"
	rm -rf "$(LOCAL_APP)"
	ditto "$(APP)" "$(LOCAL_APP)"
	codesign --verify --deep --strict "$(LOCAL_APP)"
	@echo "installed $(LOCAL_APP)"

# Install, then quit any running copy and open the new one. pgrep never
# sends Apple Events, so probing does not launch the app; the [.] keeps
# this recipe's own command line from matching.
local: install
	@if pgrep -f "Jarvis[.]app/Contents/MacOS/Jarvis" >/dev/null 2>&1; then \
	    osascript -e 'tell application id "com.karanvirkang.jarvis" to quit' >/dev/null 2>&1 || true; \
	    for i in $$(seq 15); do pgrep -f "Jarvis[.]app/Contents/MacOS/Jarvis" >/dev/null 2>&1 || break; sleep 1; done; \
	fi; \
	if pgrep -f "Jarvis[.]app/Contents/MacOS/Jarvis" >/dev/null 2>&1; then \
	    echo "an old Jarvis is still running — quit it and retry" >&2; exit 1; \
	fi
	open "$(LOCAL_APP)"
	@sleep 3; pgrep -f "Jarvis[.]app/Contents/MacOS/Jarvis" >/dev/null 2>&1 || \
	    (echo "Jarvis exited right after launch — run \"$(LOCAL_APP)/Contents/MacOS/Jarvis\" to see why" >&2; exit 1)
	@echo "Jarvis is running"

# Phase 0 flow benchmark (Tests/JarvisAppTests/FlowBenchTests.swift): typed transcripts through
# the production path against a fixture desk, no model call, no desktop
# change. Rows append to bench/results/flows.jsonl under BENCH_LABEL.
BENCH_LABEL ?= $(COMMIT)
BENCH_RUNS ?= 15
bench-flows:
	@mkdir -p bench/results
	JARVIS_BENCH_FLOWS=1 JARVIS_BENCH_RUNS=$(BENCH_RUNS) JARVIS_BENCH_LABEL=$(BENCH_LABEL) \
	    JARVIS_BENCH_OUT=$(CURDIR)/bench/results/flows.jsonl \
	    scripts/lane-test.sh swift test --filter FlowBenchTests
	python3 bench/flows/report.py bench/results/flows.jsonl $(wildcard bench/results/realtime.jsonl)

run: local

clean:
	rm -rf build .build

# launchd can't read ~/Documents, so the agent runs an installed copy of the
# script. Rerun this target after changing scripts/local-ci.sh.
local-ci-install:
	mkdir -p "$(LOCAL_CI_HOME)/bin" "$(LOCAL_CI_HOME)/logs" "$(dir $(LOCAL_CI_PLIST))"
	install -m 755 scripts/local-ci.sh "$(LOCAL_CI_HOME)/bin/local-ci.sh"
	sed 's|@CI_HOME@|$(LOCAL_CI_HOME)|g' scripts/local-ci.plist > "$(LOCAL_CI_PLIST)"
	plutil -lint "$(LOCAL_CI_PLIST)"
	launchctl bootout $(LOCAL_CI_JOB) 2>/dev/null || true
	launchctl enable $(LOCAL_CI_JOB)
	launchctl bootstrap gui/$$(id -u) "$(LOCAL_CI_PLIST)"
	@echo "local CI polls every 5 minutes; log $(LOCAL_CI_HOME)/logs/poll.log"

# Pausing stops a running job too; its head is retried after resume.
local-ci-pause:
	launchctl disable $(LOCAL_CI_JOB)
	launchctl bootout $(LOCAL_CI_JOB) 2>/dev/null || true

local-ci-resume:
	launchctl enable $(LOCAL_CI_JOB)
	launchctl bootstrap gui/$$(id -u) "$(LOCAL_CI_PLIST)"

local-ci-uninstall:
	launchctl bootout $(LOCAL_CI_JOB) 2>/dev/null || true
	launchctl enable $(LOCAL_CI_JOB)
	rm -f "$(LOCAL_CI_PLIST)"
	@echo "removed the agent; checkout and logs remain in $(LOCAL_CI_HOME)"

# End-to-end flows on a signed Jarvis (e2e/README.md), one desktop-lock owner
# at a time. They launch Jarvis, speak to it and open Calculator, so run them
# only when the owner says go. JARVIS_E2E_APP picks the build.
e2e:
	scripts/with-desktop-lock.py e2e/scripts/run.sh

e2e-install:
	e2e/scripts/install.sh

e2e-uninstall:
	e2e/scripts/uninstall.sh
