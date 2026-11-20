import XCTest
@testable import Jarvis

/// GPT-Live latency and cost bench (KAR-75). Rendered speech goes straight
/// into real Live sessions through the WebRTC engine in manual rendering
/// mode, so no audio device opens and nothing is heard. Paid: it runs only
/// with JARVIS_LIVE_BENCH=1, JARVIS_LIVE_MIC=1 (the transport's own guard)
/// and JARVIS_LIVE_KEYCHAIN=1, and stops itself before
/// JARVIS_LIVE_BENCH_BUDGET dollars. Each turn and session is one JSON line
/// in JARVIS_LIVE_BENCH_OUT, with timings and counts, never transcript text.
@MainActor
final class LiveBenchTests: XCTestCase {
    private struct Line {
        let id: String
        let text: String
        let action: Bool
    }

    private static let lines = [
        Line(id: "capital", text: "What's the capital of Australia?", action: false),
        Line(id: "calculator", text: "Open Calculator.", action: true),
        Line(id: "minutes", text: "How many minutes are in a day?", action: false),
        Line(id: "note", text: "Make a new note that says buy milk.", action: true),
        Line(id: "cat", text: "Give me one good name for a cat.", action: false),
        Line(id: "volume", text: "Turn the volume down a little.", action: true),
        Line(id: "multiply", text: "What's seven times eight?", action: false),
        Line(id: "calendar", text: "Show me my calendar for tomorrow.", action: true),
        Line(id: "spell", text: "How do you spell rhythm?", action: false),
        Line(id: "search", text: "Search the web for the weather in Paris.", action: true),
    ]

    private static let instructions = """
    You are Jarvis, a calm, friendly voice assistant on a Mac. Be clear and brief: one short sentence.

    Backchannel policy: Use few backchannels.

    Interruption policy: Stop speaking when the user interrupts. Listen to what they say.

    Delegation policy:
    Backend tools:
    - Mac: open apps, create notes, change settings such as volume, show the calendar, search the web.

    Delegate to the backend when:
    - The user asks the Mac to do something.

    Do not delegate when:
    - You can answer from your own knowledge, such as facts, spelling or arithmetic.

    Delegate to the backend before saying an action is done.
    Do not guess the result while waiting.
    """

    private func ms(_ duration: Duration?) -> Int? {
        guard let duration else { return nil }
        return Int((Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1000)
    }

    private static func cost(_ usage: LiveUsage?) -> Double {
        guard let usage else { return 15 * 0.05 / 60 }
        let paused = Double(usage.pausedSeconds ?? 0)
        let active = usage.activeSeconds.map(Double.init) ?? max(usage.seconds - paused, 0)
        return max(active, 15) * 0.05 / 60 + paused * 0.02 / 60
    }

    func testLiveTurnBench() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JARVIS_LIVE_BENCH"] == "1", environment["JARVIS_LIVE_MIC"] == "1",
              environment["JARVIS_LIVE_KEYCHAIN"] == "1" else {
            throw XCTSkip("Set JARVIS_LIVE_BENCH=1, JARVIS_LIVE_MIC=1 and JARVIS_LIVE_KEYCHAIN=1 to run the paid Live bench")
        }
        #if canImport(LiveKitWebRTC)
        let sessions = Int(environment["JARVIS_LIVE_BENCH_SESSIONS"] ?? "") ?? 1
        let turns = Int(environment["JARVIS_LIVE_BENCH_TURNS"] ?? "") ?? 2
        let budget = Double(environment["JARVIS_LIVE_BENCH_BUDGET"] ?? "") ?? 0.10
        let out = URL(fileURLWithPath: environment["JARVIS_LIVE_BENCH_OUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("live-bench.jsonl").path)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let log = try FileHandle(forWritingTo: out)
        defer { try? log.close() }
        func write(_ row: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
            log.write(data + Data("\n".utf8))
            print("live_bench \(String(decoding: data, as: UTF8.self))")
        }

        let store = KeychainAPIKeyStore(service: "com.chriswozniczek.jevvoice", account: "openAIAPIKey",
                                        allowUserInteraction: false)
        let key = try XCTUnwrap(try store.read(), "no OpenAI key in Keychain")
        let rig = try LiveAudioRig(.rendered)
        let speech = try Self.lines.map { try LiveAudioRig.speech($0.text) }
        let idleTimeouts = [5, 8, 12]
        var spent = 0.0
        var completedTurns = 0

        sessionLoop: for index in 0..<sessions {
            guard spent + 0.05 < budget else { break }
            var config = LiveSessionConfig(instructions: Self.instructions)
            config.idleTimeoutS = idleTimeouts[index % idleTimeouts.count]
            let live = LiveSession(transport: WebRTCLiveTransport(), broker: LiveConnectTests.DirectLiveSessions(key: key),
                                   config: config)
            var events: [(LiveSessionEvent, ContinuousClock.Instant)] = []
            var latestUsage: LiveUsage?
            live.onEvent = { event in
                events.append((event, .now))
                if case .usage(let usage) = event { latestUsage = usage }
                if case .delegation(let delegation) = event {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        live.send(LiveAppend(kind: .commentary, content: "Done.", delegationID: delegation.id))
                        events.append((.delegation(LiveDelegation(id: "result:" + delegation.id, offsetMs: 0)), .now))
                    }
                }
            }
            let began = ContinuousClock.now
            do { try await live.start(timeout: .seconds(20)) } catch {
                write(["kind": "session", "session": index, "cold": index == 0, "error": String(describing: error)])
                spent += Self.cost(nil)
                continue
            }
            var row: [String: Any] = ["kind": "session", "session": index, "cold": index == 0,
                                      "idle_timeout_s": config.idleTimeoutS, "start_ms": ms(.now - began) ?? -1]
            for step in live.startSteps { row["step_\(step.step)_ms"] = Int(step.seconds * 1000) }

            for turn in 0..<turns {
                let sessionCost = Self.cost(latestUsage)
                guard spent + sessionCost + 0.03 < budget else {
                    write(["kind": "stop", "reason": "budget", "spent_estimate": spent + sessionCost])
                    _ = await live.close(timeout: .seconds(10))
                    spent += sessionCost
                    break sessionLoop
                }
                guard live.phase == .standby else {
                    write(["kind": "turn", "session": index, "turn": turn, "error": "not in standby: \(live.phase)"])
                    break
                }
                let pick = (index * turns + turn) % Self.lines.count
                let line = Self.lines[pick]
                events.removeAll()
                rig.clearOutput()
                let speechStart = ContinuousClock.now
                let speechEnd = speechStart + rig.play(speech[pick])

                var quietSince: ContinuousClock.Instant?
                let deadline = speechEnd + .seconds(25)
                while ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                    guard ContinuousClock.now > speechEnd + .milliseconds(500) else { continue }
                    let loud = rig.loudOutput(since: speechEnd)
                    let results = events.filter { if case .delegation(let d) = $0.0 { return d.id.hasPrefix("result:") }; return false }
                    let lastLoud = loud.last
                    let resultHeard = results.isEmpty || loud.contains { $0 > results[0].1 }
                    if let lastLoud, resultHeard, ContinuousClock.now - lastLoud > .milliseconds(1500) {
                        quietSince = lastLoud
                        break
                    }
                    if case .ended = live.phase { break }
                }
                let pausedAt: ContinuousClock.Instant? = await {
                    let pauseDeadline = ContinuousClock.now + .seconds(config.idleTimeoutS + 8)
                    while ContinuousClock.now < pauseDeadline {
                        if let paused = events.first(where: { if case .paused = $0.0 { return true }; return false }) {
                            return paused.1
                        }
                        if case .ended = live.phase { return nil }
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    return nil
                }()

                func first(_ match: (LiveSessionEvent) -> Bool) -> ContinuousClock.Instant? {
                    events.first { match($0.0) }?.1
                }
                let resumed = first { if case .resumed = $0 { return true }; return false }
                let heard = first { if case .inputTranscript = $0 { return true }; return false }
                let spoke = first { if case .outputTranscript = $0 { return true }; return false }
                let delegated = first { if case .delegation(let d) = $0 { return !d.id.hasPrefix("result:") }; return false }
                let resultSent = first { if case .delegation(let d) = $0 { return d.id.hasPrefix("result:") }; return false }
                let loud = rig.loudOutput(since: speechStart)
                let firstAudio = loud.first
                let resultAudio = resultSent.flatMap { sent in loud.first { $0 > sent } }
                let outputChars = events.reduce(0) { total, item in
                    if case .outputTranscript(let delta) = item.0 { return total + delta.text.count }
                    return total
                }
                let errors = events.compactMap { item -> String? in
                    if case .error(let error) = item.0 { return error.code ?? error.type }
                    return nil
                }
                var turnRow: [String: Any] = [
                    "kind": "turn", "session": index, "turn": turn, "line": line.id, "action": line.action,
                    "speech_ms": ms(speechEnd - speechStart) ?? 0, "delegated": delegated != nil,
                    "output_chars": outputChars, "errors": errors, "paused": pausedAt != nil,
                ]
                turnRow["resume_after_speech_start_ms"] = ms(resumed.map { $0 - speechStart })
                turnRow["input_transcript_after_speech_end_ms"] = ms(heard.map { $0 - speechEnd })
                turnRow["output_text_after_speech_end_ms"] = ms(spoke.map { $0 - speechEnd })
                turnRow["first_audio_after_speech_end_ms"] = ms(firstAudio.map { $0 - speechEnd })
                turnRow["delegation_after_speech_end_ms"] = ms(delegated.map { $0 - speechEnd })
                turnRow["result_audio_after_append_ms"] = ms(zip2(resultSent, resultAudio).map { $1 - $0 })
                turnRow["pause_after_quiet_ms"] = ms(zip2(quietSince, pausedAt).map { $1 - $0 })
                write(turnRow)
                completedTurns += 1
                if pausedAt == nil {
                    try await Task.sleep(for: .seconds(2))
                    if live.phase != .standby { break }
                }
            }
            let ending = await live.close(timeout: .seconds(10))
            let cost = Self.cost(ending.usage ?? latestUsage)
            spent += cost
            row["reason"] = String(describing: ending.reason)
            row["confirmed"] = ending.confirmed
            row["usage_seconds"] = (ending.usage ?? latestUsage)?.seconds
            row["active_seconds"] = (ending.usage ?? latestUsage)?.activeSeconds
            row["paused_seconds"] = (ending.usage ?? latestUsage)?.pausedSeconds
            row["cost"] = cost
            row["spent"] = spent
            write(row)
        }
        let stats = rig.inputStats
        write(["kind": "summary", "turns": completedTurns, "spent": spent, "budget": budget,
               "engine_starts": stats.starts, "all_offline": stats.allManual])
        XCTAssertTrue(stats.allManual, "the bench must never open an audio device")
        XCTAssertGreaterThan(completedTurns, 0)
        #else
        throw XCTSkip("WebRTC isn't fetched: run python3 -I ThirdParty/WebRTC/fetch.py first")
        #endif
    }

    private func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
        guard let a, let b else { return nil }
        return (a, b)
    }
}
