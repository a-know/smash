import Foundation

public enum OAuthFormEncoder {
    public static func encode(_ parameters: [URLQueryItem]) throws -> Data {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedParameters = try parameters.map { parameter in
            guard let encodedName = parameter.name.addingPercentEncoding(withAllowedCharacters: allowedCharacters),
                let encodedValue = (parameter.value ?? "").addingPercentEncoding(
                    withAllowedCharacters: allowedCharacters
                )
            else {
                throw AuthenticationError.unexpected
            }
            return "\(encodedName)=\(encodedValue)"
        }
        return Data(encodedParameters.joined(separator: "&").utf8)
    }
}
