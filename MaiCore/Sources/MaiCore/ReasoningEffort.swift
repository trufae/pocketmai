import Foundation

/// How hard a model is asked to think before it answers, as `/set effort` sets
/// it. One level serves every provider: `requestFields` turns it into the
/// fields each API family understands (`reasoning_effort` for OpenAI, `think`
/// for Ollama, `enable_thinking` for Qwen, `thinking` for DeepSeek, the
/// `reasoning` object for OpenRouter), and `promptSection` into guidance for
/// the system prompt, so a model with no reasoning control of its own still
/// hears how much care the task deserves.
public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
  case low
  case medium
  case high
  case xhigh
  case max

  /// The names a command completes to, from the least effort to the most.
  public static let names = allCases.map(\.rawValue)

  /// The level for a name as people type it: the raw names, `x-high`,
  /// `extra-high`, `maximum`, and the first letters.
  public init?(name: String) {
    let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: "_", with: "")
    switch key {
    case "low", "l": self = .low
    case "medium", "med", "m": self = .medium
    case "high", "h": self = .high
    case "xhigh", "extrahigh", "veryhigh", "xh": self = .xhigh
    case "max", "maximum", "ultra": self = .max
    default: return nil
    }
  }

  public var displayName: String {
    switch self {
    case .low: "low"
    case .medium: "medium"
    case .high: "high"
    case .xhigh: "very high"
    case .max: "maximum"
    }
  }

  /// What the system prompt asks for at this level.
  public var guidance: String {
    switch self {
    case .low:
      "Answer directly and briefly. Do not deliberate over alternatives or edge cases unless the task is ambiguous or a mistake would be costly."
    case .medium:
      "Think briefly before answering: plan the steps, check the main assumptions, and keep the reasoning proportionate to the task."
    case .high:
      "Think the problem through before answering: consider the alternatives, work through the tricky cases and the edge cases, and verify the result before presenting it."
    case .xhigh:
      "Reason thoroughly before answering: explore the alternatives, question your assumptions, work through every edge case, and double-check each conclusion. Thoroughness matters more than speed."
    case .max:
      "Take all the reasoning the task needs: examine every alternative, test each assumption, verify each step and the final result, and revisit earlier conclusions when something does not fit. Correctness matters more than speed or brevity."
    }
  }

  // MARK: - System prompt

  /// The system prompt section for a level and the extra guidance a person
  /// set with it; nil when there is neither.
  public static func promptSection(effort: ReasoningEffort?, guidance: String?) -> String? {
    let extra = guidance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard effort != nil || !extra.isEmpty else { return nil }
    var parts: [String] = []
    if let effort {
      parts.append("Reasoning effort: \(effort.displayName). \(effort.guidance)")
    }
    if !extra.isEmpty { parts.append(extra) }
    return parts.joined(separator: "\n\n")
  }

  /// The section for a request's options: the level `reasoningEffort` names
  /// when it is one of ours (a provider's own value, such as `minimal`, adds
  /// no section) and `reasoningGuidance`.
  public static func promptSection(for options: GenerationOptions) -> String? {
    promptSection(
      effort: options.reasoningEffort.flatMap(ReasoningEffort.init(name:)),
      guidance: options.reasoningGuidance)
  }

  // MARK: - Provider request fields

  /// The API family an endpoint belongs to, told from the model name, the
  /// provider's id and name, and its base URL.
  public enum APIFamily: Equatable, Sendable {
    case openAI
    case openRouter
    case deepSeek
    case qwen
    case ollama
    case generic

    public static func detect(model: String, provider: String = "", baseURL: String = "")
      -> APIFamily
    {
      let text = "\(model) \(provider) \(baseURL)".lowercased()
      if text.contains("openrouter.ai") { return .openRouter }
      if text.contains("ollama") || text.contains(":11434") { return .ollama }
      if text.contains("dashscope") || text.contains("aliyuncs") || text.contains("qwen") {
        return .qwen
      }
      if text.contains("deepseek") { return .deepSeek }
      if text.contains("api.openai.com") || text.contains("openai.azure.com") { return .openAI }
      return .generic
    }
  }

  /// The request body fields that ask an endpoint for this level, detected
  /// from the model, provider, and base URL. A caller merges them under its
  /// own explicit fields, so a configured `additional` value always wins.
  public func requestFields(model: String, provider: String = "", baseURL: String = "")
    -> [String: JSONValue]
  {
    requestFields(
      family: .detect(model: model, provider: provider, baseURL: baseURL), model: model)
  }

  public func requestFields(family: APIFamily, model: String) -> [String: JSONValue] {
    switch family {
    case .openRouter:
      return [
        "reasoning": .object([
          "effort": .string(effortName(allowingXHigh: true)),
          "enabled": .bool(true),
          "exclude": .bool(false),
        ])
      ]
    case .deepSeek:
      return [
        "thinking": .object(["type": .string("enabled")]),
        "reasoning_effort": .string(effortName(allowingXHigh: false)),
      ]
    case .qwen:
      return [
        "enable_thinking": .bool(true),
        "thinking_budget": .integer(thinkingBudget),
        "chat_template_kwargs": .object(["enable_thinking": .bool(true)]),
      ]
    case .ollama:
      let effort = effortName(allowingXHigh: false)
      if model.lowercased().contains("gpt-oss") {
        return ["think": .string(effort), "reasoning_effort": .string(effort)]
      }
      return [
        "think": .bool(true),
        "reasoning_effort": .string(effort),
        "chat_template_kwargs": .object(["enable_thinking": .bool(true)]),
      ]
    case .openAI:
      guard Self.isOpenAIReasoningModel(model) else { return [:] }
      return [
        "reasoning_effort": .string(effortName(allowingXHigh: Self.supportsOpenAIXHigh(model)))
      ]
    case .generic:
      return ["reasoning_effort": .string(effortName(allowingXHigh: false))]
    }
  }

  /// The `reasoning_effort` value: `low`, `medium`, `high`, and `xhigh` where
  /// the endpoint knows it; `max` is the most an endpoint offers.
  public func effortName(allowingXHigh: Bool) -> String {
    switch self {
    case .low: "low"
    case .medium: "medium"
    case .high: "high"
    case .xhigh, .max: allowingXHigh ? "xhigh" : "high"
    }
  }

  /// Qwen's `thinking_budget`, in tokens.
  public var thinkingBudget: Int {
    switch self {
    case .low: 1024
    case .medium: 4096
    case .high: 8192
    case .xhigh: 32768
    case .max: 65536
    }
  }

  /// OpenAI rejects `reasoning_effort` on models without reasoning, so it is
  /// only sent to the ones known to have it: gpt-5 and later, and the o-series.
  static func isOpenAIReasoningModel(_ model: String) -> Bool {
    let text = model.lowercased()
    if text.hasPrefix("gpt-"), let generation = text.dropFirst(4).first?.wholeNumberValue {
      return generation >= 5
    }
    if text.count >= 2, text.first == "o", text.dropFirst().first?.isNumber == true {
      return true
    }
    return false
  }

  /// `xhigh` arrived with gpt-5.1-codex-max and is accepted from gpt-5.2 on.
  static func supportsOpenAIXHigh(_ model: String) -> Bool {
    let text = model.lowercased()
    if text.contains("codex-max") { return true }
    guard text.hasPrefix("gpt-") else { return false }
    let version = text.dropFirst(4).prefix { $0.isNumber || $0 == "." }
    let parts = version.split(separator: ".").compactMap { Int($0) }
    guard let major = parts.first else { return false }
    if major > 5 { return true }
    return major == 5 && (parts.count > 1 ? parts[1] : 0) >= 2
  }
}
