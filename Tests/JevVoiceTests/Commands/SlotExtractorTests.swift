import XCTest
@testable import JevVoiceCore

final class SlotExtractorTests: XCTestCase {
    func testExplicitSearchSiteIsNotPartOfTheQuery() {
        XCTAssertEqual(SlotExtractor.searchQuery(from: "search YouTube for cats", site: .youtube), "cats")
        XCTAssertEqual(SlotExtractor.searchQuery(from: "search for cats on DuckDuckGo", site: .duckDuckGo), "cats")
        XCTAssertEqual(SlotExtractor.searchQuery(from: "search for YouTube tutorials", site: nil), "YouTube tutorials")
    }

    func testGoogleHomepageDoesNotRequireASpokenDomain() {
        for clause in ["open google", "Open Google.", "please visit Google", "go to google"] {
            XCTAssertEqual(SlotExtractor.url(from: clause), "https://www.google.com", clause)
        }
    }

    func testGoogleHomepageDoesNotCaptureAppNamesOrSearchQueries() {
        for clause in ["open Google Chrome", "open Google Drive", "search for Google", "google cats", "type open Google"] {
            XCTAssertNil(SlotExtractor.url(from: clause), clause)
        }
    }

    func testSpokenDotURL() {
        XCTAssertEqual(SlotExtractor.url(from: "go to google dot com"), "https://google.com")
    }

    func testURLWithPath() {
        XCTAssertEqual(SlotExtractor.url(from: "open github.com/chris"), "https://github.com/chris")
    }

    func testNoURL() {
        XCTAssertNil(SlotExtractor.url(from: "open notes"))
    }

    func testSearchQuery() {
        XCTAssertEqual(
            SlotExtractor.searchQuery(from: "search for swift concurrency"),
            "swift concurrency"
        )
    }

    func testDictationText() {
        XCTAssertEqual(SlotExtractor.dictationText(from: "type hello world"), "hello world")
    }

    func testDictationRequiresALeadingLiteralInstruction() {
        for clause in ["search for how to write Swift", "open type editor", "I heard her say hello", "typewriter"] {
            XCTAssertNil(SlotExtractor.dictationText(from: clause), clause)
        }
    }

    func testLiteralPrefixesPreserveAllRemainingText() {
        for prefix in ["type", "write", "dictate", "say", "please type", "can you write", "could you please dictate", "would you say", "will you please type"] {
            XCTAssertEqual(
                SlotExtractor.dictationText(from: " \(prefix) Hello 🦊 and close Notes "),
                "Hello 🦊 and close Notes",
                prefix
            )
        }
        XCTAssertEqual(SlotExtractor.dictationText(from: "TYPE “don’t stop” then close Notes"), "“don’t stop” then close Notes")
        XCTAssertNil(SlotExtractor.dictationText(from: "please type   "))
    }

    func testPercentDigits() {
        XCTAssertEqual(SlotExtractor.numberPercent(from: "set volume to 30 percent"), 30)
    }

    func testPercentWords() {
        XCTAssertEqual(SlotExtractor.numberPercent(from: "set volume to max"), 100)
        XCTAssertEqual(SlotExtractor.numberPercent(from: "set volume to half"), 50)
    }
}
