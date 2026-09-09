import Foundation

/// A launch request produced by a widget tap or an App Intent (Action Button /
/// Siri / Shortcuts) and consumed by the app once it comes to the foreground.
enum LaunchCommand: Codable, Equatable, Sendable {
  /// Open a fresh composer. When `text` is present the app sends it straight
  /// away; otherwise it just focuses the composer so the user can type.
  case newPrompt(text: String?)
  /// Open the app directly into voice-conversation mode.
  case voice
  /// Jump to an existing chat, e.g. from a Live Activity or a finished-reply
  /// notification.
  case openConversation(id: UUID)
  /// Import whatever the share extension left in the shared inbox: pictures,
  /// voice messages and documents shared from WhatsApp, Telegram, Files, ...
  case importSharedContent
}

/// Builds and parses the `pocketmai://` deep links used by the home/lock-screen
/// widgets. The scheme is already registered in the app's Info.plist.
enum PocketMaiDeepLink {
  static let scheme = "pocketmai"
  static let promptHost = "prompt"
  static let voiceHost = "voice"
  static let conversationHost = "conversation"
  static let sharedContentHost = "shared"

  static func url(for command: LaunchCommand) -> URL {
    var components = URLComponents()
    components.scheme = scheme
    switch command {
    case .newPrompt(let text):
      components.host = promptHost
      if let text, !text.isEmpty {
        components.queryItems = [URLQueryItem(name: "text", value: text)]
      }
    case .voice:
      components.host = voiceHost
    case .openConversation(let id):
      components.host = conversationHost
      components.path = "/\(id.uuidString)"
    case .importSharedContent:
      components.host = sharedContentHost
    }
    return components.url ?? URL(string: "\(scheme)://\(promptHost)").unsafelyUnwrapped
  }

  static func command(from url: URL) -> LaunchCommand? {
    guard url.scheme == scheme else { return nil }
    switch url.host {
    case promptHost:
      let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "text" })?
        .value
      return .newPrompt(text: text)
    case voiceHost:
      return .voice
    case conversationHost:
      guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
      return .openConversation(id: id)
    case sharedContentHost:
      return .importSharedContent
    default:
      return nil
    }
  }
}
