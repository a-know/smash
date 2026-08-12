import Foundation

public struct AccessToken: Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension AccessToken: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
}
