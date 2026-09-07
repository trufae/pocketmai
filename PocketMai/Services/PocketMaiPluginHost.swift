import Foundation
import MaiCore
import MaiOpenAI
import MaiStandardTools

/// PocketMai's static composition root. iOS cannot load arbitrary unsigned
/// dylibs, so app integrations use the same MaiPlugin API as the CLI while
/// remaining normal, code-signed Swift modules in the application bundle.
actor PocketMaiPluginHost {
  static let shared = PocketMaiPluginHost()

  private let registry = PluginRegistry()
  private var startup: Task<Void, Error>?
  private var standardTools: [String: any AgentTool]?

  private init() {}

  func makeOpenAIProvider(
    endpoint: OpenAIEndpoint,
    requestTimeout: TimeInterval = 600
  ) async throws -> MaiOpenAI.OpenAICompatibleProvider {
    try await prepare()
    guard let baseURL = URL(string: endpoint.baseURL) else {
      throw ChatProviderError.invalidEndpoint(endpoint.baseURL)
    }
    let provider = try await registry.makeProvider(
      from: ConfiguredProvider(
        id: endpoint.id.uuidString,
        kind: .openAICompatible,
        displayName: endpoint.name,
        baseURL: baseURL,
        apiKey: endpoint.apiKey,
        headers: endpoint.effectiveHeaders,
        timeout: requestTimeout),
      environment: [:])
    guard let provider = provider as? MaiOpenAI.OpenAICompatibleProvider else {
      throw ChatProviderError.providerRequestFailed(
        "The OpenAI plugin returned an incompatible provider.")
    }
    return provider
  }

  func makeOCRProvider() async throws -> any OCRProvider {
    try await prepare()
    return try await registry.makeOCRProvider(
      kind: "pocketmai-vision",
      context: PluginFactoryContext(id: "pocketmai-vision"))
  }

  func installedPlugins() async throws -> [InstalledPlugin] {
    try await prepare()
    return await registry.installedPlugins()
  }

  func callStandardTool(
    name: String,
    arguments: [String: JSONValue]
  ) async -> String {
    do {
      try await prepare()
      if standardTools == nil {
        let tools = try await registry.makeTools(
          kind: MaiStandardToolsPlugin.factoryKind,
          context: PluginFactoryContext(id: "pocketmai-standard-tools"))
        standardTools = Dictionary(
          tools.map { ($0.definition.name, $0) },
          uniquingKeysWith: { first, _ in first })
      }
      guard let tool = standardTools?[name] else {
        return "Error: standard tool '\(name)' is not registered."
      }
      return await call(tool: tool, arguments: arguments)
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  func call(
    tool: any AgentTool,
    arguments: [String: JSONValue]
  ) async -> String {
    do {
      let context = ToolExecutionContext(
        run: AgentEventContext(
          runID: UUID(), parentRunID: nil, agentID: "pocketmai", depth: 0),
        modelTurn: 0)
      return try await tool.call(arguments: .object(arguments), context: context).text
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  private func prepare() async throws {
    if let startup {
      return try await startup.value
    }
    let registry = registry
    let task = Task {
      try await registry.install(MaiOpenAIPlugin(), origin: "PocketMai")
      try await registry.install(MaiStandardToolsPlugin(), origin: "PocketMai")
      try await registry.install(PocketMaiPlatformPlugin(), origin: "PocketMai")
    }
    startup = task
    do {
      try await task.value
    } catch {
      startup = nil
      throw error
    }
  }
}

private struct PocketMaiPlatformPlugin: MaiPlugin {
  let manifest = PluginManifest(
    id: "org.mai.pocketmai-platform",
    displayName: "PocketMai platform integrations",
    version: "1.0.0",
    capabilities: [.ocrProvider])

  func register(in registry: PluginRegistry) async throws {
    try await registry.register(
      ocrFactory: PocketMaiOCRFactory(),
      from: manifest.id)
  }
}

private struct PocketMaiOCRFactory: ConfiguredOCRProviderFactory {
  let kind = "pocketmai-vision"

  func makeOCRProvider(context: PluginFactoryContext) throws -> any OCRProvider {
    PocketMaiOCRProvider()
  }
}
