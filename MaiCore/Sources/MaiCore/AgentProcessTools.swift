import Foundation

/// The `agent_*` tool family — start, status, result, stop — as any host can
/// offer it: the definitions a model sees, the parsing of what it passes, the
/// process bookkeeping around a child run, and the results a parent gets
/// back. The one thing a host brings is how a child actually runs, as a
/// closure that produces an `AgentResult`. `AgentRuntime` runs its children
/// through this; a host with a tool loop of its own, such as PocketMai, runs
/// its children through the same calls and the same `AgentSupervisor`, so an
/// agent behaves the same wherever it is started.
public enum AgentProcessTools {
  public static let startToolName = "agent_start"
  public static let statusToolName = "agent_status"
  public static let resultToolName = "agent_result"
  public static let stopToolName = "agent_stop"
  public static let toolNames: Set<String> = [
    startToolName, statusToolName, resultToolName, stopToolName,
  ]

  /// Earlier spellings of `agent_start`. They are still executed so existing
  /// configurations and fine-tuned providers keep working, but they are no
  /// longer offered: six near-identical tools only confuse a model.
  public static let legacySpawnToolName = "spawn_agent"
  public static let legacyLaunchToolName = "agent_launch"
  public static let legacyStartToolNames: Set<String> = [
    legacySpawnToolName, legacyLaunchToolName,
  ]
  /// Every name the family answers to, so a host never registers a tool
  /// under one of them.
  public static let reservedToolNames: Set<String> = toolNames.union(legacyStartToolNames)

  /// Maps a retired tool name onto the one that replaced it.
  public static func canonicalName(_ name: String) -> String {
    legacyStartToolNames.contains(name) ? startToolName : name
  }

  public static func isAgentTool(_ name: String) -> Bool {
    reservedToolNames.contains(name)
  }

  /// How many transcript messages `agent_status` returns for `log: true`.
  public static let defaultLogMessages = 20
  static let maximumLogMessages = 200
  static let logMessageLength = 2000

  // MARK: - Definitions

  /// An agent a parent may name in `agent_start`.
  public struct OfferedAgent: Equatable, Sendable {
    public var id: String
    /// What it is for, shown next to its name; empty shows the name alone.
    public var purpose: String

    public init(id: String, purpose: String = "") {
      self.id = id
      self.purpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  /// The four definitions, worded for what this parent may do: name one of
  /// `agents`, run a worker with its own tools when `delegating`, or both.
  public static func definitions(
    offering agents: [OfferedAgent],
    delegating: Bool
  ) -> [ToolDefinition] {
    let offered = agents.sorted { $0.id < $1.id }
    var startProperties: [String: JSONValue] = [
      "context": .object([
        "type": .string("string"),
        "description": .string(
          "What it cannot discover on its own: facts, decisions, and paths already found. It cannot see this conversation."
        ),
      ]),
      "task": .object([
        "type": .string("string"),
        "description": .string("The single thing to do."),
      ]),
      "output": .object([
        "type": .string("string"),
        "description": .string(
          "What to return and in what shape, for example \"file paths, one per line, no prose\"."
        ),
      ]),
      "wait": .object([
        "type": .string("boolean"),
        "description": .string(
          "Wait for the answer (default); false returns a pid to collect with \(resultToolName)."
        ),
      ]),
      "tools": .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string("Subset of the agent's tools to allow."),
      ]),
    ]
    if !offered.isEmpty {
      let described = offered.map { agent in
        agent.purpose.isEmpty ? agent.id : "\(agent.id) — \(agent.purpose)"
      }
      startProperties["agent"] = .object([
        "type": .string("string"),
        "enum": .array(offered.map { .string($0.id) }),
        "description": .string(
          "Which agent to run. \(described.joined(separator: "; "))."
            + (delegating ? " Omit to use a general worker with your own tools." : "")),
      ])
    }

    let names = offered.map(\.id)
    let startDescription =
      delegating
      ? "Run a task in a child agent with your tools; only its answer enters this conversation. Use it for work with bulky tool output, not for small calls."
      : "Run one task in a child agent with a transcript of its own; only its answer comes back. Agents: \(names.joined(separator: ", "))."

    return [
      ToolDefinition(
        name: startToolName,
        description: startDescription,
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object(startProperties),
          "required": .array([.string("task"), .string("output")]),
          "additionalProperties": .bool(false),
        ]),
        annotations: ToolAnnotations(
          readOnly: false,
          destructive: false,
          idempotent: false,
          openWorld: true,
          approval: .confirm)),
      ToolDefinition(
        name: statusToolName,
        description:
          "List your child agents and their state, one line each, pid first (#2). With pid and log, read that agent's transcript.",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "pid": .object([
              "type": .string("string"),
              "description": .string("An agent's pid, the number after # (2 for '#2 main.worker')."),
            ]),
            "tree": .object([
              "type": .string("boolean"),
              "description": .string("Include grandchildren."),
            ]),
            "log": .object([
              "type": .string("integer"),
              "description": .string(
                "With pid: also return the last N messages of its transcript (1-200)."),
            ]),
          ]),
          "additionalProperties": .bool(false),
        ]),
        annotations: ToolAnnotations(
          readOnly: true,
          destructive: false,
          idempotent: true,
          openWorld: false,
          approval: .automatic)),
      ToolDefinition(
        name: resultToolName,
        description:
          "Take the answer of a child started with wait false, by pid; waits for it unless wait is false. A failed child returns its error and the end of its transcript.",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "pid": .object([
              "type": .string("string"),
              "description": .string("The pid returned by \(startToolName)."),
            ]),
            "wait": .object([
              "type": .string("boolean"),
              "description": .string("Block until it finishes (default true)."),
            ]),
          ]),
          "required": .array([.string("pid")]),
          "additionalProperties": .bool(false),
        ]),
        annotations: ToolAnnotations(
          readOnly: true,
          destructive: false,
          idempotent: false,
          openWorld: false,
          approval: .automatic)),
      ToolDefinition(
        name: stopToolName,
        description:
          "Stop a child agent and everything it started.",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "pid": .object([
              "type": .string("string"),
              "description": .string("The pid to stop."),
            ]),
            "reason": .object([
              "type": .string("string"),
              "description": .string("Why, for the log."),
            ]),
          ]),
          "required": .array([.string("pid")]),
          "additionalProperties": .bool(false),
        ]),
        annotations: ToolAnnotations(
          readOnly: false,
          destructive: false,
          idempotent: true,
          openWorld: false,
          approval: .automatic)),
    ]
  }

  // MARK: - agent_start

  /// What a model passed to `agent_start`, parsed once. `spawn_agent` took
  /// `task` and `agent_launch` took `prompt`; both become the task half of a
  /// brief with no context and no output contract.
  public struct StartArguments: Equatable, Sendable {
    public var brief: AgentTaskBrief
    /// The agent named, trimmed; nil or empty asks for a derived worker.
    public var agent: String?
    /// The subset of tools asked for, when any.
    public var tools: Set<String>?
    /// Whether the parent waits for the answer. `agent_launch` was always
    /// asynchronous; the others wait unless told not to.
    public var wait: Bool

    public init(brief: AgentTaskBrief, agent: String? = nil, tools: Set<String>? = nil, wait: Bool) {
      self.brief = brief
      self.agent = agent
      self.tools = tools
      self.wait = wait
    }

    /// Nil when there is no task to hand out.
    public init?(arguments: [String: JSONValue], toolName: String = startToolName) {
      let brief =
        AgentTaskBrief(arguments: arguments)
        ?? (arguments["prompt"]?.stringValue).map { AgentTaskBrief(task: $0) }
      guard let brief else { return nil }
      let agent = arguments["agent"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
      self.init(
        brief: brief,
        agent: agent?.isEmpty == false ? agent : nil,
        tools: arguments["tools"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) },
        wait: arguments["wait"]?.coercedBoolValue ?? (toolName != legacyLaunchToolName))
    }

    /// `toolNames` narrowed to what was asked for, when the two overlap; a
    /// request that names none of them keeps the full set.
    public func narrowed(_ toolNames: Set<String>) -> Set<String> {
      guard let tools else { return toolNames }
      let allowed = toolNames.intersection(tools)
      return allowed.isEmpty ? toolNames : allowed
    }
  }

  /// A child registered and started: its pid, the task running it, and
  /// whether it is waiting for a subagent slot rather than running.
  public struct Launch: Sendable {
    public var pid: AgentPID
    public var task: Task<AgentResult, Error>
    public var queued: Bool

    public init(pid: AgentPID, task: Task<AgentResult, Error>, queued: Bool) {
      self.pid = pid
      self.task = task
      self.queued = queued
    }
  }

  /// When a queued child stops waiting for a slot: the instant its run's
  /// time limit passes, and the limit to report when it does.
  public struct QueueDeadline: Sendable {
    public var instant: ContinuousClock.Instant
    public var interruption: AgentRunInterruption

    public init(instant: ContinuousClock.Instant, interruption: AgentRunInterruption) {
      self.instant = instant
      self.interruption = interruption
    }
  }

  private struct QueueDeadlineExceeded: Error {
    let message: String
  }

  /// Registers a child under `parent` and settles whether it runs now: a
  /// child past the concurrency limit is not refused, it is registered as
  /// queued and `run` starts it on its own when a sibling ends, so a model
  /// can hand out all the work it has and collect the answers as they come.
  public static func register(
    supervisor: AgentSupervisor,
    runID: UUID = UUID(),
    parent: AgentPID?,
    agentID: String,
    displayName: String? = nil,
    task: String,
    depth: Int,
    limit: Int
  ) async -> (pid: AgentPID, admitted: Bool) {
    let pid = await supervisor.register(
      runID: runID,
      parent: parent,
      agentID: agentID,
      displayName: displayName,
      task: task,
      depth: depth)
    // Whether the child runs now or waits is settled here, so the tool result
    // the parent gets says which.
    let admitted = await supervisor.admit(pid, limit: limit)
    return (pid, admitted)
  }

  /// The body of a child's task: waits for a slot when the child was not
  /// admitted, runs `body`, and tells the supervisor how the run ended,
  /// asking for attention when `background`. A host wraps this in a task of
  /// its own — so the child runs where the host wants it to — and attaches
  /// that task with `AgentSupervisor.attach`, so stopping the child through
  /// the supervisor ends it whether or not the parent is waiting.
  /// `onAdmitted` runs when a queued child gets its slot.
  public static func run(
    _ pid: AgentPID,
    supervisor: AgentSupervisor,
    limit: Int,
    admitted: Bool,
    background: Bool,
    queueDeadline: QueueDeadline? = nil,
    onAdmitted: @escaping @Sendable () async -> Void = {},
    body: @escaping @Sendable () async throws -> AgentResult
  ) async throws -> AgentResult {
    do {
      if !admitted {
        try await awaitSlot(pid, supervisor: supervisor, limit: limit, deadline: queueDeadline)
        await onAdmitted()
      }
      let child = try await body()
      // A body that answered after it was stopped is recorded as stopped:
      // the supervisor already told everyone why it ended.
      try Task.checkCancellation()
      await supervisor.finish(pid, result: child, announce: background)
      return child
    } catch is CancellationError {
      await supervisor.fail(pid, state: .cancelled, message: "Cancelled", announce: background)
      throw CancellationError()
    } catch let deadline as QueueDeadlineExceeded {
      await supervisor.fail(
        pid, state: .interrupted, message: deadline.message, announce: background)
      throw AgentRuntimeError.limitExceeded("time")
    } catch {
      await supervisor.fail(
        pid, state: .failed, message: error.localizedDescription, announce: background)
      throw error
    }
  }

  /// `register`, a task running `run`, and `attach` in one call, for a host
  /// that does not mind where the child's task runs. `announce` is called
  /// once the slot question is settled, with whether the child is running,
  /// and again with `true` when a queued child gets its slot.
  public static func launch(
    supervisor: AgentSupervisor,
    runID: UUID = UUID(),
    parent: AgentPID?,
    agentID: String,
    displayName: String? = nil,
    task: String,
    depth: Int,
    limit: Int,
    background: Bool,
    queueDeadline: QueueDeadline? = nil,
    announce: @escaping @Sendable (_ pid: AgentPID, _ admitted: Bool) async -> Void = { _, _ in },
    body: @escaping @Sendable (_ pid: AgentPID) async throws -> AgentResult
  ) async -> Launch {
    let (pid, admitted) = await register(
      supervisor: supervisor,
      runID: runID,
      parent: parent,
      agentID: agentID,
      displayName: displayName,
      task: task,
      depth: depth,
      limit: limit)
    await announce(pid, admitted)
    let handle = Task {
      try await run(
        pid,
        supervisor: supervisor,
        limit: limit,
        admitted: admitted,
        background: background,
        queueDeadline: queueDeadline,
        onAdmitted: { await announce(pid, true) }
      ) {
        try await body(pid)
      }
    }
    await supervisor.attach(handle, to: pid)
    return Launch(pid: pid, task: handle, queued: !admitted)
  }

  /// Where a queued child waits for a subagent slot, in its own task: it asks
  /// the supervisor again every 100ms until it is admitted, so stopping it
  /// ends the wait like any other cancellation, and a run's deadline applies
  /// to time spent waiting as well.
  private static func awaitSlot(
    _ pid: AgentPID,
    supervisor: AgentSupervisor,
    limit: Int,
    deadline: QueueDeadline?
  ) async throws {
    while !(await supervisor.admit(pid, limit: limit)) {
      if let deadline, ContinuousClock.now >= deadline.instant {
        throw QueueDeadlineExceeded(message: "\(deadline.interruption.summary) while queued")
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  /// Waits for a child and marks its answer as taken, the way `agent_start`
  /// with `wait` does. Cancelling the caller cancels the child.
  public static func awaitChild(
    _ task: Task<AgentResult, Error>,
    pid: AgentPID,
    supervisor: AgentSupervisor
  ) async throws -> AgentResult {
    let child = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    await supervisor.collect(pid)
    return child
  }

  /// What `agent_start` answers when the parent does not wait: the pid to
  /// poll and collect, and whether the child is running or queued behind
  /// `slots` busy siblings.
  public static func startedResult(
    callID: String,
    pid: AgentPID,
    agentID: String,
    queued: Bool,
    slots: Int
  ) -> ToolResult {
    let text =
      queued
      ? "Queued \(agentID) as \(pid): all \(slots) subagent slot\(slots == 1 ? " is" : "s are") busy, so it starts when one frees up. Poll \(statusToolName), then \(resultToolName) with pid \"\(pid.rawValue)\"."
      : "Started \(agentID) as \(pid). Poll \(statusToolName), then \(resultToolName) with pid \"\(pid.rawValue)\"."
    return ToolResult(
      callID: callID,
      content: [.text(text)],
      structuredContent: .object([
        "pid": .string(String(pid.rawValue)),
        "agent": .string(agentID),
        "status": .string(queued ? "queued" : "running"),
      ]))
  }

  /// The tool result a parent gets for a child that ended. A child a limit
  /// paused before it answered comes back as an error carrying whatever it
  /// said last, so the parent can decide whether to start it again with a
  /// narrower brief.
  public static func childResult(
    callID: String,
    pid: AgentPID,
    agentID: String,
    result child: AgentResult
  ) -> ToolResult {
    let summary = childSummary(pid, agentID: agentID, result: child)
    guard let interruption = child.interruption else {
      return ToolResult(callID: callID, content: childAnswer(child), structuredContent: summary)
    }
    var text = "Error: agent '\(agentID)' \(pid) stopped before answering: \(interruption.summary)."
    let last = child.response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !last.isEmpty { text += "\nIts last message:\n\(last)" }
    return ToolResult(
      callID: callID, content: [.text(text)], structuredContent: summary, isError: true)
  }

  /// The error a waiting `agent_start` answers with when its child did not
  /// end with a result.
  public static func childFailure(
    callID: String,
    pid: AgentPID,
    agentID: String,
    error: Error
  ) -> ToolResult {
    if error is CancellationError {
      return failure(callID: callID, "agent '\(agentID)' \(pid) was cancelled.")
    }
    return failure(
      callID: callID, "agent '\(agentID)' \(pid) failed: \(error.localizedDescription)")
  }

  /// `Error: <message>`, the shape every refused agent call takes.
  public static func failure(callID: String, _ message: String) -> ToolResult {
    ToolResult(callID: callID, text: "Error: \(message)", isError: true)
  }

  /// Only the child's answer travels back: its tool traffic and reasoning stay
  /// in the transcript that is about to be discarded.
  private static func childAnswer(_ child: AgentResult) -> [ContentPart] {
    let content = child.response.content.filter { part in
      switch part {
      case .toolCall, .toolResult, .reasoning: false
      default: true
      }
    }
    return content.isEmpty ? [.text(child.response.text)] : content
  }

  private static func childSummary(
    _ pid: AgentPID,
    agentID: String,
    result: AgentResult
  ) -> JSONValue {
    var value: [String: JSONValue] = [
      "pid": .string(String(pid.rawValue)),
      "agent": .string(agentID),
      "status": .string(result.interruption == nil ? "completed" : "interrupted"),
      "turns": .integer(result.modelTurns),
      "tools": .integer(result.toolCalls),
    ]
    if let tokens = result.usage?.totalTokens { value["tokens"] = .integer(tokens) }
    if let interruption = result.interruption { value["error"] = .string(interruption.summary) }
    return .object(value)
  }

  // MARK: - agent_status

  /// Lists the caller's children — its whole subtree with `tree` — or, with
  /// a pid, one of them, optionally with the end of its transcript.
  public static func status(
    arguments: [String: JSONValue],
    callID: String,
    caller: AgentPID?,
    supervisor: AgentSupervisor
  ) async -> ToolResult {
    let tree = await supervisor.tree()
    guard let caller else {
      return failure(callID: callID, "this run has no process table.")
    }
    let rawPID = arguments["pid"]?.coercedStringValue ?? arguments["id"]?.coercedStringValue ?? ""
    let listed: [AgentProcessInfo]
    var structured: [String: JSONValue] = [:]
    var text: String
    if rawPID.isEmpty {
      let wholeTree = arguments["tree"]?.coercedBoolValue ?? false
      let descendants = Array(tree.subtree(of: caller).dropFirst())
      listed = wholeTree ? descendants : descendants.filter { $0.parent == caller }
      text = listed.isEmpty ? "No child agents." : listed.map(\.summaryLine).joined(separator: "\n")
      if !listed.isEmpty {
        text += "\nThe number after # is the pid the agent_* tools take."
      }
    } else {
      let pid: AgentPID
      switch childPID(rawPID, of: caller, in: tree) {
      case .success(let found): pid = found
      case .failure(let error): return failure(callID: callID, error.message)
      }
      guard let info = tree.info(pid) else {
        return failure(callID: callID, "agent \(pid) is not one of yours.")
      }
      listed = [info]
      text = info.summaryLine
      if let count = logCount(arguments["log"]) {
        let excerpt = await transcriptExcerpt(pid, last: count, supervisor: supervisor)
        text += "\n" + excerpt.text
        structured["transcript"] = excerpt.json
      }
    }
    structured["agents"] = .array(listed.map { processJSON($0) })
    structured["count"] = .integer(listed.count)
    return ToolResult(
      callID: callID,
      content: [.text(text)],
      structuredContent: .object(structured))
  }

  /// How many transcript messages a `log` argument asks for; nil for none.
  private static func logCount(_ value: JSONValue?) -> Int? {
    guard let value else { return nil }
    if let number = value.coercedNumberValue, number >= 1 {
      return min(Int(number), maximumLogMessages)
    }
    return value.coercedBoolValue == true ? defaultLogMessages : nil
  }

  /// The end of an agent's transcript, numbered as the whole of it is, in the
  /// pasteable form hosts print; long messages are clipped.
  public static func transcriptExcerpt(
    _ pid: AgentPID,
    last count: Int,
    supervisor: AgentSupervisor
  ) async -> (text: String, json: JSONValue) {
    let messages = await supervisor.transcript(pid)
    guard !messages.isEmpty else {
      return ("Transcript of \(pid): nothing yet.", .array([]))
    }
    let start = max(0, messages.count - count)
    var lines = [
      messages.count > count
        ? "Transcript of \(pid), last \(count) of \(messages.count) messages:"
        : "Transcript of \(pid), \(messages.count) message\(messages.count == 1 ? "" : "s"):"
    ]
    var rows: [JSONValue] = []
    for (offset, message) in messages[start...].enumerated() {
      let index = start + offset + 1
      var rendered = TranscriptCopy.render(message)
      if rendered.count > logMessageLength {
        rendered = String(rendered.prefix(logMessageLength)) + "…"
      }
      lines.append("[\(index)] \(message.role.rawValue): \(rendered)")
      rows.append(
        .object([
          "index": .integer(index), "role": .string(message.role.rawValue),
          "text": .string(rendered),
        ]))
    }
    return (lines.joined(separator: "\n"), .array(rows))
  }

  /// One process as `agent_status` reports it.
  public static func processJSON(_ info: AgentProcessInfo) -> JSONValue {
    var value: [String: JSONValue] = [
      "pid": .string(String(info.pid.rawValue)),
      "agent": .string(info.agentID),
      "status": .string(info.state.rawValue),
      "turns": .integer(info.modelTurns),
      "tools": .integer(info.toolCalls),
    ]
    if let tokens = info.usage?.totalTokens { value["tokens"] = .integer(tokens) }
    if let failure = info.failure { value["error"] = .string(failure) }
    if let attention = info.attention { value["attention"] = .string(attention.summary) }
    return .object(value)
  }

  private struct ChildLookupError: Error {
    let message: String
  }

  /// The child a tool call names. A name such as `main.worker` is explained
  /// rather than rejected, since that is what a model tends to pass.
  private static func childPID(
    _ rawPID: String,
    of caller: AgentPID?,
    in tree: AgentProcessTree
  ) -> Result<AgentPID, ChildLookupError> {
    guard let pid = AgentPID(text: rawPID) else {
      return .failure(
        ChildLookupError(
          message:
            "'\(rawPID)' is not a pid. Pass the number \(statusToolName) shows after # (2 for '#2 main.worker'); agent names are not identifiers."
        ))
    }
    guard let caller, tree.isDescendant(pid, of: caller) else {
      return .failure(ChildLookupError(message: "agent \(pid) is not one of yours."))
    }
    return .success(pid)
  }

  // MARK: - agent_result

  /// Takes a child's answer by pid, waiting for it unless `wait` is false.
  /// A child that ended without a result answers with its error and the end
  /// of its transcript.
  public static func result(
    arguments: [String: JSONValue],
    callID: String,
    caller: AgentPID?,
    supervisor: AgentSupervisor
  ) async -> ToolResult {
    let rawPID = arguments["pid"]?.coercedStringValue ?? arguments["id"]?.coercedStringValue ?? ""
    let pid: AgentPID
    switch childPID(rawPID, of: caller, in: await supervisor.tree()) {
    case .success(let found): pid = found
    case .failure(let error): return failure(callID: callID, error.message)
    }
    let wait = arguments["wait"]?.coercedBoolValue ?? true

    if let finished = await supervisor.result(pid) {
      await supervisor.collect(pid)
      return childResult(callID: callID, pid: pid, agentID: finished.agentID, result: finished)
    }
    guard let handle = await supervisor.handle(pid) else {
      let info = await supervisor.info(pid)
      let reason = info?.failure ?? "it produced no result"
      var message = "agent \(pid) is not available: \(reason)."
      if !(await supervisor.transcript(pid)).isEmpty {
        let excerpt = await transcriptExcerpt(pid, last: 6, supervisor: supervisor)
        message += "\n" + excerpt.text
        message += "\n\(statusToolName) with pid \(pid.rawValue) and log reads more."
      }
      return failure(callID: callID, message)
    }
    guard wait else {
      let info = await supervisor.info(pid)
      return ToolResult(
        callID: callID,
        content: [.text(info?.summaryLine ?? "\(pid) is still running.")],
        structuredContent: info.map { processJSON($0) })
    }
    do {
      let child = try await awaitChild(handle, pid: pid, supervisor: supervisor)
      return childResult(callID: callID, pid: pid, agentID: child.agentID, result: child)
    } catch is CancellationError {
      return failure(callID: callID, "agent \(pid) was cancelled.")
    } catch {
      return failure(callID: callID, "agent \(pid) failed: \(error.localizedDescription)")
    }
  }

  // MARK: - agent_stop

  /// Stops one of the caller's children and everything under it.
  public static func stop(
    arguments: [String: JSONValue],
    callID: String,
    caller: AgentPID?,
    supervisor: AgentSupervisor,
    stoppedBy: String
  ) async -> ToolResult {
    let rawPID = arguments["pid"]?.coercedStringValue ?? arguments["id"]?.coercedStringValue ?? ""
    let reason = arguments["reason"]?.stringValue ?? "Stopped by \(stoppedBy)"
    let pid: AgentPID
    switch childPID(rawPID, of: caller, in: await supervisor.tree()) {
    case .success(let found): pid = found
    case .failure(let error): return failure(callID: callID, error.message)
    }
    let stopped = await supervisor.stop(pid, reason: reason)
    return ToolResult(
      callID: callID,
      content: [
        .text("Stopped \(stopped.map(\.description).joined(separator: ", ")).")
      ],
      structuredContent: .object([
        "stopped": .array(stopped.map { .string(String($0.rawValue)) })
      ]))
  }
}
