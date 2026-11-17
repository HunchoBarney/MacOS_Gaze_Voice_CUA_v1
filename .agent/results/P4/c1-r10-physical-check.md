# R10 normal app check

Signed candidate is running normally through LaunchServices:
`~/jarvis-local/c1-candidates/jev-c1-final-r10-y6wbos0n/Jev Voice.app`.
Executable2261f60b64e0c8cb26a5996c62ee3154e1c2afc86481847e2e479cb9ab30d5f0.
Source2 voice review and source3 packaging/artifact review PASS;
181 Swift tests (1 optional skip),15 package checks,0 failures.

Current live evidence: `c1-r10-live-517183df9f/`.
App PID23708 at last observation. Initial normal-launch helper completed
with startup_pending; no health file yet. Native process sample proves
Config.init is waiting inside KeychainAPIKeyStore.read/SecItemCopyMatching
before VoiceController/microphone startup.

Observed and raised the actual SecurityAgent window:
"Jev Voice wants to access key ... in your keychain." It requests the
login Keychain password and offers Always Allow/Deny/Allow. Only static
labels were read and the window raised. No password field was read,
no authorization button clicked, no key copied. User has been asked
to approve it directly on their Mac. Leave this app/dialog running.

After the user clears the OS prompt:

1. Read new health/voice events and actual app UI. Confirm Realtime
   session and listening readiness; don't infer it from process existence.
2. In the already-open disposable `Jev hands-free check.txt`, the user
   speaks naturally without Fn: a question, a small scroll, a related
   follow-up, continued scroll and stop. Exact phrases are not required.
3. Ask to open Calculator and return to this document. Interrupt a spoken
   reply and continue; check listening persists and the prior response
   cannot act later.
4. Preserve the separate physical Fn/literal dictation/Escape obligation.
   Use the disposable document and check final words/exactly-once insertion.

No physical speech, actual Realtime readiness, speech-to-effect latency,
accuracy comparison or whole C1 acceptance is claimed yet. Authentication
waiting is not a measured voice-performance result. No synthetic speech
or typed turn is a substitute for human G6.

Original daily app is missing, cause unknown, not restored. The intact
verified R9-2 candidate is the explicitly recorded retained fallback.
No daily installation, commits or pushes.
