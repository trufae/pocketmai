import Foundation
import MaiCore
import XCTest

@testable import PocketMai

final class ConversationTransferTests: XCTestCase {
  private func conversation(_ title: String, createdAt: TimeInterval) -> Conversation {
    let timestamp = Date(timeIntervalSince1970: createdAt)
    var conversation = Conversation()
    conversation.title = title
    conversation.createdAt = timestamp
    conversation.updatedAt = timestamp
    conversation.messages = [ChatMessage(role: .user, text: title, createdAt: timestamp)]
    return conversation
  }

  private func subagentRecord(
    pid: AgentPID,
    parent: AgentPID?,
    runID: UUID,
    parentRunID: UUID? = nil,
    text: String
  ) -> AgentProcessRecord {
    AgentProcessRecord(
      process: AgentProcessInfo(
        pid: pid,
        parent: parent,
        runID: runID,
        agentID: "helper",
        task: text,
        state: .completed,
        depth: parentRunID == nil ? 1 : 2,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        finishedAt: Date(timeIntervalSince1970: 1_700_000_001)),
      messages: [.user(text), .assistant("Done: \(text)")],
      parentRunID: parentRunID)
  }

  func testConversationExportsUsePocketMaiJSONSuffix() {
    XCTAssertEqual(ConversationExportFormat.json.fileExtension, "pocketmai.json")
    XCTAssertEqual(ConversationExportFormat.debug.fileExtension, "json")
    XCTAssertTrue(
      ConversationExportFiles.isConversationExport(filename: "Two Chats.POCKETMAI.JSON"))
    XCTAssertFalse(ConversationExportFiles.isConversationExport(filename: "ordinary.json"))
  }

  func testSingleConversationEnvelopeRemainsCompatible() throws {
    let original = conversation("Legacy chat", createdAt: 1_700_000_000)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(
      ConversationExportEnvelope(
        conversation: original,
        exportedAt: Date(timeIntervalSince1970: 1_700_000_100),
        pocketMaiVersion: "1.7.4"))
    let portable = try MaiArchive.decode(from: encoded)

    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "conversations")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ConversationExportEnvelope.self, from: legacyData)

    XCTAssertEqual(decoded.conversation, original)
    XCTAssertEqual(decoded.exportedConversations, [original])
    XCTAssertEqual(portable.chats?.first?.id, original.id)
    XCTAssertEqual(portable.chats?.first?.messages.last?.text, original.messages.last?.text)
  }

  func testPackedEnvelopeKeepsLegacyConversationAndAllConversations() throws {
    let first = conversation("First", createdAt: 1_700_000_200)
    let second = conversation("Second", createdAt: 1_700_000_100)
    let envelope = ConversationExportEnvelope(
      conversations: [first, second],
      exportedAt: Date(timeIntervalSince1970: 1_700_000_300),
      pocketMaiVersion: "1.7.4")

    XCTAssertEqual(envelope.conversation, first)
    XCTAssertEqual(envelope.exportedConversations, [first, second])
    XCTAssertEqual(envelope.createdAt, second.createdAt)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(envelope)
    let portable = try MaiArchive.decode(from: data)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ConversationExportEnvelope.self, from: data)

    XCTAssertEqual(decoded.conversation, first)
    XCTAssertEqual(decoded.exportedConversations, [first, second])
    XCTAssertEqual(portable.chats?.map(\.id), [first.id, second.id])
  }

  func testConversationEnvelopeEmbedsPortableChatWithoutChangingLegacyPayload() throws {
    struct LegacyEnvelope: Decodable {
      var format: String
      var conversation: Conversation
    }

    let original = conversation("Shared chat", createdAt: 1_700_000_400)
    var envelope = ConversationExportEnvelope(
      conversation: original,
      exportedAt: Date(timeIntervalSince1970: 1_700_000_500),
      pocketMaiVersion: "1.7.4")
    envelope.portable = MaiArchive(
      generator: "PocketMai tests",
      chats: [AgentChat(pocketMai: original, settings: AppSettings())])

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(envelope)
    let portable = try MaiArchive.decode(from: data)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacy = try decoder.decode(LegacyEnvelope.self, from: data)

    XCTAssertEqual(envelope.conversation, original)
    XCTAssertEqual(legacy.format, ConversationExportEnvelope.format)
    XCTAssertEqual(legacy.conversation, original)
    XCTAssertEqual(portable.chats?.first?.id, original.id)
    XCTAssertEqual(portable.chats?.first?.title, original.title)
  }

  func testPortableConversationRoundTripKeepsNestedSubagentChats() throws {
    let childRunID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    var original = conversation("Delegated chat", createdAt: 1_700_000_400)
    original.subagents = [
      subagentRecord(
        pid: 2, parent: 1, runID: childRunID, text: "Research the question"),
      subagentRecord(
        pid: 3, parent: 2, runID: UUID(), parentRunID: childRunID,
        text: "Read the source"),
    ]

    let settings = AppSettings()
    let portable = AgentChat(pocketMai: original, settings: settings)
    XCTAssertEqual(portable.subagents, original.subagents)
    XCTAssertEqual(portable.subagents[1].parentRunID, childRunID)
    XCTAssertEqual(portable.subagents[0].messages.last?.text, "Done: Research the question")

    let restored = Conversation(archive: portable, settings: settings)
    XCTAssertEqual(restored.subagents, original.subagents)

    let legacyEnvelope = ConversationExportEnvelope(conversation: original)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let legacyDecoded = try MaiArchive.decode(from: encoder.encode(legacyEnvelope))
    XCTAssertEqual(legacyDecoded.chats?.first?.subagents, original.subagents)

    var envelope = legacyEnvelope
    envelope.portable = MaiArchive(generator: "PocketMai tests", chats: [portable])
    let decoded = try MaiArchive.decode(from: encoder.encode(envelope))
    XCTAssertEqual(decoded.chats?.first?.subagents, original.subagents)
  }

  func testPortableProviderAndMCPAdaptersPreserveSharedSettings() throws {
    let expiry = Date(timeIntervalSince1970: 1_700_000_600)
    let endpoint = OpenAIEndpoint(
      name: "Remote",
      baseURL: "https://models.example/v1",
      apiKey: "token",
      defaultModel: "example-model",
      defaultReasoningLevel: .high,
      authMethod: .oauth,
      oauthClientID: "client",
      oauthRefreshToken: "refresh",
      oauthAccessTokenExpiresAt: expiry,
      headers: ["X-Test": "yes"])
    let restoredEndpoint = try XCTUnwrap(OpenAIEndpoint(archive: ConfiguredProvider(pocketMai: endpoint)))
    XCTAssertEqual(restoredEndpoint, endpoint)

    var authentication = MCPAuthentication()
    authentication.method = .oauth
    authentication.oauthAccessToken = "access"
    authentication.oauthRefreshToken = "refresh"
    authentication.oauthAccessTokenExpiresAt = expiry
    authentication.oauthClientID = "client"
    let server = MCPServer(
      name: "Tools", baseURL: "https://mcp.example", isEnabled: false,
      transport: .streamableHTTP, authentication: authentication)
    let restoredServer = try XCTUnwrap(MCPServer(archive: ConfiguredMCPServer(pocketMai: server)))
    XCTAssertEqual(restoredServer, server)
  }
}
