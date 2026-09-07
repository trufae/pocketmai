import Foundation
import UIKit
import WebKit

/// One in-app WebKit page shared by the browser tools and the
/// picture-in-picture card. Owns the web view so the page, and the cookies
/// behind a login the user completed by hand, survive between tool calls.
///
/// The web view keeps a fixed viewport regardless of how it is shown: the card
/// scales it down, the expanded view shows it 1:1. That keeps the layout, the
/// element refs, and the screenshot coordinates the model works with stable.
@MainActor
final class BrowserSession: NSObject, ObservableObject {
  static let loadTimeout: TimeInterval = 25
  private static let settleDelay: Duration = .milliseconds(350)
  private static let pollInterval: Duration = .milliseconds(150)

  let viewportSize: CGSize
  private(set) var webView: WKWebView!

  @Published private(set) var title = ""
  @Published private(set) var currentURL: URL?
  @Published private(set) var isLoading = false
  @Published private(set) var canGoBack = false
  @Published private(set) var canGoForward = false
  /// The expanded, hand-operated presentation is open.
  @Published var isExpanded = false
  /// What the model last did with the page, shown under the card.
  @Published private(set) var lastActivity = ""

  /// Last navigation failure, reported once by the next tool call.
  private var pendingLoadError: String?
  /// Last `alert()` shown by the page, reported once by the next tool call.
  private var pendingDialogMessage: String?
  private var observations: [NSKeyValueObservation] = []

  init(viewportSize: CGSize) {
    self.viewportSize = viewportSize
    super.init()
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.allowsInlineMediaPlayback = true
    let webView = WKWebView(
      frame: CGRect(origin: .zero, size: viewportSize),
      configuration: configuration)
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    self.webView = webView
    observations = [
      webView.observe(\.title, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.refreshState() }
      },
      webView.observe(\.url, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.refreshState() }
      },
      webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.refreshState() }
      },
      webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.refreshState() }
      },
      webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.refreshState() }
      },
    ]
  }

  func tearDown() {
    observations.removeAll()
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    webView.removeFromSuperview()
  }

  var displayHost: String {
    currentURL?.host ?? (title.isEmpty ? "Browser" : title)
  }

  func noteActivity(_ text: String) {
    let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    lastActivity = collapsed.count > 48 ? String(collapsed.prefix(48)) + "…" : collapsed
  }

  // MARK: - Navigation

  /// Starts loading `url` and returns once the navigation settles or the
  /// timeout passes. The tool reports whatever the page shows at that point.
  func load(_ url: URL) async {
    pendingLoadError = nil
    webView.load(URLRequest(url: url, timeoutInterval: Self.loadTimeout))
    await waitForLoad()
  }

  func load(urlString: String) {
    guard let url = Self.url(from: urlString) else { return }
    Task { await load(url) }
  }

  func goBack() async {
    guard webView.canGoBack else { return }
    webView.goBack()
    await waitForLoad()
  }

  func goForward() {
    guard webView.canGoForward else { return }
    webView.goForward()
  }

  func reload() {
    webView.reload()
  }

  /// A click may start a navigation a tick later, so this first gives the page
  /// a moment, then waits for any load in flight, then lets the DOM settle.
  func waitForLoad(timeout: TimeInterval = loadTimeout) async {
    try? await Task.sleep(for: Self.settleDelay)
    let deadline = Date().addingTimeInterval(timeout)
    while webView.isLoading, Date() < deadline {
      try? await Task.sleep(for: Self.pollInterval)
    }
    try? await Task.sleep(for: Self.settleDelay)
  }

  /// Messages the page produced since the last tool call: a failed load or a
  /// JavaScript alert the user never saw.
  func takePendingNotices() -> [String] {
    var notices: [String] = []
    if let pendingLoadError {
      notices.append("Load error: \(pendingLoadError)")
    }
    if let pendingDialogMessage {
      notices.append("Page alert: \(pendingDialogMessage)")
    }
    pendingLoadError = nil
    pendingDialogMessage = nil
    return notices
  }

  // MARK: - Scripting

  /// Runs `body` as an async function body inside the page with the shared
  /// `__pm` helpers in scope, and returns its result as text.
  func call(_ body: String, arguments: [String: Any] = [:]) async -> String {
    do {
      let result = try await webView.callAsyncJavaScript(
        BrowserPageScript.helpers + "\n" + body,
        arguments: arguments,
        in: nil,
        contentWorld: .page)
      return Self.text(from: result)
    } catch {
      return "Error: JavaScript failed: \(error.localizedDescription)"
    }
  }

  func snapshot() async throws -> UIImage {
    let configuration = WKSnapshotConfiguration()
    configuration.afterScreenUpdates = true
    return try await webView.takeSnapshot(configuration: configuration)
  }

  static func clearWebsiteData() async {
    let store = WKWebsiteDataStore.default()
    await store.removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
      modifiedSince: .distantPast)
  }

  // MARK: - Helpers

  static func url(from text: String) -> URL? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if !trimmed.contains("://") {
      trimmed = "https://" + trimmed
    }
    guard let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = url.host, !host.isEmpty
    else {
      return nil
    }
    return url
  }

  private static func text(from result: Any?) -> String {
    switch result {
    case nil:
      return "null"
    case let string as String:
      return string
    case let number as NSNumber:
      return number.stringValue
    case let value?:
      guard JSONSerialization.isValidJSONObject(value),
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
        let string = String(data: data, encoding: .utf8)
      else {
        return String(describing: value)
      }
      return string
    }
  }

  private func refreshState() {
    title = webView.title ?? ""
    currentURL = webView.url
    isLoading = webView.isLoading
    canGoBack = webView.canGoBack
    canGoForward = webView.canGoForward
  }
}

// MARK: - WKNavigationDelegate

extension BrowserSession: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction
  ) async -> WKNavigationActionPolicy {
    guard let scheme = navigationAction.request.url?.scheme?.lowercased() else { return .cancel }
    // Custom schemes would bounce the user into other apps mid-task.
    return ["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    refreshState()
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    recordLoadError(error)
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    recordLoadError(error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    pendingLoadError = "the page process crashed; reload it"
    refreshState()
  }

  private func recordLoadError(_ error: Error) {
    let nsError = error as NSError
    // Cancelled loads are routine (redirects, a new navigation replacing one).
    guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled),
      !(nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
    else {
      return
    }
    pendingLoadError = error.localizedDescription
    refreshState()
  }
}

// MARK: - WKUIDelegate

extension BrowserSession: WKUIDelegate {
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    // target=_blank links open in the same page; there is only one.
    if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
      webView.load(URLRequest(url: url))
    }
    return nil
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo
  ) async {
    pendingDialogMessage = message
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo
  ) async -> Bool {
    pendingDialogMessage = message
    return true
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?,
    initiatedByFrame frame: WKFrameInfo
  ) async -> String? {
    pendingDialogMessage = prompt
    return defaultText
  }
}
