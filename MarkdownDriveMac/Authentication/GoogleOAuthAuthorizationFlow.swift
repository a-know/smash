import AppKit
import CryptoKit
import Foundation
import MarkdownDriveCore
import Security

struct GoogleAuthorizationGrant: Sendable {
    let code: String
    let codeVerifier: String
    let redirectURI: URL
}

protocol GoogleOAuthAuthorizationFlowProtocol: Sendable {
    func authorize(configuration: GoogleOAuthConfiguration) async throws -> GoogleAuthorizationGrant
}

struct GoogleOAuthAuthorizationFlow: GoogleOAuthAuthorizationFlowProtocol {
    func authorize(configuration: GoogleOAuthConfiguration) async throws -> GoogleAuthorizationGrant {
        let server = try OAuthLoopbackServer()
        let codeVerifier = try randomURLSafeString(byteCount: 64)
        let state = try randomURLSafeString(byteCount: 32)
        let codeChallenge = base64URLEncoded(Data(SHA256.hash(data: Data(codeVerifier.utf8))))

        let authorizationURL = try makeAuthorizationURL(
            configuration: configuration,
            redirectURI: server.redirectURI,
            codeChallenge: codeChallenge,
            state: state
        )

        let didOpen = await MainActor.run {
            NSWorkspace.shared.open(authorizationURL)
        }
        guard didOpen else {
            server.close()
            throw AuthenticationError.browserLaunchFailed
        }

        let callback = try await receiveCallback(from: server)
        if callback.error == "access_denied" {
            throw AuthenticationError.authorizationCancelled
        }
        guard callback.error == nil,
            callback.state == state,
            let code = callback.code,
            !code.isEmpty
        else {
            throw AuthenticationError.invalidAuthorizationResponse
        }

        return GoogleAuthorizationGrant(
            code: code,
            codeVerifier: codeVerifier,
            redirectURI: server.redirectURI
        )
    }

    private func receiveCallback(from server: OAuthLoopbackServer) async throws -> OAuthCallback {
        try await withThrowingTaskGroup(of: OAuthCallback.self) { group in
            group.addTask {
                try await server.receiveCallback()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(300))
                throw AuthenticationError.authorizationCancelled
            }

            guard let callback = try await group.next() else {
                throw AuthenticationError.callbackListenerFailed
            }
            group.cancelAll()
            return callback
        }
    }

    private func makeAuthorizationURL(
        configuration: GoogleOAuthConfiguration,
        redirectURI: URL,
        codeChallenge: String,
        state: String
    ) throws -> URL {
        guard var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth") else {
            throw AuthenticationError.unexpected
        }

        components.queryItems = [
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]

        guard let url = components.url else {
            throw AuthenticationError.unexpected
        }
        return url
    }

    private func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AuthenticationError.unexpected
        }
        return base64URLEncoded(Data(bytes))
    }

    private func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
