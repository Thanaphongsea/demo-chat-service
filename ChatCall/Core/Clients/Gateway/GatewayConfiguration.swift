import Foundation

/// Where the chat gateway lives: REST `/v4/*` and the realtime socket share this origin.
/// Defaults to the dev auth origin; override with `-gatewayURL`.
nonisolated struct GatewayConfiguration: Equatable, Sendable {
  let httpBase: URL

  init(httpBase: URL) { self.httpBase = httpBase }

  static let dev = GatewayConfiguration(httpBase: AuthConfiguration.dev.baseURL)

  /// `wss://<host>/ws/connection/websocket` (`ws` for a plain-HTTP gateway).
  var websocketURL: URL {
    var parts = URLComponents(url: httpBase, resolvingAgainstBaseURL: false) ?? URLComponents()
    parts.scheme = httpBase.scheme == "https" ? "wss" : "ws"
    parts.path = "/ws/connection/websocket"
    parts.query = nil
    return parts.url ?? httpBase
  }

  /// Launch-argument override on top of `dev`; an invalid override is ignored.
  init(defaults: UserDefaults = .standard) {
    let url = defaults.string(forKey: "gatewayURL").flatMap(URL.init(string:)).flatMap {
      $0.scheme == "https" || $0.scheme == "http" ? $0 : nil
    }
    self.init(httpBase: url ?? Self.dev.httpBase)
  }
}
