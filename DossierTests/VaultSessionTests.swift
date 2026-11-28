import LocalAuthentication
import Testing
@testable import Dossier

/// One unlock opens every number until Dossier locks again.
@MainActor
struct VaultSessionTests {
    @Test func lockingEndsTheSession() {
        let session = VaultSession()
        session.end()
        #expect(session.context == nil, "numbers need a new check after the app locks")
    }

    @Test func aLockedAppHasNoUnlockToReuse() {
        let lock = AppLock()
        if lock.isEnabled {
            #expect(lock.isLocked, "a fresh launch is locked")
            #expect(lock.recentUnlock() == nil, "nothing opens numbers while the app is locked")
        }
    }
}
