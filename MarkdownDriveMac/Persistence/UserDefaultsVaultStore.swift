import Foundation
import MarkdownDriveCore

actor UserDefaultsVaultStore: VaultStore {
    private let defaults: UserDefaults
    private let key: String

    init(
        suiteName: String? = nil,
        key: String = "selectedVault"
    ) {
        if let suiteName, let suiteDefaults = UserDefaults(suiteName: suiteName) {
            defaults = suiteDefaults
        } else {
            defaults = .standard
        }
        self.key = key
    }

    func loadVault() throws -> Vault? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }
        return try JSONDecoder().decode(Vault.self, from: data)
    }

    func saveVault(_ vault: Vault) throws {
        defaults.set(try JSONEncoder().encode(vault), forKey: key)
    }
}
