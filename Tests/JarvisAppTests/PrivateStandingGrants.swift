import XCTest
@testable import Jarvis

extension XCTestCase {
    /// Points `CuaStandingGrants` at a suite only this test sees. Every
    /// test process on the Mac shares `UserDefaults.standard`, so a grant
    /// written there by another test would change what this one is asked.
    func usePrivateStandingGrants() {
        let suite = "\(type(of: self)).grants.\(UUID().uuidString)"
        CuaStandingGrants.defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock {
            CuaStandingGrants.defaults.removePersistentDomain(forName: suite)
            CuaStandingGrants.defaults = .standard
        }
    }
}
