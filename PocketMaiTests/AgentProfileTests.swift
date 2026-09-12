import Foundation
import MaiCore
import XCTest

@testable import PocketMai

/// Agents are named snapshots of the agent-scoped settings. The live fields on
/// `AppSettings` always belong to the selected agent; switching stores them on
/// the agent being left and loads the one being entered.
final class AgentProfileTests: XCTestCase {
  private let endpointID = UUID()
  private let promptID = UUID()
  private let mcpServerID = UUID()

  /// Every agent-scoped field set away from its default, so a field missing
  /// from either side of the snapshot shows up as a mismatch.
  private func customAgentSettings() -> AgentSettings {
    var custom = AgentSettings()
    custom.defaultProvider = .openAICompatible
    custom.appleModelID = "apple-model"
    custom.localMLXModelID = "local/model"
    custom.selectedEndpointID = endpointID
    custom.defaultReasoningLevel = ReasoningLevel.allCases.last ?? .automatic
    custom.streamByDefault = false
    custom.showThinkingByDefault = true
    custom.defaultSystemPromptID = promptID
    custom.defaultEnabledTools = Set(BuiltInToolID.allCases.prefix(2))
    custom.defaultEnabledMCPServers = [mcpServerID]
    custom.defaultEnabledMCPTools = ["server:tool"]
    custom.mcpRequestTimeoutSeconds = 45
    custom.llmRequestTimeoutSeconds = 180
    custom.toolCallingMode = ToolCallingMode.allCases.first { $0 != .text } ?? .text
    custom.maxToolCallsPerTurn = 3
    custom.yoloModeEnabled = false
    custom.useToolProxy = true
    custom.contextWindowMode = ContextWindowMode.allCases.first { $0 != .full } ?? .full
    custom.includeAssistantResponsesInContext = false
    custom.includeReasoningContentInContext = true
    custom.mlxMaxKVSize = MLXKVCacheSize.allCases.first { $0 != .auto } ?? .auto
    custom.mlxAutoCompact = true
    XCTAssertNotEqual(custom, AgentSettings())
    return custom
  }

  func testDefaultsStartWithTheStockAgentSelected() {
    let settings = AppSettings.defaults
    XCTAssertEqual(settings.agents.map(\.id), [AgentProfile.stockID])
    XCTAssertEqual(settings.selectedAgentID, AgentProfile.stockID)
    XCTAssertEqual(settings.selectedAgent.name, AgentProfile.stockName)
    XCTAssertEqual(settings.agentSettings, AgentSettings())
    XCTAssertEqual(settings.agents[0].settings, AgentSettings())
  }

  func testToolCallLimitDefaultsAndBoundsApplyToEveryAgent() throws {
    XCTAssertEqual(AppSettings.defaultMaxToolCallsPerTurn, 50)
    XCTAssertEqual(AgentSettings().maxToolCallsPerTurn, 50)
    XCTAssertEqual(AppSettings().maxToolCallsPerTurn, 50)
    XCTAssertEqual(AppSettings.clampedMaxToolCallsPerTurn(0), 1)
    XCTAssertEqual(AppSettings.clampedMaxToolCallsPerTurn(100), 100)
    XCTAssertEqual(AppSettings.clampedMaxToolCallsPerTurn(101), 100)

    let decodedAgent = try JSONDecoder().decode(
      AgentSettings.self, from: Data(#"{"maxToolCallsPerTurn":101}"#.utf8))
    XCTAssertEqual(decodedAgent.maxToolCallsPerTurn, 100)

    let decodedSettings = try JSONDecoder().decode(
      AppSettings.self, from: Data(#"{"maxToolCallsPerTurn":101}"#.utf8))
    XCTAssertEqual(decodedSettings.maxToolCallsPerTurn, 100)
    XCTAssertEqual(decodedSettings.agents[0].settings.maxToolCallsPerTurn, 100)
  }

  func testAgentSettingsRoundTripThroughTheLiveFields() {
    var settings = AppSettings.defaults
    let custom = customAgentSettings()
    settings.agentSettings = custom
    XCTAssertEqual(settings.agentSettings, custom)
    XCTAssertEqual(settings.defaultProvider, .openAICompatible)
    XCTAssertEqual(settings.selectedEndpointID, endpointID)
    XCTAssertEqual(settings.defaultSystemPromptID, promptID)
    XCTAssertTrue(settings.useToolProxy)
  }

  func testSwitchingAgentsSwapsSettingsAndKeepsTheOnesLeftBehind() {
    var settings = AppSettings.defaults
    settings.agentSettings = customAgentSettings()
    let coder = settings.addAgent(named: "  Coder ")
    XCTAssertEqual(coder.name, "Coder")
    XCTAssertEqual(coder.settings, customAgentSettings(), "a new agent copies the selected one")

    XCTAssertTrue(settings.selectAgent(coder.id))
    settings.maxToolCallsPerTurn = 12
    settings.useToolProxy = false

    XCTAssertTrue(settings.selectAgent(AgentProfile.stockID))
    XCTAssertEqual(settings.agentSettings, customAgentSettings())
    XCTAssertEqual(settings.agents.first { $0.id == coder.id }?.settings.maxToolCallsPerTurn, 12)
    XCTAssertEqual(settings.agents.first { $0.id == coder.id }?.settings.useToolProxy, false)

    XCTAssertTrue(settings.selectAgent(coder.id))
    XCTAssertEqual(settings.maxToolCallsPerTurn, 12)
    XCTAssertFalse(settings.useToolProxy)
    XCTAssertFalse(settings.selectAgent(UUID()), "an unknown id changes nothing")
    XCTAssertEqual(settings.selectedAgentID, coder.id)
  }

  func testRemovingTheSelectedAgentFallsBackToStock() {
    var settings = AppSettings.defaults
    let stockSettings = customAgentSettings()
    settings.agentSettings = stockSettings
    let extra = settings.addAgent(named: "Extra")
    settings.selectAgent(extra.id)
    settings.yoloModeEnabled = true

    XCTAssertFalse(settings.removeAgent(AgentProfile.stockID), "the stock agent stays")
    XCTAssertTrue(settings.removeAgent(extra.id))
    XCTAssertEqual(settings.agents.map(\.id), [AgentProfile.stockID])
    XCTAssertEqual(settings.selectedAgentID, AgentProfile.stockID)
    XCTAssertEqual(settings.agentSettings, stockSettings)
    XCTAssertFalse(settings.removeAgent(extra.id), "removing twice is a no-op")
  }

  func testUpdatingAnAgentKeepsANameWhenTheNewOneIsBlank() {
    var settings = AppSettings.defaults
    let agent = settings.addAgent(named: "", description: " Finds papers ", canSpawnSubagents: true)
    XCTAssertEqual(agent.name, "Agent 2")
    XCTAssertEqual(agent.description, "Finds papers")
    XCTAssertTrue(agent.canSpawnSubagents)
    settings.updateAgent(
      agent.id, name: " Research ", description: "", canSpawnSubagents: false)
    XCTAssertEqual(settings.agents.last?.name, "Research")
    XCTAssertEqual(settings.agents.last?.description, "")
    XCTAssertEqual(settings.agents.last?.canSpawnSubagents, false)
    settings.updateAgent(agent.id, name: "   ", description: "Reads", canSpawnSubagents: true)
    XCTAssertEqual(settings.agents.last?.name, "Research")
    XCTAssertEqual(settings.agents.last?.description, "Reads")
    XCTAssertEqual(settings.agents.last?.canSpawnSubagents, true)
  }

  func testSettingsFromBeforeAgentsGetAStockAgentHoldingThem() throws {
    let legacy = """
      {"defaultProvider":"openAICompatible","selectedEndpointID":"\(endpointID.uuidString)","maxToolCallsPerTurn":5,"useToolProxy":true}
      """
    let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
    XCTAssertEqual(decoded.agents.map(\.id), [AgentProfile.stockID])
    XCTAssertEqual(decoded.selectedAgentID, AgentProfile.stockID)
    XCTAssertEqual(decoded.agents[0].name, AgentProfile.stockName)
    XCTAssertEqual(decoded.agents[0].settings.defaultProvider, .openAICompatible)
    XCTAssertEqual(decoded.agents[0].settings.selectedEndpointID, endpointID)
    XCTAssertEqual(decoded.agents[0].settings.maxToolCallsPerTurn, 5)
    XCTAssertTrue(decoded.agents[0].settings.useToolProxy)
  }

  func testAgentsSurviveEncodingAndStaleSelectionsAreRepaired() throws {
    var settings = AppSettings.defaults
    settings.agentSettings = customAgentSettings()
    let coder = settings.addAgent(
      named: "Coder", description: "Writes Swift", canSpawnSubagents: true)
    settings.selectAgent(coder.id)
    settings.maxToolCallsPerTurn = 9

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    XCTAssertEqual(decoded.agents.map(\.name), [AgentProfile.stockName, "Coder"])
    XCTAssertEqual(decoded.agents[1].description, "Writes Swift")
    XCTAssertTrue(decoded.agents[1].canSpawnSubagents)
    XCTAssertEqual(decoded.agents[0].description, "")
    XCTAssertFalse(decoded.agents[0].canSpawnSubagents)
    XCTAssertEqual(decoded.selectedAgentID, coder.id)
    XCTAssertEqual(decoded.maxToolCallsPerTurn, 9)
    XCTAssertEqual(decoded.agents[1].settings.maxToolCallsPerTurn, 9)
    XCTAssertEqual(decoded.agents[0].settings, customAgentSettings())

    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["selectedAgentID"] = UUID().uuidString
    object["agents"] = [["id": coder.id.uuidString, "name": "", "settings": [String: Any]()]]
    let repaired = try JSONDecoder().decode(
      AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(repaired.selectedAgentID, AgentProfile.stockID)
    XCTAssertEqual(repaired.agents.map(\.name), [AgentProfile.stockName, "Agent 1"])
    XCTAssertEqual(
      repaired.agents[0].settings.maxToolCallsPerTurn, 9,
      "the stock agent is rebuilt from the live fields")
  }
}
