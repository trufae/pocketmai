import Foundation
import Testing

@testable import MaiCore
@testable import MaiOpenAI

// `/effort` sets one level for every provider. The level becomes the fields
// each API family takes and a system prompt section, so a model with no
// reasoning control still hears how much care the task deserves.

@Test("Levels parse from the names people type and map to each API family's fields")
func effortMapsToProviderFields() {
  #expect(ReasoningEffort.names == ["low", "medium", "high", "xhigh", "max"])
  #expect(ReasoningEffort(name: "X-High") == .xhigh)
  #expect(ReasoningEffort(name: "maximum") == .max)
  #expect(ReasoningEffort(name: "h") == .high)
  #expect(ReasoningEffort(name: "minimal") == nil)

  let openAI = "https://api.openai.com/v1"
  #expect(
    ReasoningEffort.high.requestFields(model: "gpt-5", baseURL: openAI)
      == ["reasoning_effort": .string("high")])
  #expect(
    ReasoningEffort.max.requestFields(model: "gpt-5", baseURL: openAI)
      == ["reasoning_effort": .string("high")])
  #expect(
    ReasoningEffort.xhigh.requestFields(model: "gpt-5.2", baseURL: openAI)
      == ["reasoning_effort": .string("xhigh")])
  #expect(
    ReasoningEffort.max.requestFields(model: "gpt-5.1-codex-max", baseURL: openAI)
      == ["reasoning_effort": .string("xhigh")])
  #expect(ReasoningEffort.high.requestFields(model: "gpt-4o", baseURL: openAI).isEmpty)
  #expect(
    ReasoningEffort.low.requestFields(model: "o3-mini", baseURL: openAI)
      == ["reasoning_effort": .string("low")])

  #expect(
    ReasoningEffort.max.requestFields(model: "gpt-oss:20b", baseURL: "http://localhost:11434/v1")
      == ["think": .string("high"), "reasoning_effort": .string("high")])
  let qwenOnOllama = ReasoningEffort.low.requestFields(
    model: "qwen3:8b", provider: "ollama Thor", baseURL: "http://thor/v1")
  #expect(qwenOnOllama["think"] == .bool(true))
  #expect(qwenOnOllama["reasoning_effort"] == .string("low"))
  #expect(qwenOnOllama["chat_template_kwargs"] == .object(["enable_thinking": .bool(true)]))

  let dashscope = ReasoningEffort.medium.requestFields(
    model: "qwen3-max", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1")
  #expect(dashscope["enable_thinking"] == .bool(true))
  #expect(dashscope["thinking_budget"] == .integer(4096))

  let deepSeek = ReasoningEffort.high.requestFields(
    model: "deepseek-reasoner", baseURL: "https://api.deepseek.com/v1")
  #expect(deepSeek["thinking"] == .object(["type": .string("enabled")]))
  #expect(deepSeek["reasoning_effort"] == .string("high"))

  #expect(
    ReasoningEffort.xhigh.requestFields(
      model: "anthropic/claude", baseURL: "https://openrouter.ai/api/v1")["reasoning"]
      == .object([
        "effort": .string("xhigh"), "enabled": .bool(true), "exclude": .bool(false),
      ]))
  #expect(
    ReasoningEffort.xhigh.requestFields(model: "mistral", baseURL: "https://example.com/v1")
      == ["reasoning_effort": .string("high")])
}

@Test("The prompt section names the level, carries the guidance, and is absent when neither is set")
func effortPromptSection() {
  let section = ReasoningEffort.promptSection(effort: .max, guidance: "Check every edge case.")
  #expect(section?.hasPrefix("Reasoning effort: maximum. Take all the reasoning") == true)
  #expect(section?.hasSuffix("\n\nCheck every edge case.") == true)
  #expect(ReasoningEffort.promptSection(effort: nil, guidance: " ") == nil)
  #expect(
    ReasoningEffort.promptSection(
      for: GenerationOptions(reasoningEffort: "minimal", reasoningGuidance: "Be terse."))
      == "Be terse.")
  #expect(
    ReasoningEffort.promptSection(for: GenerationOptions(reasoningEffort: "low"))?
      .hasPrefix("Reasoning effort: low.") == true)
}

@Test("The OpenAI-compatible request carries the family's fields, and explicit extras win")
func openAIRequestCarriesEffort() throws {
  let provider = OpenAICompatibleProvider(
    configuration: .init(
      id: "thor", displayName: "Ollama on Thor", baseURL: URL(string: "http://thor:11434/v1")!))
  let mapped = try provider.makeURLRequest(
    ProviderRequest(
      model: "gpt-oss:20b", messages: [.user("hi")],
      options: GenerationOptions(reasoningEffort: "max"), stream: false),
    model: "gpt-oss:20b")
  let body = try JSONDecoder().decode(JSONValue.self, from: try #require(mapped.httpBody))
  #expect(body.objectValue?["think"] == .string("high"))
  #expect(body.objectValue?["reasoning_effort"] == .string("high"))

  let explicit = try provider.makeURLRequest(
    ProviderRequest(
      model: "gpt-oss:20b", messages: [.user("hi")],
      options: GenerationOptions(reasoningEffort: "max", additional: ["think": .string("low")]),
      stream: false),
    model: "gpt-oss:20b")
  let explicitBody = try JSONDecoder().decode(JSONValue.self, from: try #require(explicit.httpBody))
  #expect(explicitBody.objectValue?["think"] == .string("low"))

  let raw = try provider.makeURLRequest(
    ProviderRequest(
      model: "gpt-oss:20b", messages: [.user("hi")],
      options: GenerationOptions(reasoningEffort: "minimal"), stream: false),
    model: "gpt-oss:20b")
  let rawBody = try JSONDecoder().decode(JSONValue.self, from: try #require(raw.httpBody))
  #expect(rawBody.objectValue?["reasoning_effort"] == .string("minimal"))
  #expect(rawBody.objectValue?["think"] == nil)
}

@Test("A run at an effort level tells the model in the system prompt, after the instructions")
func runtimeInsertsEffortSection() async throws {
  let provider = EffortScriptedProvider()
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  let result = try await runtime.run(
    AgentRequest(
      provider: "effort-scripted",
      model: "fixture",
      messages: [.system("Be brief."), .user("Hi")],
      options: GenerationOptions(reasoningEffort: "high", reasoningGuidance: "Mind the edge cases.")
    )
  ) { _ in }
  #expect(result.response.text == "Hello.")
  let sent = try #require(await provider.requests.first)
  let systems = sent.messages.filter { $0.role == .system }.map(\.text)
  #expect(systems.first == "Be brief.")
  #expect(
    systems.contains {
      $0.hasPrefix("Reasoning effort: high.") && $0.hasSuffix("Mind the edge cases.")
    })
  #expect(sent.messages.last?.text == "Hi")
  #expect(sent.options.reasoningEffort == "high")
}

private actor EffortScriptedProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "effort-scripted", displayName: "Effort scripted", capabilities: [.streaming])
  private(set) var requests: [ProviderRequest] = []

  func complete(_ request: ProviderRequest, emit: @escaping ProviderEventHandler) async throws
    -> ProviderResponse
  {
    requests.append(request)
    return ProviderResponse(message: .assistant("Hello."), stopReason: .stop)
  }
}
