import Foundation

/// UI-independent orchestration for providers, tools, approvals, MCP tools,
/// and bounded child-agent runs. Hosts own presentation and persistence and
/// observe work through `AgentEvent` values and the shared `AgentSupervisor`.
public actor AgentRuntime {
  public static let agentStartToolName = AgentProcessTools.startToolName
  public static let agentStatusToolName = AgentProcessTools.statusToolName
  public static let agentResultToolName = AgentProcessTools.resultToolName
  public static let agentStopToolName = AgentProcessTools.stopToolName
  public static let agentToolNames: Set<String> = AgentProcessTools.toolNames
  public static let agentToolGroup = ToolGroupDefinition(
    id: "agents",
    sourceID: "runtime",
    displayName: "Agents",
    description: "Start, inspect, collect, and stop child agents.",
    toolNames: agentToolNames)
  /// Earlier spellings of `agent_start`. They are still executed so existing
  /// configurations and fine-tuned providers keep working, but they are no
  /// longer offered: six near-identical tools only confuse a model.
  public static let subagentToolName = AgentProcessTools.legacySpawnToolName
  public static let agentLaunchToolName = AgentProcessTools.legacyLaunchToolName

  private struct RegisteredMCP: Sendable {
    var source: any MCPToolSource
    var toolNames: Set<String>
  }

  private var providers: [ProviderID: any ChatProvider] = [:]
  private var tools: [String: any AgentTool] = [:]
  private var agents: [String: AgentDefinition] = [:]
  private var registeredMCPs: [String: RegisteredMCP] = [:]
  private let approvalHandler: any ApprovalHandler
  /// Overrides for the delegation brief and the derived worker's instructions.
  /// Nil keeps the built-in text, so MaiCore works without configuration.
  private var delegationTemplate: String?
  private var workerInstructions: String?
  /// The compaction prompt autocompact renders; nil keeps the built-in one.
  private var compactionTemplate: String?
  /// Durable notes added to the system prompt of top-level runs. A child agent
  /// grepping a file does not need the user's standing preferences, so this
  /// never reaches one.
  private var memorySection: String?
  private var instructionsSection: String?
  /// Where every completed provider call's tokens and timing are folded in.
  /// Nil keeps the runtime silent about usage, as it was before hosts asked.
  private var usageStats: ModelUsageStore?

  /// The process table every run reports into. Hosts read it for `/agents`,
  /// follow its events for notifications, and stop subtrees through it.
  public nonisolated let supervisor: AgentSupervisor

  public init(
    approvalHandler: any ApprovalHandler = DenyInteractiveApprovals(),
    supervisor: AgentSupervisor = AgentSupervisor()
  ) {
    self.approvalHandler = approvalHandler
    self.supervisor = supervisor
  }

  /// Adds any provider implementation to the runtime by its descriptor ID.
  public func register(
    _ provider: any ChatProvider,
    replacingExisting: Bool = false
  ) throws {
    let descriptor = provider.descriptor
    let rawID = descriptor.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawID.isEmpty else { throw AgentRuntimeError.invalidProviderID }
    guard replacingExisting || providers[descriptor.id] == nil else {
      throw AgentRuntimeError.providerAlreadyRegistered(descriptor.id)
    }
    providers[descriptor.id] = provider
  }

  public func register(
    tool: any AgentTool,
    replacingExisting: Bool = false
  ) throws {
    let name = tool.definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw AgentToolError.invalidName }
    guard !Self.reservedToolNames.contains(name) else {
      throw AgentRuntimeError.reservedToolName(name)
    }
    guard replacingExisting || tools[name] == nil else {
      throw AgentToolError.duplicateName(name)
    }
    tools[name] = tool
  }

  public func register(
    agent: AgentDefinition,
    replacingExisting: Bool = false
  ) throws {
    let id = agent.id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { throw AgentRuntimeError.invalidAgentID }
    guard replacingExisting || agents[id] == nil else {
      throw AgentRuntimeError.agentAlreadyRegistered(id)
    }
    agents[id] = agent
  }

  /// Installs the ledger every provider call reports into: tokens from the
  /// provider's usage payload (estimated from text length when it has none)
  /// and the wall-clock timing of the call. Nil stops recording.
  public func configureUsageStats(_ store: ModelUsageStore?) {
    usageStats = store
  }

  /// The ledger installed with `configureUsageStats`, for `/stats` screens.
  public func usageStatsStore() -> ModelUsageStore? {
    usageStats
  }

  /// Installs the durable memory every top-level run should see, already
  /// wrapped in its envelope by `AgentMemory.promptSection`. Nil removes it.
  public func configureMemory(_ section: String?) {
    memorySection = section?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
  }

  /// Installs the project's AGENTS.md text, already wrapped by
  /// `AgentInstructionsFile.promptSection`. Runs at every depth see it: a
  /// child working in the same tree needs the same rules. Nil removes it.
  public func configureProjectInstructions(_ section: String?) {
    instructionsSection =
      section?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
  }

  /// Installs host-configured delegation text. Empty or nil values restore the
  /// built-in template and worker instructions.
  public func configureDelegation(prompt: String?, workerInstructions: String?) {
    delegationTemplate = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
    self.workerInstructions =
      workerInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
  }

  /// Installs the template autocompact summarizes with, the same one a host
  /// uses for `/chat compact`. Empty or nil restores `AgentCompactionPrompt`.
  public func configureCompaction(prompt: String?) {
    compactionTemplate = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
  }

  @discardableResult
  public func register(
    mcp source: any MCPToolSource,
    replacingExistingTools: Bool = false
  ) async throws -> MCPServerCatalog {
    let catalog = try await source.connect()
    let agentTools = try await source.agentTools()
    for tool in agentTools {
      try register(tool: tool, replacingExisting: replacingExistingTools)
    }
    registeredMCPs[catalog.serverID] = RegisteredMCP(
      source: source,
      toolNames: Set(agentTools.map { $0.definition.name }))
    return catalog
  }

  /// Forgets a tool registered directly, so it is no longer offered or run.
  /// Tools that came with an MCP server leave with `unregisterMCP` instead.
  @discardableResult
  public func unregister(toolNamed name: String) -> Bool {
    tools.removeValue(forKey: name) != nil
  }

  /// Disconnects an MCP source and removes the tools discovered from it.
  @discardableResult
  public func unregisterMCP(serverID: String) async -> Set<String> {
    guard let registration = registeredMCPs.removeValue(forKey: serverID) else { return [] }
    for name in registration.toolNames { tools[name] = nil }
    await registration.source.close()
    return registration.toolNames
  }

  public func availableProviders() -> [ProviderDescriptor] {
    providers.values.map(\.descriptor).sorted {
      $0.id.rawValue.localizedStandardCompare($1.id.rawValue) == .orderedAscending
    }
  }

  public func availableModels(provider id: ProviderID) async throws -> [ModelDescriptor] {
    guard let provider = providers[id] else {
      throw AgentRuntimeError.providerNotRegistered(id)
    }
    return try await provider.availableModels().sorted {
      $0.id.localizedStandardCompare($1.id) == .orderedAscending
    }
  }

  public func availableTools() -> [ToolDefinition] {
    tools.values.map(\.definition).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  /// Every registered definition, disabled ones included, so a host can list
  /// and re-enable them. Pass false to see only what can actually be run.
  public func availableAgents(includingDisabled: Bool = true) -> [AgentDefinition] {
    agents.values
      .filter { includingDisabled || $0.isEnabled }
      .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
  }

  public func run(
    agentID: String,
    messages: [AgentMessage],
    emit: @escaping AgentEventHandler = { _ in }
  ) async throws -> AgentResult {
    guard let definition = agents[agentID] else {
      throw AgentRuntimeError.agentNotRegistered(agentID)
    }
    let request = request(for: definition, messages: messages)
    return try await run(request, emit: emit)
  }

  /// Registers an idle top-level process for a conversation before any turn
  /// runs, so a host can queue messages for it and list it, then pass the pid
  /// to `run(_:process:emit:)` when the first turn starts.
  /// Forgets a definition, so it is no longer offered or startable. A run
  /// already using it carries on with the copy it was given.
  public func unregister(agentID: String) {
    agents[agentID] = nil
  }

  public func allocateProcess(agentID: String, task: String = "") async -> AgentPID {
    await supervisor.register(
      runID: UUID(),
      parent: nil,
      agentID: agentID,
      displayName: agentID,
      task: task,
      depth: 0)
  }

  /// Runs one turn. Pass the pid an earlier turn returned as `process` to keep
  /// a conversation's identity — and the background children it started —
  /// across turns; a stale or omitted pid starts a fresh process.
  @discardableResult
  public func run(
    _ request: AgentRequest,
    process: AgentPID? = nil,
    emit: @escaping AgentEventHandler = { _ in }
  ) async throws -> AgentResult {
    let budget = RunBudget(limits: request.limits)
    let runID = UUID()
    let task = AgentProcessInfo.oneLine(
      request.messages.last { $0.role == .user }?.text ?? "", limit: 60)
    var resumed: AgentPID?
    if let existing = process, await supervisor.reopen(existing, runID: runID, task: task) {
      resumed = existing
    }
    let pid: AgentPID
    if let resumed {
      pid = resumed
    } else {
      pid = await supervisor.register(
        runID: runID,
        parent: nil,
        agentID: request.agentID,
        displayName: request.agentID,
        task: task,
        depth: 0)
    }
    do {
      let result = try await runInternal(
        request,
        runID: runID,
        pid: pid,
        parentRunID: nil,
        depth: 0,
        budget: budget,
        emit: emit)
      await supervisor.finish(pid, result: result, announce: false)
      return result
    } catch is CancellationError {
      await supervisor.fail(pid, state: .cancelled, message: "Cancelled", announce: false)
      throw CancellationError()
    } catch {
      await supervisor.fail(
        pid, state: .failed, message: error.localizedDescription, announce: false)
      throw error
    }
  }

  /// Where a paused run waits. A person pauses through the supervisor while
  /// the run is inside a model call or a tool; it gets here at the next
  /// boundary and stays until it is resumed or stopped.
  private func holdWhilePaused(_ pid: AgentPID) async throws {
    guard await supervisor.isPaused(pid) else { return }
    // "thinking" or a tool name would describe work that is not happening.
    await supervisor.note(pid, activity: "")
    while await supervisor.isPaused(pid) {
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func runInternal(
    _ request: AgentRequest,
    runID: UUID,
    pid: AgentPID,
    parentRunID: UUID?,
    depth: Int,
    budget: RunBudget,
    emit: @escaping AgentEventHandler
  ) async throws -> AgentResult {
    try Task.checkCancellation()
    guard let provider = providers[request.provider] else {
      throw AgentRuntimeError.providerNotRegistered(request.provider)
    }

    let context = AgentEventContext(
      runID: runID,
      parentRunID: parentRunID,
      agentID: request.agentID,
      depth: depth,
      pid: pid)
    let concreteDefinitions = try visibleDefinitions(for: request)
    let definitions =
      request.useToolProxy && !concreteDefinitions.isEmpty
      ? ToolProxy.definitions(for: concreteDefinitions, exposing: request.proxyExposedTools)
      : concreteDefinitions
    let supportsNativeTools = provider.descriptor.capabilities.contains(.nativeToolCalling)
    if request.toolCallingStrategy == .native, !definitions.isEmpty, !supportsNativeTools {
      throw AgentRuntimeError.nativeToolCallingUnavailable(request.provider)
    }
    let textToolMode: ToolCallingMode?
    switch request.toolCallingStrategy {
    case .automatic:
      textToolMode = definitions.isEmpty || supportsNativeTools ? nil : .json
    case .native:
      textToolMode = nil
    case .text:
      textToolMode = definitions.isEmpty ? nil : .text
    case .xml:
      textToolMode = definitions.isEmpty ? nil : .xml
    case .json:
      textToolMode = definitions.isEmpty ? nil : .json
    }
    let usesTextToolProtocol = textToolMode != nil
    var transcript = request.messages
    var totalUsage: TokenUsage?
    /// What the provider counted on the last call, for the autocompact
    /// estimate. Cleared when a summary changes the transcript's shape.
    var lastUsage: TokenUsage?
    var localModelTurns = 0
    var localToolCalls = 0
    var repeatedCalls: [ToolCallKey: Int] = [:]
    /// Set once a call came back a fourth time with the same arguments, or the
    /// model answered three tool results in a row with nothing. The next turn
    /// is offered no tools and asked to answer: a model that keeps repeating a
    /// refused call, or keeps saying nothing, otherwise does so until the turn
    /// limit.
    var repeatGuardTripped = false
    var consecutiveEmptyReplies = 0
    var completedToolRuns: [ToolCallKey: String] = [:]

    /// A limit met at a turn boundary pauses the run instead of failing it.
    /// The transcript ends in a user message or in tool results, so running
    /// it again picks the task up exactly where it stopped.
    func pause(_ interruption: AgentRunInterruption) async -> AgentResult {
      // Only what this run said counts as its reply; an older assistant
      // message would be printed twice by a host that streams.
      let response =
        transcript.dropFirst(request.messages.count).last { $0.role == .assistant }
        ?? .assistant("")
      let result = AgentResult(
        runID: context.runID,
        agentID: request.agentID,
        provider: request.provider,
        response: response,
        transcript: transcript,
        usage: totalUsage,
        stopReason: .unknown,
        modelTurns: localModelTurns,
        toolCalls: localToolCalls,
        interruption: interruption)
      await emit(.finished(context, result))
      return result
    }

    await emit(.started(context, provider.descriptor))
    await supervisor.note(pid, state: .running, transcript: transcript)
    while true {
      try Task.checkCancellation()
      try await holdWhilePaused(pid)
      // In size mode the bodies of files read two or more results ago make
      // way for a reference before every call; in cache mode nothing sent
      // is ever touched, so the server's prompt cache covers it.
      if request.context == .size, let report = AgentContextPruning.prune(&transcript) {
        lastUsage = nil
        await emit(.transcriptEdited(context, report))
        await supervisor.note(pid, transcript: transcript)
      }
      // Anything a person queued for this process since the last turn joins
      // the conversation here, after the tool results the model is about to
      // read, so a running agent can be steered without stopping it.
      let injected = await supervisor.drainInbox(pid)
      if !injected.isEmpty {
        for message in injected {
          transcript.append(message)
          await emit(.userMessage(context, message))
        }
        await supervisor.note(pid, transcript: transcript)
      }
      // A conversation past the agent's autocompact threshold is folded here,
      // before the limits are checked, so a run that pauses next hands its
      // host the smaller transcript too.
      if request.autocompact.isEnabled {
        let estimate = AgentAutocompaction.estimatedTokens(of: transcript, lastUsage: lastUsage)
        if estimate >= request.autocompact.tokens,
          let selection = AgentAutocompaction.selection(in: transcript)
        {
          await emit(.compactionStarted(context, estimatedTokens: estimate))
          await supervisor.note(pid, activity: "compacting")
          do {
            let summary = try await summarize(
              selection, of: transcript, provider: provider, request: request, budget: budget,
              context: context, pid: pid, emit: emit)
            let usage =
              summary.response.usage
              ?? .estimated(
                inputTokens: ModelCallStats.estimatedTokenCount(
                  of: transcript.filter { selection.contains($0.id) }),
                outputTokens: ModelCallStats.estimatedTokenCount(
                  forCharacterCount: summary.response.message.text.count))
            totalUsage = totalUsage.merging(usage)
            await supervisor.note(pid, usage: totalUsage)
            await budget.record(tokens: usage.totalTokens)
            let text = summary.response.message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw CompactionError.emptySummary }
            let applied = AgentTranscriptEditor.apply(
              [.compact(messageIDs: selection, summary: text)], to: transcript)
            transcript = applied.messages
            lastUsage = nil
            await emit(.transcriptEdited(context, applied.report))
            await supervisor.note(pid, transcript: transcript)
          } catch is RunDeadlineExceeded {
            return await pause(budget.timeInterruption)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            // The run goes on with what it has; the next boundary tries again
            // once the conversation has grown.
            await emit(.compactionFailed(context, error.localizedDescription))
          }
        }
      }
      if localModelTurns >= request.limits.maxModelTurns {
        return await pause(.modelTurns(limit: request.limits.maxModelTurns))
      }
      if let interruption = await budget.claimModelTurn() {
        return await pause(interruption)
      }
      localModelTurns += 1
      await emit(.modelStarted(context, turn: localModelTurns))
      await supervisor.note(pid, modelTurns: localModelTurns, activity: "thinking")

      // Once the run's tool budget is spent the model gets no tools and is
      // told to answer, instead of the run failing with a limit error.
      let toolBudgetExhausted =
        !definitions.isEmpty
        && (localToolCalls >= request.limits.maxToolCalls || repeatGuardTripped)
      var providerMessages = transcript
      if let instructionsSection {
        insertSystem(instructionsSection, into: &providerMessages)
      }
      if let memorySection, depth == 0 {
        insertSystem(memorySection, into: &providerMessages)
      }
      if textToolMode != nil || toolBudgetExhausted {
        let prompt =
          toolBudgetExhausted
          ? (repeatGuardTripped ? Self.repeatedCallPrompt : Self.toolBudgetExhaustedPrompt)
          : textToolPrompt(definitions, mode: textToolMode ?? .text)
        insertSystem(prompt, into: &providerMessages)
      }
      let offersTools = !usesTextToolProtocol && !toolBudgetExhausted
      let providerRequest = ProviderRequest(
        model: request.model,
        messages: providerMessages,
        tools: offersTools ? definitions : [],
        toolChoice: definitions.isEmpty || !offersTools ? .none : request.toolChoice,
        responseFormat: request.responseFormat,
        options: request.options,
        stream: usesTextToolProtocol ? false : request.stream)
      let call: ProviderCall
      let repairsEmptyReply = localToolCalls > 0 && localModelTurns < request.limits.maxModelTurns
      do {
        call = try await complete(
          providerRequest, with: provider, retry: request.retry, budget: budget,
          context: context, pid: pid, retriesEmptyReply: !repairsEmptyReply, emit: emit
        ) { event in
          if usesTextToolProtocol, case .textDelta = event {
            return
          }
          await emit(.provider(context, event))
        }
      } catch is RunDeadlineExceeded {
        // Time ran out inside the call. The reply is lost, but the transcript
        // is whole, so the pause is as clean as one at the top of the loop.
        return await pause(budget.timeInterruption)
      } catch is ProviderEmptyResponseError where repairsEmptyReply {
        // A model that answers a tool result with nothing at all is told what
        // is expected of it, as after a malformed call; retrying the same
        // request twice and then failing the whole run threw the work away.
        consecutiveEmptyReplies += 1
        if consecutiveEmptyReplies >= Self.maximumEmptyReplies { repeatGuardTripped = true }
        var feedback = AgentToolLoopPolicy.repairFeedbackAfterToolResult(
          mode: textToolMode ?? .native)
        if request.useToolProxy { feedback += "\n" + ToolProxy.repairHint }
        transcript.append(.assistant(feedback))
        await supervisor.note(pid, transcript: transcript)
        continue
      }
      consecutiveEmptyReplies = 0
      var providerResponse = call.response
      try Task.checkCancellation()
      if let usageStats {
        // The user's own words count once, on the turn that carried them;
        // later turns of the same run only resend context.
        let userInputTokens =
          localModelTurns == 1
          ? ModelCallStats.estimatedTokenCount(of: Self.trailingUserMessages(in: request.messages))
          : nil
        await usageStats.record(
          ModelCallStats.measured(
            providerLabel: provider.descriptor.id.rawValue,
            modelID: request.model,
            messages: providerMessages,
            response: providerResponse,
            timing: call.timing,
            end: call.ended,
            userInputTokens: userInputTokens),
          at: call.ended)
      }
      // A provider that reports no usage still spent tokens: they are
      // estimated from text length, and the total says so with a `~`.
      let usage =
        providerResponse.usage
        ?? .estimated(
          inputTokens: ModelCallStats.estimatedTokenCount(of: providerMessages),
          outputTokens: ModelCallStats.estimatedTokenCount(
            forCharacterCount: providerResponse.message.text.count))
      totalUsage = totalUsage.merging(usage)
      lastUsage = providerResponse.usage
      await supervisor.note(pid, usage: totalUsage)
      await budget.record(tokens: usage.totalTokens)

      // A server such as Ollama parses the model's own function-call syntax
      // into native tool calls even when the request offered no tools. Those
      // calls are as good as a text block and run below; reading only the text
      // would mistake the turn for one without a call and repeat the repair
      // feedback until the turn limit.
      // The text protocols offer a `respond` pseudo-tool; a server may hand it
      // back as a native call. It is the final answer, not a host tool.
      if textToolMode != nil, providerResponse.message.toolCalls.count == 1,
        let respond = providerResponse.message.toolCalls.first,
        respond.name == AgentToolLoopPolicy.responseToolName
      {
        let content = respond.arguments.objectValue?["content"]?.coercedStringValue ?? ""
        providerResponse.message = .assistant(content)
        providerResponse.stopReason = .stop
        if !content.isEmpty { await emit(.provider(context, .textDelta(content))) }
      }
      if let textToolMode, !toolBudgetExhausted, providerResponse.message.toolCalls.isEmpty {
        let decision = AgentToolLoopPolicy.evaluate(
          response: providerResponse.message.text,
          tools: definitions,
          mode: textToolMode,
          completedToolRuns: completedToolRuns,
          remainingToolCalls: request.limits.maxToolCalls - localToolCalls)
        switch decision {
        case .final(let text):
          if text != providerResponse.message.text {
            providerResponse.message = replacingText(in: providerResponse.message, with: text)
          }
          if !text.isEmpty { await emit(.provider(context, .textDelta(text))) }
        case .repair(let feedback):
          providerResponse.message = .assistant(feedback)
          transcript.append(providerResponse.message)
          continue
        case .execute(let parsedCalls):
          let calls = parsedCalls.map(toolCall)
          var content = providerResponse.message.content.filter {
            if case .reasoning = $0 { return true }
            return false
          }
          content.append(contentsOf: calls.map(ContentPart.toolCall))
          providerResponse.message.content = content
          providerResponse.stopReason = .toolCall
          for (index, call) in calls.enumerated() {
            await emit(
              .provider(
                context,
                .toolCallDelta(
                  ToolCallDelta(
                    index: index,
                    id: call.id,
                    name: call.name,
                    argumentsFragment: call.arguments.compactJSONString))))
          }
        }
      }
      transcript.append(providerResponse.message)
      await supervisor.note(pid, transcript: transcript)

      let calls = providerResponse.message.toolCalls
      if calls.isEmpty {
        // A message that arrived while the model was answering is not left
        // behind for a run that is about to end: the loop goes round once more
        // so the answer takes it into account. A run out of turns ends anyway
        // and leaves the message queued for its host.
        if localModelTurns < request.limits.maxModelTurns,
          await budget.canClaimModelTurn(),
          await supervisor.hasQueuedMessages(pid)
        {
          continue
        }
        let result = AgentResult(
          runID: context.runID,
          agentID: request.agentID,
          provider: request.provider,
          response: providerResponse.message,
          transcript: transcript,
          usage: totalUsage,
          stopReason: providerResponse.stopReason,
          modelTurns: localModelTurns,
          toolCalls: localToolCalls)
        await emit(.finished(context, result))
        return result
      }

      for call in calls {
        try Task.checkCancellation()
        try await holdWhilePaused(pid)
        let result: ToolResult
        if budget.deadlinePassed {
          // Out of time between two calls: the rest are answered rather than
          // run, so the transcript stays sendable and the pause at the top of
          // the loop is clean.
          await emit(.toolStarted(context, call))
          result = ToolResult(
            callID: call.id,
            text:
              "Error: the run's time limit was reached before this call ran; it was not executed.",
            isError: true)
          await emit(.toolFinished(context, result))
        } else if localToolCalls < request.limits.maxToolCalls, await budget.claimToolCall() {
          localToolCalls += 1
          await supervisor.note(pid, toolCalls: localToolCalls, activity: call.name)
          // Repeating a call is often right — the directory changed, a file
          // was written, a child is being polled — so only a call that keeps
          // coming back with the same arguments is stopped, and never one of
          // the agent tools, which exist to be polled.
          let key = ToolCallKey(call)
          let repeats = repeatedCalls[key, default: 0]
          let pollable = Self.reservedToolNames.contains(Self.canonicalToolName(call.name))
          if pollable || repeats < Self.maximumIdenticalCalls {
            repeatedCalls[key] = repeats + 1
            result = try await execute(
              call,
              definitions: concreteDefinitions,
              request: request,
              context: context,
              modelTurn: localModelTurns,
              depth: depth,
              budget: budget,
              emit: emit)
          } else {
            repeatGuardTripped = true
            await emit(.toolStarted(context, call))
            result = ToolResult(
              callID: call.id,
              text:
                "Error: this exact call has already run \(repeats) times with the same arguments; change them, or answer with what you have.",
              isError: true)
            await emit(.toolFinished(context, result))
          }
        } else {
          result = ToolResult(
            callID: call.id,
            text:
              "Error: the tool call budget for this run (\(request.limits.maxToolCalls)) is exhausted; this call was not executed. Answer with the information already gathered.",
            isError: true)
          await emit(.toolFinished(context, result))
        }
        if !result.isError { completedToolRuns[ToolCallKey(call)] = result.text }
        transcript.append(
          AgentMessage(role: .tool, content: [.toolResult(result)]))
        await supervisor.note(pid, transcript: transcript)
      }
    }
  }

  private struct ProviderCall {
    var response: ProviderResponse
    var timing: StreamTimingObservation
    var ended: Date
  }

  /// One provider call under the run's retry policy and deadline. A failure
  /// that is not a cancellation is repeated after the policy's delay, up to
  /// its attempts, each announced with `retrying`; the deadline cuts a call
  /// short with `RunDeadlineExceeded`. Cancellation passes through untouched.
  private func complete(
    _ providerRequest: ProviderRequest,
    with provider: any ChatProvider,
    retry: AgentRetryPolicy,
    budget: RunBudget,
    context: AgentEventContext,
    pid: AgentPID,
    retriesEmptyReply: Bool = true,
    emit: @escaping AgentEventHandler,
    onEvent: @escaping ProviderEventHandler
  ) async throws -> ProviderCall {
    var attempt = 0
    while true {
      let timing = StreamTimingRecorder()
      do {
        let response = try await withDeadline(budget.deadline) {
          try await provider.complete(providerRequest) { event in
            timing.note(event)
            await onEvent(event)
          }
        }
        return ProviderCall(response: response, timing: timing.observation, ended: Date())
      } catch is CancellationError {
        throw CancellationError()
      } catch is RunDeadlineExceeded {
        throw RunDeadlineExceeded()
      } catch is ProviderEmptyResponseError where !retriesEmptyReply {
        throw ProviderEmptyReply()
      } catch {
        guard attempt < retry.attempts else { throw error }
        attempt += 1
        await emit(
          .retrying(
            context, attempt: attempt, limit: retry.attempts, delaySeconds: retry.delaySeconds,
            error: error.localizedDescription))
        await supervisor.note(pid, activity: "retrying")
        if retry.delaySeconds > 0 {
          try await Task.sleep(for: .seconds(retry.delaySeconds))
        }
        if budget.deadlinePassed { throw RunDeadlineExceeded() }
      }
    }
  }

  /// Asks the run's own model for a summary of the selected messages, with
  /// the configured compaction prompt and the automatic focus.
  private func summarize(
    _ selection: [String],
    of transcript: [AgentMessage],
    provider: any ChatProvider,
    request: AgentRequest,
    budget: RunBudget,
    context: AgentEventContext,
    pid: AgentPID,
    emit: @escaping AgentEventHandler
  ) async throws -> ProviderCall {
    let selected = Set(selection)
    let prompt = AgentCompactionPrompt.render(
      transcript: AgentCompactionPrompt.transcript(of: transcript.filter { selected.contains($0.id) }),
      focus: AgentCompactionPrompt.automaticFocus,
      template: compactionTemplate)
    let call = try await complete(
      ProviderRequest(
        model: request.model,
        messages: [.user(prompt)],
        tools: [],
        toolChoice: .none,
        responseFormat: .text,
        options: request.options,
        stream: false),
      with: provider, retry: request.retry, budget: budget, context: context, pid: pid,
      emit: emit
    ) { _ in }
    if let usageStats {
      await usageStats.record(
        ModelCallStats.measured(
          providerLabel: provider.descriptor.id.rawValue,
          modelID: request.model,
          messages: [.user(prompt)],
          response: call.response,
          timing: call.timing,
          end: call.ended),
        at: call.ended)
    }
    return call
  }

  private enum CompactionError: LocalizedError {
    case emptySummary

    var errorDescription: String? {
      switch self {
      case .emptySummary: "the model returned an empty summary"
      }
    }
  }

  /// Thrown inside a run when `limits.maxSeconds` passes; never leaves the
  /// runtime, which turns it into a paused result.
  private struct RunDeadlineExceeded: Error {}

  /// Runs `body`, or throws `RunDeadlineExceeded` once `deadline` passes and
  /// cancels the body. No deadline runs the body as it is.
  private func withDeadline<T: Sendable>(
    _ deadline: ContinuousClock.Instant?,
    _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    guard let deadline else { return try await body() }
    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await body() }
      group.addTask {
        try await Task.sleep(until: deadline, clock: .continuous)
        throw RunDeadlineExceeded()
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else { throw RunDeadlineExceeded() }
      return first
    }
  }

  private func execute(
    _ call: ToolCall,
    definitions: [ToolDefinition],
    request: AgentRequest,
    context: AgentEventContext,
    modelTurn: Int,
    depth: Int,
    budget: RunBudget,
    emit: @escaping AgentEventHandler
  ) async throws -> ToolResult {
    // A proxied model that names a hidden tool directly still gets it run:
    // the proxy saves tokens, it is not a permission boundary.
    if request.useToolProxy, call.name == ToolProxy.listName {
      await emit(.toolStarted(context, call))
      let result = ToolResult(
        callID: call.id,
        text: ToolProxy.listTools(
          arguments: call.arguments.objectValue ?? [:],
          definitions: ToolProxy.hiddenDefinitions(
            in: definitions, exposing: request.proxyExposedTools)))
      await emit(.toolFinished(context, result))
      return result
    }

    let resolvedCall: ToolCall
    if request.useToolProxy, call.name == ToolProxy.callName {
      let resolved = ToolProxy.resolveCall(
        arguments: call.arguments.objectValue ?? [:], definitions: definitions)
      guard let target = resolved.call else {
        let result = ToolResult(
          callID: call.id,
          text: resolved.error ?? "Error: invalid proxied tool call.",
          isError: true)
        await emit(.toolFinished(context, result))
        return result
      }
      resolvedCall = ToolCall(
        id: call.id, name: target.name, arguments: .object(target.argumentValues))
    } else {
      resolvedCall = call
    }

    // Legacy names resolve to the definition of the tool that replaced them,
    // and a name the provider could not map (text protocols offer no tools, so
    // its resolver is empty) gets the same alias and glued-suffix treatment.
    let definitionName = Self.canonicalToolName(resolvedCall.name)
    let definition =
      definitions.first(where: { $0.name == definitionName })
      ?? AgentToolNameResolver(tools: definitions).canonicalName(for: definitionName)
      .flatMap { canonical in definitions.first(where: { $0.name == canonical }) }
    guard let definition else {
      // A call that never runs is still shown, so the person sees what the
      // model tried rather than an error out of nowhere.
      await emit(.toolStarted(context, resolvedCall))
      let result = ToolResult(
        callID: resolvedCall.id,
        text: "Error: tool '\(resolvedCall.name)' is not available to this agent.",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }
    if definitionName == resolvedCall.name,
      let validationError = ToolSchemaValidator.validate(
        arguments: resolvedCall.arguments,
        definition: definition)
    {
      await emit(.toolStarted(context, resolvedCall))
      let result = ToolResult(
        callID: resolvedCall.id,
        text: "Error: \(validationError).",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }

    let approvedCall: ToolCall
    if definition.annotations.approval == .automatic {
      approvedCall = resolvedCall
    } else {
      let approval = ApprovalRequest(run: context, tool: definition, call: resolvedCall)
      await emit(.approvalRequested(context, approval))
      if let pid = context.pid { await supervisor.raise(.approval(approval), for: pid) }
      let decision: ApprovalDecision
      do {
        decision = try await approvalHandler.decide(approval)
      } catch {
        if let pid = context.pid { await supervisor.clearAttention(for: pid) }
        throw error
      }
      if let pid = context.pid { await supervisor.clearAttention(for: pid) }
      await emit(.approvalDecided(context, decision))
      switch decision {
      case .approve(let arguments):
        approvedCall = ToolCall(
          id: resolvedCall.id, name: resolvedCall.name, arguments: arguments)
      case .deny(let reason):
        let result = ToolResult(
          callID: call.id,
          text: "Error: tool call denied. \(reason)",
          isError: true)
        await emit(.toolFinished(context, result))
        return result
      case .cancelRun:
        throw CancellationError()
      }
    }

    if definitionName == approvedCall.name,
      let validationError = ToolSchemaValidator.validate(
        arguments: approvedCall.arguments,
        definition: definition)
    {
      let result = ToolResult(
        callID: approvedCall.id,
        text: "Error: approved arguments are invalid: \(validationError).",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }
    await emit(.toolStarted(context, approvedCall))
    switch definitionName {
    case Self.agentStartToolName:
      return await startAgent(
        approvedCall,
        legacyName: resolvedCall.name,
        request: request,
        parent: context,
        depth: depth,
        budget: budget,
        emit: emit)
    case Self.agentStatusToolName:
      return await reportAgentStatus(approvedCall, parent: context, emit: emit)
    case Self.agentResultToolName:
      return await collectAgentResult(approvedCall, parent: context, emit: emit)
    case Self.agentStopToolName:
      return await stopAgent(approvedCall, parent: context, emit: emit)
    default:
      break
    }
    guard let tool = tools[approvedCall.name] else {
      let result = ToolResult(
        callID: approvedCall.id,
        text: "Error: tool '\(approvedCall.name)' is not registered.",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }
    do {
      let output = try await tool.call(
        arguments: approvedCall.arguments,
        context: ToolExecutionContext(run: context, modelTurn: modelTurn))
      let result = ToolResult(
        callID: approvedCall.id,
        content: output.content,
        structuredContent: output.structuredContent,
        isError: output.isError)
      await emit(.toolFinished(context, result))
      return result
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let result = ToolResult(
        callID: approvedCall.id,
        text: "Error: \(error.localizedDescription)",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }
  }

  // MARK: - The agent_* tool family

  // The family itself lives in `AgentProcessTools`, shared with hosts that run
  // children through a loop of their own. What stays here is what only the
  // runtime knows: which definition a name resolves to, the derived worker,
  // the run budget, and the events a host follows.

  private func startAgent(
    _ call: ToolCall,
    legacyName: String,
    request: AgentRequest,
    parent: AgentEventContext,
    depth: Int,
    budget: RunBudget,
    emit: @escaping AgentEventHandler
  ) async -> ToolResult {
    let arguments = call.arguments.objectValue ?? [:]
    guard let start = AgentProcessTools.StartArguments(arguments: arguments, toolName: legacyName)
    else {
      return await fail(call, "the brief needs a non-empty 'task'.", parent: parent, emit: emit)
    }

    let definition: AgentDefinition
    if let requestedAgent = start.agent {
      guard request.subagentNames.contains(requestedAgent), var named = agents[requestedAgent],
        named.isEnabled
      else {
        return await fail(
          call, "agent '\(requestedAgent)' is not available to this agent.",
          parent: parent, emit: emit)
      }
      named.toolNames = start.narrowed(named.toolNames)
      definition = named
    } else if request.toolDelegation.delegatesTools {
      definition = derivedWorker(for: request, toolNames: start.narrowed(request.toolNames))
    } else {
      return await fail(
        call,
        "no agent was named. Available agents: "
          + request.subagentNames.sorted().joined(separator: ", ") + ".",
        parent: parent, emit: emit)
    }

    guard request.limits.maxSubagents > 0 else {
      return await fail(
        call, "this agent may not start children (limits.maxSubagents is 0).",
        parent: parent, emit: emit)
    }
    guard await budget.allowsChild(depth: depth + 1) else {
      return await fail(
        call, "the subagent depth limit for this run is reached.",
        parent: parent, emit: emit)
    }

    let prompt = AgentDelegationPrompt.render(
      start.brief,
      agent: definition.id,
      workingDirectory: FileManager.default.currentDirectoryPath,
      template: delegationTemplate)
    let childRequest = self.request(for: definition, messages: [.user(prompt)])
    let childRunID = UUID()
    let childDepth = depth + 1
    // A child past the concurrency limit is not refused: it is registered as
    // queued and starts on its own when a sibling ends, so the model can hand
    // out all the work it has and collect the answers as they come.
    let (childPID, admitted) = await AgentProcessTools.register(
      supervisor: supervisor,
      runID: childRunID,
      parent: parent.pid,
      agentID: definition.id,
      displayName: definition.displayName,
      task: start.brief.headline,
      depth: childDepth,
      limit: request.limits.maxSubagents)
    let childContext = AgentEventContext(
      runID: childRunID,
      parentRunID: parent.runID,
      agentID: definition.id,
      depth: childDepth,
      pid: childPID)
    await emit(
      admitted ? .childStarted(parent, child: childContext) : .childQueued(parent, child: childContext))
    // Every child's events reach the host, background or not, tagged with the
    // child's own context and pid. How they are shown — prefixed, folded into
    // one line, or dropped — is the host's call, not the runtime's. The child
    // runs in a task of its own, so `agent_stop` kills a blocking child the
    // same way it kills a background one.
    let task = Task {
      try await AgentProcessTools.run(
        childPID,
        supervisor: supervisor,
        limit: request.limits.maxSubagents,
        admitted: admitted,
        background: !start.wait,
        queueDeadline: budget.deadline.map {
          AgentProcessTools.QueueDeadline(instant: $0, interruption: budget.timeInterruption)
        },
        onAdmitted: { await emit(.childStarted(parent, child: childContext)) }
      ) {
        try await self.runInternal(
          childRequest,
          runID: childRunID,
          pid: childPID,
          parentRunID: parent.runID,
          depth: childDepth,
          budget: budget,
          emit: emit)
      }
    }
    await supervisor.attach(task, to: childPID)
    let launched = AgentProcessTools.Launch(pid: childPID, task: task, queued: !admitted)

    guard start.wait else {
      let result = AgentProcessTools.startedResult(
        callID: call.id,
        pid: launched.pid,
        agentID: definition.id,
        queued: launched.queued,
        slots: request.limits.maxSubagents)
      await emit(.toolFinished(parent, result))
      return result
    }

    let result: ToolResult
    do {
      let child = try await AgentProcessTools.awaitChild(
        launched.task, pid: launched.pid, supervisor: supervisor)
      await emit(.childFinished(parent, child: child))
      result = AgentProcessTools.childResult(
        callID: call.id, pid: launched.pid, agentID: definition.id, result: child)
    } catch {
      result = AgentProcessTools.childFailure(
        callID: call.id, pid: launched.pid, agentID: definition.id, error: error)
    }
    await emit(.toolFinished(parent, result))
    return result
  }

  private func reportAgentStatus(
    _ call: ToolCall,
    parent: AgentEventContext,
    emit: @escaping AgentEventHandler
  ) async -> ToolResult {
    let result = await AgentProcessTools.status(
      arguments: call.arguments.objectValue ?? [:],
      callID: call.id,
      caller: parent.pid,
      supervisor: supervisor)
    await emit(.toolFinished(parent, result))
    return result
  }

  private func collectAgentResult(
    _ call: ToolCall,
    parent: AgentEventContext,
    emit: @escaping AgentEventHandler
  ) async -> ToolResult {
    let result = await AgentProcessTools.result(
      arguments: call.arguments.objectValue ?? [:],
      callID: call.id,
      caller: parent.pid,
      supervisor: supervisor)
    await emit(.toolFinished(parent, result))
    return result
  }

  private func stopAgent(
    _ call: ToolCall,
    parent: AgentEventContext,
    emit: @escaping AgentEventHandler
  ) async -> ToolResult {
    let result = await AgentProcessTools.stop(
      arguments: call.arguments.objectValue ?? [:],
      callID: call.id,
      caller: parent.pid,
      supervisor: supervisor,
      stoppedBy: parent.agentID)
    await emit(.toolFinished(parent, result))
    return result
  }

  /// The agent MaiCore invents when a delegating agent does not name a child:
  /// same provider and model, the parent's tools, and inline delegation so it
  /// actually runs them. Without it, switching delegation on would leave an
  /// agent with no way to do anything.
  private func derivedWorker(
    for request: AgentRequest,
    toolNames: Set<String>
  ) -> AgentDefinition {
    AgentDefinition(
      id: "\(request.agentID).worker",
      displayName: "\(request.agentID) worker",
      instructions: workerInstructions ?? AgentDelegationPrompt.workerInstructions,
      provider: request.provider,
      model: request.model,
      toolNames: toolNames,
      stream: request.stream,
      limits: request.limits,
      options: request.options,
      toolCallingStrategy: request.toolCallingStrategy,
      useToolProxy: request.useToolProxy,
      proxyExposedTools: request.proxyExposedTools,
      toolDelegation: .inline,
      retry: request.retry,
      autocompact: request.autocompact,
      context: request.context)
  }

  private func fail(
    _ call: ToolCall,
    _ message: String,
    parent: AgentEventContext,
    emit: @escaping AgentEventHandler
  ) async -> ToolResult {
    let result = AgentProcessTools.failure(callID: call.id, message)
    await emit(.toolFinished(parent, result))
    return result
  }

  private func visibleDefinitions(for request: AgentRequest) throws -> [ToolDefinition] {
    for name in request.subagentNames where agents[name] == nil {
      throw AgentRuntimeError.agentNotRegistered(name)
    }
    let mcpToolNames = registeredMCPs.values.reduce(into: Set<String>()) {
      $0.formUnion($1.toolNames)
    }
    let concreteNames = request.toolNames.union(mcpToolNames)
    // A disabled definition stays registered so a host can list it, but it is
    // never offered as a subagent.
    let offeredAgents = request.subagentNames.filter { agents[$0]?.isEnabled == true }
    // What an agent may call is its definition's allow-list, wherever it sits
    // in the tree. Delegation adds a way to hand work to a child that has the
    // same tools; it never takes the tools away. It only takes effect where
    // children are actually permitted.
    let delegating = request.toolDelegation.delegatesTools && request.limits.maxSubagents > 0
    var definitions: [ToolDefinition] = []
    for name in concreteNames.sorted() {
      if let tool = tools[name] { definitions.append(tool.definition) }
    }
    // Raw AgentRequest callers predate tool groups, so nil preserves their
    // behavior. Hosts pass the profile's groups and make this a real per-agent
    // permission; accepting the full name set also honors hand-written files.
    let agentToolsEnabled =
      request.toolGroupNames.map {
        $0.contains(Self.agentToolGroup.id)
          || Self.agentToolNames.isSubset(of: request.toolNames)
      } ?? true
    if agentToolsEnabled, request.limits.maxSubagents > 0,
      delegating || !offeredAgents.isEmpty
    {
      definitions.append(
        contentsOf: agentToolDefinitions(allowedAgentNames: offeredAgents, delegating: delegating))
    }
    return definitions
  }

  private func agentToolDefinitions(
    allowedAgentNames: Set<String>,
    delegating: Bool
  ) -> [ToolDefinition] {
    let offered = allowedAgentNames.map { name -> AgentProcessTools.OfferedAgent in
      guard let agent = agents[name] else { return AgentProcessTools.OfferedAgent(id: name) }
      let purpose =
        agent.description.isEmpty
        ? (agent.displayName == name ? "" : agent.displayName) : agent.description
      return AgentProcessTools.OfferedAgent(id: name, purpose: purpose)
    }
    return AgentProcessTools.definitions(offering: offered, delegating: delegating)
  }

  private func request(
    for definition: AgentDefinition,
    messages: [AgentMessage]
  ) -> AgentRequest {
    var transcript = messages
    let instructions = definition.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    if !instructions.isEmpty {
      transcript.insert(.system(instructions), at: 0)
    }
    return AgentRequest(
      agentID: definition.id,
      provider: definition.provider,
      model: definition.model,
      messages: transcript,
      toolNames: definition.toolNames,
      toolGroupNames: definition.toolGroupNames,
      subagentNames: definition.subagentNames,
      toolChoice: definition.toolChoice,
      responseFormat: definition.responseFormat,
      options: definition.options,
      limits: definition.limits,
      stream: definition.stream,
      toolCallingStrategy: definition.toolCallingStrategy,
      useToolProxy: definition.useToolProxy,
      proxyExposedTools: definition.proxyExposedTools,
      toolDelegation: definition.toolDelegation,
      retry: definition.retry,
      autocompact: definition.autocompact,
      context: definition.context)
  }

  static let toolBudgetExhaustedPrompt =
    "The tool call budget for this run is exhausted and no tools are available anymore. Do not call tools; give the final answer using the information already gathered."
  static let repeatedCallPrompt =
    "The last turns made no progress: the same tool call was repeated with identical arguments, or no reply was produced. No tools are available anymore. Do not call tools; give the final answer using the information already gathered, and say what could not be done."
  /// Empty replies in a row before the tools are withdrawn.
  static let maximumEmptyReplies = 3

  /// Adds a system message after the configured instructions and before the
  /// conversation, so run-scoped context never enters the stored transcript.
  /// The user messages a turn was started with: everything after the last
  /// assistant reply.
  static func trailingUserMessages(in messages: [AgentMessage]) -> [AgentMessage] {
    var trailing: [AgentMessage] = []
    for message in messages.reversed() {
      if message.role == .assistant { break }
      if message.role == .user { trailing.append(message) }
    }
    return trailing
  }

  private func insertSystem(_ prompt: String, into messages: inout [AgentMessage]) {
    let index =
      messages.firstIndex { $0.role != .system && $0.role != .developer }
      ?? messages.endIndex
    messages.insert(.system(prompt), at: index)
  }

  private func textToolPrompt(
    _ definitions: [ToolDefinition],
    mode: ToolCallingMode
  ) -> String {
    "Tools are available through a \(mode.displayName.uppercased()) fallback protocol.\n\n"
      + AgentTooling.promptDescription(
        for: AgentToolLoopPolicy.definitions(includingResponseTool: definitions), mode: mode)
  }

  private func toolCall(_ call: ParsedToolCall) -> ToolCall {
    return ToolCall(
      id: call.toolCallID ?? "text_\(UUID().uuidString)",
      name: call.name,
      arguments: .object(call.argumentValues))
  }

  private func replacingText(in message: AgentMessage, with text: String) -> AgentMessage {
    var message = message
    message.content.removeAll {
      if case .text = $0 { return true }
      if case .toolCall = $0 { return true }
      return false
    }
    if !text.isEmpty { message.content.append(.text(text)) }
    return message
  }
}

extension AgentRuntime {
  /// How often one call may run with exactly the same arguments in one run
  /// before it is refused as a loop.
  static let maximumIdenticalCalls = 3

  fileprivate static let reservedToolNames: Set<String> = AgentProcessTools.reservedToolNames

  /// Maps a retired tool name onto the one that replaced it.
  fileprivate static func canonicalToolName(_ name: String) -> String {
    AgentProcessTools.canonicalName(name)
  }
}

/// Rethrown by the run loop's completion wrapper for an empty model reply it
/// was told not to retry.
struct ProviderEmptyReply: ProviderEmptyResponseError {}

public enum AgentRuntimeError: LocalizedError, Equatable, Sendable {
  case invalidProviderID
  case providerAlreadyRegistered(ProviderID)
  case providerNotRegistered(ProviderID)
  case invalidAgentID
  case agentAlreadyRegistered(String)
  case agentNotRegistered(String)
  case reservedToolName(String)
  case nativeToolCallingUnavailable(ProviderID)
  case limitExceeded(String)

  public var errorDescription: String? {
    switch self {
    case .invalidProviderID:
      "Provider identifiers cannot be empty."
    case .providerAlreadyRegistered(let id):
      "Provider '\(id)' is already registered."
    case .providerNotRegistered(let id):
      "Provider '\(id)' is not registered."
    case .invalidAgentID:
      "Agent identifiers cannot be empty."
    case .agentAlreadyRegistered(let id):
      "Agent '\(id)' is already registered."
    case .agentNotRegistered(let id):
      "Agent '\(id)' is not registered."
    case .reservedToolName(let name):
      "Tool name '\(name)' is reserved by MaiCore."
    case .nativeToolCallingUnavailable(let provider):
      "Provider '\(provider)' does not support native tool calling. Use automatic, text, xml, or json."
    case .limitExceeded(let resource):
      "Agent run exceeded its \(resource) limit."
    }
  }
}

/// What one run and every child it starts share: the turn and token counts
/// against the root's limits, and the deadline. Concurrency of children is
/// the supervisor's business, since background children outlive the run.
private actor RunBudget {
  private let limits: AgentRunLimits
  private var modelTurns = 0
  private var toolCalls = 0
  private var tokens = 0
  /// When `limits.maxSeconds` runs out, fixed at the start of the run.
  nonisolated let deadline: ContinuousClock.Instant?

  init(limits: AgentRunLimits) {
    self.limits = limits
    deadline = limits.maxSeconds.map { ContinuousClock.now + .seconds($0) }
  }

  nonisolated var deadlinePassed: Bool {
    deadline.map { ContinuousClock.now >= $0 } ?? false
  }

  nonisolated var timeInterruption: AgentRunInterruption {
    .time(limitSeconds: limits.maxSeconds ?? 0)
  }

  /// Nil once a turn is claimed; otherwise the limit that stops the run.
  func claimModelTurn() -> AgentRunInterruption? {
    if let interruption = exhausted() { return interruption }
    modelTurns += 1
    return nil
  }

  /// The limit already reached, if any, without claiming anything.
  func exhausted() -> AgentRunInterruption? {
    if deadlinePassed { return timeInterruption }
    if let maximum = limits.maxTotalTokens, tokens >= maximum {
      return .totalTokens(limit: maximum)
    }
    if modelTurns >= limits.maxModelTurns { return .modelTurns(limit: limits.maxModelTurns) }
    return nil
  }

  func canClaimModelTurn() -> Bool {
    exhausted() == nil
  }

  func claimToolCall() -> Bool {
    guard toolCalls < limits.maxToolCalls else { return false }
    toolCalls += 1
    return true
  }

  func allowsChild(depth: Int) -> Bool {
    depth <= limits.maxSubagentDepth
  }

  func record(tokens newTokens: Int) {
    tokens += max(0, newTokens)
  }
}

extension Optional where Wrapped == TokenUsage {
  fileprivate func merging(_ other: TokenUsage?) -> TokenUsage? {
    guard let other else { return self }
    guard let current = self else { return other }
    return TokenUsage(
      inputTokens: current.inputTokens + other.inputTokens,
      outputTokens: current.outputTokens + other.outputTokens,
      totalTokens: current.totalTokens + other.totalTokens,
      cachedTokens: merge(current.cachedTokens, other.cachedTokens),
      reasoningTokens: merge(current.reasoningTokens, other.reasoningTokens),
      isEstimated: current.isEstimated || other.isEstimated)
  }

  private func merge(_ first: Int?, _ second: Int?) -> Int? {
    guard first != nil || second != nil else { return nil }
    return (first ?? 0) + (second ?? 0)
  }
}

extension String {
  fileprivate var nilWhenEmpty: String? { isEmpty ? nil : self }
}
