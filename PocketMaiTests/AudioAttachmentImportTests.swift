import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import PocketMai

final class AudioAttachmentImportTests: XCTestCase {
  func testRecordingsArePickedOutOfTheDocumentPicker() {
    for ext in ["m4a", "mp3", "ogg", "opus", "wav", "M4A", "Ogg"] {
      XCTAssertTrue(
        AudioTranscriptionService.isAudioFile(URL(fileURLWithPath: "/tmp/message.\(ext)")),
        "\(ext) should be transcribed")
    }
    XCTAssertFalse(AudioTranscriptionService.isAudioFile(URL(fileURLWithPath: "/tmp/notes.txt")))
    XCTAssertFalse(AudioTranscriptionService.isAudioFile(URL(fileURLWithPath: "/tmp/report.pdf")))
  }

  func testPickerOffersTheRecordingTypes() {
    let types = AudioTranscriptionService.pickerContentTypes
    XCTAssertTrue(types.contains(.audio))
    XCTAssertTrue(types.contains(.mp3))
    XCTAssertTrue(types.contains(.mpeg4Audio))
    XCTAssertEqual(types.count, Set(types).count)
  }

  func testPickerKeepsCanonicalTypesWithoutExtensionRegistration() {
    let types = AudioTranscriptionService.pickerContentTypes { _ in nil }
    XCTAssertEqual(types, [.audio, .mp3, .mpeg4Audio])
  }

  func testPickerDeduplicatesAliasesAndPreservesAdditionalTypes() {
    var resolvedExtensions: [String] = []
    let types = AudioTranscriptionService.pickerContentTypes { ext in
      resolvedExtensions.append(ext)
      switch ext {
      case "mp3", "mpga": return .mp3
      case "m4a", "mp4a": return .mpeg4Audio
      case "wav", "wave": return .wav
      default: return nil
      }
    }
    XCTAssertEqual(types, [.audio, .mp3, .mpeg4Audio, .wav])
    XCTAssertEqual(resolvedExtensions, AudioTranscriptionService.audioExtensions.sorted())
  }

  func testStagedCopyOutlivesThePickedFile() throws {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).m4a")
    try Data("not really audio".utf8).write(to: source)

    let staged = try AudioTranscriptionService.stagedCopy(of: source)
    defer { try? FileManager.default.removeItem(at: staged) }
    try FileManager.default.removeItem(at: source)

    XCTAssertNotEqual(staged, source)
    XCTAssertEqual(staged.pathExtension, "m4a")
    XCTAssertEqual(try Data(contentsOf: staged), Data("not really audio".utf8))
  }
}
