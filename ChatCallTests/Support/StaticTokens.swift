import Foundation

@testable import ChatCall

nonisolated struct StaticTokens: AccessTokenProvider {
  func validToken() async throws -> AccessToken {
    AccessToken(value: "T", expiresAt: .distantFuture)
  }
  func invalidate(_ token: AccessToken) async {}
}
