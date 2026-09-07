import Foundation
import MaiCore
import XCTest

@testable import PocketMai

/// A stand-in for an OpenAI-compatible endpoint, answering from a script that
/// looks at what the app sent: the parent's first turn gets a tool call, the
/// child's brief gets an answer, and the parent's follow-up gets the answer
/// echoed back. It intercepts `URLSession.shared`, which is what the OpenAI
/// plugin uses, so no socket is opened.
final class StubChatEndpoint: URLProtocol {
  static let host = "stub.local"
  nonisolated(unsafe) static var requests: [[String: Any]] = []
  private static let lock = NSLock()

  static func install() {
    lock.withLock { requests = [] }
    URLProtocol.registerClass(StubChatEndpoint.self)
  }

  static func uninstall() {
    URLProtocol.unregisterClass(StubChatEndpoint.self)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == host
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let body = Self.body(of: request)
    let payload: [String: Any]
    if request.url?.path.hasSuffix("/models") == true {
      payload = ["object": "list", "data": [["id": "stub"]]]
    } else {
      let json =
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
      Self.lock.withLock { Self.requests.append(json) }
      payload = Self.reply(to: json)
    }
    let data = try! JSONSerialization.data(withJSONObject: payload)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func body(of request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      guard read > 0 else { break }
      data.append(buffer, count: read)
    }
    return data
  }

  private static func reply(to request: [String: Any]) -> [String: Any] {
    let messages = request["messages"] as? [[String: Any]] ?? []
    if let toolResult = messages.last(where: { $0["role"] as? String == "tool" }) {
      let content = toolResult["content"] as? String ?? ""
      return completion(content: "Parent got: \(content)")
    }
    let lastUser = messages.last { $0["role"] as? String == "user" }
    let prompt = lastUser?["content"] as? String ?? ""
    if prompt.contains("## Task") {
      return completion(content: "Child answer")
    }
    return [
      "id": "stub-call",
      "object": "chat.completion",
      "choices": [
        [
          "index": 0,
          "finish_reason": "tool_calls",
          "message": [
            "role": "assistant",
            "content": "",
            "tool_calls": [
              [
                "id": "call_1",
                "type": "function",
                "function": [
                  "name": AgentProcessTools.startToolName,
                  "arguments": "{\"task\":\"Say hi\",\"output\":\"Two words\"}",
                ],
              ]
            ],
          ],
        ]
      ],
    ]
  }

  private static func completion(content: String) -> [String: Any] {
    [
      "id": "stub-final",
      "object": "chat.completion",
      "choices": [
        [
          "index": 0,
          "finish_reason": "stop",
          "message": ["role": "assistant", "content": content],
        ]
      ],
    ]
  }
}

/// The whole path a chat takes when its agent delegates: the parent calls
/// agent_start, a child conversation runs in its own task against the same
/// endpoint, its answer comes back as the tool result, and the supervisor
/// shows the child as this chat's, finished and collected.
@MainActor
final class SubagentEndToEndTests: XCTestCase {
  private var store: AppStore!

  override func setUp() async throws {
    try await super.setUp()
    StubChatEndpoint.install()
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("pocketmai-subagent-\(UUID().uuidString)", isDirectory: true)
    store = AppStore(persistence: PersistenceStore(localBaseURL: base))
    let deadline = Date().addingTimeInterval(20)
    while !store.hasLoadedPersistedSettings {
      XCTAssertLessThan(Date(), deadline, "settings never loaded")
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  override func tearDown() async throws {
    StubChatEndpoint.uninstall()
    store = nil
    try await super.tearDown()
  }

  func testAgentStartRunsAChildAndHandsItsAnswerToTheParent() async throws {
    let endpoint = OpenAIEndpoint(
      name: "Stub",
      baseURL: "https://\(StubChatEndpoint.host)/v1",
      apiKey: "stub",
      defaultModel: "stub",
      isEnabled: true)
    store.settings.openAIEndpoints = [endpoint]
    store.settings.defaultProvider = .openAICompatible
    store.settings.selectedEndpointID = endpoint.id
    store.settings.toolCallingMode = .native
    store.settings.yoloModeEnabled = true
    store.settings.agents[0].canSpawnSubagents = true
    XCTAssertTrue(store.settings.selectedAgent.canSpawnSubagents)

    var conversation = Conversation()
    conversation.provider = .openAICompatible
    conversation.endpointID = endpoint.id
    conversation.modelID = "stub"
    conversation.usesStreaming = false
    conversation.enabledTools = []
    conversation.enabledMCPServers = []
    conversation.messages = [ChatMessage(role: .user, text: "Delegate this")]

    let result = try await AssistantToolLoop.runIsolated(
      conversation: conversation,
      settings: store.settings,
      baseContext: "",
      store: store)

    XCTAssertEqual(result.text, "Parent got: Child answer")
    XCTAssertEqual(result.toolRuns.map(\.name), [AgentProcessTools.startToolName])
    XCTAssertEqual(result.toolRuns.first?.result, "Child answer")
    XCTAssertFalse(result.toolRuns.first?.isError ?? true)

    // Three model calls: the parent's, the child's, and the parent's again.
    XCTAssertEqual(StubChatEndpoint.requests.count, 3)
    let childRequest = StubChatEndpoint.requests[1]
    let childMessages = childRequest["messages"] as? [[String: Any]] ?? []
    let childPrompt = childMessages.last { $0["role"] as? String == "user" }?["content"] as? String
    XCTAssertTrue(childPrompt?.contains("## Task\n\nSay hi") == true, childPrompt ?? "")
    XCTAssertTrue(childPrompt?.contains("running as agent 'Main.worker'") == true)
    let childSystem = childMessages.first { $0["role"] as? String == "system" }?["content"] as? String
    XCTAssertTrue(childSystem?.contains("focused worker agent") == true, childSystem ?? "")
    // The worker gets the parent's tools but may not delegate further.
    let childTools = (childRequest["tools"] as? [[String: Any]] ?? []).compactMap {
      ($0["function"] as? [String: Any])?["name"] as? String
    }
    XCTAssertFalse(childTools.contains(AgentProcessTools.startToolName), "\(childTools)")

    // The supervisor lists the child under the chat's own process, done and taken.
    await store.refreshAgentProcesses()
    let children = store.agentChildren(of: conversation.id)
    XCTAssertEqual(children.count, 1)
    let child = try XCTUnwrap(children.first)
    XCTAssertEqual(child.agentID, "Main.worker")
    XCTAssertEqual(child.displayName, "Main worker")
    XCTAssertEqual(child.state, .completed)
    XCTAssertTrue(child.isCollected)
    XCTAssertEqual(child.depth, 1)
    XCTAssertEqual(child.task, "Say hi")
    XCTAssertEqual(child.modelTurns, 1)
    let transcript = await store.agentTranscript(child.pid)
    XCTAssertEqual(transcript.map(\.role), [.user, .assistant])
    XCTAssertEqual(transcript.last?.text, "Child answer")
    XCTAssertFalse(store.hasLiveAgentChildren(in: conversation.id))
  }
}
