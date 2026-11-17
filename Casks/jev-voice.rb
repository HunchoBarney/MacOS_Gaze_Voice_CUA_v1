cask "jev-voice" do
  version "0.1.5"
  sha256 "e6385fbdac9e6d7aa7145e217779704bb14363f9ac984126526c39b87199de41"

  url "https://github.com/chris-wozniczek/jev-voice-control/releases/download/v#{version}/Jev-Voice-#{version}.zip"
  name "Jev Voice"
  desc "Menu-bar voice control powered by TypeSafe AI's Jev"
  homepage "https://github.com/chris-wozniczek/jev-voice-control"

  depends_on :macos

  app "Jev Voice.app"

  # The app is ad-hoc signed (no Apple Developer ID yet); drop the quarantine
  # flag so Gatekeeper does not block the first launch.
  postflight_steps do
    run "/usr/bin/xattr",
        args:         ["-dr", "com.apple.quarantine", "{{appdir}}/Jev Voice.app"],
        must_succeed: false
  end

  uninstall quit: "com.chriswozniczek.jevvoice"

  zap trash: "~/Library/Preferences/com.chriswozniczek.jevvoice.plist"

  # NOTE: this cask describes the upstream jev-voice-control distribution; the
  # local build path is `make local` (see README). Caveats below match the
  # current app, not the published zip.
  caveats <<~EOS
    Jev Voice lives in the menu bar (no Dock icon). Hold Fn/Globe to talk.
    Voice streams to OpenAI's realtime API — set an OpenAI API key in
    Settings → Voice (stored in Keychain); a ChatGPT sign-in won't work.
    Grant Microphone, Accessibility and Screen Recording when prompted
    (Camera too if you enable eye tracking), then set your TypeSafe API key
    in Settings → Commands.
    If macOS still reports the app "Not Opened" (ad-hoc signature), run:
      xattr -dr com.apple.quarantine "#{appdir}/Jev Voice.app"
  EOS
end
