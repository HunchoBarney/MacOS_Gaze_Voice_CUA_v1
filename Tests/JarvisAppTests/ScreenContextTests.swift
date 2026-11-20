import XCTest
@testable import Jarvis

/// The screen reader's privacy contract: secure fields are found by role
/// or subrole, secret-labelled fields keep their frame for redaction but
/// never their value, vault apps are withheld whole, and a partial read
/// never claims its redactions are complete.
final class ScreenContextTests: XCTestCase {

    private func rect(_ y: CGFloat) -> CGRect { CGRect(x: 10, y: y, width: 200, height: 24) }

    private func window(_ children: [ScreenNode]) -> ScreenNode {
        ScreenNode(role: "AXWindow", title: "Sign in", children: children)
    }

    func testNativeSecureFieldIsRedactedByRole() {
        let digest = ScreenContext.digest(app: "Mail", bundleID: "com.apple.mail", windowTitle: "Sign in", root: window([
            ScreenNode(role: "AXSecureTextField", title: "Password", value: "hunter2", frame: rect(40)),
        ]))
        XCTAssertEqual(digest.redactions, [rect(40)])
        XCTAssertEqual(digest.items.map(\.kind), ["password field"])
        XCTAssertFalse(digest.rendered.contains("hunter2"))
        XCTAssertTrue(digest.redactionsComplete)
    }

    /// Web and Electron password boxes are AXTextField with the secure
    /// subrole. Checking the role alone misses every browser login.
    func testWebSecureFieldIsRedactedBySubrole() {
        let web = ScreenNode(role: "AXWebArea", url: "https://bank.example/login", children: [
            ScreenNode(role: "AXTextField", subrole: "AXSecureTextField", description: "Password", value: "••••", frame: rect(80)),
        ])
        let digest = ScreenContext.digest(app: "Safari", bundleID: "com.apple.Safari", windowTitle: "Bank", root: window([web]))
        XCTAssertEqual(digest.redactions, [rect(80)])
        XCTAssertEqual(digest.pageURL, "https://bank.example/login")
        XCTAssertEqual(digest.items.first?.kind, "password field")
    }

    func testSecretLabelledFieldKeepsFrameButNotValue() {
        let digest = ScreenContext.digest(app: "Safari", bundleID: nil, windowTitle: "Pay", root: window([
            ScreenNode(role: "AXTextField", description: "Card number", value: "4111 1111 1111 1111", frame: rect(20)),
            ScreenNode(role: "AXTextField", description: "Security code", value: "123", frame: rect(50)),
            ScreenNode(role: "AXTextField", description: "Name on card", value: "Rose Byrne", frame: rect(80)),
        ]))
        XCTAssertEqual(digest.redactions, [rect(20), rect(50)])
        XCTAssertFalse(digest.rendered.contains("4111"))
        XCTAssertFalse(digest.rendered.contains("123"))
        XCTAssertTrue(digest.rendered.contains("Name on card: Rose Byrne"))
    }

    func testCardNumbersInPlainTextAreMasked() {
        let digest = ScreenContext.digest(app: "Notes", bundleID: nil, windowTitle: "Cards", root: window([
            ScreenNode(role: "AXStaticText", value: "Visa 4111-1111-1111-1111, order 1234567890123"),
        ]))
        XCTAssertTrue(digest.rendered.contains("Visa [card number hidden]"))
        XCTAssertTrue(digest.rendered.contains("1234567890123"), "a non-Luhn number is ordinary text")
    }

    func testPasswordManagersAreWithheldWhole() {
        for (bundle, name) in [("com.1password.1password", "1Password"), (nil, "Passwords"), ("com.apple.keychainaccess", "Keychain Access")] {
            let digest = ScreenContext.digest(app: name, bundleID: bundle, windowTitle: "Vault", root: window([
                ScreenNode(role: "AXStaticText", value: "bank login: rose / hunter2"),
            ]))
            XCTAssertEqual(digest.withheld, .vault, name)
            XCTAssertTrue(digest.items.isEmpty, name)
            XCTAssertFalse(digest.rendered.contains("hunter2"), name)
        }
    }

    /// Links keep their address next to their words, which is what a scam
    /// check compares; a control's own static-text children are not
    /// repeated as separate lines.
    func testLinksCarryTheirAddressAndControlsReadTheirText() {
        let digest = ScreenContext.digest(app: "Mail", bundleID: "com.apple.mail", windowTitle: "Inbox", root: window([
            ScreenNode(role: "AXHeading", title: "Your Apple ID has been suspended"),
            ScreenNode(role: "AXLink", url: "https://appleid-verify-secure.info/login", frame: rect(100), children: [
                ScreenNode(role: "AXStaticText", value: "Verify now"),
            ]),
            ScreenNode(role: "AXButton", description: "Attach", frame: rect(10)),
            ScreenNode(role: "AXCheckBox", title: "Remember me", value: "1"),
        ]))
        XCTAssertEqual(digest.items.map(\.kind), ["heading", "link", "button", "checkbox"])
        XCTAssertEqual(digest.items[1].text, "Verify now")
        XCTAssertEqual(digest.items[1].url, "https://appleid-verify-secure.info/login")
        XCTAssertEqual(digest.items[3].text, "Remember me (on)")
        XCTAssertEqual(digest.frame(ref: "e3"), rect(10))
        XCTAssertTrue(digest.rendered.contains("[e2] link \"Verify now\" -> https://appleid-verify-secure.info/login"))
        XCTAssertFalse(digest.rendered.contains("x: 10"), "frames stay on the Mac")
    }

    /// A secure field nested inside a control, or found after the text
    /// budget ran out, still lands in the redactions.
    func testRedactionsSurviveTheTextBudget() {
        var limits = ScreenContext.Limits()
        limits.maxItems = 2
        let digest = ScreenContext.digest(app: "Safari", bundleID: nil, windowTitle: "Login", root: window([
            ScreenNode(role: "AXStaticText", value: "Welcome back"),
            ScreenNode(role: "AXStaticText", value: "Sign in to continue"),
            ScreenNode(role: "AXStaticText", value: "Email"),
            ScreenNode(role: "AXGroup", children: [
                ScreenNode(role: "AXTextField", subrole: "AXSecureTextField", frame: rect(200)),
            ]),
            ScreenNode(role: "AXButton", title: "Show", children: [
                ScreenNode(role: "AXSecureTextField", frame: rect(240)),
            ]),
        ]), limits: limits)
        XCTAssertEqual(digest.items.count, 2)
        XCTAssertTrue(digest.truncated)
        XCTAssertEqual(digest.redactions, [rect(200), rect(240)])
        XCTAssertTrue(digest.redactionsComplete)
    }

    func testIncompleteReadNeverClaimsCompleteRedactions() {
        let digest = ScreenContext.digest(app: "Safari", bundleID: nil, windowTitle: "Login", root: window([
            ScreenNode(role: "AXStaticText", value: "Hello"),
        ]), complete: false)
        XCTAssertFalse(digest.redactionsComplete)
        XCTAssertTrue(digest.truncated)
    }

    func testSecureFieldWithoutFrameBlocksPictures() {
        let digest = ScreenContext.digest(app: "App", bundleID: nil, windowTitle: "", root: window([
            ScreenNode(role: "AXSecureTextField"),
        ]))
        XCTAssertFalse(digest.redactionsComplete)
    }

    func testSensitiveLabelsMatchWholeWords() {
        XCTAssertTrue(SensitiveContent.isSensitiveLabel("Enter your PIN"))
        XCTAssertTrue(SensitiveContent.isSensitiveLabel("One-time code"))
        XCTAssertTrue(SensitiveContent.isSensitiveLabel("Password:"))
        XCTAssertFalse(SensitiveContent.isSensitiveLabel("Pinned notes"))
        XCTAssertFalse(SensitiveContent.isSensitiveLabel("Subject"))
    }

    func testLuhn() {
        XCTAssertTrue(SensitiveContent.luhn("4111111111111111"))
        XCTAssertFalse(SensitiveContent.luhn("4111111111111112"))
    }
}
