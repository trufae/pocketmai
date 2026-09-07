import Foundation
import MaiCore
import XCTest

@testable import PocketMai

/// The agent_* tools reach a chat only through the selected agent's
/// permission, and name every other agent as a child it may start.
@MainActor
final class SubagentToolTests: XCTestCase {
  func testAgentToolsFollowTheSelectedAgentsPermission() {
    var settings = AppSettings.defaults
    let conversation = Conversation()
    XCTAssertTrue(SubagentTool.definitions(for: conversation, settings: settings).isEmpty)
    XCTAssertFalse(
      ToolAgentRegistry.definitions(for: conversation, settings: settings)
        .contains { SubagentTool.isAgentTool($0.name) })

    settings.agents[0].canSpawnSubagents = true
    let names = SubagentTool.definitions(for: conversation, settings: settings).map(\.name)
    XCTAssertEqual(Set(names), AgentProcessTools.toolNames)
    XCTAssertEqual(names.first, AgentProcessTools.startToolName)
    let registry = ToolAgentRegistry.definitions(for: conversation, settings: settings).map(\.name)
    XCTAssertTrue(Set(registry).isSuperset(of: AgentProcessTools.toolNames))

    var withoutTools = conversation
    withoutTools.toolsEnabled = false
    XCTAssertTrue(SubagentTool.definitions(for: withoutTools, settings: settings).isEmpty)
    XCTAssertTrue(ToolAgentRegistry.definitions(for: withoutTools, settings: settings).isEmpty)
  }

  func testOtherAgentsAreOfferedByNameWithoutTheCaller() throws {
    var settings = AppSettings.defaults
    settings.addAgent(named: "Researcher", description: "Finds things on the web")
    settings.addAgent(named: "Researcher", description: "A second one with the same name")
    settings.addAgent(named: "Coder")
    settings.selectAgent(AgentProfile.stockID)

    let offered = SubagentTool.offeredAgents(settings: settings)
    XCTAssertEqual(offered.map(\.id), ["Researcher", "Coder"])
    XCTAssertEqual(offered.first?.purpose, "Finds things on the web")

    settings.agents[0].canSpawnSubagents = true
    let start = try XCTUnwrap(
      SubagentTool.definitions(for: Conversation(), settings: settings).first)
    let agent = start.inputSchema.objectValue?["properties"]?.objectValue?["agent"]?.objectValue
    XCTAssertEqual(agent?["enum"], .array([.string("Coder"), .string("Researcher")]))
    XCTAssertTrue(
      agent?["description"]?.stringValue?.contains("Omit to use a general worker") == true)

    // Selecting another agent moves the caller: it is left out, the stock one offered.
    settings.selectAgent(try XCTUnwrap(settings.agents.first { $0.name == "Coder" }?.id))
    XCTAssertEqual(
      SubagentTool.offeredAgents(settings: settings).map(\.id),
      [AgentProfile.stockName, "Researcher"])
  }

  func testThePlanSentenceFollowsTheSetting() throws {
    var settings = AppSettings.defaults
    settings.agents[0].canSpawnSubagents = true
    XCTAssertTrue(settings.plansBeforeDelegating)
    let planned = try XCTUnwrap(
      SubagentTool.definitions(for: Conversation(), settings: settings).first)
    XCTAssertTrue(planned.description.contains("numbered plan"), planned.description)
    settings.plansBeforeDelegating = false
    let unplanned = try XCTUnwrap(
      SubagentTool.definitions(for: Conversation(), settings: settings).first)
    XCTAssertFalse(unplanned.description.contains("numbered plan"), unplanned.description)

    // Settings saved before the switch existed load with it on.
    let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    XCTAssertTrue(legacy.plansBeforeDelegating)
    let off = try JSONDecoder().decode(
      AppSettings.self, from: Data(#"{"plansBeforeDelegating":false}"#.utf8))
    XCTAssertFalse(off.plansBeforeDelegating)
  }

  func testEveryAgentToolIsAnAsynchronousCall() {
    var settings = AppSettings.defaults
    settings.agents[0].canSpawnSubagents = true
    let definitions = SubagentTool.definitions(for: Conversation(), settings: settings)
    XCTAssertEqual(Set(definitions.map(\.name)), AgentProcessTools.toolNames)
    XCTAssertTrue(definitions.allSatisfy { $0.annotations.concurrent })
  }

  func testAChildIsAPeerUntilTheLeafDepth() throws {
    var settings = AppSettings.defaults
    settings.agents[0].canSpawnSubagents = true
    settings.addAgent(named: "Coder")
    settings.selectAgent(AgentProfile.stockID)
    let coderID = try XCTUnwrap(settings.agents.first { $0.name == "Coder" }?.id)
    let coderIndex = try XCTUnwrap(settings.agents.firstIndex { $0.id == coderID })
    settings.agents[coderIndex].canSpawnSubagents = true

    // One level down a worker keeps the permission and sees the tools.
    let worker = SubagentTool.childSettings(
      from: settings, agentID: AgentProfile.stockID, depth: 1)
    XCTAssertEqual(worker.selectedAgentID, AgentProfile.stockID)
    XCTAssertTrue(worker.selectedAgent.canSpawnSubagents)
    XCTAssertFalse(SubagentTool.definitions(for: Conversation(), settings: worker).isEmpty)

    // At the leaf depth it could not start anything, so the tools are withheld.
    let leaf = SubagentTool.childSettings(
      from: settings, agentID: AgentProfile.stockID, depth: SubagentTool.maxDepth)
    XCTAssertFalse(leaf.selectedAgent.canSpawnSubagents)
    XCTAssertTrue(SubagentTool.definitions(for: Conversation(), settings: leaf).isEmpty)

    // A named profile is selected in the copy and follows the same rule.
    let named = SubagentTool.childSettings(from: settings, agentID: coderID, depth: 1)
    XCTAssertEqual(named.selectedAgentID, coderID)
    XCTAssertTrue(named.selectedAgent.canSpawnSubagents)
    let namedLeaf = SubagentTool.childSettings(
      from: settings, agentID: coderID, depth: SubagentTool.maxDepth)
    XCTAssertEqual(namedLeaf.selectedAgentID, coderID)
    XCTAssertFalse(namedLeaf.selectedAgent.canSpawnSubagents)

    // The caller's own settings are untouched.
    XCTAssertEqual(settings.selectedAgentID, AgentProfile.stockID)
    XCTAssertTrue(settings.selectedAgent.canSpawnSubagents)
    XCTAssertTrue(settings.agents[coderIndex].canSpawnSubagents)
  }

  func testAWorkerTranscriptKeepsEveryTurnInOrder() {
    var conversation = Conversation()
    conversation.messages = [
      ChatMessage(role: .user, text: "brief"),
      ChatMessage(role: .assistant, text: ""),
      ChatMessage(role: .assistant, text: "answer"),
    ]
    let transcript = SubagentRunner.transcript(of: conversation)
    XCTAssertEqual(transcript.map(\.role), [.user, .assistant])
    XCTAssertEqual(transcript.map(\.text), ["brief", "answer"])
  }
}
