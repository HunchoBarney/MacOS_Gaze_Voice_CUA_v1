import XCTest
import JevVoiceCore
@testable import JevVoice

/// Hunt fixes: peeled media qualifiers, punctuated fillers, vague
/// open-referents, multi-quoted payloads, the rightmost qualifier peel,
/// and the in-memory-only driver verify record.
@MainActor
final class CuaFastLaneHuntTests: XCTestCase {

    private func app(_ name: String, bundle: String, running: Bool = false, pid: Int = 0) -> JSONValue {
        .object(["name": .string(name), "bundle_id": .string(bundle),
                 "running": .bool(running), "pid": .number(Double(pid))])
    }

    // MARK: - Peeled media qualifiers

    /// A media phrase that peeled a qualifier can't be scoped by it — the
    /// system keys are global. "play it in spotify" is a resume, never a
    /// literal app search for "it"; the agent loop owns the peeled form.
    func testPeeledMediaPhraseIsNotALiteralSearch() {
        for phrase in ["play it in spotify",
                       "play the next song in spotify",
                       "play music in spotify",
                       "play that in spotify",
                       "next track in spotify",
                       "pause in spotify"] {
            XCTAssertNil(CuaFastAction.parse(phrase), phrase)
        }
        // The unpeeled forms keep their whole-phrase media-key lanes.
        XCTAssertEqual(CuaFastAction.parse("play it")?.action.body, .mediaKey(.playPause))
        XCTAssertEqual(CuaFastAction.parse("play the next song")?.action.body, .mediaKey(.nextTrack))
        XCTAssertEqual(CuaFastAction.parse("play music")?.action.body, .mediaKey(.playPause))
    }

    /// Referents that escaped mediaTable still aren't literal queries —
    /// "play a song in spotify" must not search Spotify for "a song".
    func testVaguePlayQueryIsNotAnAppSearch() {
        for phrase in ["play a song in spotify",
                       "play it in spotify",
                       "search and play the next song in spotify"] {
            XCTAssertNil(CuaFastAction.parse(phrase), phrase)
        }
    }

    /// The production failure mode: a peeled "play it" became
    /// appSearch("it", playTopHit: true) on Spotify and played whatever
    /// the top hit was. No lane at all is the honest answer.
    func testPeeledPlayPronounNeverReachesSpotifySearch() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Spotify", bundle: "com.spotify.client", running: true, pid: 9)]
        XCTAssertNil(sut.resolveFastLane(goal: "play it in spotify", apps: apps))
        // A real title keeps the deterministic lane.
        let resolved = sut.resolveFastLane(goal: "play never gonna give you up in spotify",
                                           apps: apps)
        XCTAssertEqual(resolved?.bundle, "com.spotify.client")
        guard case .appSearch(let query, let play) = resolved?.action?.body else {
            return XCTFail("expected appSearch, got \(String(describing: resolved?.action?.body))")
        }
        XCTAssertEqual(query, "never gonna give you up")
        XCTAssertTrue(play)
    }

    // MARK: - Punctuated fillers

    /// stripFillers ran on raw text and required whitespace after the
    /// filler — a spoken comma ("Jarvis, type hello") blocked the strip
    /// and the type lane never matched.
    func testPunctuatedFillerStillReachesTheTypeLane() {
        XCTAssertEqual(CuaFastAction.parse("Jarvis, type hello")?.action.body, .type("hello"))
        XCTAssertEqual(CuaFastAction.parse("Hey Jarvis, type hello")?.action.body, .type("hello"))
        XCTAssertEqual(CuaFastAction.parse("Jarvis type hello")?.action.body, .type("hello"))
        XCTAssertEqual(CuaFastAction.parse("type hello")?.action.body, .type("hello"))
    }

    // MARK: - Vague referents

    /// "open the app" used to substring-match "app" inside "App Store".
    /// The bare word names the app in front — or nothing.
    func testOpenTheAppResolvesFrontmostNotAppStore() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("App Store", bundle: "com.apple.AppStore", running: true, pid: 8),
                    app("Notes", bundle: "com.apple.Notes", running: true, pid: 5)]
        let resolved = sut.resolveFastLane(goal: "open the app", apps: apps,
                                           frontmostBundleOverride: "com.apple.Notes")
        XCTAssertEqual(resolved?.bundle, "com.apple.Notes")
        XCTAssertEqual(resolved?.openVerb, "open")
        // No resolvable frontmost → the loop owns it; never App Store.
        XCTAssertNil(sut.resolveFastLane(goal: "open the app", apps: apps,
                                         frontmostBundleOverride: "com.example.unknown"))
        XCTAssertNil(sut.resolveFastLane(goal: "open an application", apps: apps,
                                         frontmostBundleOverride: "com.example.unknown"))
    }

    /// A pronoun that can't resolve to the frontmost app must never fall
    /// through to text matching — "it" uniquely substring-matches
    /// "Digital Color Meter" and would foreground the wrong app.
    func testPronounNeverTextMatchesAnApp() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Digital Color Meter", bundle: "com.apple.DigitalColorMeter",
                        running: true, pid: 4)]
        XCTAssertNil(sut.resolveFastLane(goal: "bring it to the front", apps: apps,
                                         frontmostBundleOverride: "com.example.unknown"))
        // With a resolvable frontmost app the pronoun still lanes.
        let resolved = sut.resolveFastLane(goal: "bring it to the front", apps: apps,
                                           frontmostBundleOverride: "com.apple.DigitalColorMeter")
        XCTAssertEqual(resolved?.bundle, "com.apple.DigitalColorMeter")
        XCTAssertEqual(resolved?.openVerb, "bring")
    }

    /// Articles are packaging like "the" — "open a notes app" names Notes.
    func testOpenArticlePrefixResolvesTheNamedApp() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Notes", bundle: "com.apple.Notes", running: true, pid: 5)]
        XCTAssertEqual(sut.resolveFastLane(goal: "open a notes app", apps: apps)?.bundle,
                       "com.apple.Notes")
        XCTAssertEqual(sut.resolveFastLane(goal: "open the notes app", apps: apps)?.bundle,
                       "com.apple.Notes")
    }

    // MARK: - Quoted payloads

    /// `"a" or "b"` only wears outer quotes — unwrapping produced the
    /// payload `a" or "b` and skipped the destination scan. Fully quoted
    /// means exactly one span covering the whole string.
    func testMultiQuotedPayloadKeepsItsQuotes() {
        XCTAssertEqual(CuaFastAction.parse("type \"yes\" or \"no\"")?.action.body,
                       .type("\"yes\" or \"no\""))
        // A genuinely single-quoted payload still unwraps.
        XCTAssertEqual(CuaFastAction.parse("type \"yes\"")?.action.body, .type("yes"))
    }

    // MARK: - Rightmost qualifier peel

    /// The qualifier peel took the FIRST "in" — "play run in the sun in
    /// spotify" scoped "the sun in spotify". The rightmost preposition is
    /// the qualifier boundary.
    func testQualifierPeelTakesTheRightmostPreposition() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Spotify", bundle: "com.spotify.client", running: true, pid: 9)]
        let resolved = sut.resolveFastLane(goal: "play run in the sun in spotify", apps: apps)
        XCTAssertEqual(resolved?.bundle, "com.spotify.client")
        guard case .appSearch(let query, let play) = resolved?.action?.body else {
            return XCTFail("expected appSearch, got \(String(describing: resolved?.action?.body))")
        }
        XCTAssertEqual(query, "run in the sun")
        XCTAssertTrue(play)
        XCTAssertEqual(resolved?.launchURLs, ["spotify:search:run%20in%20the%20sun"])
    }

    // MARK: - Front-suffix for all raise verbs

    /// "to the front" was only stripped for "bring" — the other raise
    /// verbs kept the tail inside the app name and failed to resolve.
    func testFrontSuffixStripsForAllRaiseVerbs() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Notes", bundle: "com.apple.Notes", running: true, pid: 5)]
        for (phrase, verb) in [("bring notes to the front", "bring"),
                               ("foreground notes to the front", "foreground"),
                               ("pull up notes to the front", "pull up"),
                               ("focus notes to the front", "focus")] {
            let resolved = sut.resolveFastLane(goal: phrase, apps: apps)
            XCTAssertEqual(resolved?.bundle, "com.apple.Notes", phrase)
            XCTAssertEqual(resolved?.openVerb, verb, phrase)
        }
    }

    // MARK: - Verify cache

    /// The persisted verify record trusted a stat fingerprint any
    /// same-UID process can compute — a swapped binary plus a forged
    /// defaults entry skipped the SHA check. The record lives for the
    /// process lifetime only; persisted state is ignored.
    func testPersistedVerifyRecordCannotBypassTheHash() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("driver-pin-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        let abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try Data("forged".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let path = file.standardizedFileURL.path
        var info = stat()
        XCTAssertEqual(stat(path, &info), 0)
        let fingerprint = "\(info.st_dev):\(info.st_ino):\(info.st_size):"
            + "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec):"
            + "\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
        UserDefaults.standard.set([path: ["sha": abcHash, "fp": fingerprint]],
                                  forKey: "cuaDependencyVerifiedStat")
        defer { UserDefaults.standard.removeObject(forKey: "cuaDependencyVerifiedStat") }
        XCTAssertThrowsError(try CuaDependency.verify(file, expectedSHA256: abcHash))
    }
}
