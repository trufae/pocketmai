import Foundation
import Testing

@testable import MaiCore

// The context tools let an agent shrink its own conversation: drop what no
// longer matters, rewrite a message, or fold a stretch into a summary. Edits
// are queued while the turn runs and applied before the next model call.

@Test("Removing either side of a tool exchange removes both, and the report counts characters")
func editorRemovesLinkedToolMessages() {
  let messages = contextFixture()
  let edit = AgentTranscriptEdit.remove(messageIDs: [messages[3].id])  // the tool result
  let applied = AgentTranscriptEditor.apply([edit], to: messages)
  #expect(applied.messages.map(\.id) == [messages[0].id, messages[1].id, messages[4].id, messages[5].id])
  #expect(applied.report.removed == 2)
  #expect(applied.report.charactersBefore > applied.report.charactersAfter)
  #expect(applied.report.summary.hasPrefix("removed 2 messages ("))

  let rewritten = AgentTranscriptEditor.apply(
    [.rewrite(messageID: messages[1].id, text: "Short instruction.")], to: messages)
  #expect(rewritten.messages[1].text == "Short instruction.")
  #expect(rewritten.report.rewritten == 1)

  let compacted = AgentTranscriptEditor.apply(
    [.compact(messageIDs: [messages[1].id, messages[2].id], summary: "The user wanted the file read; it was.")],
    to: messages)
  #expect(compacted.report.compacted == 3)  // the tool result goes with its call
  #expect(compacted.messages.count == 4)
  #expect(compacted.messages[1].role == .user)
  #expect(compacted.messages[1].text.contains("Summary of earlier parts of this conversation"))
  #expect(compacted.messages[1].text.hasSuffix("The user wanted the file read; it was."))
  #expect(compacted.messages[2].id == messages[4].id)
}

private func contextFixture() -> [AgentMessage] {
  [
    .system("You are terse."),
    .user("Please read a.c but first let me tell you a long story about my weekend."),
    AgentMessage(
      role: .assistant,
      content: [.toolCall(ToolCall(id: "call-1", name: "read_file", arguments: .object(["path": .string("a.c")])))]),
    AgentMessage(role: .tool, content: [.toolResult(ToolResult(callID: "call-1", text: String(repeating: "x", count: 500)))]),
    .user("Now summarize it."),
    AgentMessage(
      role: .assistant,
      content: [.toolCall(ToolCall(id: "call-2", name: "context_list", arguments: .object([:])))]),
  ]
}

private actor ContextScriptedProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "context-scripted", displayName: "Context scripted",
    capabilities: [.streaming, .nativeToolCalling])
  private var responses: [ProviderResponse]
  private(set) var requests: [ProviderRequest] = []

  init(responses: [ProviderResponse]) { self.responses = responses }

  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws -> ProviderResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw ContextTestError.missingResponse }
    return responses.removeFirst()
  }
}

private struct AllowAllContextApprovals: ApprovalHandler {
  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    .approve(arguments: request.call.arguments)
  }
}

private actor ContextEventRecorder {
  private(set) var events: [AgentEvent] = []
  func append(_ event: AgentEvent) { events.append(event) }
}

private enum ContextTestError: Error { case missingResponse }
