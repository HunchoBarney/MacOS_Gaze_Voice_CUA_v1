APP = build/Jev Voice.app
BINARY = .build/release/JevVoice
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ZIP = build/Jev-Voice-$(VERSION).zip

.PHONY: setup build app run test test-tools dist clean

setup:
	@test "$$(sw_vers -productVersion | cut -d. -f1)" -ge 26 || (echo "macOS 26 or newer is required" >&2; exit 1)
	@test "$$(xcrun --sdk macosx --show-sdk-version | cut -d. -f1)" -ge 26 || (echo "macOS 26 SDK or newer is required" >&2; exit 1)
	@xcrun --find swift >/dev/null
	@swift --version
	@xcrun --sdk macosx --show-sdk-version
	@echo "Runtime prerequisites: see docs/DEVELOPMENT.md and ThirdParty/Cua/README.md"

build:
	swift build -c release

app: build
	mkdir -p "$(APP)/Contents/MacOS"
	cp "$(BINARY)" "$(APP)/Contents/MacOS/JevVoice"
	cp Info.plist "$(APP)/Contents/Info.plist"
	mkdir -p "$(APP)/Contents/Resources/ThirdParty/FluidVoice"
	cp ThirdParty/FluidVoice/LICENSE ThirdParty/FluidVoice/NOTICE.md "$(APP)/Contents/Resources/ThirdParty/FluidVoice/"
	# Finder metadata on a generated bundle prevents signing; retain security attributes.
	xattr -dr com.apple.FinderInfo "$(APP)" 2>/dev/null || true
	codesign --force --deep --sign - "$(APP)"

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
