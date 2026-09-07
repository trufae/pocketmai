import Foundation
import Testing

@testable import MaiACP
@testable import MaiCore

/// An in-memory transport pair, so two peers can talk without spawning a
/// process. Whatever one end sends, the other end receives.
private final class PipeTransport: JSONRPCTransport, @unchecked Sendable {
  private let outbound: AsyncStream<JSONRPCMessage>.Continuation
  private let inbound: AsyncStream<JSONRPCMessage>
  private let peerContinuation: AsyncStream<JSONRPCMessage>.Continuation

  private init(
    inbound: AsyncStream<JSONRPCMessage>,
    outbound: AsyncStream<JSONRPCMessage>.Continuation,
    peerContinuation: AsyncStream<JSONRPCMessage>.Continuation
  ) {
    self.inbound = inbound
    self.outbound = outbound
    self.peerContinuation = peerContinuation
  }

  static func pair() -> (PipeTransport, PipeTransport) {
    let (aStream, aCont) = AsyncStream<JSONRPCMessage>.makeStream(bufferingPolicy: .unbounded)
    let (bStream, bCont) = AsyncStream<JSONRPCMessage>.makeStream(bufferingPolicy: .unbounded)
    // a sends into b's stream and reads from a's stream.
    let a = PipeTransport(inbound: aStream, outbound: bCont, peerContinuation: aCont)
    let b = PipeTransport(inbound: bStream, outbound: aCont, peerContinuation: bCont)
    return (a, b)
  }

  func messages() -> AsyncStream<JSONRPCMessage> { inbound }
  func send(_ message: JSONRPCMessage) throws { outbound.yield(message) }
  func close() {
    outbound.finish()
    peerContinuation.finish()
  }
}

@Test("A JSON-RPC message keeps the 2.0 envelope and result/error shape")
func jsonRPCEncoding() throws {
  let request = JSONRPCMessage.request(id: 7, method: "session/prompt", params: .object([:]))
  let requestJSON = try JSONEncoder().encode(request)
  let requestObject = try JSONDecoder().decode(JSONValue.self, from: requestJSON).objectValue
  #expect(requestObject?["jsonrpc"]?.stringValue == "2.0")
  #expect(requestObject?["id"]?.intValue == 7)
  #expect(request.isRequest)

  // A response always carries a result key, even when null.
  let response = JSONRPCMessage.response(id: .integer(7), result: .null)
  let responseObject = try JSONDecoder().decode(
    JSONValue.self, from: JSONEncoder().encode(response)
  ).objectValue
  #expect(responseObject?.keys.contains("result") == true)
  #expect(responseObject?.keys.contains("method") == false)

  let failure = JSONRPCMessage.failure(id: .integer(7), error: .methodNotFound("x"))
  #expect(failure.error?.code == JSONRPCError.methodNotFound)
}

@Test("Two peers exchange requests, replies, and errors over a transport")
func jsonRPCPeerRoundTrip() async throws {
  let (clientTransport, serverTransport) = PipeTransport.pair()
  let server = JSONRPCPeer(
    transport: serverTransport,
    onRequest: { method, params in
      switch method {
      case "echo": return params ?? .null
      default: throw JSONRPCError.methodNotFound(method)
      }
    })
  await server.start()
  let client = JSONRPCPeer(transport: clientTransport)
  await client.start()

  let echoed = try await client.request("echo", params: .string("hi"), timeout: 5)
  #expect(echoed.stringValue == "hi")

  await #expect(throws: JSONRPCError.self) {
    _ = try await client.request("missing", timeout: 5)
  }
  await client.close()
  await server.close()
}

@Test("ACP content blocks flatten a prompt and read agent updates")
func acpContentBlocks() {
  let prompt: JSONValue = .array([
    .object(["type": .string("text"), "text": .string("summarize")]),
    .object(["type": .string("resource_link"), "name": .string("README"), "uri": .string("f.md")]),
  ])
  #expect(ACP.promptText(prompt) == "summarize\n\nREADME: f.md")

  // Updates carry content as a single block or an array; both read.
  #expect(ACP.ContentBlock.text(from: .object(["text": .string("hi")])) == "hi")
  #expect(
    ACP.ContentBlock.text(
      from: .array([.object(["text": .string("a")]), .object(["text": .string("b")])])) == "ab")

  #expect(ACP.StopReason(.cancelled) == .cancelled)
  #expect(ACP.StopReason.endTurn.providerStopReason == .stop)
}

@Test("The permission policy picks the once option matching the verdict")
func acpPermissionPolicy() {
  let options: [JSONValue] = [
    .object(["optionId": .string("allow_once"), "kind": .string("allow_once")]),
    .object(["optionId": .string("allow_always"), "kind": .string("allow_always")]),
    .object(["optionId": .string("reject_once"), "kind": .string("reject_once")]),
  ]
  #expect(ACPPermissionPolicy.allow.optionID(from: options, kind: "edit") == "allow_once")
  #expect(ACPPermissionPolicy.reject.optionID(from: options, kind: "read") == "reject_once")
  // auto approves read-only kinds and rejects the rest.
  #expect(ACPPermissionPolicy.auto.optionID(from: options, kind: "read") == "allow_once")
  #expect(ACPPermissionPolicy.auto.optionID(from: options, kind: "edit") == "reject_once")
}

@Test("A catalog agent becomes an acp-kind provider record")
func acpCatalog() {
  let gemini = ACPCatalog.agent("gemini")
  #expect(gemini?.command == "gemini")
  let provider = gemini?.configuredProvider()
  #expect(provider?.kind == ACPConfiguredProviderFactory.providerKind)
  #expect(provider?.options["command"]?.stringValue == "gemini")
  #expect(provider?.options["args"]?.arrayValue?.first?.stringValue == "--acp")
  #expect(ACPCatalog.agent("nope") == nil)
}

@Test("pmai's ACP server answers initialize, session/new, and session/prompt")
func acpServerServesARuntime() async throws {
  // A scripted provider stands in for a model; the server should stream its
  // reply as agent_message_chunk and answer session/prompt with a stop reason.
  let provider = ACPScriptedProvider(responses: [
    ProviderResponse(message: .assistant("Hello from pmai"), stopReason: .stop)
  ])
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  let agent = AgentDefinition(
    id: "main", instructions: "Be brief.", provider: "scripted", model: "fixture")
  try await runtime.register(agent: agent)

  let (clientTransport, serverTransport) = PipeTransport.pair()
  let server = ACPServer(runtime: runtime, agent: agent, bridge: ACPPermissionBridge())
  let serving = Task { await server.serve(on: serverTransport) }

  let chunks = ChunkRecorder()
  let client = JSONRPCPeer(
    transport: clientTransport,
    onNotification: { method, params in
      guard method == ACP.Method.sessionUpdate else { return }
      let update = params?.objectValue?["update"]?.objectValue
      if update?["sessionUpdate"]?.stringValue == ACP.Update.agentMessageChunk.rawValue {
        await chunks.append(ACP.ContentBlock.text(from: update?["content"]))
      }
    })
  await client.start()

  let initialize = try await client.request(
    ACP.Method.initialize, params: .object(["protocolVersion": .integer(1)]), timeout: 5)
  #expect(initialize.objectValue?["protocolVersion"]?.intValue == 1)
  #expect(initialize.objectValue?["agentInfo"]?.objectValue?["name"]?.stringValue == "pmai")

  let session = try await client.request(
    ACP.Method.sessionNew, params: .object(["cwd": .string("/tmp")]), timeout: 5)
  let sessionID = try #require(session.objectValue?["sessionId"]?.stringValue)

  let result = try await client.request(
    ACP.Method.sessionPrompt,
    params: .object([
      "sessionId": .string(sessionID),
      "prompt": .array([.object(["type": .string("text"), "text": .string("hi")])]),
    ]),
    timeout: 5)
  #expect(result.objectValue?["stopReason"]?.stringValue == ACP.StopReason.endTurn.rawValue)
  #expect(await chunks.joined == "Hello from pmai")

  await client.close()
  serving.cancel()
}

@Test("pmai's MCP server exposes the agent as one prompt tool")
func mcpServerExposesAgent() async throws {
  let provider = ACPScriptedProvider(responses: [
    ProviderResponse(message: .assistant("42"), stopReason: .stop)
  ])
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  let agent = AgentDefinition(
    id: "oracle", description: "Answers questions.", instructions: "",
    provider: "scripted", model: "fixture")
  try await runtime.register(agent: agent)

  let (clientTransport, serverTransport) = PipeTransport.pair()
  let server = MCPAgentServer(runtime: runtime, agent: agent)
  let serving = Task { await server.serve(on: serverTransport) }
  let client = JSONRPCPeer(transport: clientTransport)
  await client.start()

  _ = try await client.request("initialize", timeout: 5)
  let tools = try await client.request("tools/list", timeout: 5)
  let tool = try #require(tools.objectValue?["tools"]?.arrayValue?.first?.objectValue)
  #expect(tool["name"]?.stringValue == "oracle")
  #expect(tool["description"]?.stringValue == "Answers questions.")

  let call = try await client.request(
    "tools/call",
    params: .object([
      "name": .string("oracle"),
      "arguments": .object(["prompt": .string("what is the answer?")]),
    ]),
    timeout: 5)
  let text = call.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
  #expect(text == "42")

  await client.close()
  serving.cancel()
}

private actor ACPScriptedProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "scripted", displayName: "Scripted", capabilities: [.streaming, .nativeToolCalling])
  private var responses: [ProviderResponse]
  init(responses: [ProviderResponse]) { self.responses = responses }

  func complete(
    _ request: ProviderRequest, emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let response =
      responses.isEmpty ? ProviderResponse(message: .assistant("")) : responses.removeFirst()
    if !response.message.text.isEmpty { await emit(.textDelta(response.message.text)) }
    return response
  }
}

private actor ChunkRecorder {
  private var chunks: [String] = []
  func append(_ chunk: String) { chunks.append(chunk) }
  var joined: String { chunks.joined() }
}
