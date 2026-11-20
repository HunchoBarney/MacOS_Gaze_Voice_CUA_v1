import Foundation

/// Safety warnings from what is already on screen, using the same
/// `ScamSignals` checks that refuse scam clicks: a fake security alert with
/// a phone number to call, a sign-in page whose link names one site but
/// goes to another, and remote-access software opened during a call.
enum SafetyRules {
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]
    static let remoteAccess: [String: String] = [
        "com.philandro.anydesk": "AnyDesk", "com.teamviewer.TeamViewer": "TeamViewer",
        "com.teamviewer.TeamViewerQS": "TeamViewer", "com.carriez.rustdesk": "RustDesk",
        "com.splashtop.Splashtop-Personal": "Splashtop", "com.logmein.GoToResolve": "GoTo Resolve",
        "com.connectwise.control": "ScreenConnect", "com.ultraviewer.UltraViewer": "UltraViewer",
    ]
    /// Link shorteners and mail trackers whose address never matches the
    /// words they wrap, by site.
    private static let redirectorSites: Set<String> = [
        "t.co", "bit.ly", "lnkd.in", "ow.ly", "tinyurl.com", "goo.gl", "list-manage.com", "sendgrid.net",
        "mandrillapp.com", "mailchi.mp", "hubspotlinks.com", "mcusercontent.com", "substack.com", "beehiiv.com",
        "mailgun.org", "awstrack.me",
    ]
    /// Redirect hosts on sites that also host pages anyone can make
    /// (Google Sites and Forms), so only the exact redirect host is skipped.
    /// Outlook's regional Safe Links hosts are matched by suffix below.
    private static let redirectorHosts: Set<String> = [
        "www.google.com", "google.com", "l.facebook.com", "lm.facebook.com", "www.linkedin.com",
        "safelinks.protection.outlook.com",
    ]
    /// One remote-access warning per tool per hour, so a second scam call
    /// later the same day is warned again.
    static let remoteWarningPeriod: TimeInterval = 3_600
    private static let signInWords = [
        "sign in", "log in", "login", "verify your", "confirm your", "account suspended", "unusual activity",
        "update your payment", "password",
    ]

    static func alerts(page digest: ScreenDigest?, frontBundleID: String?, frontAppName: String?,
                       onCall: Bool, now: Date) -> [ProactiveAlert] {
        var alerts: [ProactiveAlert] = []
        if onCall, let tool = frontBundleID.flatMap({ remoteAccess[$0] }) ?? frontAppName.flatMap(remoteName) {
            let period = Int(now.timeIntervalSince1970 / remoteWarningPeriod)
            alerts.append(ProactiveAlert(
                key: "safety.remote.\(tool).\(period)", source: .safety, category: .security,
                headline: "Careful: callers who ask you to open \(tool) are often scammers, so hang up if you don't know them",
                offer: "Want me to quit \(tool)?", action: .request("quit \(tool)"), at: now))
        }
        guard let digest, digest.withheld == nil,
              digest.webArea || frontBundleID.map(browsers.contains) == true else { return alerts }
        let page = digest.pageURL.flatMap(ScamSignals.host(of:)).map(ScamSignals.site) ?? digest.windowTitle
        let text = digest.items.map(\.text).joined(separator: "\n")
        if let number = ScamSignals.alarmPhoneNumber(in: text) {
            alerts.append(ProactiveAlert(
                key: "safety.alarm.\(page).\(number)", source: .safety, category: .security,
                headline: "Careful: this page looks like a fake security alert, so don't call the number on it",
                offer: "Want me to close the tab?", action: .request("close this tab"), at: now))
        }
        let lowered = text.lowercased()
        let asksToSignIn = digest.items.contains { $0.kind == "password field" }
            || signInWords.contains { lowered.contains($0) }
        if asksToSignIn {
            for item in digest.items where item.kind == "link" {
                guard let mismatch = ScamSignals.linkMismatch(text: item.text, url: item.url),
                      !redirectorSites.contains(ScamSignals.site(mismatch.actual)),
                      !redirectorHosts.contains(mismatch.actual),
                      !mismatch.actual.hasSuffix(".safelinks.protection.outlook.com") else { continue }
                alerts.append(ProactiveAlert(
                    key: "safety.link.\(page).\(mismatch.actual)", source: .safety, category: .security,
                    headline: "Careful: a link here says \(mismatch.shown) but goes to \(mismatch.actual)",
                    offer: "Want me to close the tab?", action: .request("close this tab"), at: now))
                break
            }
        }
        return alerts
    }

    private static func remoteName(_ appName: String) -> String? {
        remoteAccess.values.first { appName.localizedCaseInsensitiveContains($0) }
    }
}
