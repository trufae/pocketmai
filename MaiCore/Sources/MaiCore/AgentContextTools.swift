import Foundation

/// An edit an agent asked for on its own conversation. The runtime applies it
/// before the agent's next model turn, so a run can drop what no longer
/// matters — a wrong instruction, a long tool result, an aside — and go on
/// with a smaller context instead of dragging it to the end.
public enum AgentTranscriptEdit: Equatable, Sendable {
  case remove(messageIDs: [String])
  case rewrite(messageID: String, text: String)
  /// Replaces the messages with one summary at the place of the first.
  case compact(messageIDs: [String], summary: String)
}

/// What applying edits did, for hosts to show and tools to report.
public struct AgentTranscriptEditReport: Equatable, Sendable {
  public var removed: Int
  public var rewritten: Int
  public var compacted: Int
  public var charactersBefore: Int
  public var charactersAfter: Int

  public init(
    removed: Int = 0,
    rewritten: Int = 0,
    compacted: Int = 0,
    charactersBefore: Int = 0,
    charactersAfter: Int = 0
  ) {
    self.removed = removed
    self.rewritten = rewritten
    self.compacted = compacted
    self.charactersBefore = charactersBefore
    self.charactersAfter = charactersAfter
  }

  public var isEmpty: Bool { removed == 0 && rewritten == 0 && compacted == 0 }

  /// `removed 3 messages, compacted 4 into a summary (12.3k → 2.1k chars)`
  public var summary: String {
    var parts: [String] = []
    if removed > 0 { parts.append("removed \(removed) message\(removed == 1 ? "" : "s")") }
    if rewritten > 0 { parts.append("rewrote \(rewritten) message\(rewritten == 1 ? "" : "s")") }
    if compacted > 0 {
      parts.append("compacted \(compacted) message\(compacted == 1 ? "" : "s") into a summary")
    }
    guard !parts.isEmpty else { return "nothing changed" }
    let before = AgentProcessInfo.compactCount(charactersBefore)
    let after = AgentProcessInfo.compactCount(charactersAfter)
    return parts.joined(separator: ", ") + " (\(before) → \(after) chars)"
  }
}

/// Applies context edits to a transcript. Removing either side of a tool
/// exchange removes the other side too, so what is left can still be sent to
/// a provider.
public enum AgentTranscriptEditor {
  public static func apply(
    _ edits: [AgentTranscriptEdit],
    to messages: [AgentMessage]
  ) -> (messages: [AgentMessage], report: AgentTranscriptEditReport) {
    var transcript = AgentTranscript(messages: messages)
    var report = AgentTranscriptEditReport(charactersBefore: characterCount(of: messages))
    for edit in edits {
      switch edit {
      case .remove(let ids):
        for id in ids {
          if let dropped = try? transcript.removeMessage(id: id) { report.removed += dropped.count }
        }
      case .rewrite(let id, let text):
        if (try? transcript.editMessage(id: id, text: text)) != nil { report.rewritten += 1 }
      case .compact(let ids, let summary):
        guard let first = ids.compactMap({ transcript.index(ofMessageID: $0) }).min() else { continue }
        var dropped = 0
        for id in ids {
          if let removed = try? transcript.removeMessage(id: id) { dropped += removed.count }
        }
        guard dropped > 0 else { continue }
        report.compacted += dropped
        var all = transcript.messages
        all.insert(summaryMessage(summary), at: min(first, all.count))
        transcript.replaceAll(with: all)
      }
    }
    report.charactersAfter = characterCount(of: transcript.messages)
    return (transcript.messages, report)
  }

  /// A transcript cut off inside a tool exchange — by Ctrl+C, a crash, a
  /// dropped connection — ends with calls nobody answered, which providers
  /// reject. This answers each with an error that says so, so the transcript
  /// can be run again and the model knows those steps did not happen.
  public static func answeringUnansweredToolCalls(
    in messages: [AgentMessage],
    reason: String
  ) -> [AgentMessage] {
    let answered = Set(messages.flatMap(\.toolResults).map(\.callID))
    var repaired = messages
    for (index, message) in messages.enumerated().reversed() where message.role == .assistant {
      let pending = message.toolCalls.filter { !answered.contains($0.id) }
      guard !pending.isEmpty else { continue }
      let results = pending.map {
        ContentPart.toolResult(
          ToolResult(callID: $0.id, text: "Error: not executed; \(reason).", isError: true))
      }
      repaired.insert(AgentMessage(role: .tool, content: results), at: index + 1)
      break
    }
    return repaired
  }

  /// A summary reads as something the conversation already covered, in the
  /// user's voice so every provider accepts it wherever it lands.
  static func summaryMessage(_ summary: String) -> AgentMessage {
    .user(
      "Summary of earlier parts of this conversation, written by the assistant to save context:\n\n"
        + summary.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  public static func characterCount(of messages: [AgentMessage]) -> Int {
    messages.reduce(0) { $0 + characterCount(of: $1) }
  }

  public static func characterCount(of message: AgentMessage) -> Int {
    message.content.reduce(0) { total, part in
      switch part {
      case .text(let text), .reasoning(let text): total + text.count
      case .toolCall(let call): total + call.name.count + call.arguments.compactJSONString.count
      case .toolResult(let result): total + result.text.count
      case .file(let file): total + (file.text?.count ?? 0)
      case .resource(let resource): total + (resource.text?.count ?? 0)
      case .image, .audio: total + 64
      }
    }
  }
}
