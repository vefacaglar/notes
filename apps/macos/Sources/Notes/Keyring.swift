import Foundation
import NotesCore

/// The passwords typed this run (newest first) and the keys derived from them. Memory only: nothing is written to disk,
/// the preferences or the Keychain, and `lock()` forgets it all (docs/format.md, "Encrypted notes").
@Observable @MainActor
final class Keyring {
    static let shared = Keyring()

    private(set) var passwords: [String] = []
    @ObservationIgnored private(set) var keys: [NoteCrypto.Key] = []
    /// Set once the user was told, in this run, that encrypting leaves copies elsewhere.
    @ObservationIgnored var hasShownEncryptionNotice = false
    /// Counts `lock()` calls. A key derived in the background is dropped when this changed meanwhile, so a lock is
    /// never undone by a slow derivation finishing afterwards.
    @ObservationIgnored private(set) var generation = 0

    var newestPassword: String? { passwords.first }

    /// Remembers a password the user typed (moved to the front when known) and the key it gave.
    func remember(password: String?, key: NoteCrypto.Key) {
        if let password, !password.isEmpty {
            passwords.removeAll { $0 == password }
            passwords.insert(password, at: 0)
        }
        remember(key)
    }

    func remember(_ key: NoteCrypto.Key) {
        keys.removeAll { $0.salt == key.salt && $0.iterations == key.iterations }
        keys.insert(key, at: 0)
    }

    func lock() {
        generation &+= 1
        passwords = []
        keys = []
    }
}
