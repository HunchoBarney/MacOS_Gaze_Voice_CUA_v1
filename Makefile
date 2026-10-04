.DEFAULT_GOAL := build

APP = build/Jev Voice.app
BINARY = .build/release/JevVoice
VENDOR = build/vendor
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ZIP = build/Jev-Voice-$(VERSION).zip

.PHONY: setup build app run test test-tools dist clean vendor

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

app: build vendor
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$(BINARY)" "$(APP)/Contents/MacOS/JevVoice"
	cp Info.plist "$(APP)/Contents/Info.plist"
	mkdir -p "$(APP)/Contents/Resources"
	# The pinned driver is embedded so spawned children inherit this app's
	# TCC identity; CuaDependency falls back to the installed driver when
	# the bundle has no embedded copy.
	cp "$(VENDOR)/cua-driver" "$(APP)/Contents/Resources/cua-driver"
	rm -rf "$(APP)/Contents/Resources/CodexRuntime"
	cp -R "$(VENDOR)/CodexRuntime" "$(APP)/Contents/Resources/CodexRuntime"
	mkdir -p "$(APP)/Contents/Resources/ThirdParty/FluidVoice"
	cp ThirdParty/FluidVoice/LICENSE ThirdParty/FluidVoice/NOTICE.md "$(APP)/Contents/Resources/ThirdParty/FluidVoice/"
	# Finder metadata on a generated bundle prevents signing; retain security attributes.
	xattr -dr com.apple.FinderInfo "$(APP)" 2>/dev/null || true
	# A stable self-signed identity keeps macOS TCC grants (Accessibility,
	# Screen Recording, Microphone) across rebuilds — adhoc signatures key on
	# cdhash, so every rebuild invalidates permissions and macOS re-prompts.
	# Embedded runtimes carry foreign signatures (cua-driver's is bound to the
	# CuaDriver.app Info.plist, which kills it on exec), and `codesign --deep`
	# does not reach loose binaries under Resources — sign each nested Mach-O
	# explicitly before sealing the app.
	@IDENTITY=$$(security find-identity -v -p codesigning | sed -n 's/.*"\(Jev Voice Local Dev\)"/\1/p' | head -1); \
	SIGN="-"; [ -n "$$IDENTITY" ] && SIGN="$$IDENTITY"; \
	find "$(APP)/Contents/Resources" -type f | while read -r file; do \
		case "$$(file -b "$$file")" in Mach-O*) codesign --force --sign "$$SIGN" "$$file" ;; esac; \
	done; \
	codesign --force --deep --sign "$$SIGN" "$(APP)"

run: app
	open "$(APP)"

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
