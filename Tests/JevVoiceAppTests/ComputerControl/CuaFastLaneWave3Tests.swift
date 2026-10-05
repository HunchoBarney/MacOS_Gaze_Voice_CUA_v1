import XCTest
import JevVoiceCore
@testable import JevVoice

/// Wave-3 fast lanes: production-string regressions, qualifier peel edges,
/// and the widened phrase coverage.
@MainActor
final class CuaFastLaneWave3Tests: XCTestCase {

    private func app(_ name: String, bundle: String, running: Bool = false, pid: Int = 0) -> JSONValue {
        .object(["name": .string(name), "bundle_id": .string(bundle),
                 "running": .bool(running), "pid": .number(Double(pid))])
    }

    /// The exact production utterance that fell to the drive loop.
    func testProductionSearchSpotifyStringLanes() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Spotify", bundle: "com.spotify.client", running: true, pid: 9),
                    app("Notes", bundle: "com.apple.Notes", running: true, pid: 5)]
        let resolved = sut.resolveFastLane(goal: "search Spotify for Marvin's Room", apps: apps)
        XCTAssertEqual(resolved?.bundle, "com.spotify.client")
        guard case .appSearch(let query, let play) = resolved?.action?.body else {
            return XCTFail("expected appSearch, got \(String(describing: resolved?.action?.body))")
        }
        XCTAssertEqual(query, "marvins room")
        XCTAssertFalse(play)
        XCTAssertEqual(resolved?.launchURLs, ["spotify:search:marvins%20room"])
    }

    /// "exit fullscreen" must reach the fullscreen-toggle lane, not the
    /// quit-app lane ("exit" is otherwise a quit verb). Generic window
    /// chords resolve against the frontmost app.
    func testExitFullscreenIsNotAQuitLane() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Spotify", bundle: "com.spotify.client", running: true, pid: 9)]
        for phrase in ["exit fullscreen", "exit full screen", "exit full-screen"] {
            let resolved = sut.resolveFastLane(goal: phrase, apps: apps,
                                               frontmostBundleOverride: "com.spotify.client")
            guard case .hotkey = resolved?.action?.body else {
                return XCTFail("\(phrase) expected hotkey lane, got \(String(describing: resolved?.action?.body))")
            }
        }
    }

    /// Flattened possessives and s-ending app names survive suffix stripping
    /// via the trailing-'s' fallback in namedApp.
    func testPossessiveSuffixDoesNotMangleSEndingAppNames() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Plus", bundle: "com.example.plus", running: true, pid: 9),
                    app("Spotify", bundle: "com.spotify.client", running: true, pid: 5)]
        let resolved = sut.resolveFastLane(goal: "minimize Plus window", apps: apps)
        XCTAssertEqual(resolved?.bundle, "com.example.plus")
        let resolved2 = sut.resolveFastLane(goal: "minimize Spotify's windows", apps: apps)
        XCTAssertEqual(resolved2?.bundle, "com.spotify.client")
    }

    /// "search and play ..." should take the same deterministic Spotify lane
    /// as "play ..." instead of falling into the drive loop's Electron typing.
    func testSearchAndPlayRoutesToSpotifyFastLane() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Spotify", bundle: "com.spotify.client", running: true, pid: 9)]
        let resolved = sut.resolveFastLane(goal: "search and play No Mistakes by Kanye", apps: apps)
        XCTAssertEqual(resolved?.bundle, "com.spotify.client")
        guard case .appSearch(_, let play) = resolved?.action?.body else {
            return XCTFail("expected appSearch, got \(String(describing: resolved?.action?.body))")
        }
        XCTAssertTrue(play)
        XCTAssertEqual(resolved?.launchURLs, ["spotify:search:no%20mistakes%20by%20kanye"])
    }

    /// Foreground phrasings are open-verbs with the verified-raise contract —
    /// the exact production utterances that fell into the 17s drive lane.
    func testBringToFrontIsAFastLane() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Messages", bundle: "com.apple.MobileSMS", running: true, pid: 7),
                    app("Notes", bundle: "com.apple.Notes", running: true, pid: 5)]
        for (phrase, verb) in [("bring messages to the front", "bring"),
                               ("bring messages forward", "bring"),
                               ("bring messages up", "bring"),
                               ("bring messages up front", "bring"),
                               ("foreground messages", "foreground"),
                               ("pull up messages", "pull up"),
                               ("bring up messages", "bring up")] {
            let resolved = sut.resolveFastLane(goal: phrase, apps: apps)
            XCTAssertEqual(resolved?.bundle, "com.apple.MobileSMS", phrase)
            XCTAssertEqual(resolved?.openVerb, verb, phrase)
        }
        XCTAssertTrue(CuaFastAction.openRequiresRaise(goal: "bring messages to the front"))
        XCTAssertTrue(CuaFastAction.openRequiresRaise(goal: "foreground notes"))
        XCTAssertFalse(CuaFastAction.openRequiresRaise(goal: "open messages"))
    }

    /// "bring it to the front" names what the user is looking at — the
    /// frontmost app, resolved through the captured hint.
    func testPronounResolvesToFrontmost() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Messages", bundle: "com.apple.MobileSMS", running: true, pid: 7),
                    app("Notes", bundle: "com.apple.Notes", running: true, pid: 5)]
        let resolved = sut.resolveFastLane(goal: "bring it to the front", apps: apps,
                                           frontmostBundleOverride: "com.apple.MobileSMS")
        XCTAssertEqual(resolved?.bundle, "com.apple.MobileSMS")
        XCTAssertEqual(resolved?.openVerb, "bring")
        // No frontmost app → the pronoun can't resolve, stays with the loop.
        XCTAssertNil(sut.resolveFastLane(goal: "bring it to the front", apps: apps,
                                         frontmostBundleOverride: "com.example.unknown"))
    }
}
