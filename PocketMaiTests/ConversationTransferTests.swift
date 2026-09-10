import Foundation
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

    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "conversations")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ConversationExportEnvelope.self, from: legacyData)

    XCTAssertEqual(decoded.conversation, original)
    XCTAssertEqual(decoded.exportedConversations, [original])
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
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ConversationExportEnvelope.self, from: data)

    XCTAssertEqual(decoded.conversation, first)
    XCTAssertEqual(decoded.exportedConversations, [first, second])
  }
}
