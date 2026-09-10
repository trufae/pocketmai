import MaiCore
import XCTest

@testable import PocketMai

final class ReasoningResponseFilteringTests: XCTestCase {
  func testEffortLevelsUseSharedProviderMappingAndKeepSavedNames() throws {
    XCTAssertEqual(ReasoningLevel.xhigh.optionValue, "xhigh")
    XCTAssertEqual(ReasoningLevel.max.optionValue, "max")
    XCTAssertNil(ReasoningLevel.automatic.optionValue)
    XCTAssertEqual(
      ReasoningLevel.disabled.requestFields(family: .qwen, model: "qwen3")["enable_thinking"],
      .bool(false))
    XCTAssertEqual(
      ReasoningLevel.xhigh.requestFields(family: .openAI, model: "gpt-5.2")["reasoning_effort"],
      .string("xhigh"))
    XCTAssertEqual(
      try JSONDecoder().decode(ReasoningLevel.self, from: Data("\"disabled\"".utf8)), .disabled)
    XCTAssertEqual(
      ReasoningLevel.disabled.templateContext(model: "mlx-community/Qwen3-4B")?["enable_thinking"]
        as? Bool, false)
  }

  func testOrderedReasoningStaysInSeparateCollapsedSections() {
    let parts: [MaiCore.ContentPart] = [
      .reasoning("first"), .text("answer"), .reasoning("second"), .text("done"),
    ]
    let rendered = MessageContentFilter.render(ReasoningText.render(parts))
    XCTAssertEqual(rendered.hiddenSections.map(\.content), ["first", "second"])
    XCTAssertTrue(rendered.visibleText.contains("answer"))
    XCTAssertTrue(rendered.visibleText.contains("done"))
  }

  func testRemovingReasoningPreservesToolCallEnvelopeExactly() {
    let toolCall = """
      <tool_call name="search">
      <arg name="query">visible request</arg>
      </tool_call>
      """
    let response = "<think>\nI might call a different tool here.\n</think>\n\n\(toolCall)"

    XCTAssertEqual(
      MessageContentFilter.removingReasoningSections(from: response),
      "\n\n\(toolCall)")
  }

  @MainActor
  func testToolParserDoesNotExecuteCallInsideReasoning() {
    let definition = ToolDefinition(
      name: "search",
      description: "Search for a query.",
      parameters: [
        ToolParameterDef(
          name: "query",
          type: "string",
          description: "Search query.",
          required: true)
      ])
    let response = """
      <think>
      TOOL_CALL
      tool: search
      query: hidden request
      END_TOOL_CALL
      </think>

      TOOL_CALL
      tool: search
      query: visible request
      END_TOOL_CALL
      """
    let actionable = MessageContentFilter.removingReasoningSections(from: response)

    let calls = AgentTooling.parseCalls(
      in: actionable,
      tools: [definition],
      mode: .text)

    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.argumentValues["query"]?.stringValue, "visible request")
  }

  func testEditableTextDropsReasoningAndTidiesBlankLines() {
    let response = """
      <think>
      Internal notes.
      </think>

      Final answer.
      """

    XCTAssertEqual(MessageContentFilter.textWithoutReasoning(from: response), "Final answer.")
  }

  func testEditableTextKeepsEverythingButReasoning() {
    let response = """
      <tool_run>
      tool(search): done
      </tool_run>

      <think>
      Internal notes.
      </think>

      Final answer.
      """

    XCTAssertEqual(
      MessageContentFilter.textWithoutReasoning(from: response),
      """
      <tool_run>
      tool(search): done
      </tool_run>

      Final answer.
      """)
  }

  func testEditableTextLeavesReasoningFreeMessagesUntouched() {
    let response = "  Final answer.\n"

    XCTAssertEqual(MessageContentFilter.textWithoutReasoning(from: response), response)
  }

  func testReasoningClosedWithoutOpeningTagIsHidden() {
    // Qwen 3.5+/3.8 and DeepSeek templates pre-fill `<think>`, so leaked reasoning
    // arrives as prose followed by a bare closing tag.
    let response = """
      I’m Qwen, an AI assistant here to help you. How can I help today?
      </think>

      I’m Qwen — what would you like to work on?
      """

    let rendered = MessageContentFilter.render(response)

    XCTAssertEqual(rendered.visibleText, "I’m Qwen — what would you like to work on?")
    XCTAssertEqual(rendered.hiddenSections.map(\.tag), ["think"])
    XCTAssertEqual(
      rendered.hiddenSections.first?.content,
      "I’m Qwen, an AI assistant here to help you. How can I help today?")
    XCTAssertEqual(
      MessageContentFilter.textWithoutReasoning(from: response),
      "I’m Qwen — what would you like to work on?")
  }

  func testUnopenedReasoningStaysOutOfTheModelContext() {
    let message = ChatMessage(role: .assistant, text: "Draft answer.\n</think>\n\nFinal answer.")

    let messages = PromptComposer.openAIHistoryMessages(
      from: message,
      includeAssistantResponses: true,
      echoReasoningContent: false)

    XCTAssertEqual(messages.map(\.text), ["Final answer."])
  }

  func testEveryReasoningBlockAroundToolRunsIsHidden() {
    let response = """
      <think>
      Need the todo tool first.
      </think>

      <tool_run>
      tool(todo_add): Added todo
      </tool_run>

      Just answer now.
      </think>

      Done: added the todo, and 12 × 12 = 144.
      """

    let rendered = MessageContentFilter.render(response)

    XCTAssertEqual(rendered.visibleText, "Done: added the todo, and 12 × 12 = 144.")
    XCTAssertEqual(rendered.hiddenSections.map(\.tag), ["think", "tool_run", "think"])
    XCTAssertEqual(rendered.hiddenSections.first?.content, "Need the todo tool first.")
    XCTAssertEqual(rendered.hiddenSections.last?.content, "Just answer now.")
  }

  func testReasoningBlocksBetweenProseAreEachHidden() {
    let response = """
      <think>
      First thought.
      </think>

      Part one.

      <think>
      Second thought.
      </think>

      Part two.
      """

    let rendered = MessageContentFilter.render(response)

    XCTAssertEqual(rendered.visibleText, "Part one.\n\nPart two.")
    XCTAssertEqual(rendered.hiddenSections.map(\.content), ["First thought.", "Second thought."])
  }

  func testClosingThinkTagInsideCodeFenceIsLeftAlone() {
    let response = "Use this:\n\n```\n</think>\n```\n\nDone."

    let rendered = MessageContentFilter.render(response)

    XCTAssertEqual(rendered.visibleText, response)
    XCTAssertTrue(rendered.hiddenSections.isEmpty)
  }

  func testInlineClosingThinkTagIsNotTreatedAsReasoning() {
    let response = "Models end reasoning with </think> before answering."

    XCTAssertEqual(MessageContentFilter.render(response).visibleText, response)
  }

  func testEditingKeepsUnopenedReasoning() {
    let response = "Draft.\n</think>\n\nFinal."

    let edited = MessageContentFilter.replacingVisibleText(in: response, with: "Edited.")

    XCTAssertEqual(edited, "Draft.\n</think>\n\nEdited.")
    XCTAssertEqual(MessageContentFilter.render(edited).visibleText, "Edited.")
  }

  func testBeginsWithUnopenedReasoning() {
    XCTAssertTrue(
      MessageContentFilter.beginsWithUnopenedReasoning("More thoughts.\n</think>\n\nAnswer."))
    XCTAssertFalse(
      MessageContentFilter.beginsWithUnopenedReasoning("<think>\nThoughts.\n</think>\n\nAnswer."))
    XCTAssertFalse(MessageContentFilter.beginsWithUnopenedReasoning("Answer without reasoning."))
  }

  func testSpuriousToolCallFilterIgnoresMarkersInsideReasoning() {
    let response = """
      <think>
      TOOL_CALL
      tool: search
      query: internal example
      END_TOOL_CALL
      </think>

      Here is the final answer.
      """

    XCTAssertEqual(AppStore.strippedSpuriousToolCallText(response), response)
  }
}
