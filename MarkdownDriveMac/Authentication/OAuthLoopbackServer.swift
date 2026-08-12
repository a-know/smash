import Darwin
import Foundation
import MarkdownDriveCore

struct OAuthCallback: Sendable {
    let code: String?
    let state: String?
    let error: String?
}

final class OAuthLoopbackServer: @unchecked Sendable {
    let redirectURI: URL

    private let callbackPath = "/oauth2callback"
    private let queue = DispatchQueue(label: "com.a-know.MarkdownDrive.oauth-loopback")
    private let lock = NSLock()
    private var listeningSocket: Int32
    private var isClosed = false

    init() throws {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketDescriptor >= 0 else {
            throw AuthenticationError.callbackListenerFailed
        }

        var noSigPipe: Int32 = 1
        setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(
                    socketDescriptor,
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }

        guard bindResult == 0, Darwin.listen(socketDescriptor, 1) == 0 else {
            Darwin.close(socketDescriptor)
            throw AuthenticationError.callbackListenerFailed
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(socketDescriptor, sockaddrPointer, &boundAddressLength)
            }
        }

        let port = UInt16(bigEndian: boundAddress.sin_port)
        guard nameResult == 0,
            port > 0,
            let redirectURI = URL(string: "http://127.0.0.1:\(port)\(callbackPath)")
        else {
            Darwin.close(socketDescriptor)
            throw AuthenticationError.callbackListenerFailed
        }

        listeningSocket = socketDescriptor
        self.redirectURI = redirectURI
    }

    deinit {
        close()
    }

    func receiveCallback() async throws -> OAuthCallback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        continuation.resume(returning: try acceptCallback())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            close()
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else {
            return
        }
        isClosed = true
        Darwin.shutdown(listeningSocket, SHUT_RDWR)
        Darwin.close(listeningSocket)
    }

    private func acceptCallback() throws -> OAuthCallback {
        let socketDescriptor = currentSocket()
        guard socketDescriptor >= 0 else {
            throw AuthenticationError.callbackListenerFailed
        }

        let clientSocket = Darwin.accept(socketDescriptor, nil, nil)
        guard clientSocket >= 0 else {
            throw AuthenticationError.callbackListenerFailed
        }
        defer {
            Darwin.close(clientSocket)
            close()
        }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(
            clientSocket,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        let request = try readRequest(from: clientSocket)
        let callback = try parseCallback(from: request)
        writeCompletionPage(to: clientSocket)
        return callback
    }

    private func currentSocket() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return isClosed ? -1 : listeningSocket
    }

    private func readRequest(from socketDescriptor: Int32) throws -> String {
        let maximumRequestSize = 16_384
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 2_048)

        while received.count < maximumRequestSize {
            let count = Darwin.read(socketDescriptor, &buffer, buffer.count)
            guard count > 0 else {
                throw AuthenticationError.invalidAuthorizationResponse
            }
            received.append(buffer, count: count)

            if received.range(of: Data("\r\n\r\n".utf8)) != nil {
                break
            }
        }

        guard received.count < maximumRequestSize,
            let request = String(data: received, encoding: .utf8)
        else {
            throw AuthenticationError.invalidAuthorizationResponse
        }
        return request
    }

    private func parseCallback(from request: String) throws -> OAuthCallback {
        guard let requestLine = request.components(separatedBy: "\r\n").first else {
            throw AuthenticationError.invalidAuthorizationResponse
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
            parts[0] == "GET",
            let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
            components.path == callbackPath
        else {
            throw AuthenticationError.invalidAuthorizationResponse
        }

        func value(named name: String) -> String? {
            components.queryItems?.first(where: { $0.name == name })?.value
        }

        return OAuthCallback(
            code: value(named: "code"),
            state: value(named: "state"),
            error: value(named: "error")
        )
    }

    private func writeCompletionPage(to socketDescriptor: Int32) {
        let html = """
            <!doctype html>
            <html lang="en">
            <head><meta charset="utf-8"><title>Markdown Drive</title></head>
            <body><p>Authorization received. You can close this tab and return to Markdown Drive.</p></body>
            </html>
            """
        let body = Data(html.utf8)
        let headers = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.count)\r
            Connection: close\r
            Cache-Control: no-store\r
            \r

            """
        var response = Data(headers.utf8)
        response.append(body)
        response.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            _ = Darwin.write(socketDescriptor, baseAddress, bytes.count)
        }
    }
}
