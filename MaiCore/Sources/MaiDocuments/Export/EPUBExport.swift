import Foundation
import MaiMarkdown

/// Writes an EPUB 3 book: a title page, then one chapter per entry, with
/// markdown rendered to XHTML and images packaged alongside.
public enum EPUBExport {
  public static func data(for document: ExportDocument) -> Data {
    let summary = document.summary
    let catalog = ExportImageCatalog(document: document)
    let renderer = HTMLRenderer(catalog: catalog)
    var chapters = [titleChapter(summary)]
    for (index, entry) in document.exportedEntries.enumerated() {
      chapters.append(chapter(entry, index: index, renderer: renderer))
    }
    let title = ExportXML.escaped(summary.title)

    let container = """
      <?xml version="1.0" encoding="UTF-8"?>
      <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles>
          <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles>
      </container>
      """
    let manifest =
      chapters.map {
        "    <item id=\"\($0.id)\" href=\"\($0.filename)\" media-type=\"application/xhtml+xml\"/>"
      }
      + catalog.resources.map {
        "    <item id=\"\($0.id)\" href=\"\(ExportXML.escaped($0.href))\" media-type=\"\(ExportXML.escaped($0.mediaType))\"/>"
      }
    let spine = chapters.map { "    <itemref idref=\"\($0.id)\"/>" }
    let opf = """
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="bookid">urn:uuid:\(document.identifier.uuidString.lowercased())</dc:identifier>
          <dc:title>\(title)</dc:title>
          <dc:language>en</dc:language>
          <dc:creator>\(ExportXML.escaped(document.generator))</dc:creator>
          <meta property="dcterms:modified">\(ExportXML.iso8601(document.updatedAt))</meta>
        </metadata>
        <manifest>
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="style" href="styles.css" media-type="text/css"/>
      \(manifest.joined(separator: "\n"))
        </manifest>
        <spine>
      \(spine.joined(separator: "\n"))
        </spine>
      </package>
      """
    let toc = chapters.map {
      "          <li><a href=\"\($0.filename)\">\(ExportXML.escaped($0.tocTitle))</a></li>"
    }
    let nav = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE html>
      <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en">
      <head>
        <meta charset="utf-8"/>
        <title>\(title)</title>
        <link rel="stylesheet" type="text/css" href="styles.css"/>
      </head>
      <body>
        <nav epub:type="toc" id="toc">
          <h1>Table of Contents</h1>
          <ol>
      \(toc.joined(separator: "\n"))
          </ol>
        </nav>
      </body>
      </html>
      """

    // The mimetype entry comes first and uncompressed, as the format requires.
    var entries: [(path: String, data: Data)] = [
      ("mimetype", Data("application/epub+zip".utf8)),
      ("META-INF/container.xml", Data(container.utf8)),
      ("OEBPS/content.opf", Data(opf.utf8)),
      ("OEBPS/nav.xhtml", Data(nav.utf8)),
      ("OEBPS/styles.css", Data(stylesCSS.utf8)),
    ]
    for chapter in chapters {
      entries.append(("OEBPS/\(chapter.filename)", Data(chapter.xhtml.utf8)))
    }
    for resource in catalog.resources {
      entries.append(("OEBPS/\(resource.href)", resource.data))
    }
    return ZipArchiveWriter.archive(entries: entries)
  }

  // MARK: - Chapters

  private struct Chapter {
    var id: String
    var filename: String
    var tocTitle: String
    var xhtml: String
  }

  private static func page(title: String, body: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">
    <head>
      <meta charset="utf-8"/>
      <title>\(ExportXML.escaped(title))</title>
      <link rel="stylesheet" type="text/css" href="styles.css"/>
    </head>
    <body>
    \(body)
    </body>
    </html>
    """
  }

  private static func titleChapter(_ summary: ExportSummary) -> Chapter {
    let body = """
        <section class="title-page">
          <h1>\(ExportXML.escaped(summary.title))</h1>
          <p class="meta">Started \(ExportXML.escaped(summary.started))</p>
          <p class="meta">Last updated \(ExportXML.escaped(summary.lastUpdated))</p>
          <p class="meta">\(ExportXML.escaped(summary.messageCount))</p>
        </section>
      """
    return Chapter(
      id: "title", filename: "title.xhtml", tocTitle: summary.title,
      xhtml: page(title: summary.title, body: body))
  }

  private static func chapter(_ entry: ExportEntry, index: Int, renderer: HTMLRenderer) -> Chapter {
    let number = index + 1
    let id = String(format: "msg%03d", number)
    let blocks = MarkdownBlockParser.blocks(from: entry.body)
    var snippet = renderer.snippet(blocks)
    if snippet.isEmpty { snippet = entry.attachments.first?.name ?? "" }
    let role = entry.role.displayName
    let tocTitle = snippet.isEmpty ? "\(number). \(role)" : "\(number). \(role) — \(snippet)"
    let body = """
        <section class="message role-\(entry.role.rawValue)" id="\(id)">
          <h1 class="role">\(ExportXML.escaped(role))</h1>
          \(renderer.html(for: entry, entryIndex: index, blocks: blocks))
        </section>
      """
    return Chapter(
      id: id, filename: "\(id).xhtml", tocTitle: tocTitle, xhtml: page(title: tocTitle, body: body))
  }

  // MARK: - Rendering

  struct HTMLRenderer {
    let catalog: ExportImageCatalog
    let embedsImages: Bool

    init(catalog: ExportImageCatalog, embedsImages: Bool = false) {
      self.catalog = catalog
      self.embedsImages = embedsImages
    }

    func html(for entry: ExportEntry, entryIndex: Int, blocks: [MarkdownBlock]) -> String {
      var parts: [String] = []
      for section in entry.reasoning
      where !section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let inner = MarkdownBlockParser.blocks(from: section).map(html(for:))
        parts.append(
          "<section class=\"reasoning\"><h2>Reasoning</h2>"
            + (inner.isEmpty ? "<p></p>" : inner.joined(separator: "\n")) + "</section>")
      }
      parts.append(contentsOf: blocks.map(html(for:)))
      let figures = entry.attachments.enumerated().compactMap { offset, image -> String? in
        guard let resource = catalog.attachment(entry: entryIndex, index: offset) else { return nil }
        return """
          <figure class="attachment-image"><img \(imageAttributes(resource, alt: image.name))/>\
          <figcaption>\(ExportXML.escaped(image.name))</figcaption></figure>
          """
      }
      if !figures.isEmpty {
        parts.append("<section class=\"attachments\">\(figures.joined(separator: "\n"))</section>")
      }
      return parts.isEmpty ? "<p></p>" : parts.joined(separator: "\n      ")
    }

    func html(for block: MarkdownBlock) -> String {
      switch block {
      case .heading(let level, let text):
        let tag = "h\(min(6, max(2, level + 1)))"
        return "<\(tag)>\(inline(text))</\(tag)>"
      case .paragraph(let text):
        return "<p>\(lines(text))</p>"
      case .quote(let text):
        return "<blockquote><p>\(lines(text))</p></blockquote>"
      case .rule:
        return "<hr/>"
      case .code(let language, let code):
        if language.lowercased() == "mermaid", let resource = catalog.diagram(source: code) {
          return
            "<figure class=\"mermaid-diagram\"><img \(imageAttributes(resource, alt: "Mermaid diagram"))/></figure>"
        }
        let attribute = language.isEmpty ? "" : " class=\"language-\(ExportXML.escaped(language))\""
        return "<pre><code\(attribute)>\(SyntaxHighlighter.html(code, language: language))</code></pre>"
      case .table(let table):
        return tableHTML(table)
      case .bullets(let items):
        return "<ul>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ul>"
      case .ordered(let items):
        return "<ol>"
          + items.map { item in
            let number = Int(item.label.prefix(while: \.isNumber)).map { " value=\"\($0)\"" } ?? ""
            return "<li\(number)>\(inline(item.text))</li>"
          }.joined() + "</ol>"
      case .tasks(let items):
        return "<ul class=\"task-list\">"
          + items.map { "<li>\($0.checked ? "&#9745;" : "&#9744;") \(inline($0.text))</li>" }.joined()
          + "</ul>"
      case .footnotes(let items):
        return "<hr/><ol class=\"footnotes\">"
          + items.map { "<li><sup>\(ExportXML.escaped($0.key))</sup> \(inline($0.text))</li>" }
          .joined() + "</ol>"
      }
    }

    /// The first line of text in a chapter, for its table-of-contents entry.
    func snippet(_ blocks: [MarkdownBlock]) -> String {
      for block in blocks {
        let candidate: String
        switch block {
        case .heading(_, let text): candidate = text
        case .paragraph(let text), .quote(let text):
          candidate = text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        case .bullets(let items): candidate = items.first ?? ""
        case .ordered(let items): candidate = items.first?.text ?? ""
        case .tasks(let items): candidate = items.first?.text ?? ""
        case .code(let language, _) where language.lowercased() == "mermaid":
          return "Mermaid diagram"
        default: continue
        }
        let plain = MarkdownInlineParser.plainText(candidate).trimmingCharacters(in: .whitespaces)
        if !plain.isEmpty {
          return plain.count <= 60 ? plain : String(plain.prefix(60)).trimmingCharacters(in: .whitespaces) + "…"
        }
      }
      return ""
    }

    private func lines(_ text: String) -> String {
      text.components(separatedBy: "\n").map(inline).joined(separator: "<br/>")
    }

    private func tableHTML(_ table: MarkdownTable) -> String {
      func align(_ index: Int) -> String {
        guard index < table.alignments.count else { return "" }
        switch table.alignments[index] {
        case .center: return " style=\"text-align:center\""
        case .trailing: return " style=\"text-align:right\""
        case .leading: return ""
        }
      }
      let head = table.headers.enumerated().map { "<th\(align($0))>\(inline($1))</th>" }.joined()
      let body = table.rows.map { row in
        "<tr>" + row.enumerated().map { "<td\(align($0))>\(inline($1))</td>" }.joined() + "</tr>"
      }.joined()
      return "<table><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table>"
    }

    private func imageAttributes(_ resource: ExportResource, alt: String) -> String {
      let source =
        embedsImages
        ? "data:\(resource.mediaType);base64,\(resource.data.base64EncodedString())"
        : resource.href
      var attributes = "src=\"\(ExportXML.escaped(source))\" alt=\"\(ExportXML.escaped(alt))\""
      if let width = resource.width, width > 0 { attributes += " width=\"\(width)\"" }
      if let height = resource.height, height > 0 { attributes += " height=\"\(height)\"" }
      return attributes
    }

    func inline(_ raw: String) -> String {
      MarkdownInlineParser.runs(from: raw).map { run -> String in
        if run.style.contains(.image) {
          let source = run.destination ?? ""
          if let resource = catalog.inlineImage(source: source) {
            return "<img \(imageAttributes(resource, alt: run.text))/>"
          }
          if let href = ExportXML.webURL(source) {
            let label = run.text.trimmingCharacters(in: .whitespaces).isEmpty ? source : run.text
            return "<a href=\"\(ExportXML.escaped(href))\">\(ExportXML.escaped(label))</a>"
          }
          return ExportXML.escaped("![\(run.text)](\(source))")
        }
        var html = ExportXML.escaped(run.text).replacingOccurrences(of: "\n", with: "<br/>")
        if run.style.contains(.code) {
          html = "<code>\(html)</code>"
          if !run.style.contains(.link), let href = ExportXML.webURL(run.text) {
            html = "<a href=\"\(ExportXML.escaped(href))\">\(html)</a>"
          }
        }
        if run.style.contains(.bold) { html = "<strong>\(html)</strong>" }
        if run.style.contains(.italic) { html = "<em>\(html)</em>" }
        if run.style.contains(.strikethrough) { html = "<del>\(html)</del>" }
        if run.style.contains(.link), let destination = run.destination {
          html = "<a href=\"\(ExportXML.escaped(destination))\">\(html)</a>"
        }
        return html
      }.joined()
    }
  }

  static let stylesCSS = """
    body {
      color: #1f2328;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      line-height: 1.5;
      margin: 5%;
    }
    h1 { font-size: 1.7em; margin: 1em 0 0.6em; }
    h2 { font-size: 1.35em; margin: 1em 0 0.5em; }
    h3 { font-size: 1.15em; margin: 1em 0 0.4em; }
    h4, h5, h6 { font-size: 1em; margin: 1em 0 0.4em; }
    h1.role {
      color: #57606a;
      font-size: 1em;
      font-weight: 600;
      letter-spacing: 0.04em;
      margin: 0 0 1em;
      text-transform: uppercase;
    }
    .title-page { text-align: center; margin-top: 30%; }
    .title-page h1 { font-size: 2em; margin-bottom: 1em; }
    .title-page .meta { color: #57606a; font-size: 0.9em; margin: 0.2em 0; }
    section.message { margin-top: 1em; }
    section.message.role-user h1.role { color: #1a7f37; }
    section.message.role-assistant h1.role { color: #0969da; }
    section.message.role-tool h1.role { color: #8250df; }
    section.message.role-error h1.role { color: #cf222e; }
    section.reasoning {
      background: #f6f8fa;
      border-left: 3px solid #8250df;
      color: #57606a;
      margin: 0 0 1em;
      padding: 0.6em 1em;
    }
    section.reasoning h2 {
      color: #8250df;
      font-size: 0.95em;
      margin-top: 0;
      text-transform: uppercase;
    }
    p { margin: 0.7em 0; }
    pre {
      background: #f6f8fa;
      border-radius: 6px;
      overflow-wrap: break-word;
      padding: 0.8em;
      white-space: pre-wrap;
      font-family: "SF Mono", Menlo, Consolas, monospace;
      font-size: 0.9em;
    }
    code {
      background: #f6f8fa;
      border-radius: 4px;
      font-family: "SF Mono", Menlo, Consolas, monospace;
      font-size: 0.9em;
      padding: 0.1em 0.3em;
    }
    del { text-decoration: line-through; }
    pre code { background: transparent; padding: 0; }
    .syntax-keyword { color: #8250df; font-weight: 600; }
    .syntax-number { color: #bc4c00; }
    .syntax-string { color: #1a7f37; }
    .syntax-comment { color: #57606a; font-style: italic; }
    blockquote {
      border-left: 3px solid #d0d7de;
      color: #57606a;
      margin: 0.7em 0;
      padding: 0 1em;
    }
    ul, ol { padding-left: 1.6em; }
    li { margin: 0.2em 0; }
    ul.task-list { list-style: none; padding-left: 0.4em; }
    a { color: #0969da; text-decoration: underline; }
    table { border-collapse: collapse; margin: 0.8em 0; width: 100%; }
    th, td {
      border: 1px solid #d0d7de;
      padding: 0.4em 0.7em;
      text-align: left;
      vertical-align: top;
    }
    th { background: #f6f8fa; font-weight: 600; }
    img { max-width: 100%; height: auto; }
    section.attachments { margin-top: 1em; }
    figure.mermaid-diagram { margin: 0.9em 0; page-break-inside: avoid; text-align: left; }
    figure.attachment-image { margin: 0.9em 0; }
    figure.attachment-image figcaption { color: #57606a; font-size: 0.85em; margin-top: 0.35em; }
    """
}

/// A small lexical highlighter for fenced code: comments, strings, numbers,
/// and a shared keyword list are wrapped in spans the stylesheet colours.
enum SyntaxHighlighter {
  static func html(_ code: String, language: String) -> String {
    let chars = Array(code)
    var result = ""
    var index = 0
    while index < chars.count {
      let c = chars[index]
      if c == "/", index + 1 < chars.count, chars[index + 1] == "*" {
        let start = index
        index += 2
        while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") { index += 1 }
        index = min(chars.count, index + 2)
        result += span("comment", String(chars[start..<index]))
        continue
      }
      if c == "/", index + 1 < chars.count, chars[index + 1] == "/" {
        let start = index
        while index < chars.count, chars[index] != "\n" { index += 1 }
        result += span("comment", String(chars[start..<index]))
        continue
      }
      if c == "#", lineLeadingComment(chars, at: index, language: language) {
        let start = index
        while index < chars.count, chars[index] != "\n" { index += 1 }
        result += span("comment", String(chars[start..<index]))
        continue
      }
      if c == "\"" || c == "'" {
        let start = index
        index += 1
        var escaped = false
        while index < chars.count {
          let next = chars[index]
          index += 1
          if escaped { escaped = false } else if next == "\\" { escaped = true } else if next == c || next == "\n" { break }
        }
        result += span("string", String(chars[start..<index]))
        continue
      }
      if c.isNumber {
        let start = index
        index += 1
        while index < chars.count, chars[index].isHexDigit || chars[index] == "." || chars[index] == "_" || chars[index] == "x" { index += 1 }
        result += span("number", String(chars[start..<index]))
        continue
      }
      if c.isLetter || c == "_" {
        let start = index
        index += 1
        while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" { index += 1 }
        let token = String(chars[start..<index])
        result += keywords.contains(token) ? span("keyword", token) : ExportXML.escaped(token)
        continue
      }
      result += ExportXML.escaped(String(c))
      index += 1
    }
    return result
  }

  private static func span(_ name: String, _ value: String) -> String {
    "<span class=\"syntax-\(name)\">\(ExportXML.escaped(value))</span>"
  }

  private static func lineLeadingComment(_ chars: [Character], at index: Int, language: String) -> Bool {
    let hashLanguages: Set<String> = [
      "", "bash", "conf", "fish", "make", "makefile", "py", "python", "rb", "ruby", "sh", "shell",
      "toml", "yaml", "yml", "zsh",
    ]
    guard hashLanguages.contains(language.trimmingCharacters(in: .whitespaces).lowercased()) else {
      return false
    }
    var cursor = index
    while cursor > 0 {
      cursor -= 1
      if chars[cursor] == "\n" { return true }
      if chars[cursor] != " " && chars[cursor] != "\t" { return false }
    }
    return true
  }

  private static let keywords: Set<String> = [
    "actor", "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
    "default", "defer", "do", "else", "enum", "export", "extends", "false", "final", "for",
    "from", "func", "function", "guard", "if", "import", "in", "interface", "let", "nil", "null",
    "private", "public", "return", "self", "static", "struct", "switch", "throw", "throws", "true",
    "try", "typealias", "var", "while",
  ]
}
