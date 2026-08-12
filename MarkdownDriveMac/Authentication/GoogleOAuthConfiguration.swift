import Foundation
import MarkdownDriveCore

struct GoogleOAuthConfiguration: Sendable {
    static let driveScope = "https://www.googleapis.com/auth/drive"

    let clientID: String
    let clientSecret: String
    let scopes: [String]

    static func load() throws -> GoogleOAuthConfiguration {
        let environmentClientID = ProcessInfo.processInfo.environment["GOOGLE_OAUTH_CLIENT_ID"]
        let bundleClientID = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String

        guard let clientID = firstConfiguredValue(environmentClientID, bundleClientID) else {
            throw AuthenticationError.configurationMissing
        }

        let environmentClientSecret = ProcessInfo.processInfo.environment["GOOGLE_OAUTH_CLIENT_SECRET"]
        let bundleClientSecret = Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientSecret") as? String

        guard let clientSecret = firstConfiguredValue(environmentClientSecret, bundleClientSecret) else {
            throw AuthenticationError.clientSecretMissing
        }

        return GoogleOAuthConfiguration(
            clientID: clientID,
            clientSecret: clientSecret,
            scopes: [driveScope]
        )
    }

    private static func firstConfiguredValue(_ candidates: String?...) -> String? {
        candidates.lazy.compactMap { candidate in
            guard let candidate else {
                return nil
            }
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || value.contains("$(") ? nil : value
        }.first
    }
}
