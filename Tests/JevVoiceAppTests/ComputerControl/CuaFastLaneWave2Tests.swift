import XCTest
import JevVoiceCore
@testable import JevVoice

/// Wave-2 fast lanes: system media keys, deictic typing, app search, play,
/// URL navigation, and the verify/latency fixes on existing lanes.
@MainActor
final class CuaFastLaneWave2Tests: XCTestCase {

    private func app(_ name: String, bundle: String, running: Bool = false, pid: Int = 0) -> JSONValue {
        .object(["name": .string(name), "bundle_id": .string(bundle),
                 "running": .bool(running), "pid": .number(Double(pid))])
    }

    // MARK: - Media key phrases

    func testMediaPhrasesParseAsSystemKeys() {
        XCTAssertEqual(CuaFastAction.parse("pause music")?.action.body, .mediaKey(.playPause))
        XCTAssertEqual(CuaFastAction.parse("play pause")?.action.body, .mediaKey(.playPause))
        XCTAssertEqual(CuaFastAction.parse("resume the music")?.action.body, .mediaKey(.playPause))
        XCTAssertEqual(CuaFastAction.parse("next track")?.action.body, .mediaKey(.nextTrack))
        XCTAssertEqual(CuaFastAction.parse("skip")?.action.body, .mediaKey(.nextTrack))
        XCTAssertEqual(CuaFastAction.parse("previous song")?.action.body, .mediaKey(.previousTrack))
        XCTAssertEqual(CuaFastAction.parse("mute")?.action.body, .mediaKey(.mute))
        XCTAssertEqual(CuaFastAction.parse("louder")?.action.body, .mediaKey(.volumeUp))
        XCTAssertEqual(CuaFastAction.parse("quieter")?.action.body, .mediaKey(.volumeDown))
        XCTAssertEqual(CuaFastAction.parse("brightness up")?.action.body, .mediaKey(.brightnessUp))
        XCTAssertEqual(CuaFastAction.parse("dim the screen")?.action.body, .mediaKey(.brightnessDown))
    }

    /// Whole-phrase media keys must never shadow the tab/window lanes, and a
    /// qualifier can't scope a global key.
    func testMediaPhrasesDoNotShadowWindowCommands() {
        guard case .hotkey = CuaFastAction.parse("next tab")?.action.body else {
            return XCTFail("next tab must stay a hotkey")
        }
        guard case .hotkey = CuaFastAction.parse("next window")?.action.body else {
            return XCTFail("next window must stay a hotkey")
        }
        // Bare "next"/"previous" are too ambiguous to lane.
        XCTAssertNil(CuaFastAction.parse("next"))
        // "play" is the media toggle; only "play <payload>" is the play lane.
        XCTAssertEqual(CuaFastAction.parse("play")?.action.body, .mediaKey(.playPause))
        // A qualifier disqualifies a global key rather than scoping it.
        XCTAssertNil(CuaFastAction.parse("mute in notes"))
        // "stop" never lanes — play/pause toggles and a paused player would
        // resume, the opposite of the request.
        XCTAssertNil(CuaFastAction.parse("stop the music"))
    }

    /// Media lanes resolve with no app at all — no lease, no window.
    func testMediaResolutionNeedsNoApp() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let resolved = sut.resolveFastLane(goal: "volume up", apps: [])
        XCTAssertEqual(resolved?.name, "")
        XCTAssertEqual(resolved?.bundle, "")
        XCTAssertEqual(resolved?.action?.body, .mediaKey(.volumeUp))
    }

    /// The media dispatch posts the key and makes zero driver calls.
    func testMediaLaneMakesNoDriverCalls() async throws {
        var posted: [MediaKeys.Key] = []
        let prior = MediaKeys.poster
        MediaKeys.poster = { key in posted.append(key); return true }
        defer { MediaKeys.poster = prior }
        var driverCalls: [String] = []
        let sut = CuaTaskAgent(call: { tool, _ in driverCalls.append(tool); return .object([:]) })
        let resolved = try XCTUnwrap(sut.resolveFastLane(goal: "volume up", apps: []))
        let evidence = try await sut.runFastLane(resolved, goal: "volume up") { _ in }
        XCTAssertEqual(posted, [.volumeUp])
        XCTAssertTrue(driverCalls.isEmpty)
        XCTAssertNotNil(evidence)
    }

    // MARK: - "type X here"

    func testTypeHereStripsDeicticDestination() {
        XCTAssertEqual(CuaFastAction.parse("type hello world here")?.action.body,
                       .deicticType("hello world"))
        XCTAssertEqual(CuaFastAction.parse("type hello at the cursor")?.action.body,
                       .deicticType("hello"))
        XCTAssertEqual(CuaFastAction.parse("type hello into this")?.action.body,
                       .deicticType("hello"))
        XCTAssertEqual(CuaFastAction.parse("type hello right here")?.action.body,
                       .deicticType("hello"))
        // Payloads ending in a "here"-shaped word are not deictic.
        XCTAssertEqual(CuaFastAction.parse("type sphere")?.action.body, .type("sphere"))
        // Quoted payloads stay verbatim.
        XCTAssertEqual(CuaFastAction.parse(#"type "look here""#)?.action.body, .type("look here"))
        // Ordinary payloads are unchanged.
        XCTAssertEqual(CuaFastAction.parse("type hello world")?.action.body, .type("hello world"))
    }

    /// The deictic lane binds the frontmost app only — a qualifier naming a
    /// different app is a contradiction, not a command.
    func testTypeHereRequiresFrontmostApp() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Notes", bundle: "com.apple.Notes", running: true, pid: 3),
                    app("Other", bundle: "com.example.Other", running: true, pid: 4)]
        let resolved = sut.resolveFastLane(goal: "type hello here", apps: apps,
                                           frontmostBundleOverride: "com.apple.Notes")
        XCTAssertEqual(resolved?.bundle, "com.apple.Notes")
        XCTAssertEqual(resolved?.action?.body, .deicticType("hello"))
        XCTAssertNil(sut.resolveFastLane(goal: "type hello here in notes", apps: apps,
                                         frontmostBundleOverride: "com.example.Other"))
    }

    // MARK: - "search APP for X"

    func testSearchAppForQueryDisambiguatesByAppResolution() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Spotify", bundle: "com.spotify.client", running: true, pid: 9),
                    app("Notes", bundle: "com.apple.Notes", running: true, pid: 5)]
        let spotify = sut.resolveFastLane(goal: "search spotify for marvins room", apps: apps)
        XCTAssertEqual(spotify?.bundle, "com.spotify.client")
        guard case .appSearch(let query, let play) = spotify?.action?.body else {
            return XCTFail("expected appSearch")
        }
        XCTAssertEqual(query, "marvins room")
        XCTAssertFalse(play)
        XCTAssertEqual(spotify?.launchURLs, ["spotify:search:marvins%20room"])
        // "search notes for recipes" resolves Notes by app match.
        XCTAssertEqual(sut.resolveFastLane(goal: "search notes for recipes", apps: apps)?.bundle,
                       "com.apple.Notes")
        // "search X in app" carries the app through the qualifier split.
        XCTAssertEqual(sut.resolveFastLane(goal: "search recipes in notes", apps: apps)?.bundle,
                       "com.apple.Notes")
        // Unresolvable app words stay with the drive loop.
        XCTAssertNil(sut.resolveFastLane(goal: "search frobnicate for x", apps: apps))
    }

    func testNamedEngineSearchBuildsResultsURL() {
        XCTAssertEqual(CuaActionCatalog.namedEngineSearchURL(engine: "google", query: "the weather"),
                       "https://www.google.com/search?q=the%20weather")
        XCTAssertEqual(CuaActionCatalog.namedEngineSearchURL(engine: "youtube", query: "lofi beats"),
                       "https://www.youtube.com/results?search_query=lofi%20beats")
        XCTAssertEqual(CuaActionCatalog.namedEngineSearchURL(engine: "github", query: "swift"),
                       "https://github.com/search?q=swift")
        XCTAssertEqual(CuaActionCatalog.namedEngineSearchURL(engine: "amazon", query: "tape"),
                       "https://www.amazon.com/s?k=tape")
        XCTAssertNil(CuaActionCatalog.namedEngineSearchURL(engine: "spotify", query: "x"))
        XCTAssertNil(CuaActionCatalog.namedEngineSearchURL(engine: "google", query: "  "))
        XCTAssertEqual(CuaActionCatalog.namedEngineSearchURL(in: "search google for the weather"),
                       "https://www.google.com/search?q=the%20weather")
        XCTAssertEqual(CuaActionCatalog.namedEngineSearchURL(in: "bing for flights"),
                       "https://www.bing.com/search?q=flights")
        XCTAssertNil(CuaActionCatalog.namedEngineSearchURL(in: "don't search google for x"))
    }

    /// A named engine where an app was expected swaps to the URL lane.
    func testEngineQualifierResolvesToNavigationURL() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Notes", bundle: "com.apple.Notes", running: true, pid: 5)]
        let resolved = sut.resolveFastLane(goal: "search google for the weather", apps: apps)
        XCTAssertEqual(resolved?.action?.body,
                       .navigateURL("https://www.google.com/search?q=the%20weather"))
    }

    // MARK: - "play X"

    func testPlayResolvesMediaAppDeterministically() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Spotify", bundle: "com.spotify.client", running: true, pid: 9),
                    app("Notes", bundle: "com.apple.Notes", running: true, pid: 5)]
        let qualified = sut.resolveFastLane(goal: "play never gonna give you up in spotify", apps: apps)
        XCTAssertEqual(qualified?.bundle, "com.spotify.client")
        guard case .appSearch(let query, let play) = qualified?.action?.body else {
            return XCTFail("expected appSearch")
        }
        XCTAssertEqual(query, "never gonna give you up")
        XCTAssertTrue(play)
        XCTAssertEqual(qualified?.launchURLs,
                       ["spotify:search:never%20gonna%20give%20you%20up"])
        // Unqualified "play X" lands on the uniquely running media app.
        XCTAssertEqual(sut.resolveFastLane(goal: "play never gonna give you up",
                                           apps: apps)?.bundle, "com.spotify.client")
        // A non-media target stays with the drive loop.
        XCTAssertNil(sut.resolveFastLane(goal: "play x in notes", apps: apps))
        // An installed-but-stopped Spotify is still the deterministic target.
        let stopped = [app("Spotify", bundle: "com.spotify.client"),
                       app("Notes", bundle: "com.apple.Notes", running: true, pid: 5)]
        XCTAssertEqual(sut.resolveFastLane(goal: "play never gonna give you up",
                                           apps: stopped)?.bundle, "com.spotify.client")
    }

    func testSpotifySearchURIEncoding() {
        XCTAssertEqual(CuaTaskAgent.spotifySearchURI("never gonna give you up"),
                       "spotify:search:never%20gonna%20give%20you%20up")
        XCTAssertEqual(CuaTaskAgent.spotifySearchURI("song & dance"),
                       "spotify:search:song%20%26%20dance")
    }

    // MARK: - URL lane

    func testNavigationURLLaneTailRules() {
        let sut = CuaTaskAgent(call: { _, _ in .object([:]) })
        let apps = [app("Notes", bundle: "com.apple.Notes", running: true, pid: 5)]
        XCTAssertEqual(sut.resolveFastLane(goal: "go to apple.com", apps: apps)?.action?.body,
                       .navigateURL("https://apple.com"))
        XCTAssertEqual(sut.resolveFastLane(goal: "open https://example.com/a?b=1",
                                           apps: apps)?.action?.body,
                       .navigateURL("https://example.com/a?b=1"))
        // A tail carrying more than the address is not the URL lane.
        XCTAssertNil(sut.resolveFastLane(goal: "go to apple.com and log in", apps: apps))
        // A named app still wins over the URL lane.
        XCTAssertNotNil(sut.resolveFastLane(goal: "open notes", apps: apps)?.openVerb)
    }

    // MARK: - Scroll reps + new phrases

    func testScrollRepsAndEdgePhrases() {
        XCTAssertEqual(CuaFastAction.parse("scroll down three times")?.action.body,
                       .scroll(direction: "down", pages: 3))
        XCTAssertEqual(CuaFastAction.parse("scroll up 2 times")?.action.body,
                       .scroll(direction: "up", pages: 2))
        XCTAssertEqual(CuaFastAction.parse("scroll down a lot")?.action.body,
                       .scroll(direction: "down", pages: 3))
        guard let top = CuaFastAction.parse("scroll to top") else { return XCTFail() }
        XCTAssertEqual(top.action.body, .hotkey(keys: ["cmd", "up"], shortcut: "⌘↑"))
        guard let note = CuaFastAction.parse("new note") else { return XCTFail() }
        XCTAssertEqual(note.action.body, .hotkey(keys: ["cmd", "n"], shortcut: "⌘N"))
        XCTAssertEqual(note.action.effect, .delivered)
    }

    // MARK: - dispatchFastType verify fix

    /// Element tokens are re-minted per snapshot — the verify poll must match
    /// the element's slot, so a same-index element with the typed value
    /// confirms insertion instead of falling through to "delivered".
    func testTypeLaneVerifiesByElementSlotNotToken() async throws {
        var typed = false
        var snapshotReads = 0
        let sut = CuaTaskAgent(call: { tool, _ in
            switch tool {
            case "list_apps", "get_accessibility_tree":
                return .object(["apps": .array([
                    self.app("Fixture", bundle: "test.fixture", running: true, pid: 42)])])
            case "list_windows":
                return .object(["windows": .array([.object([
                    "window_id": .number(7), "is_on_screen": .bool(true)])])])
            case "get_window_state":
                snapshotReads += 1
                return .object(["elements": .array([.object([
                    "role": .string("AXTextArea"), "label": .string("Body"),
                    "element_index": .number(3),
                    // A fresh token per snapshot — the old code could never match.
                    "element_token": .string("tok-\(snapshotReads)"),
                    "value": .string(typed ? "hello" : "")])])])
            case "type_text":
                typed = true
            default:
                break
            }
            return .object([:])
        })
        let resolved = try XCTUnwrap(sut.resolveFastLane(
            goal: "type hello in fixture",
            apps: [app("Fixture", bundle: "test.fixture", running: true, pid: 42)]))
        let evidence = try await sut.runFastLane(resolved, goal: "type hello in fixture") { _ in }
        XCTAssertEqual(evidence, "Typed the text into Body in Fixture.")
    }
}
