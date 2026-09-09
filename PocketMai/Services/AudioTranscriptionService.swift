import AVFoundation
import Foundation
import Speech

/// Turns a shared audio file into text with the on-device recogniser.
///
/// This is the path a voice message takes when it is shared into PocketMai:
/// WhatsApp and Telegram hand over Opus audio in an Ogg container, which
/// AVFoundation does not read, so those files are repackaged as CAF first (see
/// `OggOpusRemuxer`). Everything AVFoundation already reads — m4a voice memos,
/// mp3, wav, caf, or the sound track of a short clip — goes straight to the
/// recogniser.
enum AudioTranscriptionService {
  enum TranscriptionError: LocalizedError, Equatable {
    case permissionDenied
    case recognizerUnavailable(String)
    case unsupportedFormat(String)
    case noSpeech(String)

    var errorDescription: String? {
      switch self {
      case .permissionDenied:
        "PocketMai needs Speech Recognition access to transcribe shared audio. "
          + "Enable it in Settings > Privacy > Speech Recognition."
      case .recognizerUnavailable(let language):
        "Speech recognition is not available for \(language)."
      case .unsupportedFormat(let name):
        "\(name) is in an audio format this device cannot decode."
      case .noSpeech(let name):
        "No speech could be recognized in \(name)."
      }
    }
  }

  /// Recognises the speech in `fileURL` and returns the transcript.
  static func transcribe(fileURL: URL, localeIdentifier: String) async throws -> String {
    guard await requestAuthorization() == .authorized else {
      throw TranscriptionError.permissionDenied
    }

    let locale = Locale(identifier: localeIdentifier)
    guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
      recognizer.isAvailable
    else {
      throw TranscriptionError.recognizerUnavailable(
        locale.localizedString(forIdentifier: localeIdentifier) ?? localeIdentifier)
    }

    let name = fileURL.lastPathComponent
    let prepared = try await decodableURL(for: fileURL)
    defer {
      if prepared != fileURL { try? FileManager.default.removeItem(at: prepared) }
    }

    // Voice messages are personal, so they stay on the device whenever the
    // language is installed for offline recognition; the network recogniser is
    // only asked when that returns nothing.
    var transcript = ""
    if recognizer.supportsOnDeviceRecognition {
      transcript = (try? await recognize(prepared, with: recognizer, onDevice: true)) ?? ""
    }
    if transcript.isEmpty {
      transcript = (try? await recognize(prepared, with: recognizer, onDevice: false)) ?? ""
    }
    let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw TranscriptionError.noSpeech(name) }
    return text
  }

  // MARK: - Permission

  private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    let status = SFSpeechRecognizer.authorizationStatus()
    guard status == .notDetermined else { return status }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
  }

  // MARK: - Formats

  /// Returns a URL the recogniser can read: the file itself when AVFoundation
  /// decodes it, otherwise a temporary PCM copy decoded from Ogg Opus.
  private static func decodableURL(for url: URL) async throws -> URL {
    if await hasAudioTrack(url) { return url }

    let name = url.lastPathComponent
    guard let oggData = try? Data(contentsOf: url, options: [.mappedIfSafe]),
      let caf = OggOpusRemuxer.cafData(from: oggData)
    else {
      throw TranscriptionError.unsupportedFormat(name)
    }

    let cafURL = temporaryURL(extension: "caf")
    defer { try? FileManager.default.removeItem(at: cafURL) }
    do {
      try caf.write(to: cafURL, options: .atomic)
      // The recogniser is far happier with plain PCM than with a repackaged
      // Opus stream, and decoding here also proves the audio is readable.
      return try decodedWAV(from: cafURL)
    } catch {
      throw TranscriptionError.unsupportedFormat(name)
    }
  }

  private static func hasAudioTrack(_ url: URL) async -> Bool {
    let asset = AVURLAsset(url: url)
    guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return false }
    return !tracks.isEmpty
  }

  private static func decodedWAV(from url: URL) throws -> URL {
    let input = try AVAudioFile(forReading: url)
    let format = input.processingFormat
    let outputURL = temporaryURL(extension: "wav")
    let output = try AVAudioFile(
      forWriting: outputURL,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ])
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
      throw TranscriptionError.unsupportedFormat(url.lastPathComponent)
    }
    while true {
      try input.read(into: buffer)
      guard buffer.frameLength > 0 else { break }
      try output.write(from: buffer)
    }
    return outputURL
  }

  private static func temporaryURL(extension pathExtension: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("PocketMaiSharedAudio-\(UUID().uuidString)")
      .appendingPathExtension(pathExtension)
  }

  // MARK: - Recognition

  private static func recognize(
    _ url: URL,
    with recognizer: SFSpeechRecognizer,
    onDevice: Bool
  ) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      let box = TranscriptionContinuationBox()
      let request = SFSpeechURLRecognitionRequest(url: url)
      request.shouldReportPartialResults = false
      request.taskHint = .dictation
      request.requiresOnDeviceRecognition = onDevice
      let task = recognizer.recognitionTask(with: request) { result, error in
        if let error {
          box.resume(continuation, throwing: error)
          return
        }
        guard let result, result.isFinal else { return }
        box.resume(continuation, returning: result.bestTranscription.formattedString)
      }
      box.keep(task)
    }
  }
}

/// `recognitionTask` can report both a result and an error; the continuation
/// must only be resumed once.
private final class TranscriptionContinuationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var didResume = false
  private var task: SFSpeechRecognitionTask?

  /// Keeps the task alive until it reports, and lets go of it afterwards.
  func keep(_ task: SFSpeechRecognitionTask) {
    lock.lock()
    defer { lock.unlock() }
    guard !didResume else { return }
    self.task = task
  }

  func resume(_ continuation: CheckedContinuation<String, Error>, returning text: String) {
    lock.lock()
    defer { lock.unlock() }
    guard !didResume else { return }
    didResume = true
    task = nil
    continuation.resume(returning: text)
  }

  func resume(_ continuation: CheckedContinuation<String, Error>, throwing error: Error) {
    lock.lock()
    defer { lock.unlock() }
    guard !didResume else { return }
    didResume = true
    task = nil
    continuation.resume(throwing: error)
  }
}
