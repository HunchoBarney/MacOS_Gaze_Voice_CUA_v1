import XCTest
@testable import JevVoiceCore

final class ClauseSplitterTests: XCTestCase {
    func testSplitsOnAndBeforeCommandVerb() {
        XCTAssertEqual(
            ClauseSplitter.split("open chrome and go to google.com"),
            ["open chrome", "go to google.com"]
        )
    }

    func testKeepsConjoinedObjectsTogether() {
        XCTAssertEqual(
            ClauseSplitter.split("open notes and spotify"),
            ["open notes and spotify"]
        )
    }

    func testSplitsOnThen() {
        XCTAssertEqual(
            ClauseSplitter.split("quit slack then open safari"),
            ["quit slack", "open safari"]
        )
    }

    func testAndThenSplitsOnce() {
        XCTAssertEqual(
            ClauseSplitter.split("open chrome and then go to google.com"),
            ["open chrome", "go to google.com"]
        )
    }

    func testDictationConsumesTheRestOfTheUtterance() {
        for transcript in [
            "type hello and close Notes",
            "write hello then launch Terminal",
            "dictate hello and then lock the screen",
            "say hello and also quit Safari",
            "please type hello then open Safari",
            "could you please write hello and close Notes",
            "type \"hello\" then close Notes",
            "type don’t stop and close Notes",
        ] {
            XCTAssertEqual(ClauseSplitter.split(transcript), [transcript], transcript)
        }
    }

    func testCommandsBeforeDictationStillSplit() {
        XCTAssertEqual(
            ClauseSplitter.split("open Notes then type hello and close Terminal"),
            ["open Notes", "type hello and close Terminal"]
        )
        XCTAssertEqual(
            ClauseSplitter.split("open Notes and then could you please say hello then lock the screen"),
            ["open Notes", "could you please say hello then lock the screen"]
        )
    }

    func testQuotedCommandWordsStayInTheirClause() {
        for quoted in [
            #""hello and open Notes""#,
            "“hello and open Notes”",
            "'hello and open Notes'",
            "‘don’t stop and open Notes’",
            #""say \"hello\" and open Notes""#,
        ] {
            XCTAssertEqual(
                ClauseSplitter.split("search for \(quoted) then open Safari"),
                ["search for \(quoted)", "open Safari"],
                quoted
            )
        }
    }

    func testUnclosedQuotesKeepTheRemainingTextTogether() {
        for quote in ["\"", "“", "'", "‘"] {
            let transcript = "search for \(quote)hello and open Notes then close Safari"
            XCTAssertEqual(ClauseSplitter.split(transcript), [transcript], transcript)
        }
    }

    func testQuotedClauseIsNotPromotedToACommand() {
        let transcript = "search for hello and \"open Notes\""
        XCTAssertEqual(ClauseSplitter.split(transcript), [transcript])
    }

    func testApostrophesAndUnicodeDoNotBlockRealCommandChains() {
        XCTAssertEqual(
            ClauseSplitter.split("open John's Notes then close Safari"),
            ["open John's Notes", "close Safari"]
        )
        XCTAssertEqual(
            ClauseSplitter.split("search for 🦊 then open Safari"),
            ["search for 🦊", "open Safari"]
        )
    }
}

final class ClauseSplitterNewVerbTests: XCTestCase {
    func testSplitsBeforeMinimize() {
        XCTAssertEqual(ClauseSplitter.split("open safari and minimize chrome"), ["open safari", "minimize chrome"])
    }

    func testSplitsBeforeMultiwordVerbs() {
        XCTAssertEqual(ClauseSplitter.split("bring up notes then shut down music"), ["bring up notes", "shut down music"])
    }
}
