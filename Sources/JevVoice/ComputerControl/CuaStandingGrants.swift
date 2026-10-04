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
    static func menuFocus(bundle: String) -> Bool {
        UserDefaults.standard.bool(forKey: menuFocusPrefix + bundle)
    }

    static func grantMenuFocus(bundle: String) {
        UserDefaults.standard.set(true, forKey: menuFocusPrefix + bundle)
    }

    /// Drops every remembered grant; the next task that needs one asks again.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: pageAccessKey)
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(menuFocusPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
