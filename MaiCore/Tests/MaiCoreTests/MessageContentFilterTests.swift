import Testing

@testable import MaiCore

@Test("Markdown notification text uses the portable plain-text fallback")
func markdownPlainTextUsesPortableFallback() {
  let markdown = "# Heading\n- **Bold** [link](https://example.com)\n`code` and ~~old~~"

  #expect(MessageContentFilter.markdownPlainText(from: markdown) == "Heading\nBold link\ncode and old")
}

@Test("One exact hidden block can be deleted without removing an identical sibling")
func removesOneHiddenSectionOccurrence() throws {
  let text = """
    <think>same thought</think>

    Visible answer.

    <think>same thought</think>
    """

  let edited = try #require(
    MessageContentFilter.removingHiddenSection(
      tag: "think", content: "same thought", occurrence: 1, from: text))

  #expect(edited == "<think>same thought</think>\n\nVisible answer.")
  #expect(MessageContentFilter.render(edited).hiddenSections.count == 1)
}
