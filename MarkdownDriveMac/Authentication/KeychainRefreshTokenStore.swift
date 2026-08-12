import Foundation
import MarkdownDriveCore
import Security

protocol RefreshTokenStore: Sendable {
    func load() throws -> String?
    func save(_ refreshToken: String) throws
    func remove() throws
}

struct KeychainRefreshTokenStore: RefreshTokenStore {
    private let service: String
    private let account: String

    init(
        service: String = "com.a-know.MarkdownDrive.oauth",
        account: String = "google-refresh-token"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
            let data = result as? Data,
            let refreshToken = String(data: data, encoding: .utf8)
        else {
            throw AuthenticationError.credentialStorageFailed
        }

        return refreshToken
    }

    func save(_ refreshToken: String) throws {
        guard let data = refreshToken.data(using: .utf8) else {
            throw AuthenticationError.credentialStorageFailed
        }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw AuthenticationError.credentialStorageFailed
        }

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw AuthenticationError.credentialStorageFailed
        }
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthenticationError.credentialStorageFailed
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
