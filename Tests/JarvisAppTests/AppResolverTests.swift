import XCTest
@testable import Jarvis

/// Contract: AppResolver turns a spoken name into a launchable identity —
/// running apps win by exact name/bundle, substrings are a fallback, and
/// nothing matched still returns an honest name-only app the driver can
/// refuse.
final class AppResolverTests: XCTestCase {
    private func resolver(_ apps: [AppResolver.App]) -> AppResolver {
        AppResolver(listApps: { apps })
    }

    func testExactNameMatch() async {
        let r = resolver([AppResolver.App(name: "Finder", bundle: "com.apple.finder", pid: 55)])
        let app = await r.resolve("finder")
        XCTAssertEqual(app?.bundle, "com.apple.finder")
        XCTAssertEqual(app?.pid, 55)
    }

    func testBundleIDMatch() async {
        let r = resolver([AppResolver.App(name: "Safari", bundle: "com.apple.Safari", pid: 9)])
        let app = await r.resolve("com.apple.safari")
        XCTAssertEqual(app?.name, "Safari")
    }

    func testSubstringMatchFallsBack() async {
        let r = resolver([AppResolver.App(name: "Visual Studio Code",
                                          bundle: "com.microsoft.VSCode", pid: 7)])
        let app = await r.resolve("studio")
        XCTAssertEqual(app?.pid, 7)
    }

    /// Unknown names still resolve to a name-only app — launch_app is the
    /// driver's honest failure point, not a silent nil here.
    func testUnknownNameResolvesNameOnly() async {
        let r = resolver([])
        let app = await r.resolve("DefinitelyNotAnAppXYZ123")
        XCTAssertEqual(app?.name, "DefinitelyNotAnAppXYZ123")
        XCTAssertNil(app?.pid)
        XCTAssertNil(app?.bundle)
    }

    func testEmptyQueryResolvesNil() async {
        let r = resolver([AppResolver.App(name: "Finder", bundle: nil, pid: 1)])
        let app = await r.resolve("   ")
        XCTAssertNil(app)
    }

    /// A substring collision exposes every equal-tier candidate sorted by
    /// name — the caller refuses by name instead of guessing. `app` still
    /// keeps resolve's first-match pick (list order, not sorted order).
    func testDetailedSubstringCollisionReturnsAllMatches() async {
        let r = resolver([
            AppResolver.App(name: "Devin Notes", bundle: nil, pid: 12),
            AppResolver.App(name: "Devin Helper", bundle: nil, pid: 11),
        ])
        let result = await r.resolveDetailed("devin")
        XCTAssertEqual(result.matches.map(\.name), ["Devin Helper", "Devin Notes"])
        XCTAssertEqual(result.app?.pid, 12)
    }

    /// An exact name outranks substring siblings — the collision never
    /// surfaces when one running app IS the query.
    func testDetailedExactNameWinsSingle() async {
        let r = resolver([
            AppResolver.App(name: "Devin", bundle: nil, pid: 1),
            AppResolver.App(name: "Devin Helper", bundle: nil, pid: 2),
        ])
        let result = await r.resolveDetailed("devin")
        XCTAssertEqual(result.matches.map(\.name), ["Devin"])
        XCTAssertEqual(result.app?.pid, 1)
    }

    func testDetailedBundleIDMatch() async {
        let r = resolver([AppResolver.App(name: "Safari", bundle: "com.apple.Safari", pid: 9)])
        let result = await r.resolveDetailed("com.apple.safari")
        XCTAssertEqual(result.matches.map(\.name), ["Safari"])
        XCTAssertEqual(result.app?.bundle, "com.apple.Safari")
    }

    /// The running-app list is cached briefly — a burst of resolves must
    /// not re-scan the process list per query.
    func testListAppsIsCached() async {
        var fetches = 0
        let r = AppResolver(listApps: {
            fetches += 1
            return [AppResolver.App(name: "Finder", bundle: nil, pid: 1)]
        })
        _ = await r.resolve("finder")
        _ = await r.resolve("finder")
        XCTAssertEqual(fetches, 1)
    }

    func testExactBundleAvoidsFullInventory() async {
        var scans = 0
        let r = AppResolver(exactBundleApps: { _ in
            [AppResolver.App(name: "Calculator", bundle: "com.apple.calculator", pid: 71)]
        }, listApps: {
            scans += 1
            return []
        })
        let result = await r.resolveDetailed("  COM.APPLE.CALCULATOR  ")
        XCTAssertEqual(result.app?.pid, 71)
        XCTAssertEqual(result.matches.map(\.bundle), ["com.apple.calculator"])
        XCTAssertEqual(scans, 0)
    }

    func testDirectBundlePreservesEveryExactMatchAndSortOrder() async {
        let r = AppResolver(exactBundleApps: { _ in [
            AppResolver.App(name: "Zeta", bundle: "com.example.Editor", pid: 8),
            AppResolver.App(name: "Alpha", bundle: "com.example.Editor", pid: 9),
            AppResolver.App(name: "Other", bundle: "com.example.Other", pid: 10),
        ] }, listApps: { [] })
        let result = await r.resolveDetailed("com.example.editor")
        XCTAssertEqual(result.app?.pid, 8)
        XCTAssertEqual(result.matches.map(\.name), ["Alpha", "Zeta"])
        XCTAssertEqual(result.matches.map(\.pid), [9, 8])
    }

    func testUnavailableOrInvalidDirectBundleFallsBackToInventory() async {
        let cases: [[AppResolver.App]] = [
            [], [AppResolver.App(name: "Wrong", bundle: "com.example.other", pid: 2)],
            [AppResolver.App(name: "Missing PID", bundle: "com.example.editor")],
            [AppResolver.App(name: "Zero PID", bundle: "com.example.editor", pid: 0)],
            [AppResolver.App(name: "Negative PID", bundle: "com.example.editor", pid: -1)],
        ]
        for direct in cases {
            var scans = 0
            let r = AppResolver(exactBundleApps: { _ in direct }, listApps: {
                scans += 1
                return [AppResolver.App(name: "Editor", bundle: "com.example.editor", pid: 23)]
            })
            let result = await r.resolveDetailed("com.example.editor")
            XCTAssertEqual(result.app?.pid, 23)
            XCTAssertEqual(result.matches.count, 1)
            XCTAssertEqual(scans, 1)
        }
    }

    func testNameLookupKeepsAmbiguityAndFullInventoryCache() async {
        var scans = 0
        let r = AppResolver(exactBundleApps: { _ in [] }, listApps: {
            scans += 1
            return [
                AppResolver.App(name: "Devin Notes", bundle: "com.example.notes", pid: 12),
                AppResolver.App(name: "Devin Helper", bundle: "com.example.helper", pid: 11),
            ]
        })
        let first = await r.resolveDetailed("devin")
        let second = await r.resolveDetailed("devin")
        XCTAssertEqual(first.matches.map(\.name), ["Devin Helper", "Devin Notes"])
        XCTAssertEqual(second.matches.map(\.pid), [11, 12])
        XCTAssertEqual(scans, 1)
    }

    func testInjectedTrailingClosureDoesNotQueryRealRunningBundle() async {
        let r = AppResolver {
            [AppResolver.App(name: "Fixture Finder", bundle: "com.apple.finder", pid: 55)]
        }
        let result = await r.resolveDetailed("com.apple.finder")
        XCTAssertEqual(result.app?.name, "Fixture Finder")
        XCTAssertEqual(result.app?.pid, 55)
    }

    func testEmptyQuerySkipsBothProviders() async {
        var calls = 0
        let r = AppResolver(exactBundleApps: { _ in calls += 1; return [] },
                            listApps: { calls += 1; return [] })
        let result = await r.resolveDetailed(" \n ")
        XCTAssertNil(result.app)
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(calls, 0)
    }
}
