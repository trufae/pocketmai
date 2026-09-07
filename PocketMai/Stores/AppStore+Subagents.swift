import Foundation
import MaiCore

/// The app's side of the agent process table: which process a conversation
/// runs as, what its children are doing, and the controls the chat offers
/// over them. Processes are session state, like pmai's; nothing here is
/// saved.
extension AppStore {
  /// Mirrors the supervisor's table into `agentProcesses` as it changes, so
  /// views follow children without polling.
  func startAgentSupervisorFeed() {
    Task { [weak self] in
      guard let self else { return }
      let events = await agentSupervisor.events()
      for await _ in events {
        await refreshAgentProcesses()
      }
    }
  }

  func refreshAgentProcesses() async {
    let processes = await agentSupervisor.processes()
    if processes != agentProcesses {
      agentProcesses = processes
    }
  }

  // MARK: - Conversation processes

  /// The process a conversation's turns run as, registered the first time an
  /// agent tool asks for it. Children hang off it, and `agent_status` lists
  /// them from it.
  func agentProcessID(for conversation: Conversation, agentName: String) async -> AgentPID {
    if let pid = agentProcessIDs[conversation.id], await agentSupervisor.info(pid) != nil {
      return pid
    }
    let pid = await agentSupervisor.register(
      runID: UUID(),
      parent: nil,
      agentID: agentName,
      displayName: agentName,
      task: conversation.displayTitle,
      depth: 0)
    agentProcessIDs[conversation.id] = pid
    return pid
  }

  func registerAgentProcess(_ pid: AgentPID, for conversationID: UUID) {
    agentProcessIDs[conversationID] = pid
  }

  func forgetAgentProcess(for conversationID: UUID) {
    agentProcessIDs[conversationID] = nil
  }

  /// Puts a conversation's process back to work for a new turn, keeping the
  /// children earlier turns started.
  func reopenAgentProcess(for conversationID: UUID) {
    guard let pid = agentProcessIDs[conversationID] else { return }
    let task = conversation(withID: conversationID)?.displayTitle ?? ""
    Task {
      if await !agentSupervisor.reopen(pid, runID: UUID(), task: task) {
        agentProcessIDs[conversationID] = nil
      }
    }
  }

  /// Marks a conversation's process idle at the end of a turn. Background
  /// children carry on; the next turn can still collect them.
  func completeAgentProcess(for conversationID: UUID) {
    guard let pid = agentProcessIDs[conversationID] else { return }
    Task { await agentSupervisor.complete(pid) }
  }

  /// Kills everything a conversation started, for a chat that is going away.
  func stopAgentProcesses(for conversationID: UUID, reason: String = "Chat closed") {
    guard let pid = agentProcessIDs.removeValue(forKey: conversationID) else { return }
    Task {
      let stopped = await agentSupervisor.stop(pid, reason: reason)
      for victim in stopped.reversed() {
        await agentSupervisor.forget(victim)
      }
      await refreshAgentProcesses()
    }
  }

  func stopAllAgentProcesses(reason: String = "Chats cleared") {
    for conversationID in Array(agentProcessIDs.keys) {
      stopAgentProcesses(for: conversationID, reason: reason)
    }
  }

  // MARK: - What the chat shows

  /// The children of a conversation, parents before their own children, in
  /// the order they were started.
  func agentChildren(of conversationID: UUID?) -> [AgentProcessInfo] {
    guard let conversationID, let root = agentProcessIDs[conversationID] else { return [] }
    return Array(AgentProcessTree(agentProcesses).subtree(of: root).dropFirst())
  }

  func hasLiveAgentChildren(in conversationID: UUID?) -> Bool {
    agentChildren(of: conversationID).contains { !$0.state.isTerminal }
  }

  func agentTranscript(_ pid: AgentPID) async -> [AgentMessage] {
    await agentSupervisor.transcript(pid)
  }

  // MARK: - Controls

  func stopAgentProcess(_ pid: AgentPID) {
    Task { await agentSupervisor.stop(pid, reason: "Stopped from the chat") }
  }

  func pauseAgentProcess(_ pid: AgentPID) {
    Task { await agentSupervisor.pause(pid) }
  }

  func resumeAgentProcess(_ pid: AgentPID) {
    Task { await agentSupervisor.resume(pid) }
  }

  /// Queues a message a running child reads before its next model turn.
  func sendMessageToAgentProcess(_ pid: AgentPID, text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    Task { await agentSupervisor.post(.user(trimmed), to: pid) }
  }

  /// Forgets the finished children of a conversation, so its process list
  /// shows only what is running.
  func clearFinishedAgentProcesses(in conversationID: UUID?) {
    let tree = AgentProcessTree(agentProcesses)
    // A finished child whose background children still run stays listed
    // with them, so nothing is orphaned.
    let finished = agentChildren(of: conversationID).filter { child in
      tree.subtree(of: child.pid).allSatisfy(\.state.isTerminal)
    }
    guard !finished.isEmpty else { return }
    Task {
      for process in finished.reversed() {
        await agentSupervisor.forget(process.pid)
      }
      await refreshAgentProcesses()
    }
  }
}
