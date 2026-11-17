import Foundation

/// Standing user authorizations for computer-control capabilities.
///
/// Each grant is asked for at most once; the persisted value answers every
/// later request for the same capability. Per-action confirmations for
/// irreversible effects (file upload, dialog acceptance, deletion/purchase)
/// are not standing grants and still ask each time.
enum CuaStandingGrants {
    private static let pageAccessKey = "cuaStandingGrant.browserPageAccess"
    private static let menuFocusPrefix = "cuaStandingGrant.menuFocus."
    private static let computerUseInputKey = "cuaStandingGrant.computerUseInput"

    /// Clicky's always-allow: input consent is granted standing rather than
    /// per turn. Voice confirmations (`requestApproval`) and the agent gate
    /// both honor it — a user who asked for no prompts is never re-asked.
    /// Driver-side policy (deny lists, delivery mode, scope) is unaffected;
    /// this only bypasses the *asking*, not the action rules.
    static var computerUseInput: Bool {
        get { UserDefaults.standard.bool(forKey: computerUseInputKey) }
        set { UserDefaults.standard.set(newValue, forKey: computerUseInputKey) }
    }

    /// `browser_prepare` with `existing_profile` — reading and acting on page
    /// content in the user's real browser profile. The driver's own launch
    /// grant and per-attach setup still gate the endpoint; this only stops
    /// the re-ask after the user approved once.
    static var browserPageAccess: Bool {
        get { UserDefaults.standard.bool(forKey: pageAccessKey) }
        set { UserDefaults.standard.set(newValue, forKey: pageAccessKey) }
    }

    /// `invoke_menu` may briefly focus a non-frontmost window (the driver
    /// restores focus afterward). Granted per bundle: trusting Chrome's menus
    /// does not authorize focusing unrelated apps.
    ///
    /// Process-wide by design: the key lives in the shared UserDefaults
    /// domain, so the agent drive children (the same binary under
    /// `--mcp-stdio`) read the same answer the voice path wrote. That is
    /// the intent — the consent is "Jev may borrow focus to reach this
    /// app's menus", not which process asked.
    static func menuFocus(bundle: String) -> Bool {
        UserDefaults.standard.bool(forKey: menuFocusPrefix + bundle)
    }

    static func grantMenuFocus(bundle: String) {
        UserDefaults.standard.set(true, forKey: menuFocusPrefix + bundle)
    }

    /// Drops every remembered grant; the next task that needs one asks again.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: computerUseInputKey)
        UserDefaults.standard.removeObject(forKey: pageAccessKey)
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(menuFocusPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
