import Foundation
import XCTest

@testable import PocketMai

/// The remuxer is what lets a WhatsApp or Telegram voice message reach the
/// speech recogniser, so the Ogg demuxing and the CAF it writes are checked
/// against a hand-built stream.
final class OggOpusRemuxerTests: XCTestCase {
  /// TOC byte for config 5: 20 ms of medium-band SILK, one frame per packet,
  /// which is 960 samples at the 48 kHz Opus always decodes to.
  private static let toc: UInt8 = 5 << 3
  private static let framesPerPacket = 960

  func testRepacksOggOpusAsCAF() throws {
    let packets: [[UInt8]] = [[Self.toc, 0x01, 0x02], [Self.toc, 0x03, 0x04, 0x05]]
    let ogg = Self.oggStream(
      headerPackets: [Self.opusHead(channels: 1, preSkip: 312), Self.opusTags()],
      audioPackets: packets)

    let caf = try XCTUnwrap(OggOpusRemuxer.cafData(from: ogg))
    XCTAssertEqual(Array(caf.prefix(4)), Array("caff".utf8))

    let chunks = Self.chunks(in: caf)
    let description = try XCTUnwrap(chunks["desc"])
    XCTAssertEqual(description.count, 32)
    XCTAssertEqual(
      Float64(bitPattern: Self.readUInt64(description, at: 0)), 48000, accuracy: 0.001)
    XCTAssertEqual(Array(description[8..<12]), Array("opus".utf8))
    XCTAssertEqual(Self.readUInt32(description, at: 16), 0)  // bytes per packet: variable
    XCTAssertEqual(Self.readUInt32(description, at: 20), UInt32(Self.framesPerPacket))
    XCTAssertEqual(Self.readUInt32(description, at: 24), 1)  // channels

    let table = try XCTUnwrap(chunks["pakt"])
    XCTAssertEqual(Self.readUInt64(table, at: 0), 2)  // packets
    XCTAssertEqual(Self.readUInt64(table, at: 8), UInt64(2 * Self.framesPerPacket - 312))
    XCTAssertEqual(Self.readUInt32(table, at: 16), 312)  // priming frames
    // One variable-length size per packet; the frame count is in the description.
    XCTAssertEqual(Array(table[24...]), [3, 4])

    let audio = try XCTUnwrap(chunks["data"])
    XCTAssertEqual(Self.readUInt32(audio, at: 0), 0)  // edit count
    XCTAssertEqual(Array(audio[4...]), packets.flatMap { $0 })
  }

  func testPacketsSplitAcrossPagesAreJoined() throws {
    // A 255-byte segment means the packet continues in the next segment, which
    // is how a long packet spans two Ogg pages.
    let longPacket = [Self.toc] + Array(repeating: UInt8(0x7F), count: 300)
    let ogg = Self.oggStream(
      headerPackets: [Self.opusHead(channels: 2, preSkip: 0), Self.opusTags()],
      audioPackets: [longPacket],
      splitAudioPages: true)

    let caf = try XCTUnwrap(OggOpusRemuxer.cafData(from: ogg))
    let chunks = Self.chunks(in: caf)
    let description = try XCTUnwrap(chunks["desc"])
    XCTAssertEqual(Self.readUInt32(description, at: 24), 2)  // channels
    let audio = try XCTUnwrap(chunks["data"])
    XCTAssertEqual(Array(audio[4...]), longPacket)
  }

  func testRejectsInputThatIsNotOggOpus() {
    XCTAssertNil(OggOpusRemuxer.cafData(from: Data("this is not audio at all".utf8)))
    XCTAssertNil(
      OggOpusRemuxer.cafData(
        from: Self.oggStream(
          headerPackets: [Self.opusHead(channels: 1, preSkip: 0), Self.opusTags()],
          audioPackets: [])))
  }

  // MARK: - Fixtures

  private static func opusHead(channels: UInt8, preSkip: UInt16) -> [UInt8] {
    var packet = Array("OpusHead".utf8)
    packet.append(1)  // version
    packet.append(channels)
    packet.append(UInt8(preSkip & 0xFF))
    packet.append(UInt8(preSkip >> 8))
    packet.append(contentsOf: [0x80, 0xBB, 0x00, 0x00])  // 48000 Hz input rate
    packet.append(contentsOf: [0x00, 0x00])  // output gain
    packet.append(0)  // channel mapping family
    return packet
  }

  private static func opusTags() -> [UInt8] {
    Array("OpusTags".utf8) + Array(repeating: UInt8(0), count: 8)
  }

  /// Builds an Ogg stream: one page per header packet, then the audio packets
  /// in a single page or, when `splitAudioPages` is set, across two pages.
  private static func oggStream(
    headerPackets: [[UInt8]],
    audioPackets: [[UInt8]],
    splitAudioPages: Bool = false
  ) -> Data {
    var data = Data()
    var sequence: UInt32 = 0
    for (index, packet) in headerPackets.enumerated() {
      data.append(
        page(
          segments: segments(for: packet),
          payload: packet,
          headerType: index == 0 ? 0x02 : 0x00,
          sequence: &sequence))
    }

    guard !audioPackets.isEmpty else { return data }
    var payload: [UInt8] = []
    var table: [UInt8] = []
    for packet in audioPackets {
      table.append(contentsOf: segments(for: packet))
      payload.append(contentsOf: packet)
    }
    guard splitAudioPages, table.count > 1 else {
      data.append(page(segments: table, payload: payload, headerType: 0x00, sequence: &sequence))
      return data
    }

    // The first page carries the 255-byte segments, the continuation page the
    // remainder of the same packet.
    let firstSegments = Array(table.prefix(table.count - 1))
    let firstLength = firstSegments.reduce(0) { $0 + Int($1) }
    data.append(
      page(
        segments: firstSegments,
        payload: Array(payload.prefix(firstLength)),
        headerType: 0x00,
        sequence: &sequence))
    data.append(
      page(
        segments: [table[table.count - 1]],
        payload: Array(payload.dropFirst(firstLength)),
        headerType: 0x01,
        sequence: &sequence))
    return data
  }

  private static func segments(for packet: [UInt8]) -> [UInt8] {
    var lengths: [UInt8] = []
    var remaining = packet.count
    while remaining >= 255 {
      lengths.append(255)
      remaining -= 255
    }
    lengths.append(UInt8(remaining))
    return lengths
  }

  private static func page(
    segments: [UInt8],
    payload: [UInt8],
    headerType: UInt8,
    sequence: inout UInt32
  ) -> Data {
    var header = Array("OggS".utf8)
    header.append(0)  // stream structure version
    header.append(headerType)
    header.append(contentsOf: Array(repeating: UInt8(0), count: 8))  // granule position
    header.append(contentsOf: littleEndian(0x1234_5678))  // stream serial
    header.append(contentsOf: littleEndian(sequence))
    header.append(contentsOf: Array(repeating: UInt8(0), count: 4))  // checksum: unchecked
    header.append(UInt8(segments.count))
    header.append(contentsOf: segments)
    sequence += 1
    return Data(header + payload)
  }

  private static func littleEndian(_ value: UInt32) -> [UInt8] {
    [
      UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF),
      UInt8((value >> 24) & 0xFF),
    ]
  }

  // MARK: - CAF reading

  private static func chunks(in caf: Data) -> [String: Data] {
    var chunks: [String: Data] = [:]
    var offset = 8  // file header
    let bytes = [UInt8](caf)
    while offset + 12 <= bytes.count {
      let type = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
      let size = Int(readUInt64(Data(bytes[(offset + 4)..<(offset + 12)]), at: 0))
      let start = offset + 12
      guard size >= 0, start + size <= bytes.count else { break }
      chunks[type] = Data(bytes[start..<(start + size)])
      offset = start + size
    }
    return chunks
  }

  private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
    let bytes = [UInt8](data)
    var value: UInt64 = 0
    for index in offset..<(offset + 8) {
      value = (value << 8) | UInt64(bytes[index])
    }
    return value
  }

  private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    let bytes = [UInt8](data)
    var value: UInt32 = 0
    for index in offset..<(offset + 4) {
      value = (value << 8) | UInt32(bytes[index])
    }
    return value
  }
}
