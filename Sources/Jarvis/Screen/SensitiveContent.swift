import Foundation

/// What Jarvis never reads aloud, sends to a model, or shows in a picture.
/// One rule set shared by every screen reader: a secure field is marked by
/// its role in native apps and by its subrole in web and Electron views,
/// and both must match. Password managers are withheld whole, since no
/// part of a vault window is safe to describe.
enum SensitiveContent {
    static let vaultBundleIDs: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess",
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "me.proton.pass.electron",
        "com.lastpass.lastpassmacdesktop", "org.keepassxc.keepassxc",
    ]
    static let vaultNames = [
        "passwords", "keychain access", "1password", "bitwarden",
        "proton pass", "lastpass", "keepassxc", "dashlane", "enpass",
    ]

    static func isVault(bundleID: String?, appName: String) -> Bool {
        if let bundleID, vaultBundleIDs.contains(bundleID) { return true }
        return vaultNames.contains(appName.lowercased())
    }

    static func isSecure(role: String, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    private static let sensitiveLabels = [
        "password", "passcode", "passphrase", "pin", "security code", "cvv", "cvc",
        "card number", "credit card", "debit card", "account number", "routing number",
        "sort code", "iban", "social security", "ssn", "one-time code", "one time code",
        "verification code", "2fa", "authentication code",
    ]

    /// A field whose label names a secret: its value is never read and its
    /// frame is blacked out in any picture.
    static func isSensitiveLabel(_ label: String) -> Bool {
        let words = " " + label.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : " " }
            .reduce(into: "") { $0.append($1) } + " "
        return sensitiveLabels.contains { words.contains(" \($0) ") }
    }

    /// Replaces Luhn-valid 13–19 digit runs (spaces and dashes allowed
    /// between digits) so a card number on screen never leaves the Mac.
    static func maskCardNumbers(_ text: String) -> String {
        guard text.contains(where: \.isNumber) else { return text }
        let pattern = #"(?<![0-9])[0-9](?:[ -]?[0-9]){12,18}(?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let digits = source.substring(with: match.range).filter(\.isNumber)
            guard (13...19).contains(digits.count), luhn(digits),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "[card number hidden]")
        }
        return result
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (offset, character) in digits.reversed().enumerated() {
            guard var digit = character.wholeNumberValue else { return false }
            if offset % 2 == 1 { digit *= 2; if digit > 9 { digit -= 9 } }
            sum += digit
        }
        return sum % 10 == 0
    }
}
