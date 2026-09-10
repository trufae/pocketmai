import Foundation

/// Splits inline think tags across arbitrary transport chunks and retains the
/// order of text/reasoning spans. Tags inside fenced code remain literal text.
public struct ReasoningStream: Sendable {
  private var fragments: [ContentPart] = []
  /// Coalesce once at completion, rather than copying growing strings per token.
  public var parts: [ContentPart] {
    var result: [ContentPart] = []
    var run = ""
    var reasoning = false
    for fragment in fragments {
      let value: String
      let next: Bool
      switch fragment {
      case .text(let text):
        value = text
        next = false
      case .reasoning(let text):
        value = text
        next = true
      default: continue
      }
      if next != reasoning && !run.isEmpty {
        result.append(reasoning ? .reasoning(run) : .text(run))
        run = ""
      }
      reasoning = next
      run += value
    }
    if !run.isEmpty { result.append(reasoning ? .reasoning(run) : .text(run)) }
    return result
  }
  private var pending = ""
  private var thinking = false
  private var codeTicks = 0

  public init() {}

  public mutating func append(_ text: String) -> [ContentPart] {
    pending += text
    var output: [ContentPart] = []
    var run = ""
    func part(_ value: String, thinking: Bool) -> ContentPart {
      thinking ? .reasoning(value) : .text(value)
    }
    while !pending.isEmpty {
      if pending.first != "<" && pending.first != "`" {
        let end = pending.firstIndex { $0 == "<" || $0 == "`" } ?? pending.endIndex
        run += pending[..<end]
        pending.removeSubrange(..<end)
        continue
      }
      if pending.first == "`" {
        let ticks = pending.prefix { $0 == "`" }.count
        // A run can be split between chunks, including the opening fence.
        if ticks == pending.count { break }
        run += pending.prefix(ticks)
        pending.removeFirst(ticks)
        if codeTicks == 0 { codeTicks = ticks } else if codeTicks == ticks { codeTicks = 0 }
        continue
      }
      let lower = String(pending.prefix(18)).lowercased()
      let markers =
        codeTicks > 0 ? [] : ["<think>", "</think>", "<|channel>thought\n", "<channel|>"]
      if let marker = markers.first(where: { lower.hasPrefix($0) }) {
        if !run.isEmpty {
          output.append(part(run, thinking: thinking))
          run = ""
        }
        pending.removeFirst(marker.count)
        if marker == "</think>" && !thinking {
          // Preserve a template-prefilled closing tag for retrospective rendering.
          run = marker
        } else {
          thinking = marker == "<think>" || marker == "<|channel>thought\n"
        }
      } else if markers.contains(where: { $0.hasPrefix(lower) }) {
        break
      } else {
        run.append(pending.removeFirst())
      }
    }
    if !run.isEmpty { output.append(part(run, thinking: thinking)) }
    for part in output { record(part) }
    return output
  }

  public mutating func appendReasoning(_ text: String) -> [ContentPart] {
    var output = flush()
    guard !text.isEmpty else { return output }
    let part = ContentPart.reasoning(text)
    record(part)
    output.append(part)
    return output
  }

  /// Call at tool boundaries and EOF to release any incomplete literal tag.
  public mutating func flush() -> [ContentPart] {
    defer {
      thinking = false
      codeTicks = 0
    }
    guard !pending.isEmpty else { return [] }
    let part: ContentPart = thinking ? .reasoning(pending) : .text(pending)
    pending = ""
    record(part)
    return [part]
  }

  private mutating func record(_ part: ContentPart) {
    fragments.append(part)
  }

}

/// Adapts ordered provider parts to the tagged text used by collapsed chat views.
public struct ReasoningText: Sendable {
  public private(set) var text = ""
  private var thinking = false
  public init() {}
  public mutating func append(_ part: ContentPart) {
    let value: String
    let isReasoning: Bool
    switch part {
    case .text(let content):
      value = content
      isReasoning = false
    case .reasoning(let content):
      value = content
      isReasoning = true
    default: return
    }
    guard !value.isEmpty else { return }
    if thinking != isReasoning {
      text += isReasoning ? (text.isEmpty ? "" : "\n\n") + "<think>\n" : "\n</think>\n\n"
      thinking = isReasoning
    }
    text += value
  }
  public var rendered: String { text + (thinking ? "\n</think>" : "") }
  public static func render(_ parts: [ContentPart]) -> String {
    var result = Self()
    for part in parts { result.append(part) }
    return result.rendered
  }
}
