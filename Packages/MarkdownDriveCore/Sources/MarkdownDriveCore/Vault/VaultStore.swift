public protocol VaultStore: Sendable {
    func loadVault() async throws -> Vault?
    func saveVault(_ vault: Vault) async throws
}
