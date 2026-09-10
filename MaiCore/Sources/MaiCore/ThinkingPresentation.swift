import Foundation

/// Presentation only. It never changes generation options or stored reasoning.
public enum ThinkingDisplay: String, Codable, CaseIterable, Identifiable, Sendable {
  case status, line, three, full
  public var id: String { rawValue }
  public var lineCount: Int { self == .three ? 3 : 1 }
  public var displayName: String {
    switch self {
    case .status: "Thinking…"
    case .line: "One scrolling line"
    case .three: "Three scrolling lines"
    case .full: "Full text"
    }
  }
}

/// A bounded tail for live frontends. Full reasoning belongs to the transcript.
public struct ThinkingPreview: Sendable {
  public private(set) var text = ""
  public static let capacity = 1500
  public init() {}
  public mutating func append(_ delta: String) {
    text = Self.tail(text + delta)
  }
  public static func tail(_ text: String) -> String {
    String(text.suffix(capacity))
  }

  /// Newest rows last. Width is supplied by the frontend (terminal cells, for example).
  public static func lines(
    _ text: String, count: Int, width: Int,
    measure: (String) -> Int = { $0.count }
  ) -> [String] {
    var rows = [""]
    var columns = 0
    for character in tail(text) {
      if character == "\n" {
        rows.append("")
        columns = 0
      } else {
        let safe = String(character).unicodeScalars.filter {
          !CharacterSet.controlCharacters.contains($0)
        }
        let value = String(String.UnicodeScalarView(safe))
        let size = measure(value)
        if columns + size > max(1, width), columns > 0 {
          rows.append("")
          columns = 0
        }
        rows[rows.count - 1] += value
        columns += size
      }
    }
    if rows.last == "", rows.count > 1 { rows.removeLast() }
    return Array(rows.suffix(max(1, count)))
  }
}
