import Foundation

/// Repackages an Ogg Opus file (`.opus`, `.ogg`) as CAF.
///
/// WhatsApp and Telegram export voice messages as Opus audio in an Ogg
/// container. iOS decodes Opus but does not read Ogg, so the packets are
/// demuxed here and rewritten into a Core Audio File, which AVFoundation — and
/// therefore the speech recogniser — opens directly. Nothing is re-encoded:
/// the same Opus packets are copied over with a packet table describing them.
enum OggOpusRemuxer {
  /// Opus always decodes at 48 kHz, whatever the original input rate was.
  private static let sampleRate = 48000.0
  private static let oggCapturePattern: [UInt8] = [0x4F, 0x67, 0x67, 0x53]  // "OggS"

  static func cafData(from data: Data) -> Data? {
    guard let stream = demux(data) else { return nil }
    return caf(for: stream)
  }

  // MARK: - Ogg

  private struct OpusStream {
    var channels: Int
    var preSkip: Int
    var packets: [Data] = []
    var frameCounts: [Int] = []
  }

  private static func demux(_ data: Data) -> OpusStream? {
    let bytes = [UInt8](data)
    guard bytes.count > 47, Array(bytes[0..<4]) == oggCapturePattern else { return nil }

    var stream: OpusStream?
    var serial: UInt32?
    var pending = Data()
    var offset = 0

    while offset + 27 <= bytes.count {
      guard Array(bytes[offset..<(offset + 4)]) == oggCapturePattern else {
        guard let next = nextPage(in: bytes, from: offset + 1) else { break }
        offset = next
        continue
      }
      let headerType = bytes[offset + 5]
      let pageSerial = readUInt32LE(bytes, at: offset + 14)
      let segmentCount = Int(bytes[offset + 26])
      let tableOffset = offset + 27
      guard tableOffset + segmentCount <= bytes.count else { break }
      let segments = Array(bytes[tableOffset..<(tableOffset + segmentCount)])
      let payloadOffset = tableOffset + segmentCount
      let payloadLength = segments.reduce(0) { $0 + Int($1) }
      guard payloadOffset + payloadLength <= bytes.count else { break }
      let pageEnd = payloadOffset + payloadLength

      // Only the first logical stream is kept: a voice message never carries
      // more, and a mixed file would interleave unrelated packets.
      if serial == nil { serial = pageSerial }
      guard pageSerial == serial else {
        offset = pageEnd
        continue
      }
      // A page that does not continue the previous packet invalidates whatever
      // was left half-read.
      if headerType & 0x01 == 0 { pending.removeAll(keepingCapacity: true) }

      var cursor = payloadOffset
      for length in segments {
        let size = Int(length)
        pending.append(contentsOf: bytes[cursor..<(cursor + size)])
        cursor += size
        guard size < 255 else { continue }
        let packet = pending
        pending.removeAll(keepingCapacity: true)
        append(packet, to: &stream)
      }
      offset = pageEnd
    }

    guard let stream, !stream.packets.isEmpty else { return nil }
    return stream
  }

  private static func append(_ packet: Data, to stream: inout OpusStream?) {
    guard !packet.isEmpty else { return }
    if packet.starts(with: Array("OpusHead".utf8)) {
      guard packet.count >= 12 else { return }
      let channels = Int(packet[packet.startIndex + 9])
      let preSkip =
        Int(packet[packet.startIndex + 10]) | (Int(packet[packet.startIndex + 11]) << 8)
      stream = OpusStream(channels: max(1, min(channels, 8)), preSkip: preSkip)
      return
    }
    if packet.starts(with: Array("OpusTags".utf8)) { return }
    guard stream != nil, let frames = frameCount(of: packet) else { return }
    stream?.packets.append(packet)
    stream?.frameCounts.append(frames)
  }

  private static func nextPage(in bytes: [UInt8], from start: Int) -> Int? {
    var index = start
    while index + 4 <= bytes.count {
      if Array(bytes[index..<(index + 4)]) == oggCapturePattern { return index }
      index += 1
    }
    return nil
  }

  private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16)
      | (UInt32(bytes[offset + 3]) << 24)
  }

  // MARK: - Opus packets

  /// The number of 48 kHz samples an Opus packet decodes to, read from its
  /// table-of-contents byte (RFC 6716 §3.1).
  private static func frameCount(of packet: Data) -> Int? {
    guard let toc = packet.first else { return nil }
    let config = Int(toc >> 3)
    let samplesPerFrame: Int
    switch config {
    case 0..<12:
      samplesPerFrame = [480, 960, 1920, 2880][config % 4]
    case 12..<16:
      samplesPerFrame = [480, 960][config % 2]
    default:
      samplesPerFrame = [120, 240, 480, 960][config % 4]
    }
    let frames: Int
    switch toc & 0x03 {
    case 0:
      frames = 1
    case 1, 2:
      frames = 2
    default:
      guard packet.count >= 2 else { return nil }
      frames = Int(packet[packet.startIndex + 1] & 0x3F)
    }
    guard frames > 0, frames <= 48 else { return nil }
    return frames * samplesPerFrame
  }

  // MARK: - CAF

  private static func caf(for stream: OpusStream) -> Data? {
    guard !stream.packets.isEmpty else { return nil }
    let totalFrames = stream.frameCounts.reduce(0, +)
    guard totalFrames > stream.preSkip else { return nil }
    // Encoders usually stick to one frame size; when they do, the audio
    // description can say so and the packet table only lists byte sizes.
    let constantFrames = Set(stream.frameCounts).count == 1 ? stream.frameCounts[0] : 0

    var caf = Data()
    caf.append(contentsOf: Array("caff".utf8))
    caf.appendBigEndian(UInt16(1))  // file version
    caf.appendBigEndian(UInt16(0))  // file flags

    var description = Data()
    description.appendBigEndian(sampleRate.bitPattern)
    description.append(contentsOf: Array("opus".utf8))
    description.appendBigEndian(UInt32(0))  // format flags
    description.appendBigEndian(UInt32(0))  // bytes per packet: variable
    description.appendBigEndian(UInt32(constantFrames))
    description.appendBigEndian(UInt32(stream.channels))
    description.appendBigEndian(UInt32(0))  // bits per channel: compressed
    caf.append(chunkHeader("desc", size: description.count))
    caf.append(description)

    var table = Data()
    table.appendBigEndian(Int64(stream.packets.count))
    table.appendBigEndian(Int64(totalFrames - stream.preSkip))
    table.appendBigEndian(Int32(stream.preSkip))
    table.appendBigEndian(Int32(0))  // remainder frames
    for (index, packet) in stream.packets.enumerated() {
      table.append(contentsOf: variableLengthInteger(packet.count))
      if constantFrames == 0 {
        table.append(contentsOf: variableLengthInteger(stream.frameCounts[index]))
      }
    }
    caf.append(chunkHeader("pakt", size: table.count))
    caf.append(table)

    var audio = Data()
    audio.appendBigEndian(UInt32(0))  // edit count
    for packet in stream.packets {
      audio.append(packet)
    }
    caf.append(chunkHeader("data", size: audio.count))
    caf.append(audio)
    return caf
  }

  private static func chunkHeader(_ type: String, size: Int) -> Data {
    var header = Data(type.utf8)
    header.appendBigEndian(Int64(size))
    return header
  }

  /// CAF packet tables store integers seven bits at a time, most significant
  /// group first, with the top bit set on every byte but the last.
  private static func variableLengthInteger(_ value: Int) -> [UInt8] {
    var remaining = max(value, 0)
    var bytes: [UInt8] = [UInt8(remaining & 0x7F)]
    remaining >>= 7
    while remaining > 0 {
      bytes.insert(UInt8((remaining & 0x7F) | 0x80), at: 0)
      remaining >>= 7
    }
    return bytes
  }
}

extension Data {
  fileprivate mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
    var bigEndian = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
  }
}
