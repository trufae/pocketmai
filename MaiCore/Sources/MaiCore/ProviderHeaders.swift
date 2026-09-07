import Foundation

/// The custom HTTP headers a configured provider sends with every request.
///
/// Configuration accepts them as an object (`{"X-Name": "value"}`), as
/// `"X-Name: value"` lines, or as one such line; all three become one
/// dictionary, and a saved configuration always writes the object form. A
/// value may contain `{{session}}`, which the transport replaces with the
/// session id of the chat a request belongs to (see `ChatSession`). That is
/// how a backend that meters or routes by session, such as OpenCode Zen with
/// its `x-opencode-session`, gets one stable id per chat without any host
/// doing per-request work.
public enum ProviderHeaders {
  /// Replaced with the chat's session id when a request is sent.
  public static let sessionPlaceholder = "{{session}}"

  /// Parses `Name: value` lines. Blank lines and lines starting with `#` are
  /// skipped, a line without a colon or with an empty name is ignored, and a
  /// repeated name keeps its last value.
  public static func parse(lines: [String]) -> [String: String] {
    var headers: [String: String] = [:]
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
      guard let separator = trimmed.firstIndex(of: ":") else { continue }
      let name = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
      let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else { continue }
      headers[name] = value
    }
    return headers
  }

  /// Parses newline-separated `Name: value` text, the form a text field holds.
  public static func parse(_ text: String) -> [String: String] {
    parse(lines: text.components(separatedBy: .newlines))
  }

  /// The `Name: value` lines of a header set, sorted by name so the same set
  /// always renders the same way.
  public static func lines(_ headers: [String: String]) -> [String] {
    headers.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
      .map { "\($0): \(headers[$0] ?? "")" }
  }

  /// The headers to send for one request: every `{{session}}` replaced with
  /// the given session id.
  public static func expand(_ headers: [String: String], sessionID: String) -> [String: String] {
    headers.mapValues { value in
      value.contains(sessionPlaceholder)
        ? value.replacingOccurrences(of: sessionPlaceholder, with: sessionID)
        : value
    }
  }

  /// Decodes a `headers` key in any of the accepted forms. A missing key is
  /// an empty set. Hosts with their own endpoint records use it so a provider
  /// file written by hand imports the same way everywhere.
  public static func decode<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key
  ) throws -> [String: String] {
    guard container.contains(key) else { return [:] }
    if let object = try? container.decode([String: String].self, forKey: key) {
      return object
    }
    if let lines = try? container.decode([String].self, forKey: key) {
      return parse(lines: lines)
    }
    if let text = try? container.decode(String.self, forKey: key) {
      return parse(text)
    }
    throw DecodingError.dataCorruptedError(
      forKey: key,
      in: container,
      debugDescription:
        "headers must be an object of names to values or an array of \"Name: value\" strings")
  }
}
