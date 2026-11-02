import Foundation

/// Dev-service URLs baked into Info.plist from `Config/Local.xcconfig`.
nonisolated enum BuildConfiguration {
  /// Fails loudly (`unset.invalid` never resolves) when the key is missing or the build setting was not expanded.
  static func url(forInfoKey key: String, bundle: Bundle = .main) -> URL {
    let raw = bundle.object(forInfoDictionaryKey: key) as? String
    guard let raw, !raw.contains("$("), let url = URL(string: raw), url.host != nil else {
      return URL(string: "https://unset.invalid")!
    }
    return url
  }
}
