import Foundation
import MaiCore

/// A conversation as exchanged between the REPL and the visual workspace.
public struct VisualConversationSeed: Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var profile: AgentDefinition
  public var messages: [AgentMessage]
  public var pendingContent: [ContentPart]
  /// The session the chat presents to providers; see `ChatSession`.
  public var sessionID: String

  public init(
    id: UUID = UUID(),
    title: String,
    profile: AgentDefinition,
    messages: [AgentMessage] = [],
    pendingContent: [ContentPart] = [],
    sessionID: String? = nil
  ) {
    self.id = id
    self.title = title
    self.profile = profile
    self.messages = messages
    self.pendingContent = pendingContent
    self.sessionID = sessionID ?? ChatSession.newID()
  }
}

public struct PaneID: Hashable, Sendable, Codable, CustomStringConvertible {
  public let rawValue: Int

  public init(_ rawValue: Int) { self.rawValue = rawValue }
  public var description: String { "pane-\(rawValue)" }
}

public enum SplitAxis: String, Equatable, Sendable, Codable {
  /// Panes placed side by side.
  case horizontal
  /// Panes stacked top to bottom.
  case vertical
}

/// A binary split tree whose leaves show one conversation each.
public indirect enum PaneNode: Equatable, Sendable {
  case leaf(PaneID, conversation: UUID)
  case split(SplitAxis, PaneNode, PaneNode)

  /// Leaves in visual order: left to right, top to bottom.
  public var leaves: [(pane: PaneID, conversation: UUID)] {
    switch self {
    case .leaf(let pane, let conversation): [(pane, conversation)]
    case .split(_, let first, let second): first.leaves + second.leaves
    }
  }

  public var paneIDs: [PaneID] { leaves.map(\.pane) }

  public func contains(_ pane: PaneID) -> Bool { paneIDs.contains(pane) }

  public func conversation(in pane: PaneID) -> UUID? {
    leaves.first { $0.pane == pane }?.conversation
  }

  func replacingLeaf(_ pane: PaneID, with node: PaneNode) -> PaneNode {
    switch self {
    case .leaf(let id, _) where id == pane:
      node
    case .leaf:
      self
    case .split(let axis, let first, let second):
      .split(
        axis,
        first.replacingLeaf(pane, with: node),
        second.replacingLeaf(pane, with: node))
    }
  }

  /// Removes a leaf, collapsing its parent split. Returns nil when this node is
  /// the removed leaf.
  func removingLeaf(_ pane: PaneID) -> PaneNode? {
    switch self {
    case .leaf(let id, _):
      id == pane ? nil : self
    case .split(let axis, let first, let second):
      switch (first.removingLeaf(pane), second.removingLeaf(pane)) {
      case (nil, let remaining?), (let remaining?, nil): remaining
      case (let first?, let second?): .split(axis, first, second)
      case (nil, nil): nil
      }
    }
  }

  func assigning(_ conversation: UUID, to pane: PaneID) -> PaneNode {
    switch self {
    case .leaf(let id, _) where id == pane:
      .leaf(id, conversation: conversation)
    case .leaf:
      self
    case .split(let axis, let first, let second):
      .split(
        axis, first.assigning(conversation, to: pane), second.assigning(conversation, to: pane))
    }
  }

  func replacingConversation(_ old: UUID, with new: UUID) -> PaneNode {
    switch self {
    case .leaf(let id, let conversation):
      .leaf(id, conversation: conversation == old ? new : conversation)
    case .split(let axis, let first, let second):
      .split(
        axis,
        first.replacingConversation(old, with: new),
        second.replacingConversation(old, with: new))
    }
  }
}

/// The pane tree plus the focused pane; every mutation keeps focus valid.
public struct PaneLayout: Equatable, Sendable {
  public private(set) var root: PaneNode
  public private(set) var focusedPane: PaneID
  private var nextPaneID: Int

  public init(conversation: UUID) {
    let first = PaneID(1)
    root = .leaf(first, conversation: conversation)
    focusedPane = first
    nextPaneID = 2
  }

  public var panes: [PaneID] { root.paneIDs }
  public var canCloseFocusedPane: Bool { panes.count > 1 }
  public var focusedConversation: UUID {
    root.conversation(in: focusedPane) ?? root.leaves[0].conversation
  }

  public func conversation(in pane: PaneID) -> UUID? { root.conversation(in: pane) }

  public mutating func focus(_ pane: PaneID) {
    guard root.contains(pane) else { return }
    focusedPane = pane
  }

  public mutating func focusNext() { focus(offset: 1) }
  public mutating func focusPrevious() { focus(offset: -1) }

  private mutating func focus(offset: Int) {
    let panes = panes
    guard panes.count > 1, let index = panes.firstIndex(of: focusedPane) else { return }
    focusedPane = panes[(index + offset + panes.count) % panes.count]
  }

  /// Splits the focused pane; the new pane shows `conversation` and takes focus.
  @discardableResult
  public mutating func split(_ axis: SplitAxis, showing conversation: UUID) -> PaneID {
    let pane = PaneID(nextPaneID)
    nextPaneID += 1
    let existing = root.conversation(in: focusedPane) ?? conversation
    root = root.replacingLeaf(
      focusedPane,
      with: .split(
        axis,
        .leaf(focusedPane, conversation: existing),
        .leaf(pane, conversation: conversation)))
    focusedPane = pane
    return pane
  }

  /// Closes the focused pane and focuses its neighbour. The last pane stays.
  @discardableResult
  public mutating func closeFocusedPane() -> Bool {
    guard canCloseFocusedPane, let index = panes.firstIndex(of: focusedPane),
      let remaining = root.removingLeaf(focusedPane)
    else { return false }
    root = remaining
    let panes = root.paneIDs
    focusedPane = panes[min(index, panes.count - 1)]
    return true
  }

  public mutating func show(_ conversation: UUID, in pane: PaneID) {
    root = root.assigning(conversation, to: pane)
  }

  /// Points every pane showing `old` at `new`, for example after deleting a conversation.
  public mutating func replaceConversation(_ old: UUID, with new: UUID) {
    root = root.replacingConversation(old, with: new)
  }
}

public enum VisualTab: String, CaseIterable, Hashable, Sendable {
  case chats
  case providers
  case mcp
  case tools
  case agents
  case stats

  public var title: String {
    switch self {
    case .chats: "Chats"
    case .providers: "Providers"
    case .mcp: "MCP"
    case .tools: "Tools"
    case .agents: "Agents"
    case .stats: "Stats"
    }
  }
}

/// Everything the workspace needs to resume where a previous visual session stopped.
public struct VisualWorkspaceSnapshot: Equatable, Sendable {
  public var conversations: [VisualConversationSeed]
  public var layout: PaneLayout
  public var selectedTab: VisualTab

  public init(
    conversations: [VisualConversationSeed],
    layout: PaneLayout,
    selectedTab: VisualTab = .chats
  ) {
    self.conversations = conversations
    self.layout = layout
    self.selectedTab = selectedTab
  }
}

/// A slash command typed into a pane, with the state the host needs to run it
/// the way its REPL would.
public struct VisualCommandRequest: Sendable {
  public var input: String
  public var conversation: VisualConversationSeed
  public var configuration: MaiConfiguration
  public var catalogs: [MCPServerCatalog]

  public init(
    input: String,
    conversation: VisualConversationSeed,
    configuration: MaiConfiguration,
    catalogs: [MCPServerCatalog]
  ) {
    self.input = input
    self.conversation = conversation
    self.configuration = configuration
    self.catalogs = catalogs
  }
}

/// What a slash command printed and how it changed the conversation.
public struct VisualCommandOutcome: Sendable {
  public var output: String
  public var conversation: VisualConversationSeed
  /// True for commands such as `/exit` that hand the terminal back to the host.
  public var leavesVisualMode: Bool

  public init(
    output: String,
    conversation: VisualConversationSeed,
    leavesVisualMode: Bool = false
  ) {
    self.output = output
    self.conversation = conversation
    self.leavesVisualMode = leavesVisualMode
  }
}

public typealias VisualCommandHandler =
  @Sendable (VisualCommandRequest) async -> VisualCommandOutcome

public struct VisualLaunch: Sendable {
  /// The REPL's conversation. It replaces the focused conversation of a resumed
  /// snapshot, or becomes the only conversation of a fresh workspace.
  public var focusedConversation: VisualConversationSeed
  public var snapshot: VisualWorkspaceSnapshot?
  public var configuration: MaiConfiguration?
  public var configurationPath: String?
  public var catalogs: [MCPServerCatalog]
  public var environment: [String: String]
  /// Runs `/commands` typed into a pane. Without a handler they are reported as unavailable.
  public var commandHandler: VisualCommandHandler?

  public init(
    focusedConversation: VisualConversationSeed,
    snapshot: VisualWorkspaceSnapshot? = nil,
    configuration: MaiConfiguration? = nil,
    configurationPath: String? = nil,
    catalogs: [MCPServerCatalog] = [],
    environment: [String: String] = [:],
    commandHandler: VisualCommandHandler? = nil
  ) {
    self.focusedConversation = focusedConversation
    self.snapshot = snapshot
    self.configuration = configuration
    self.configurationPath = configurationPath
    self.catalogs = catalogs
    self.environment = environment
    self.commandHandler = commandHandler
  }
}

public struct VisualOutcome: Sendable {
  public var focusedConversation: VisualConversationSeed
  public var snapshot: VisualWorkspaceSnapshot
  public var configuration: MaiConfiguration
  public var configurationChanged: Bool
  public var catalogs: [MCPServerCatalog]
  public var summary: String

  public init(
    focusedConversation: VisualConversationSeed,
    snapshot: VisualWorkspaceSnapshot,
    configuration: MaiConfiguration,
    configurationChanged: Bool,
    catalogs: [MCPServerCatalog],
    summary: String
  ) {
    self.focusedConversation = focusedConversation
    self.snapshot = snapshot
    self.configuration = configuration
    self.configurationChanged = configurationChanged
    self.catalogs = catalogs
    self.summary = summary
  }
}
