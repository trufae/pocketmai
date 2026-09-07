import MaiCore
import XCTest

@testable import PocketMai

final class EndpointHeadersTests: XCTestCase {
  func testOpenCodePresetsRequireASessionHeader() {
    for name in ["OpenCode Zen", "OpenCode Go"] {
      let preset = endpointProviderPresets.first { $0.name == name }
      XCTAssertEqual(preset?.headers, ["x-opencode-session": "{{session}}"], name)
    }
    XCTAssertEqual(endpointProviderPresets.first { $0.name == "OpenAI" }?.headers, [:])
  }

  func testEffectiveHeadersAddWhatThePresetNeedsToOlderEndpoints() {
    var endpoint = OpenAIEndpoint(name: "Go", baseURL: "https://opencode.ai/zen/go/v1")
    XCTAssertEqual(endpoint.effectiveHeaders, ["x-opencode-session": "{{session}}"])

    // The user's own value wins, and their other headers come along.
    endpoint.headers = ["x-opencode-session": "fixed", "X-Tenant": "acme"]
    XCTAssertEqual(
      endpoint.effectiveHeaders, ["x-opencode-session": "fixed", "X-Tenant": "acme"])

    let custom = OpenAIEndpoint(
      name: "Proxy", baseURL: "https://proxy.example/v1", headers: ["X-Tenant": "acme"])
    XCTAssertEqual(custom.effectiveHeaders, ["X-Tenant": "acme"])
  }

  func testHeadersSurviveTheProviderJSONRoundTrip() throws {
    let endpoint = OpenAIEndpoint(
      name: "Proxy", baseURL: "https://proxy.example/v1", headers: ["X-Tenant": "acme"])
    let data = try JSONEncoder().encode(endpoint)
    XCTAssertEqual(try JSONDecoder().decode(OpenAIEndpoint.self, from: data), endpoint)

    // A provider file written by hand may use the line form pmai accepts.
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["headers"] = ["X-Tenant: acme", "x-opencode-session: {{session}}"]
    let lines = try JSONSerialization.data(withJSONObject: object)
    XCTAssertEqual(
      try JSONDecoder().decode(OpenAIEndpoint.self, from: lines).headers,
      ["X-Tenant": "acme", "x-opencode-session": "{{session}}"])

    // Settings saved before headers existed decode to none.
    object.removeValue(forKey: "headers")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    XCTAssertEqual(try JSONDecoder().decode(OpenAIEndpoint.self, from: legacy).headers, [:])
  }

  func testHeadersChangeTheConnectionSignature() {
    let plain = OpenAIEndpoint(name: "Proxy", baseURL: "https://proxy.example/v1")
    var withHeaders = plain
    withHeaders.headers = ["X-Tenant": "acme"]
    XCTAssertNotEqual(plain.connectionSignature, withHeaders.connectionSignature)
  }

  func testConversationsKeepTheSessionMaiCoreMintsForThem() throws {
    let conversation = Conversation()
    XCTAssertFalse(conversation.sessionID.isEmpty)
    XCTAssertNotEqual(conversation.sessionID, Conversation().sessionID)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(conversation)
    XCTAssertEqual(
      try decoder.decode(Conversation.self, from: data).sessionID, conversation.sessionID)

    // A conversation saved before sessions existed gets the same one on every load.
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "sessionID")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    XCTAssertEqual(
      try decoder.decode(Conversation.self, from: legacy).sessionID,
      ChatSession.legacyID(for: conversation.id))
  }
}
