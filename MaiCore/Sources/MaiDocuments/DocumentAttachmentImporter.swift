import Foundation
import MaiCore

/// A file turned into text a model can read, ready to attach to a message.
public struct DocumentAttachment: Equatable, Sendable {
  /// The attachment's file name, for example `report.md` for a converted document.
  public var name: String
  public var content: ContentPart
  /// How the file was converted, or nil when its text was attached verbatim.
  public var note: String?
  public var characterCount: Int

  public init(name: String, content: ContentPart, note: String?, characterCount: Int) {
    self.name = name
    self.content = content
    self.note = note
    self.characterCount = characterCount
  }
}

public enum DocumentAttachmentKind: String, Equatable, Sendable {
  case word
  case pdf
  case epub
  case json
  case text
  case image
}

public enum DocumentImportError: LocalizedError, Equatable, Sendable {
  case fileNotFound(String)
  case isDirectory(String)
  case imageRequiresImageImporter(String)
  case textTooLarge(limit: Int)
  case notUTF8(String)
  case binaryFile(String)
  case emptyText(String)

  public var errorDescription: String? {
    switch self {
    case .fileNotFound(let path):
      "File '\(path)' does not exist."
    case .isDirectory(let path):
      "'\(path)' is a directory."
    case .imageRequiresImageImporter(let name):
      "'\(name)' is an image; attach it with the image importer instead."
    case .textTooLarge(let limit):
      "Text attachments are limited to \(limit / 1_000_000).\(limit % 1_000_000 / 100_000) MB."
    case .notUTF8(let name):
      "'\(name)' is not UTF-8 text."
    case .binaryFile(let name):
      "'\(name)' appears to be binary; only documents and text files can be attached."
    case .emptyText(let name):
      "'\(name)' does not contain any text."
    }
  }
}

/// Turns documents into Markdown or plain-text file parts: Word and PDF files are
/// converted to Markdown, JSON becomes an indented outline, and text files are
/// attached as they are. Images are left to `ImageAttachmentImporter`.
public enum DocumentAttachmentImporter {
  /// The same ceiling the iOS app applies to text attachments.
  public static let maximumTextBytes = 1_500_000

  private static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif",
  ]
  private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

  public static func kind(forFilename name: String) -> DocumentAttachmentKind {
    switch (name as NSString).pathExtension.lowercased() {
    case "docx": .word
    case "pdf": .pdf
    case "epub": .epub
    case "json": .json
    case let ext where imageExtensions.contains(ext): .image
    default: .text
    }
  }

  public static func attachment(at url: URL) throws -> DocumentAttachment {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw DocumentImportError.fileNotFound(url.path)
    }
    guard !isDirectory.boolValue else { throw DocumentImportError.isDirectory(url.path) }
    let name = url.lastPathComponent
    if kind(forFilename: name) == .image {
      throw DocumentImportError.imageRequiresImageImporter(name)
    }
    return try attachment(data: try Data(contentsOf: url), filename: name)
  }

  public static func attachment(data: Data, filename: String) throws -> DocumentAttachment {
    let baseName = (filename as NSString).deletingPathExtension
    switch kind(forFilename: filename) {
    case .word:
      return try converted(
        DOCXImporter.markdown(from: data),
        name: baseName + ".md",
        mimeType: "text/markdown",
        note: "converted from Word to Markdown")
    case .pdf:
      return try converted(
        PDFImporter.markdown(from: data),
        name: baseName + ".md",
        mimeType: "text/markdown",
        note: "converted from PDF to Markdown")
    case .epub:
      return try converted(
        EPUBImporter.markdown(from: data),
        name: baseName + ".md",
        mimeType: "text/markdown",
        note: "converted from EPUB to Markdown")
    case .json:
      return try converted(
        JSONDocumentImporter.render(data: data).text,
        name: baseName + ".txt",
        mimeType: "text/plain",
        note: "converted from JSON to an indented outline")
    case .image:
      throw DocumentImportError.imageRequiresImageImporter(filename)
    case .text:
      guard data.count <= maximumTextBytes else {
        throw DocumentImportError.textTooLarge(limit: maximumTextBytes)
      }
      guard !looksBinary(data) else { throw DocumentImportError.binaryFile(filename) }
      guard let text = String(data: data, encoding: .utf8) else {
        throw DocumentImportError.notUTF8(filename)
      }
      guard text.contains(where: { !$0.isWhitespace }) else {
        throw DocumentImportError.emptyText(filename)
      }
      let mimeType =
        markdownExtensions.contains((filename as NSString).pathExtension.lowercased())
        ? "text/markdown" : "text/plain"
      return DocumentAttachment(
        name: filename,
        content: .file(FileContent(name: filename, mimeType: mimeType, text: text)),
        note: nil,
        characterCount: text.count)
    }
  }

  private static func converted(
    _ text: String,
    name: String,
    mimeType: String,
    note: String
  ) throws -> DocumentAttachment {
    guard text.utf8.count <= maximumTextBytes else {
      throw DocumentImportError.textTooLarge(limit: maximumTextBytes)
    }
    return DocumentAttachment(
      name: name,
      content: .file(FileContent(name: name, mimeType: mimeType, text: text)),
      note: note,
      characterCount: text.count)
  }

  /// A NUL byte, or a high share of other control characters in the first few
  /// kilobytes, marks a file as binary rather than text.
  static func looksBinary(_ data: Data) -> Bool {
    let sample = data.prefix(8_192)
    guard !sample.isEmpty else { return false }
    var suspicious = 0
    for byte in sample {
      if byte == 0 { return true }
      if byte < 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D, byte != 0x0C, byte != 0x1B {
        suspicious += 1
      }
    }
    return suspicious * 10 > sample.count
  }
}
