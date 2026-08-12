import Foundation

public enum OAuthErrorClassifier {
    public static func safeCode(
        code: String?,
        description: String?,
        statusCode: Int
    ) -> String {
        let knownCodes = [
            "access_denied",
            "invalid_client",
            "invalid_grant",
            "invalid_request",
            "temporarily_unavailable",
            "unauthorized_client",
            "unsupported_grant_type",
        ]

        guard let code, knownCodes.contains(code) else {
            return "HTTP_\(statusCode)"
        }
        guard code == "invalid_request",
            let reason = invalidRequestReason(from: description)
        else {
            return code
        }
        return "\(code)/\(reason)"
    }

    private static func invalidRequestReason(from description: String?) -> String? {
        guard let description else {
            return nil
        }
        let normalized = description.lowercased()

        if normalized.contains("client_secret") || normalized.contains("client secret") {
            return "client_secret_rejected"
        }
        if normalized.contains("redirect_uri") || normalized.contains("redirect uri") {
            return "redirect_uri_rejected"
        }
        if normalized.contains("code_verifier") || normalized.contains("code verifier")
            || normalized.contains("code_challenge") || normalized.contains("code challenge")
        {
            return "pkce_rejected"
        }
        if normalized.contains("grant_type") || normalized.contains("grant type") {
            return "grant_type_rejected"
        }
        if normalized.contains("client_id") || normalized.contains("client id") {
            return "client_id_rejected"
        }
        if normalized.contains("authorization code")
            || normalized.contains("parameter: code")
            || normalized.contains("parameter 'code'")
        {
            return "authorization_code_rejected"
        }
        return nil
    }
}
