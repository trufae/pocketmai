import Foundation

/// Builds the quoted block a reply starts from, in the shape mail clients use:
/// every line is prefixed with `"> "` so Markdown renders it as a block quote,
/// and long paragraphs are hard-wrapped so the quote stays narrow enough to
/// read as quoted material next to the reply typed under it. The iOS reply
/// action and the CLI's `/reply` command both start from this text.
public enum MarkdownQuote {
  /// Total width of a quoted line, quote marker included.
  public static let defaultLineWidth = 40

  private static let marker = "> "

  public static func quote(_ text: String, lineWidth: Int = defaultLineWidth) -> String {
    let budget = max(1, lineWidth - marker.count)
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    var lines: [String] = []
    for paragraph in normalized.components(separatedBy: "\n") {
      let wrappedLines = wrapped(paragraph, width: budget)
      if wrappedLines.isEmpty {
        // A blank source line stays blank inside the quote. The bare ">" keeps
        // the renderer from splitting one block quote into two.
        lines.append(">")
      } else {
        lines.append(contentsOf: wrappedLines.map { marker + $0 })
      }
    }
    return lines.joined(separator: "\n")
  }

  /// Greedy word wrap. A word that cannot fit on a line of its own — a long URL,
  /// mostly — is split across lines, because the width is a hard limit here.
  private static func wrapped(_ paragraph: String, width: Int) -> [String] {
    var lines: [String] = []
    var current = ""
    for word in paragraph.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
      for chunk in chunks(of: String(word), width: width) {
        if current.isEmpty {
          current = chunk
        } else if current.count + 1 + chunk.count <= width {
          current += " " + chunk
        } else {
          lines.append(current)
          current = chunk
        }
      }
    }
    if !current.isEmpty {
      lines.append(current)
    }
    return lines
  }

  private static func chunks(of word: String, width: Int) -> [String] {
    guard word.count > width else { return [word] }
    var chunks: [String] = []
    var index = word.startIndex
    while index < word.endIndex {
      let end = word.index(index, offsetBy: width, limitedBy: word.endIndex) ?? word.endIndex
      chunks.append(String(word[index..<end]))
      index = end
    }
    return chunks
  }
}
