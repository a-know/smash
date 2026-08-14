import Foundation
import MarkdownDriveCore

protocol GoogleOAuthTokenClientProtocol: Sendable {
    func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: URL,
        configuration: GoogleOAuthConfiguration
    ) async throws -> GoogleTokenResponse

    func refreshAccessToken(
        refreshToken: String,
        configuration: GoogleOAuthConfiguration
    ) async throws -> GoogleTokenResponse

    func revoke(_ token: String) async
}

struct GoogleOAuthTokenClient: GoogleOAuthTokenClientProtocol {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        redirectURI: URL,
        configuration: GoogleOAuthConfiguration
    ) async throws -> GoogleTokenResponse {
        try await requestToken(
            parameters: [
                URLQueryItem(name: "client_id", value: configuration.clientID),
                URLQueryItem(name: "client_secret", value: configuration.clientSecret),
                URLQueryItem(name: "code", value: code),
                URLQueryItem(name: "code_verifier", value: codeVerifier),
                URLQueryItem(name: "grant_type", value: "authorization_code"),
                URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            ],
            invalidGrantError: .oauthServerRejected(code: "invalid_grant")
        )
    }

    func refreshAccessToken(
        refreshToken: String,
        configuration: GoogleOAuthConfiguration
    ) async throws -> GoogleTokenResponse {
        try await requestToken(
            parameters: [
                URLQueryItem(name: "client_id", value: configuration.clientID),
                URLQueryItem(name: "client_secret", value: configuration.clientSecret),
                URLQueryItem(name: "refresh_token", value: refreshToken),
                URLQueryItem(name: "grant_type", value: "refresh_token"),
            ],
            invalidGrantError: .reauthenticationRequired
        )
    }

    func revoke(_ token: String) async {
        guard var components = URLComponents(string: "https://oauth2.googleapis.com/revoke") else {
            return
        }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await session.data(for: request)
    }

    private func requestToken(
        parameters: [URLQueryItem],
        invalidGrantError: AuthenticationError
    ) async throws -> GoogleTokenResponse {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw AuthenticationError.unexpected
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = try OAuthFormEncoder.encode(parameters)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthenticationError.networkFailure
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthenticationError.tokenExchangeFailed
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let oauthError = try? JSONDecoder().decode(GoogleOAuthErrorResponse.self, from: data)
            if oauthError?.error == "invalid_grant" {
                throw invalidGrantError
            }
            throw AuthenticationError.oauthServerRejected(
                code: OAuthErrorClassifier.safeCode(
                    code: oauthError?.error,
                    description: oauthError?.errorDescription,
                    statusCode: httpResponse.statusCode
                )
            )
        }

        do {
            let tokenResponse = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
            guard tokenResponse.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
                throw AuthenticationError.invalidAuthorizationResponse
            }
            return tokenResponse
        } catch let error as AuthenticationError {
            throw error
        } catch {
            throw AuthenticationError.invalidAuthorizationResponse
        }
    }

}

struct GoogleTokenResponse: Decodable, Sendable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?
    let tokenType: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }
}

private struct GoogleOAuthErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}
