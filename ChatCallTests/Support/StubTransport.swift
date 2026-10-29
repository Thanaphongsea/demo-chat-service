import Foundation

@testable import ChatCall

nonisolated struct StubReply: Sendable {
  var status: Int
  var data: Data
  var headers: [String: String]

  init(_ status: Int, _ data: Data = Data(), headers: [String: String] = [:]) {
    self.status = status
    self.data = data
    self.headers = headers
  }

  /// A gateway answer: it carries the `X-Request-Id` the real gateway always echoes.
  static func gateway(_ status: Int = 200, json: String = "{}", headers: [String: String] = [:])
    -> StubReply
  {
    StubReply(
      status, Data(json.utf8), headers: headers.merging(["X-Request-Id": "req-1"]) { $1 })
  }
}

nonisolated final class StubTransport: HTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [URLRequest] = []
  private let handler: @Sendable (URLRequest) async throws -> StubReply

  init(reply handler: @escaping @Sendable (URLRequest) async throws -> StubReply) {
    self.handler = handler
  }

  convenience init(_ handler: @escaping @Sendable (URLRequest) async throws -> (Int, Data)) {
    self.init(reply: { request in
      let (status, data) = try await handler(request)
      return StubReply(status, data)
    })
  }

  var requests: [URLRequest] { lock.withLock { recorded } }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    lock.withLock { recorded.append(request) }
    let reply = try await handler(request)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
    return (reply.data, response)
  }
}
