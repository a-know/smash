import Foundation

public protocol DriveHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionDriveHTTPTransport: DriveHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DriveError.invalidResponse
        }
        return (data, httpResponse)
    }
}
