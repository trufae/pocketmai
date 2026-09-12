import Foundation
import MaiMarkdown

/// Writes one self-contained HTML document. It shares the EPUB renderer, but
/// embeds images as data URLs so the exported file can be moved on its own.
public enum HTMLExport {
  public static func data(for document: ExportDocument) -> Data {
    Data(text(for: document).utf8)
  }

  public static func text(for document: ExportDocument) -> String {
    let summary = document.summary
    let catalog = ExportImageCatalog(document: document)
    let renderer = EPUBExport.HTMLRenderer(catalog: catalog, embedsImages: true)
    let messages = document.exportedEntries.enumerated().map { index, entry in
      let blocks = MarkdownBlockParser.blocks(from: entry.body)
      return """
        <section class="message role-\(entry.role.rawValue)" id="msg\(index + 1)">
          <h1 class="role">\(ExportXML.escaped(entry.role.displayName))</h1>
          \(renderer.html(for: entry, entryIndex: index, blocks: blocks))
        </section>
        """
    }.joined(separator: "\n")
    let title = ExportXML.escaped(summary.title)
    return """
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <meta name="generator" content="\(ExportXML.escaped(document.generator))"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title>\(title)</title>
        <style>
      \(EPUBExport.stylesCSS)
        </style>
      </head>
      <body>
        <main class="conversation">
          <header class="title-page">
            <h1>\(title)</h1>
            <p class="meta">Started \(ExportXML.escaped(summary.started))</p>
            <p class="meta">Last updated \(ExportXML.escaped(summary.lastUpdated))</p>
            <p class="meta">\(ExportXML.escaped(summary.messageCount))</p>
          </header>
      \(messages)
        </main>
      </body>
      </html>
      """
  }
}
