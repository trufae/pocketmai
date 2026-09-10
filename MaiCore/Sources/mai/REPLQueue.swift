import Foundation
import MaiCore

/// Who a typed message is for.
enum REPLMessageTarget: Equatable {
  /// The chat's own agent.
  case main
  /// A running agent process, by pid.
  case agent(AgentPID)
}

extension MaiCLI {
  /// `@3 text` (or `@#3`, `@agent#3`) sends one message to a running agent
  /// without changing the focus; `@main text` reaches the chat even while a
  /// child is focused. Anything else is an ordinary message.
  static func addressedMessage(_ text: String) -> (target: REPLMessageTarget, body: String)? {
    guard text.hasPrefix("@") else { return nil }
    let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
    guard parts.count == 2 else { return nil }
    let body = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return nil }
    var address = parts[0].lowercased()
    if ["main", "0", "chat"].contains(address) { return (.main, body) }
    if address.hasPrefix("agent") { address = String(address.dropFirst(5)) }
    guard let pid = AgentPID(text: address) else { return nil }
    return (.agent(pid), body)
  }

  /// A pid typed after a command: `3`, `#3`, `agent#3`, or `main`.
  static func focusTarget(_ text: String) -> REPLMessageTarget? {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if ["main", "chat", "0", "off", "none"].contains(value) { return .main }
    if value.hasPrefix("@") { value = String(value.dropFirst()) }
    if value.hasPrefix("agent") { value = String(value.dropFirst(5)) }
    guard let pid = AgentPID(text: value) else { return nil }
    return .agent(pid)
  }

  /// `/queue` shows and edits the messages waiting for the next model turn of
  /// any agent: `push` adds one without sending it, `pop` drops the newest,
  /// `drop` drops them all. A pid narrows `pop` and `drop` to one agent.
  static func handleQueueCommand(
    _ argument: String,
    focus: REPLMessageTarget,
    main: AgentPID,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
    let action = fields.first?.lowercased() ?? ""
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let supervisor = runtime.supervisor

    switch action {
    case "", "list", "ls":
      let queued = await supervisor.queuedMessages()
      guard !queued.isEmpty else {
        await terminal.line(
          "Nothing is queued. A message typed while a turn runs waits here until the agent's next model turn."
        )
        return
      }
      await terminal.line("Queued messages (\(queued.count)), oldest first:")
      for (index, entry) in queued.enumerated() {
        let info = await supervisor.info(entry.pid)
        let name = info.map { $0.depth == 0 ? "main" : $0.agentID } ?? "?"
        let state = info.map { $0.state.isTerminal ? " (\($0.state.shortLabel))" : "" } ?? ""
        let text = AgentProcessInfo.oneLine(entry.message.text, limit: 100)
        await terminal.line("  \(index + 1). agent#\(entry.pid.rawValue) \(name)\(state)  \(text)")
      }
      await terminal.line(
        "Each is delivered at its agent's next model turn. /queue pop drops the newest, /queue drop drops all."
      )

    case "push", "add":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /queue push [@PID] TEXT")
        return
      }
      let (target, body) = addressedMessage(rest) ?? (focus, rest)
      let pid: AgentPID
      switch target {
      case .main: pid = main
      case .agent(let requested): pid = requested
      }
      guard let info = await supervisor.info(pid) else {
        await terminal.line("No agent #\(pid.rawValue).")
        return
      }
      guard pid == main || !info.state.isTerminal else {
        await terminal.line(
          "agent#\(pid.rawValue) has finished; /agents log \(pid.rawValue) shows what it said.")
        return
      }
      await supervisor.post(.user(body), to: pid)
      let count = await supervisor.queuedMessages(for: pid).count
      await terminal.line(
        "Queued for \(describe(pid, main: main, info: info)) (\(count) waiting). It goes out at the agent's next model turn; /continue submits the chat queue; a new message asks what to do."
      )

    case "pop":
      let pid = rest.isEmpty ? nil : focusTarget(rest).map { $0.pid(main: main) }
      if !rest.isEmpty, pid == nil {
        await terminal.line("Usage: /queue pop [PID]")
        return
      }
      guard let dropped = await supervisor.discardLastQueuedMessage(for: pid) else {
        await terminal.line(pid.map { "Nothing is queued for agent#\($0.rawValue)." } ?? "Nothing is queued.")
        return
      }
      await terminal.line(
        "Dropped from agent#\(dropped.pid.rawValue): \(AgentProcessInfo.oneLine(dropped.message.text, limit: 100))"
      )

    case "drop", "flush", "clear":
      let pid = rest.isEmpty ? nil : focusTarget(rest).map { $0.pid(main: main) }
      if !rest.isEmpty, pid == nil {
        await terminal.line("Usage: /queue drop [PID]")
        return
      }
      let dropped = await supervisor.clearQueuedMessages(for: pid)
      guard !dropped.isEmpty else {
        await terminal.line(pid.map { "Nothing is queued for agent#\($0.rawValue)." } ?? "Nothing is queued.")
        return
      }
      await terminal.line("Dropped \(dropped.count) queued message\(dropped.count == 1 ? "" : "s").")

    default:
      await terminal.line(queueHelp)
    }
  }

  static func describe(_ pid: AgentPID, main: AgentPID, info: AgentProcessInfo?) -> String {
    guard pid != main, let info else { return "this chat (agent#\(pid.rawValue))" }
    return "agent#\(pid.rawValue) (\(info.agentID))"
  }

  static let queueHelp = """
    Queue commands. A message typed while a turn runs is queued and joins the
    conversation at the agent's next model turn — in the middle of its tool
    loop — instead of waiting for the turn to end.

      /queue                 List every queued message and the agent it is for
      /queue push TEXT       Queue TEXT for the focused agent without sending it
      /queue push @PID TEXT  Queue TEXT for one agent
      /queue pop [PID]       Drop the newest queued message (of one agent)
      /queue drop [PID]      Drop every queued message (of one agent)

    Ctrl+C keeps undelivered messages. /continue submits the chat queue.
    If you type a new message with a nonempty queue, choose submit (queue
    first), ignore (keep it for a later turn), or clear (discard it).

    @PID TEXT sends one message to a running agent; /agents focus PID makes it
    the target of everything you type until /agents focus main.
    """
}

extension REPLMessageTarget {
  func pid(main: AgentPID) -> AgentPID {
    switch self {
    case .main: main
    case .agent(let pid): pid
    }
  }
}
