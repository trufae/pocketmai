import Foundation
import XCTest

@testable import MaiCore

final class MarkdownQuoteTests: XCTestCase {
  // Pins the wrapping itself, at a width of its own, so that tuning
  // `defaultLineWidth` stays a product decision instead of a test failure.
  func testWrapsAndPrefixesEveryLine() {
    let quoted = MarkdownQuote.quote(
      "The quick brown fox jumps over the lazy dog", lineWidth: 20)

    XCTAssertEqual(
      quoted,
      """
      > The quick brown
      > fox jumps over the
      > lazy dog
      """)
  }

  // Whatever the default width is, the wrap has to be greedy: a line is only
  // broken because the next word would not have fit on it.
  func testDefaultWidthPacksEachLineBeforeBreakingIt() {
    let words = Array(repeating: "lorem", count: 40)
    let lines = MarkdownQuote.quote(words.joined(separator: " "))
      .components(separatedBy: "\n")

    XCTAssertGreaterThan(lines.count, 1, "The sample must be long enough to wrap")
    for line in lines.dropLast() {
      XCTAssertGreaterThan(
        line.count + " lorem".count, MarkdownQuote.defaultLineWidth,
        "Broke early, another word still fitted: \(line)")
    }
  }

  func testEveryLineFitsTheConfiguredWidth() {
    let text = "Assistants answer questions about wrapping behaviour in narrow bubbles."
    let quoted = MarkdownQuote.quote(text)

    for line in quoted.components(separatedBy: "\n") {
      XCTAssertTrue(line.hasPrefix("> "), "Missing quote marker: \(line)")
      XCTAssertLessThanOrEqual(line.count, MarkdownQuote.defaultLineWidth, "Too long: \(line)")
    }
  }

  func testKeepsBlankLinesInsideTheQuote() {
    let quoted = MarkdownQuote.quote("first\n\nsecond")

    XCTAssertEqual(
      quoted,
      """
      > first
      >
      > second
      """)
    XCTAssertFalse(quoted.contains("> \n"), "Blank quoted lines must not carry trailing spaces")
  }

  func testSplitsWordsThatCannotFitOnALineOfTheirOwn() {
    let quoted = MarkdownQuote.quote("see https://example.com/some/very/long/path")

    for line in quoted.components(separatedBy: "\n") {
      XCTAssertLessThanOrEqual(line.count, MarkdownQuote.defaultLineWidth, "Too long: \(line)")
    }
    XCTAssertEqual(
      quoted.replacingOccurrences(of: "> ", with: "").replacingOccurrences(of: "\n", with: ""),
      "see https://example.com/some/very/long/path".replacingOccurrences(of: " ", with: ""))
  }

  func testHonoursACustomWidthAndNormalizesWindowsNewlines() {
    let quoted = MarkdownQuote.quote("alpha beta\r\ngamma", lineWidth: 12)

    XCTAssertEqual(
      quoted,
      """
      > alpha beta
      > gamma
      """)
  }

  func testEmptyTextProducesAnEmptyQuotedLine() {
    XCTAssertEqual(MarkdownQuote.quote(""), ">")
  }
}
