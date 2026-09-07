import Foundation

// MARK: - Timing

/// Wall-clock observations collected while one streamed provider call is read.
/// Chunk timestamps are recorded so the timing resolver can tell a genuinely
/// paced stream apart from a whole response delivered in one network burst.
public struct StreamTimingObservation: Equatable, Sendable {
  public var requestStart: Date
  public var firstTokenAt: Date?
  public var lastTokenAt: Date?
  public var tokenChunkCount: Int

  public init(
    requestStart: Date = Date(),
    firstTokenAt: Date? = nil,
    lastTokenAt: Date? = nil,
    tokenChunkCount: Int = 0
  ) {
    self.requestStart = requestStart
    self.firstTokenAt = firstTokenAt
    self.lastTokenAt = lastTokenAt
    self.tokenChunkCount = tokenChunkCount
  }

  public mutating func noteTokenChunk(at date: Date = Date()) {
    if firstTokenAt == nil { firstTokenAt = date }
    lastTokenAt = date
    tokenChunkCount += 1
  }
}

/// Timing split derived from a `StreamTimingObservation` once a call finishes.
public struct ResolvedGenerationTiming: Equatable, Sendable {
  public var promptSeconds: TimeInterval
  public var generationSeconds: TimeInterval
  /// Seconds from sending the request until the first streamed token arrived.
  /// Nil when the response was not streamed.
  public var firstTokenSeconds: TimeInterval?

  public init(
    promptSeconds: TimeInterval,
    generationSeconds: TimeInterval,
    firstTokenSeconds: TimeInterval?
  ) {
    self.promptSeconds = promptSeconds
    self.generationSeconds = generationSeconds
    self.firstTokenSeconds = firstTokenSeconds
  }
}

/// Collects `StreamTimingObservation` from a provider's event callback, which
/// may run on any executor, so the observation can be read once the call ends.
public final class StreamTimingRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: StreamTimingObservation

  public init(requestStart: Date = Date()) {
    stored = StreamTimingObservation(requestStart: requestStart)
  }

  public func noteTokenChunk(at date: Date = Date()) {
    lock.withLock { stored.noteTokenChunk(at: date) }
  }

  /// Counts every event that carries generated content; usage payloads are
  /// bookkeeping the model did not generate and never move the window.
  public func note(_ event: ProviderEvent, at date: Date = Date()) {
    switch event {
    case .textDelta, .reasoningDelta, .toolCallDelta: noteTokenChunk(at: date)
    case .usage: break
    }
  }

  public var observation: StreamTimingObservation {
    lock.withLock { stored }
  }

  public func resolve(end: Date = Date()) -> ResolvedGenerationTiming {
    ModelCallStats.resolveTiming(observation, end: end)
  }
}

// MARK: - One call

/// Metrics for one or more model calls behind an assistant message. Token counts
/// come from provider usage payloads (OpenAI-compatible `usage`, MLX completion
/// info); `tokensEstimated` marks backends that only expose text, where counts
/// are derived from character length (~4 chars/token). The property names are
/// the persisted JSON keys, shared by every host that stores these.
public struct ModelCallStats: Codable, Equatable, Sendable {
  public var providerLabel: String
  public var modelID: String
  public var inputTokens: Int
  /// Estimated tokens in the user-authored message(s) for this turn only.
  public var userInputTokens: Int?
  /// Provider completion total, including hidden reasoning when reported that way.
  public var outputTokens: Int
  /// Estimated tokens in response text actually received, excluding hidden reasoning.
  public var receivedTextTokens: Int?
  /// Provider-reported hidden reasoning tokens, when the backend exposes them.
  public var reasoningTokens: Int?
  /// Number of image inputs actually sent to a vision-capable provider.
  public var imageInputs: Int?
  public var cachedTokens: Int
  /// Prompt processing (local inference) or time to first streamed token
  /// (network providers). Zero when the response arrived as one burst and the
  /// split is unknowable.
  public var promptSeconds: TimeInterval
  public var generationSeconds: TimeInterval
  /// Seconds until the provider emitted the first token of the response. Nil for
  /// non-streaming calls, where no first-token signal exists.
  public var firstTokenSeconds: TimeInterval?
  public var tokensEstimated: Bool
  public var callCount: Int

  public init(
    providerLabel: String,
    modelID: String,
    inputTokens: Int = 0,
    userInputTokens: Int? = nil,
    outputTokens: Int = 0,
    receivedTextTokens: Int? = nil,
    reasoningTokens: Int? = nil,
    imageInputs: Int? = nil,
    cachedTokens: Int = 0,
    promptSeconds: TimeInterval = 0,
    generationSeconds: TimeInterval = 0,
    firstTokenSeconds: TimeInterval? = nil,
    tokensEstimated: Bool = false,
    callCount: Int = 1
  ) {
    self.providerLabel = providerLabel
    self.modelID = modelID
    self.inputTokens = inputTokens
    self.userInputTokens = userInputTokens
    self.outputTokens = outputTokens
    self.receivedTextTokens = receivedTextTokens
    self.reasoningTokens = reasoningTokens
    self.imageInputs = imageInputs
    self.cachedTokens = cachedTokens
    self.promptSeconds = promptSeconds
    self.generationSeconds = generationSeconds
    self.firstTokenSeconds = firstTokenSeconds
    self.tokensEstimated = tokensEstimated
    self.callCount = callCount
  }

  /// Completion tokens that correspond to the generated response text. Provider
  /// completion totals include hidden reasoning tokens on reasoning models.
  public var visibleOutputTokens: Int {
    max(0, outputTokens - (reasoningTokens ?? 0))
  }

  public var tokensPerSecond: Double? {
    guard visibleOutputTokens > 0, generationSeconds > 0 else { return nil }
    return Double(visibleOutputTokens) / generationSeconds
  }

  public var promptTokensPerSecond: Double? {
    guard inputTokens > 0, promptSeconds > 0, !tokensEstimated else { return nil }
    return Double(inputTokens) / promptSeconds
  }

  /// Seconds the model was busy with this call: waiting for the first token
  /// plus streaming the rest.
  public var totalSeconds: TimeInterval { promptSeconds + generationSeconds }

  /// What a message footer says about the call(s) behind it:
  /// `42.1 tok/s · first tok 0.85s · ~1.2k in · 300 cached · ~450 out · 3 calls`.
  public var summary: String {
    var parts: [String] = []
    if let tokensPerSecond { parts.append(ModelUsageFormat.speed(tokensPerSecond)) }
    if let firstTokenSeconds {
      parts.append("first tok \(ModelUsageFormat.seconds(firstTokenSeconds))")
    }
    let approx = tokensEstimated ? "~" : ""
    parts.append("\(approx)\(ModelUsageFormat.count(inputTokens)) in")
    if cachedTokens > 0 { parts.append("\(ModelUsageFormat.count(cachedTokens)) cached") }
    parts.append("\(approx)\(ModelUsageFormat.count(outputTokens)) out")
    if callCount > 1 { parts.append("\(callCount) calls") }
    return parts.joined(separator: " · ")
  }

  /// A stream whose first→last token window is shorter than this never showed
  /// the client any real generation pacing, so the window cannot be a divisor.
  public static let minimumStreamedGenerationSeconds: TimeInterval = 0.2
  /// Below this many observed chunks the whole response arrived in a burst or
  /// two, so first→last chunk timing says nothing about generation speed.
  public static let minimumStreamedTokenChunks = 3

  /// Splits one call's wall time into prompt wait and generation time. Speed is
  /// measured over the first→last received token window, so cold starts and the
  /// trailing usage/[DONE] wait never pollute tok/s. When the body arrived as a
  /// burst (buffered delivery is common on localhost endpoints) that window is
  /// near zero and dividing by it explodes tok/s, so total wall time — an
  /// honest lower bound — is used instead, matching non-streaming calls.
  public static func resolveTiming(
    _ observation: StreamTimingObservation,
    end: Date
  ) -> ResolvedGenerationTiming {
    let totalSeconds = max(0, end.timeIntervalSince(observation.requestStart))
    guard let firstTokenAt = observation.firstTokenAt else {
      return ResolvedGenerationTiming(
        promptSeconds: 0, generationSeconds: totalSeconds, firstTokenSeconds: nil)
    }
    let firstTokenSeconds = max(0, firstTokenAt.timeIntervalSince(observation.requestStart))
    let lastTokenAt = observation.lastTokenAt ?? end
    let streamedSeconds = max(0, lastTokenAt.timeIntervalSince(firstTokenAt))
    guard
      streamedSeconds >= minimumStreamedGenerationSeconds,
      observation.tokenChunkCount >= minimumStreamedTokenChunks
    else {
      return ResolvedGenerationTiming(
        promptSeconds: 0, generationSeconds: totalSeconds, firstTokenSeconds: firstTokenSeconds)
    }
    return ResolvedGenerationTiming(
      promptSeconds: firstTokenSeconds,
      generationSeconds: streamedSeconds,
      firstTokenSeconds: firstTokenSeconds)
  }

  public mutating func merge(_ other: ModelCallStats) {
    providerLabel = other.providerLabel
    modelID = other.modelID
    inputTokens += other.inputTokens
    if let userInputTokens = other.userInputTokens {
      self.userInputTokens = (self.userInputTokens ?? 0) + userInputTokens
    }
    outputTokens += other.outputTokens
    if let receivedTextTokens = other.receivedTextTokens {
      self.receivedTextTokens = (self.receivedTextTokens ?? 0) + receivedTextTokens
    }
    if let reasoningTokens = other.reasoningTokens {
      self.reasoningTokens = (self.reasoningTokens ?? 0) + reasoningTokens
    }
    if let imageInputs = other.imageInputs {
      self.imageInputs = (self.imageInputs ?? 0) + imageInputs
    }
    cachedTokens += other.cachedTokens
    promptSeconds += other.promptSeconds
    generationSeconds += other.generationSeconds
    // The first round's latency is the one the user felt waiting for output.
    firstTokenSeconds = firstTokenSeconds ?? other.firstTokenSeconds
    tokensEstimated = tokensEstimated || other.tokensEstimated
    callCount += other.callCount
  }

  public static func estimatedTokenCount(forCharacterCount count: Int) -> Int {
    count <= 0 ? 0 : max(1, count / 4)
  }

  /// Estimated tokens of the text carried by a set of messages.
  public static func estimatedTokenCount(of messages: [AgentMessage]) -> Int {
    estimatedTokenCount(forCharacterCount: messages.reduce(0) { $0 + $1.text.count })
  }

  /// The stats of one provider call the runtime just completed. Counts come
  /// from the response's usage when the provider reported any, and are
  /// estimated from text length otherwise.
  public static func measured(
    providerLabel: String,
    modelID: String,
    messages: [AgentMessage],
    response: ProviderResponse,
    timing: StreamTimingObservation,
    end: Date = Date(),
    userInputTokens: Int? = nil
  ) -> ModelCallStats {
    let images = messages.reduce(0) { total, message in
      total
        + message.content.filter {
          if case .image = $0 { return true }
          return false
        }.count
    }
    return measured(
      providerLabel: providerLabel,
      modelID: modelID,
      usage: response.usage,
      estimatedInputTokens: estimatedTokenCount(of: messages),
      outputCharacterCount: response.message.text.count,
      timing: timing,
      end: end,
      userInputTokens: userInputTokens,
      imageInputs: images > 0 ? images : nil)
  }

  /// The stats of one call from what every host has at hand once a call
  /// ends: the provider's usage payload (nil when it reported none), the
  /// input estimate to fall back on, the length of the text received, and
  /// the stream timing. PocketMai's providers and the runtime both go
  /// through here, so a call is measured the same way on every host.
  public static func measured(
    providerLabel: String,
    modelID: String,
    usage: TokenUsage?,
    estimatedInputTokens: Int,
    outputCharacterCount: Int,
    timing: StreamTimingObservation,
    end: Date = Date(),
    userInputTokens: Int? = nil,
    imageInputs: Int? = nil
  ) -> ModelCallStats {
    let resolved = resolveTiming(timing, end: end)
    let receivedTextTokens = estimatedTokenCount(forCharacterCount: outputCharacterCount)
    return ModelCallStats(
      providerLabel: providerLabel,
      modelID: modelID,
      inputTokens: usage?.inputTokens ?? estimatedInputTokens,
      userInputTokens: userInputTokens,
      outputTokens: usage?.outputTokens ?? receivedTextTokens,
      receivedTextTokens: receivedTextTokens,
      reasoningTokens: usage?.reasoningTokens,
      imageInputs: imageInputs,
      cachedTokens: usage?.cachedTokens ?? 0,
      promptSeconds: resolved.promptSeconds,
      generationSeconds: resolved.generationSeconds,
      firstTokenSeconds: resolved.firstTokenSeconds,
      tokensEstimated: usage?.isEstimated ?? true)
  }
}

// MARK: - Lifetime totals

/// Running totals for one provider/model pair across every call a host made.
/// Average speed is visible output tokens divided by total generation seconds,
/// so hidden reasoning does not inflate it. The property names are the
/// persisted JSON keys.
public struct ModelUsageTotals: Codable, Identifiable, Equatable, Sendable {
  public var providerLabel: String
  public var modelID: String
  public var inputTokens: Int
  /// Estimated tokens in user-authored messages, excluding resent context.
  public var userInputTokens: Int?
  public var outputTokens: Int
  /// Estimated tokens in response text received, excluding hidden reasoning.
  public var receivedTextTokens: Int?
  /// Provider-reported reasoning tokens. Nil means this provider has not exposed them.
  public var reasoningTokens: Int?
  /// Number of images actually included in vision-capable provider requests.
  public var imageInputs: Int?
  public var cachedTokens: Int
  public var promptSeconds: TimeInterval
  public var generationSeconds: TimeInterval
  public var callCount: Int
  public var estimatedCallCount: Int
  /// Speed of the most recent call, over visible output tokens.
  public var lastOutputTokensPerSecond: Double?
  /// Most recent time-to-first-token. Optional so totals persisted before the
  /// field existed still decode.
  public var lastFirstTokenSeconds: TimeInterval?
  /// Sum and count of observed first-token latencies, for the average.
  public var firstTokenSecondsTotal: TimeInterval?
  public var firstTokenSampleCount: Int?
  public var lastUsedAt: Date

  public init(
    providerLabel: String,
    modelID: String,
    inputTokens: Int = 0,
    userInputTokens: Int? = nil,
    outputTokens: Int = 0,
    receivedTextTokens: Int? = nil,
    reasoningTokens: Int? = nil,
    imageInputs: Int? = nil,
    cachedTokens: Int = 0,
    promptSeconds: TimeInterval = 0,
    generationSeconds: TimeInterval = 0,
    callCount: Int = 0,
    estimatedCallCount: Int = 0,
    lastOutputTokensPerSecond: Double? = nil,
    lastFirstTokenSeconds: TimeInterval? = nil,
    firstTokenSecondsTotal: TimeInterval? = nil,
    firstTokenSampleCount: Int? = nil,
    lastUsedAt: Date = .distantPast
  ) {
    self.providerLabel = providerLabel
    self.modelID = modelID
    self.inputTokens = inputTokens
    self.userInputTokens = userInputTokens
    self.outputTokens = outputTokens
    self.receivedTextTokens = receivedTextTokens
    self.reasoningTokens = reasoningTokens
    self.imageInputs = imageInputs
    self.cachedTokens = cachedTokens
    self.promptSeconds = promptSeconds
    self.generationSeconds = generationSeconds
    self.callCount = callCount
    self.estimatedCallCount = estimatedCallCount
    self.lastOutputTokensPerSecond = lastOutputTokensPerSecond
    self.lastFirstTokenSeconds = lastFirstTokenSeconds
    self.firstTokenSecondsTotal = firstTokenSecondsTotal
    self.firstTokenSampleCount = firstTokenSampleCount
    self.lastUsedAt = lastUsedAt
  }

  public static func id(providerLabel: String, modelID: String) -> String {
    "\(providerLabel)|\(modelID)"
  }

  public var id: String { Self.id(providerLabel: providerLabel, modelID: modelID) }

  /// `provider — model`, or just the provider when the model adds nothing.
  public var title: String {
    modelID.isEmpty || modelID == providerLabel
      ? providerLabel
      : "\(providerLabel) — \(modelID)"
  }

  public var visibleOutputTokens: Int {
    max(0, outputTokens - (reasoningTokens ?? 0))
  }

  public var totalTokens: Int { inputTokens + outputTokens }

  /// Seconds this model has been busy answering: prompt waits plus generation.
  public var totalSeconds: TimeInterval { promptSeconds + generationSeconds }

  public var averageTokensPerSecond: Double? {
    guard visibleOutputTokens > 0, generationSeconds > 0 else { return nil }
    return Double(visibleOutputTokens) / generationSeconds
  }

  public var averagePromptTokensPerSecond: Double? {
    guard inputTokens > 0, promptSeconds > 0, estimatedCallCount == 0 else { return nil }
    return Double(inputTokens) / promptSeconds
  }

  public var averageFirstTokenSeconds: TimeInterval? {
    guard let total = firstTokenSecondsTotal, let count = firstTokenSampleCount, count > 0
    else { return nil }
    return total / Double(count)
  }

  /// The efficiency score `totalTokens / (totalSeconds × callCount)`: how many
  /// tokens each request moved per second the model was in use. Nil until the
  /// model has both moved tokens and spent time.
  public var efficiency: Double? {
    Self.efficiency(tokens: totalTokens, seconds: totalSeconds, requests: callCount)
  }

  public static func efficiency(tokens: Int, seconds: TimeInterval, requests: Int) -> Double? {
    guard tokens > 0, seconds > 0, requests > 0 else { return nil }
    return Double(tokens) / (seconds * Double(requests))
  }

  /// The number behind one ranking metric, nil when the row cannot show it.
  public func value(_ metric: ModelUsageReport.Metric) -> Double? {
    switch metric {
    case .speed: averageTokensPerSecond
    case .time: Optional(totalSeconds)
    case .efficiency: efficiency
    }
  }

  /// One line under the model's name with the facts the rankings leave out:
  /// `~1.2k sent · ~3.4k recv · 45 req · 12m34s in use · prompt 800.0 tok/s · first tok 0.85s`.
  public var summary: String {
    var parts: [String] = []
    if let userInputTokens, userInputTokens > 0 {
      parts.append("~\(ModelUsageFormat.count(userInputTokens)) sent")
    }
    if let receivedTextTokens, receivedTextTokens > 0 {
      parts.append("~\(ModelUsageFormat.count(receivedTextTokens)) recv")
    }
    if let reasoningTokens, reasoningTokens > 0 {
      parts.append("\(ModelUsageFormat.count(reasoningTokens)) thinking")
    }
    if let imageInputs, imageInputs > 0 {
      parts.append("\(imageInputs) image\(imageInputs == 1 ? "" : "s")")
    }
    if cachedTokens > 0 { parts.append("\(ModelUsageFormat.count(cachedTokens)) cached") }
    parts.append("\(callCount) req")
    if totalSeconds > 0 { parts.append("\(ModelUsageFormat.duration(totalSeconds)) in use") }
    if let averagePromptTokensPerSecond {
      parts.append("prompt \(ModelUsageFormat.speed(averagePromptTokensPerSecond))")
    }
    if let averageFirstTokenSeconds {
      parts.append("first tok \(ModelUsageFormat.seconds(averageFirstTokenSeconds))")
    }
    return parts.joined(separator: " · ")
  }

  /// Everything recorded about the row, one fact per line, for a detail
  /// sheet or `/stats show PROVIDER:MODEL`.
  public var detailLines: [String] {
    let estimated = estimatedCallCount > 0
    var lines: [String] = []
    if let userInputTokens, userInputTokens > 0 {
      lines.append("Text sent: \(ModelUsageFormat.tokens(userInputTokens, estimated: true))")
    }
    if let receivedTextTokens, receivedTextTokens > 0 {
      lines.append("Text received: \(ModelUsageFormat.tokens(receivedTextTokens, estimated: true))")
    }
    lines.append("Prompt tokens: \(ModelUsageFormat.tokens(inputTokens, estimated: estimated))")
    lines.append("Completion tokens: \(ModelUsageFormat.tokens(outputTokens, estimated: estimated))")
    if let reasoningTokens, reasoningTokens > 0 {
      lines.append("Thinking tokens: \(ModelUsageFormat.tokens(reasoningTokens))")
    }
    if let imageInputs, imageInputs > 0 { lines.append("Images sent: \(imageInputs)") }
    if cachedTokens > 0 { lines.append("Cached tokens: \(ModelUsageFormat.tokens(cachedTokens))") }
    lines.append("Requests: \(callCount)")
    if estimated { lines.append("Estimated counts: \(estimatedCallCount) req") }
    if let averageTokensPerSecond {
      lines.append("Average output speed: \(ModelUsageFormat.speed(averageTokensPerSecond))")
    }
    if let lastOutputTokensPerSecond {
      lines.append("Last output speed: \(ModelUsageFormat.speed(lastOutputTokensPerSecond))")
    }
    if let averagePromptTokensPerSecond {
      lines.append(
        "Prompt processing speed: \(ModelUsageFormat.speed(averagePromptTokensPerSecond))")
    }
    if let lastFirstTokenSeconds {
      lines.append("Last time to first token: \(ModelUsageFormat.seconds(lastFirstTokenSeconds))")
    }
    if let averageFirstTokenSeconds {
      lines.append(
        "Average time to first token: \(ModelUsageFormat.seconds(averageFirstTokenSeconds))")
    }
    if generationSeconds > 0 {
      lines.append("Generation time: \(ModelUsageFormat.duration(generationSeconds))")
    }
    if totalSeconds > 0 { lines.append("Time in use: \(ModelUsageFormat.duration(totalSeconds))") }
    if let efficiency { lines.append("Efficiency: \(ModelUsageFormat.efficiency(efficiency))") }
    if lastUsedAt > .distantPast {
      lines.append("Last used: \(lastUsedAt.formatted(date: .abbreviated, time: .shortened))")
    }
    return lines
  }

  /// Folds one completed call into the totals.
  public mutating func record(_ stats: ModelCallStats, at date: Date = Date()) {
    inputTokens += stats.inputTokens
    if let userInputTokens = stats.userInputTokens {
      self.userInputTokens = (self.userInputTokens ?? 0) + userInputTokens
    }
    outputTokens += stats.outputTokens
    if let receivedTextTokens = stats.receivedTextTokens {
      self.receivedTextTokens = (self.receivedTextTokens ?? 0) + receivedTextTokens
    }
    if let reasoningTokens = stats.reasoningTokens {
      self.reasoningTokens = (self.reasoningTokens ?? 0) + reasoningTokens
    }
    if let imageInputs = stats.imageInputs {
      self.imageInputs = (self.imageInputs ?? 0) + imageInputs
    }
    cachedTokens += stats.cachedTokens
    promptSeconds += stats.promptSeconds
    generationSeconds += stats.generationSeconds
    callCount += stats.callCount
    if stats.tokensEstimated {
      estimatedCallCount += stats.callCount
    }
    lastOutputTokensPerSecond = stats.tokensPerSecond ?? lastOutputTokensPerSecond
    if let firstTokenSeconds = stats.firstTokenSeconds {
      lastFirstTokenSeconds = firstTokenSeconds
      firstTokenSecondsTotal = (firstTokenSecondsTotal ?? 0) + firstTokenSeconds
      firstTokenSampleCount = (firstTokenSampleCount ?? 0) + 1
    }
    lastUsedAt = date
  }
}

/// Every model of one provider summed, for provider-level listings.
public struct ProviderUsageTotals: Identifiable, Equatable, Sendable {
  public var providerLabel: String
  public var modelCount: Int
  public var inputTokens: Int
  public var userInputTokens: Int
  public var outputTokens: Int
  public var receivedTextTokens: Int
  public var reasoningTokens: Int
  public var imageInputs: Int
  public var cachedTokens: Int
  public var promptSeconds: TimeInterval
  public var generationSeconds: TimeInterval
  public var callCount: Int
  public var estimatedCallCount: Int
  public var lastUsedAt: Date

  public var id: String { providerLabel }
  public var totalTokens: Int { inputTokens + outputTokens }
  public var totalSeconds: TimeInterval { promptSeconds + generationSeconds }

  public var efficiency: Double? {
    ModelUsageTotals.efficiency(tokens: totalTokens, seconds: totalSeconds, requests: callCount)
  }

  /// One line under the provider's name:
  /// `3 models · ~1.2k sent · ~3.4k recv · 45 req · 12m34s in use`.
  public var summary: String {
    var parts = ["\(modelCount) model\(modelCount == 1 ? "" : "s")"]
    if userInputTokens > 0 { parts.append("~\(ModelUsageFormat.count(userInputTokens)) sent") }
    if receivedTextTokens > 0 {
      parts.append("~\(ModelUsageFormat.count(receivedTextTokens)) recv")
    }
    if reasoningTokens > 0 { parts.append("\(ModelUsageFormat.count(reasoningTokens)) thinking") }
    if imageInputs > 0 { parts.append("\(imageInputs) image\(imageInputs == 1 ? "" : "s")") }
    parts.append("\(callCount) req")
    if totalSeconds > 0 { parts.append("\(ModelUsageFormat.duration(totalSeconds)) in use") }
    return parts.joined(separator: " · ")
  }

  public init(providerLabel: String, models: [ModelUsageTotals]) {
    self.providerLabel = providerLabel
    modelCount = models.count
    inputTokens = models.reduce(0) { $0 + $1.inputTokens }
    userInputTokens = models.reduce(0) { $0 + ($1.userInputTokens ?? 0) }
    outputTokens = models.reduce(0) { $0 + $1.outputTokens }
    receivedTextTokens = models.reduce(0) { $0 + ($1.receivedTextTokens ?? 0) }
    reasoningTokens = models.reduce(0) { $0 + ($1.reasoningTokens ?? 0) }
    imageInputs = models.reduce(0) { $0 + ($1.imageInputs ?? 0) }
    cachedTokens = models.reduce(0) { $0 + $1.cachedTokens }
    promptSeconds = models.reduce(0) { $0 + $1.promptSeconds }
    generationSeconds = models.reduce(0) { $0 + $1.generationSeconds }
    callCount = models.reduce(0) { $0 + $1.callCount }
    estimatedCallCount = models.reduce(0) { $0 + $1.estimatedCallCount }
    lastUsedAt = models.map(\.lastUsedAt).max() ?? .distantPast
  }
}

// MARK: - Ledger

/// The whole usage table: one totals row per provider/model pair. Encodes as a
/// bare JSON array of rows, the shape PocketMai has always persisted.
public struct ModelUsageLedger: Codable, Equatable, Sendable {
  public var totals: [ModelUsageTotals]

  public init(totals: [ModelUsageTotals] = []) {
    self.totals = totals
  }

  public init(from decoder: Decoder) throws {
    totals = try decoder.singleValueContainer().decode([ModelUsageTotals].self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(totals)
  }

  public var isEmpty: Bool { totals.isEmpty }

  public func totals(id: String) -> ModelUsageTotals? {
    totals.first { $0.id == id }
  }

  /// Folds one call into its provider/model row, creating the row on first
  /// use. Calls that moved no tokens at all are ignored. Returns the updated
  /// row, or nil when nothing was recorded.
  @discardableResult
  public mutating func record(_ stats: ModelCallStats, at date: Date = Date())
    -> ModelUsageTotals?
  {
    guard stats.inputTokens > 0 || stats.outputTokens > 0 else { return nil }
    let id = ModelUsageTotals.id(providerLabel: stats.providerLabel, modelID: stats.modelID)
    var entry =
      totals.first { $0.id == id }
      ?? ModelUsageTotals(providerLabel: stats.providerLabel, modelID: stats.modelID)
    entry.record(stats, at: date)
    if let index = totals.firstIndex(where: { $0.id == id }) {
      totals[index] = entry
    } else {
      totals.append(entry)
    }
    return entry
  }

  public mutating func reset() {
    totals.removeAll()
  }

  /// Drops one provider/model row. Returns whether it existed.
  @discardableResult
  public mutating func remove(id: String) -> Bool {
    let before = totals.count
    totals.removeAll { $0.id == id }
    return totals.count != before
  }

  /// Drops every model of a provider. Returns how many rows went.
  @discardableResult
  public mutating func remove(providerLabel: String) -> Int {
    let before = totals.count
    totals.removeAll { $0.providerLabel == providerLabel }
    return before - totals.count
  }

  /// The rows a user names on a command line: a row id, a provider label
  /// (every model of it), or `PROVIDER:MODEL`.
  public func totals(matching target: String) -> [ModelUsageTotals] {
    if let row = totals(id: target) { return [row] }
    let byProvider = totals.filter { $0.providerLabel == target }
    if !byProvider.isEmpty { return byProvider }
    guard let separator = target.firstIndex(of: ":") else { return [] }
    let id = ModelUsageTotals.id(
      providerLabel: String(target[..<separator]),
      modelID: String(target[target.index(after: separator)...]))
    return totals(id: id).map { [$0] } ?? []
  }

  /// Drops the rows `totals(matching:)` names. Returns how many rows went.
  @discardableResult
  public mutating func remove(matching target: String) -> Int {
    let ids = Set(totals(matching: target).map(\.id))
    totals.removeAll { ids.contains($0.id) }
    return ids.count
  }

  /// Rows that can show a speed, fastest first: a ranking at a glance.
  public var sortedBySpeed: [ModelUsageTotals] {
    totals
      .filter { $0.averageTokensPerSecond != nil }
      .sorted { ($0.averageTokensPerSecond ?? 0) > ($1.averageTokensPerSecond ?? 0) }
  }

  public var sortedByLastUsed: [ModelUsageTotals] {
    totals.sorted { $0.lastUsedAt > $1.lastUsedAt }
  }

  public var sortedByTime: [ModelUsageTotals] {
    totals.sorted { $0.totalSeconds > $1.totalSeconds }
  }

  /// Rows with an efficiency score, best first.
  public var sortedByEfficiency: [ModelUsageTotals] {
    totals
      .filter { $0.efficiency != nil }
      .sorted { ($0.efficiency ?? 0) > ($1.efficiency ?? 0) }
  }

  public var providerTotals: [ProviderUsageTotals] {
    Dictionary(grouping: totals, by: \.providerLabel)
      .map { ProviderUsageTotals(providerLabel: $0.key, models: $0.value) }
      .sorted {
        $0.providerLabel.localizedCaseInsensitiveCompare($1.providerLabel) == .orderedAscending
      }
  }

  public var totalSeconds: TimeInterval { totals.reduce(0) { $0 + $1.totalSeconds } }
  public var callCount: Int { totals.reduce(0) { $0 + $1.callCount } }
  public var estimatedCallCount: Int { totals.reduce(0) { $0 + $1.estimatedCallCount } }
  public var inputTokens: Int { totals.reduce(0) { $0 + $1.inputTokens } }
  public var outputTokens: Int { totals.reduce(0) { $0 + $1.outputTokens } }
  public var totalTokens: Int { inputTokens + outputTokens }

  /// The efficiency score of every row taken together.
  public var efficiency: Double? {
    ModelUsageTotals.efficiency(tokens: totalTokens, seconds: totalSeconds, requests: callCount)
  }
  public var userInputTokens: Int { totals.reduce(0) { $0 + ($1.userInputTokens ?? 0) } }
  public var receivedTextTokens: Int { totals.reduce(0) { $0 + ($1.receivedTextTokens ?? 0) } }
  public var reasoningTokens: Int { totals.reduce(0) { $0 + ($1.reasoningTokens ?? 0) } }
  public var imageInputs: Int { totals.reduce(0) { $0 + ($1.imageInputs ?? 0) } }

  // MARK: Persistence

  /// Reads a ledger written by any host: ISO 8601 dates from MaiCore files and
  /// the numeric dates PocketMai's earlier releases stored are both accepted.
  public static func decode(_ data: Data, coding: MaiJSONCoding = .default) throws
    -> ModelUsageLedger
  {
    try coding.makeDecoder().decode(ModelUsageLedger.self, from: data)
  }

  public func encoded(coding: MaiJSONCoding = .default) throws -> Data {
    try coding.makeEncoder().encode(self)
  }

  public static func load(from url: URL, coding: MaiJSONCoding = .default) throws
    -> ModelUsageLedger
  {
    guard FileManager.default.fileExists(atPath: url.path) else { return ModelUsageLedger() }
    return try decode(Data(contentsOf: url), coding: coding)
  }

  public func save(to url: URL, coding: MaiJSONCoding = .default) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded(coding: coding).write(to: url, options: .atomic)
  }
}

/// Where a `ModelUsageStore` keeps its ledger between launches.
public protocol ModelUsagePersistence: Sendable {
  func load() throws -> ModelUsageLedger
  func save(_ ledger: ModelUsageLedger) throws
}

/// One JSON file, the way pmai keeps `~/.pmai/stats.json`.
public struct FileModelUsagePersistence: ModelUsagePersistence {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func load() throws -> ModelUsageLedger {
    try ModelUsageLedger.load(from: url)
  }

  public func save(_ ledger: ModelUsageLedger) throws {
    try ledger.save(to: url)
  }
}

/// One `UserDefaults` value, the way PocketMai keeps its totals. The suite is
/// named rather than held so the persistence stays Sendable.
public struct UserDefaultsModelUsagePersistence: ModelUsagePersistence {
  public let key: String
  public let suiteName: String?

  public init(key: String, suiteName: String? = nil) {
    self.key = key
    self.suiteName = suiteName
  }

  private var defaults: UserDefaults {
    suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  public func load() throws -> ModelUsageLedger {
    guard let data = defaults.data(forKey: key) else { return ModelUsageLedger() }
    return try ModelUsageLedger.decode(data)
  }

  public func save(_ ledger: ModelUsageLedger) throws {
    defaults.set(try ledger.encoded(), forKey: key)
  }
}

/// The shared, concurrency-safe home of a host's usage ledger. The runtime
/// records into it after every provider call; commands and screens read it.
/// Every change is written through the persistence at once, so a crash never
/// loses more than the call in flight.
public actor ModelUsageStore {
  public private(set) var ledger: ModelUsageLedger
  /// The last persistence failure, for hosts that want to show it.
  public private(set) var lastPersistenceError: String?
  private let persistence: (any ModelUsagePersistence)?
  private var subscribers: [UUID: AsyncStream<ModelUsageLedger>.Continuation] = [:]

  public init(persistence: (any ModelUsagePersistence)? = nil) {
    self.persistence = persistence
    ledger = (try? persistence?.load()) ?? ModelUsageLedger()
  }

  public init(url: URL) {
    self.init(persistence: FileModelUsagePersistence(url: url))
  }

  /// The file behind the ledger, when it is kept in one.
  public var location: URL? {
    (persistence as? FileModelUsagePersistence)?.url
  }

  public func totals() -> [ModelUsageTotals] { ledger.totals }

  @discardableResult
  public func record(_ stats: ModelCallStats, at date: Date = Date()) -> ModelUsageTotals? {
    guard let entry = ledger.record(stats, at: date) else { return nil }
    persist()
    return entry
  }

  public func reset() {
    ledger.reset()
    persist()
  }

  @discardableResult
  public func remove(id: String) -> Bool {
    let removed = ledger.remove(id: id)
    if removed { persist() }
    return removed
  }

  @discardableResult
  public func remove(providerLabel: String) -> Int {
    let removed = ledger.remove(providerLabel: providerLabel)
    if removed > 0 { persist() }
    return removed
  }

  /// Drops the rows a command-line target names; see `ModelUsageLedger.totals(matching:)`.
  @discardableResult
  public func remove(matching target: String) -> Int {
    let removed = ledger.remove(matching: target)
    if removed > 0 { persist() }
    return removed
  }

  /// Every ledger written after subscribing, for screens that stay open.
  public func changes() -> AsyncStream<ModelUsageLedger> {
    let id = UUID()
    return AsyncStream { continuation in
      subscribers[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { await self?.unsubscribe(id) }
      }
    }
  }

  private func unsubscribe(_ id: UUID) {
    subscribers[id] = nil
  }

  private func persist() {
    do {
      try persistence?.save(ledger)
      lastPersistenceError = nil
    } catch {
      lastPersistenceError = error.localizedDescription
    }
    for continuation in subscribers.values { continuation.yield(ledger) }
  }
}

// MARK: - Presentation

/// An sRGB color in 0...1 components, so every host can paint a provider the
/// same way without sharing a UI framework.
public struct ModelUsageColor: Hashable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double

  public init(red: Double, green: Double, blue: Double) {
    self.red = min(1, max(0, red))
    self.green = min(1, max(0, green))
    self.blue = min(1, max(0, blue))
  }

  /// `#rrggbb`, the spelling terminal color settings accept.
  public var hex: String {
    String(
      format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()),
      Int((blue * 255).rounded()))
  }
}

/// A label-derived hue gives every provider a distinct, repeatable chart
/// color that is the same in PocketMai, the REPL, and the visual workspace.
public enum ModelUsagePalette {
  public static let saturation = 0.68
  public static let brightness = 0.88

  /// Hue in 0..<1 from an FNV-1a hash of the label.
  public static func hue(forProviderLabel label: String) -> Double {
    var hash: UInt64 = 1_469_598_103_934_665_603
    for byte in label.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return Double(hash % 360) / 360
  }

  public static func color(forProviderLabel label: String) -> ModelUsageColor {
    color(hue: hue(forProviderLabel: label), saturation: saturation, brightness: brightness)
  }

  /// HSB to sRGB, all components in 0...1.
  public static func color(hue: Double, saturation: Double, brightness: Double)
    -> ModelUsageColor
  {
    let h = (hue - hue.rounded(.down)) * 6
    let sector = Int(h.rounded(.down)) % 6
    let fraction = h - h.rounded(.down)
    let p = brightness * (1 - saturation)
    let q = brightness * (1 - saturation * fraction)
    let t = brightness * (1 - saturation * (1 - fraction))
    switch sector {
    case 0: return ModelUsageColor(red: brightness, green: t, blue: p)
    case 1: return ModelUsageColor(red: q, green: brightness, blue: p)
    case 2: return ModelUsageColor(red: p, green: brightness, blue: t)
    case 3: return ModelUsageColor(red: p, green: q, blue: brightness)
    case 4: return ModelUsageColor(red: t, green: p, blue: brightness)
    default: return ModelUsageColor(red: brightness, green: p, blue: q)
    }
  }
}

/// Text spellings shared by every host: speeds, durations, counts, and bars.
public enum ModelUsageFormat {
  /// `42.1 tok/s`
  public static func speed(_ tokensPerSecond: Double) -> String {
    String(format: "%.1f tok/s", tokensPerSecond)
  }

  /// `0.85s` under ten seconds, `12.3s` above.
  public static func seconds(_ seconds: TimeInterval) -> String {
    String(format: seconds >= 10 ? "%.1fs" : "%.2fs", seconds)
  }

  /// `3.2 tok/s/req`: tokens per second in use, per request.
  public static func efficiency(_ score: Double) -> String {
    String(format: "%.1f tok/s/req", score)
  }

  /// `text` cut to `width` cells with a trailing ellipsis, for a label column.
  public static func clip(_ text: String, to width: Int) -> String {
    guard text.count > width, width > 1 else { return text }
    return String(text.prefix(width - 1)) + "…"
  }

  /// `text` padded with spaces to `width` cells, on the left when `leading`.
  public static func pad(_ text: String, to width: Int, leading: Bool = false) -> String {
    let missing = max(0, width - text.count)
    guard missing > 0 else { return text }
    let fill = String(repeating: " ", count: missing)
    return leading ? fill + text : text + fill
  }

  /// `<1s`, `5s`, `1m4s`, or `2h3m4s`: how long something took or has been
  /// running, rounded to whole seconds.
  public static func duration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds > 0 else { return "<1s" }
    let total = Int(seconds.rounded())
    guard total >= 1 else { return "<1s" }
    let (hours, minutes, remainder) = (total / 3600, total % 3600 / 60, total % 60)
    if hours > 0 { return "\(hours)h\(minutes)m\(remainder)s" }
    if minutes > 0 { return "\(minutes)m\(remainder)s" }
    return "\(remainder)s"
  }

  /// `950`, `1.2k`, `12.0k`, `552.2k`, `3.4M`: a count short enough for a
  /// status line. Every token count a host prints goes through here, so the
  /// same number reads the same everywhere.
  public static func count(_ count: Int) -> String {
    guard count >= 1_000 else { return String(count) }
    let thousandths = (count + 50) / 100
    guard thousandths >= 10_000 else { return "\(thousandths / 10).\(thousandths % 10)k" }
    let millionths = (count + 50_000) / 100_000
    return "\(millionths / 10).\(millionths % 10)M"
  }

  /// A token count with its unit, `~` first when the number was estimated
  /// rather than reported by the provider: `12.0k tok`, `~552.2k tok`.
  public static func tokens(_ count: Int, estimated: Bool = false) -> String {
    "\(estimated ? "~" : "")\(Self.count(count)) tok"
  }

  /// A horizontal bar of `width` cells filled to `fraction`, using eighth
  /// blocks for the last cell so short bars still differ.
  public static func bar(fraction: Double, width: Int) -> String {
    guard width > 0 else { return "" }
    let clamped = fraction.isFinite ? min(1, max(0, fraction)) : 0
    let eighths = Int((clamped * Double(width) * 8).rounded())
    let full = eighths / 8
    let partial = eighths % 8
    let partials = [" ", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
    var bar = String(repeating: "█", count: min(full, width))
    if full < width {
      bar += partials[partial]
      bar += String(repeating: " ", count: max(0, width - full - 1))
    }
    return bar
  }
}

/// The usage ledger arranged for display: rows ranked by speed, each with
/// its bar fractions and provider color, plus the totals for a headline.
/// Hosts render the rows with their own widgets; `lines` is the plain-text
/// rendering the REPL prints and the visual workspace's command output shows.
public struct ModelUsageReport: Equatable, Sendable {
  /// The rankings every host shows, in the order they are printed.
  public enum Metric: String, CaseIterable, Sendable {
    /// Average visible output speed.
    case speed
    /// Seconds the model has been busy in total.
    case time
    /// `totalTokens / (totalSeconds × callCount)`.
    case efficiency

    /// The heading over the bars: `Average output speed`.
    public var title: String {
      switch self {
      case .speed: "Average output speed"
      case .time: "Time in use"
      case .efficiency: "Efficiency"
      }
    }

    /// The short name a picker or `/stats METRIC` uses: `Speed`.
    public var label: String {
      switch self {
      case .speed: "Speed"
      case .time: "Time"
      case .efficiency: "Efficiency"
      }
    }

    /// How the number is computed, for help text and footers.
    public var explanation: String {
      switch self {
      case .speed: "visible output tokens over the streaming window of each call"
      case .time: "the wait for the first token plus generation time, summed over every call"
      case .efficiency: "total tokens divided by seconds in use and by requests"
      }
    }

    /// The number spelled out — `42.1 tok/s`, `12m34s`, `3.2 tok/s/req` —
    /// or what a row without it says.
    public func text(_ value: Double?) -> String {
      switch self {
      case .speed: value.map(ModelUsageFormat.speed) ?? "no speed"
      case .time: ModelUsageFormat.duration(value ?? 0)
      case .efficiency: value.map(ModelUsageFormat.efficiency) ?? "no score"
      }
    }
  }

  public struct Row: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var providerLabel: String
    public var modelID: String
    public var color: ModelUsageColor
    public var speed: Double?
    public var seconds: TimeInterval
    public var efficiency: Double?
    /// Each metric relative to the best row, 0...1; zero for a row without it.
    public var fractions: [Metric: Double]
    public var callCount: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int
    public var estimated: Bool
    public var averageFirstTokenSeconds: TimeInterval?
    public var lastUsedAt: Date

    public var totalTokens: Int { inputTokens + outputTokens }
    public var speedFraction: Double { fraction(.speed) }
    public var secondsFraction: Double { fraction(.time) }

    /// The row's number for one metric, nil when it has none.
    public func number(_ metric: Metric) -> Double? {
      switch metric {
      case .speed: speed
      case .time: Optional(seconds)
      case .efficiency: efficiency
      }
    }

    public func fraction(_ metric: Metric) -> Double {
      fractions[metric] ?? 0
    }

    /// The bar's number, `42.1 tok/s`, `12m34s`, or `3.2 tok/s/req`.
    public func value(_ metric: Metric) -> String {
      metric.text(number(metric))
    }

    /// What the row says after its bar: `12m34s · 45 req · 120.3k tok`. The
    /// metrics the bar does not show come first, so every ranking reads whole.
    public func detail(_ metric: Metric) -> String {
      var parts: [String] = []
      switch metric {
      case .speed: parts.append(ModelUsageFormat.duration(seconds))
      case .time: if let speed { parts.append(ModelUsageFormat.speed(speed)) }
      case .efficiency:
        if let speed { parts.append(ModelUsageFormat.speed(speed)) }
        parts.append(ModelUsageFormat.duration(seconds))
      }
      parts.append("\(callCount) req")
      parts.append(ModelUsageFormat.tokens(totalTokens, estimated: estimated))
      return parts.joined(separator: " · ")
    }
  }

  public var rows: [Row]
  public var modelCount: Int
  public var callCount: Int
  public var totalSeconds: TimeInterval
  public var inputTokens: Int
  public var outputTokens: Int
  public var reasoningTokens: Int
  public var efficiency: Double?
  public var hasEstimates: Bool

  public init(_ ledger: ModelUsageLedger) {
    let best = Dictionary(
      uniqueKeysWithValues: Metric.allCases.map { metric in
        (metric, ledger.totals.compactMap { $0.value(metric) }.max() ?? 0)
      })
    let ranked =
      ledger.sortedBySpeed
      + ledger.totals.filter { $0.averageTokensPerSecond == nil }.sorted {
        $0.totalSeconds > $1.totalSeconds
      }
    rows = ranked.map { entry in
      Row(
        id: entry.id,
        title: entry.title,
        providerLabel: entry.providerLabel,
        modelID: entry.modelID,
        color: ModelUsagePalette.color(forProviderLabel: entry.providerLabel),
        speed: entry.averageTokensPerSecond,
        seconds: entry.totalSeconds,
        efficiency: entry.efficiency,
        fractions: Dictionary(
          uniqueKeysWithValues: Metric.allCases.map { metric in
            let top = best[metric] ?? 0
            return (metric, top > 0 ? (entry.value(metric) ?? 0) / top : 0)
          }),
        callCount: entry.callCount,
        inputTokens: entry.inputTokens,
        outputTokens: entry.outputTokens,
        reasoningTokens: entry.reasoningTokens ?? 0,
        estimated: entry.estimatedCallCount > 0,
        averageFirstTokenSeconds: entry.averageFirstTokenSeconds,
        lastUsedAt: entry.lastUsedAt)
    }
    modelCount = ledger.totals.count
    callCount = ledger.callCount
    totalSeconds = ledger.totalSeconds
    inputTokens = ledger.inputTokens
    outputTokens = ledger.outputTokens
    reasoningTokens = ledger.reasoningTokens
    efficiency = ledger.efficiency
    hasEstimates = ledger.estimatedCallCount > 0
  }

  public init(totals: [ModelUsageTotals]) {
    self.init(ModelUsageLedger(totals: totals))
  }

  public var isEmpty: Bool { rows.isEmpty }

  /// Rows ranked for one metric, best first; rows without it keep their
  /// speed ranking at the end.
  public func rows(for metric: Metric) -> [Row] {
    switch metric {
    case .speed: rows
    case .time, .efficiency: rows.sorted { ($0.number(metric) ?? -1) > ($1.number(metric) ?? -1) }
    }
  }

  /// `2 models · 57 requests · 15m36s in use · 150.4k tokens · efficiency 2.8 tok/s/req`
  public var headline: String {
    var parts = [
      "\(modelCount) model\(modelCount == 1 ? "" : "s")",
      "\(callCount) request\(callCount == 1 ? "" : "s")",
      "\(ModelUsageFormat.duration(totalSeconds)) in use",
      "\(hasEstimates ? "~" : "")\(ModelUsageFormat.count(inputTokens + outputTokens)) tokens",
    ]
    if reasoningTokens > 0 {
      parts.append("\(ModelUsageFormat.count(reasoningTokens)) thinking")
    }
    if let efficiency {
      parts.append("efficiency \(ModelUsageFormat.efficiency(efficiency))")
    }
    return parts.joined(separator: " · ")
  }

  public static let emptyMessage =
    "No model usage recorded yet. Statistics appear after the first model response."

  /// What a run of report text is, so a terminal can color it: headings, the
  /// provider-colored label and bar, the number, and the muted rest.
  public enum Style: Equatable, Sendable {
    case heading
    case headline
    case label(ModelUsageColor)
    case bar(ModelUsageColor)
    case value
    case detail
    case note
  }

  /// One run of a report line; `style` is nil for spacing.
  public struct Run: Equatable, Sendable {
    public var text: String
    public var style: Style?

    public init(_ text: String, _ style: Style? = nil) {
      self.text = text
      self.style = style
    }
  }

  /// The report as styled runs, one array per line: a headline, then one
  /// bar per model for each metric. `lines` joins them into plain text.
  public func runs(width: Int = 80, metrics: [Metric] = Metric.allCases) -> [[Run]] {
    guard !isEmpty else { return [[Run(Self.emptyMessage)]] }
    var lines: [[Run]] = [[Run("Model usage: ", .heading), Run(headline, .headline)]]
    let labelWidth = min(28, rows.map { $0.title.count }.max() ?? 0)
    for metric in metrics {
      lines.append([Run(metric.title, .heading)])
      let metricRows = rows(for: metric)
      let valueWidth = metricRows.map { $0.value(metric).count }.max() ?? 0
      let barWidth = max(6, min(30, width - labelWidth - valueWidth - 34))
      for row in metricRows {
        lines.append([
          Run("  "),
          Run(
            ModelUsageFormat.pad(ModelUsageFormat.clip(row.title, to: labelWidth), to: labelWidth),
            .label(row.color)),
          Run(" "),
          Run(ModelUsageFormat.bar(fraction: row.fraction(metric), width: barWidth), .bar(row.color)),
          Run(" "),
          Run(ModelUsageFormat.pad(row.value(metric), to: valueWidth, leading: true), .value),
          Run("  "),
          Run(row.detail(metric), .detail),
        ])
      }
    }
    if hasEstimates {
      lines.append([
        Run(
          "~ marks token counts estimated from text length (about 4 characters per token).",
          .note)
      ])
    }
    return lines
  }

  /// The plain-text report. `paint` may wrap a styled run in color for
  /// terminals that show it; the text stays free of escapes otherwise, so
  /// any surface can print it.
  public func lines(
    width: Int = 80,
    metrics: [Metric] = Metric.allCases,
    paint: (String, Style) -> String = { text, _ in text }
  ) -> [String] {
    runs(width: width, metrics: metrics).map { line in
      line.map { run in run.style.map { paint(run.text, $0) } ?? run.text }.joined()
    }
  }
}
