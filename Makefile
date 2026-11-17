.DEFAULT_GOAL := build

APP = build/Jev Voice.app
BINARY = .build/release/JevVoice
VENDOR = build/vendor
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ZIP = build/Jev-Voice-$(VERSION).zip

# `make local` is the everyday path: build → stage → sign → install to
# ~/jarvis-local → relaunch. Staging/signing outside the synced Documents
# checkout sidesteps the com.apple.provenance detritus that makes in-place
# codesign fail spuriously here (see AGENTS.md).
LOCAL_DIR ?= $(HOME)/jarvis-local
LOCAL_APP = $(LOCAL_DIR)/Jev Voice.app
STAGE_APP ?= $(APP)

.PHONY: setup build app run local stage test test-tools dist clean vendor tracker-deps bundle-tracker check-tracker install-tracker

setup:
	@test "$$(sw_vers -productVersion | cut -d. -f1)" -ge 26 || (echo "macOS 26 or newer is required" >&2; exit 1)
	@test "$$(xcrun --sdk macosx --show-sdk-version | cut -d. -f1)" -ge 26 || (echo "macOS 26 SDK or newer is required" >&2; exit 1)
	@xcrun --find swift >/dev/null
	@swift --version
	@xcrun --sdk macosx --show-sdk-version
	@echo "Runtime prerequisites: see ThirdParty/Cua/README.md and AGENTS.md"

build:
	swift build -c release

vendor:
	ThirdParty/Cua/fetch-embedded-binaries.sh "$(VENDOR)"

# Assemble the bundle without signing — STAGE_APP picks the destination.
stage: build vendor
	mkdir -p "$(STAGE_APP)/Contents/MacOS"
	cp "$(BINARY)" "$(STAGE_APP)/Contents/MacOS/JevVoice"
	cp Info.plist "$(STAGE_APP)/Contents/Info.plist"
	mkdir -p "$(STAGE_APP)/Contents/Resources"
	# The pinned driver is embedded so spawned children inherit this app's
	# TCC identity; CuaDependency falls back to the installed driver when
	# the bundle has no embedded copy.
	cp "$(VENDOR)/cua-driver" "$(STAGE_APP)/Contents/Resources/cua-driver"
	rm -rf "$(STAGE_APP)/Contents/Resources/CodexRuntime"
	cp -R "$(VENDOR)/CodexRuntime" "$(STAGE_APP)/Contents/Resources/CodexRuntime"
	mkdir -p "$(STAGE_APP)/Contents/Resources/ThirdParty/FluidVoice"
	cp ThirdParty/FluidVoice/LICENSE ThirdParty/FluidVoice/NOTICE.md "$(STAGE_APP)/Contents/Resources/ThirdParty/FluidVoice/"
	mkdir -p "$(STAGE_APP)/Contents/Resources/ThirdParty/CuaDriver"
	cp ThirdParty/Cua/LICENSE.md ThirdParty/Cua/THIRD_PARTY_NOTICES.md "$(STAGE_APP)/Contents/Resources/ThirdParty/CuaDriver/"
	python3 scripts/bundle-conversation-vad.py --app "$(STAGE_APP)"
	# Tracker payload — staged into Contents/Resources/EyeTracker/ when the
	# EyeTracking checkout can produce a complete one (built dist/ + a pnpm
	# node_modules), warned and skipped when it can't: a bare app must still
	# build for dev. SKIP_TRACKER_BUNDLE=1 bypasses the copy entirely.
	scripts/bundle-tracker.sh --if-present "$(STAGE_APP)"

app: stage
	scripts/sign-app.sh "$(APP)"
	@scripts/check-tracker.sh --brief "$(APP)" || \
		echo "app: no eye tracker resolves for this bundle — gaze verbs will refuse (run \`make tracker-deps bundle-tracker\`)" >&2

# Tracker prerequisites — checked (not rebuilt) on every `make local`, so
# it's fast when satisfied. Each step is idempotent; SKIP_TRACKER_DEPS=1
# bypasses the whole thing (e.g. a CI run that never launches the tracker).
ifndef SKIP_TRACKER_DEPS
tracker-deps:
	@NODE=""; \
	for c in /opt/homebrew/bin/node /usr/local/bin/node "$$(command -v node 2>/dev/null)"; do \
		if [ -n "$$c" ] && [ -x "$$c" ]; then NODE="$$c"; break; fi; \
	done; \
	if [ -z "$$NODE" ]; then \
		echo "tracker-deps: node not found (checked /opt/homebrew/bin/node, /usr/local/bin/node, PATH)" >&2; \
		echo "tracker-deps: install node (brew install node) or rerun with SKIP_TRACKER_DEPS=1" >&2; \
		exit 1; \
	fi; \
	echo "tracker-deps: node = $$NODE"; \
	export PATH="$$(dirname "$$NODE"):$$PATH"; \
	cd "$(CURDIR)/EyeTracking" || exit 1; \
	if [ ! -d node_modules ]; then \
		echo "tracker-deps: node_modules missing — corepack pnpm install --frozen-lockfile"; \
		corepack pnpm install --frozen-lockfile || exit 1; \
	fi; \
	if [ ! -f dist/index.html ]; then \
		echo "tracker-deps: dist/index.html missing — corepack pnpm build"; \
		corepack pnpm build > /tmp/jev-tracker-build.log 2>&1 \
			|| { tail -n 25 /tmp/jev-tracker-build.log >&2; \
			     echo "tracker-deps: pnpm build failed — full log at /tmp/jev-tracker-build.log" >&2; exit 1; }; \
		tail -n 3 /tmp/jev-tracker-build.log; \
	fi; \
	if [ -f scripts/fetch-models.sh ]; then \
		echo "tracker-deps: running scripts/fetch-models.sh"; \
		bash scripts/fetch-models.sh \
			|| echo "tracker-deps: fetch-models.sh ended nonzero — it prints any manual step itself; continuing"; \
	fi; \
	if [ -f scripts/patch-electron-app.sh ]; then \
		echo "tracker-deps: running scripts/patch-electron-app.sh"; \
		bash scripts/patch-electron-app.sh || exit 1; \
	fi; \
	echo "tracker-deps: satisfied"
else
tracker-deps:
	@echo "tracker-deps: SKIP_TRACKER_DEPS set — skipped"
endif

# Build, sign, install and relaunch the app in one step. The tracker
# checkout is linked into app support so the bundle finds it wherever it
# lives — no env vars, no launchctl.
local: tracker-deps
	$(MAKE) stage STAGE_APP="$(LOCAL_APP)"
	scripts/sign-app.sh "$(LOCAL_APP)"
	mkdir -p "$$HOME/Library/Application Support/JevVoice"
	ln -sfn "$(CURDIR)/EyeTracking" "$$HOME/Library/Application Support/JevVoice/EyeTracking"
	@scripts/check-tracker.sh --brief "$(LOCAL_APP)" || \
		echo "local: no eye tracker resolves for this install — gaze will be unavailable (run \`make tracker-deps\` and retry)" >&2
	# `tell application id … to quit` LAUNCHES the app when it isn't
	# running — probe for a live process first (pgrep, no Apple Events, so
	# no Automation prompt either) and only then ask it to quit.
	@if pgrep -f "Jev Voice[.]app/Contents/MacOS/JevVoice" >/dev/null 2>&1; then \
		echo "Jev Voice is running — asking it to quit"; \
		osascript -e 'tell application id "com.chriswozniczek.jevvoice" to quit' >/dev/null 2>&1 || true; \
	else \
		echo "Jev Voice isn't running — nothing to quit"; \
	fi
	# The quit is async — wait for the pid to actually exit before opening
	# the new copy, or the instance lock kills the newcomer. The [.] keeps
	# this recipe's own command line from self-matching pgrep/pkill.
	@for i in $$(seq 15); do \
		pgrep -f "Jev Voice[.]app/Contents/MacOS/JevVoice" >/dev/null 2>&1 || break; \
		sleep 1; \
	done; \
	if pgrep -f "Jev Voice[.]app/Contents/MacOS/JevVoice" >/dev/null 2>&1; then \
		echo "old Jev Voice still alive after 15s — pkill"; \
		pkill -f "Jev Voice[.]app/Contents/MacOS/JevVoice" || true; \
		for i in $$(seq 5); do \
			pgrep -f "Jev Voice[.]app/Contents/MacOS/JevVoice" >/dev/null 2>&1 || break; \
			sleep 1; \
		done; \
	fi; \
	if pgrep -f "Jev Voice[.]app/Contents/MacOS/JevVoice" >/dev/null 2>&1; then \
		echo "ERROR: an old Jev Voice refuses to die — kill it by hand before relaunching" >&2; \
		exit 1; \
	fi
	open "$(LOCAL_APP)"
	# `open` returning only means LaunchServices accepted the request — a
	# launch that crashes (bad signature, missing dylib, held lock) would
	# otherwise look exactly like success. Verify a real process exists.
	@sleep 3; \
	if ! pgrep -f "Jev Voice[.]app/Contents/MacOS/JevVoice" >/dev/null 2>&1; then \
		echo "ERROR: Jev Voice exited within 3s of launch." >&2; \
		echo "  run it by hand to see the failure: \"$(LOCAL_APP)/Contents/MacOS/JevVoice\"" >&2; \
		exit 1; \
	fi; \
	echo "Jev Voice is running"
	# /ready is the honest readiness signal — 200 means the tracker is
	# producing frames, 503 means its API is up but still starting. An
	# orphaned tracker can serve /health while the app is dead, so the app
	# pid is re-checked on every pass through this loop.
	@echo "Waiting for the tracker API (/ready)…"; \
	for i in $$(seq 90); do \
		if ! pgrep -f "Jev Voice[.]app/Contents/MacOS/JevVoice" >/dev/null 2>&1; then \
			echo "ERROR: Jev Voice died while waiting for the tracker — check ~/Library/Application Support/JevVoice/tracker.log" >&2; \
			exit 1; \
		fi; \
		code=$$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:47892/ready" 2>/dev/null); \
		if [ "$$code" = "200" ]; then \
			echo "tracker producing frames — all set"; \
			exit 0; \
		elif [ "$$code" = "503" ]; then \
			[ $$((i % 10)) -eq 0 ] && echo "tracker API up — still starting ($${i}s)"; \
		elif [ $$((i % 15)) -eq 0 ]; then \
			echo "tracker not ready yet (HTTP $$code — a persistent 404 means this EyeTracking build predates /ready)"; \
		fi; \
		sleep 1; \
	done; \
	echo "tracker not ready after 90s — the app is still running; check ~/Library/Application Support/JevVoice/tracker.log" >&2; \
	exit 1

# Stage the tracker payload into the staged app — strict: fails when
# EyeTracking can't produce a complete payload. `stage`/`app`/`local`
# already include it opportunistically; this target is the explicit,
# verified path. Layout contract: Contents/Resources/EyeTracker/ with
# scripts/start-prod.cjs, dist/, electron/, a pruned pnpm node_modules and
# bin/node — see the header of scripts/bundle-tracker.sh.
bundle-tracker: tracker-deps stage
	scripts/bundle-tracker.sh "$(STAGE_APP)"

# Report which tracker resolution path the staged app would use
# (env / sibling checkout / app-support install / bundled payload).
check-tracker:
	@scripts/check-tracker.sh "$(STAGE_APP)"

# Installed-layout alternative to bundling: real files (not the symlink
# `make local` creates) at the app-support location TrackerHost probes.
# Writable at runtime, so tracker calibration writes don't dirty the
# signed bundle — for running the app without keeping this checkout.
install-tracker:
	scripts/bundle-tracker.sh --dest "$$HOME/Library/Application Support/JevVoice/EyeTracking"

# `run` routes through the installed copy — in this checkout the
# in-place bundle can't sign (provenance detritus), and an unsigned
# rebuild throws away every TCC grant anyway.
run: local

test: test-tools
	swift test

test-tools:
	python3 -B -m unittest discover -s Tests/Tooling -v

# Zip suitable for a GitHub release asset / Homebrew cask (ditto preserves signatures).
dist: app
	rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(ZIP)"
	shasum -a 256 "$(ZIP)"

clean:
	rm -rf build .build
