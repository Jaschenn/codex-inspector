import Markdown
import XCTest

@testable import CodexInspector

final class MarkdownContentTests: XCTestCase {
  func testPreviewRecognizesHeadingsListsQuotesTablesAndCode() {
    let document = Document(
      parsing: """
        # 标题

        > 引用

        - 第一项
        - 第二项

        ```json
        {"enabled":true}
        ```

        | 名称 | 数量 |
        | --- | ---: |
        | example | 12 |
        """)
    let blocks = Array(document.children)
    XCTAssertTrue(blocks.contains { $0 is Heading })
    XCTAssertTrue(blocks.contains { $0 is BlockQuote })
    XCTAssertTrue(blocks.contains { $0 is UnorderedList })
    XCTAssertEqual((blocks.first { $0 is CodeBlock } as? CodeBlock)?.language, "json")
    let table = blocks.first { $0 is Table } as? Table
    XCTAssertEqual(table?.maxColumnCount, 2)
    XCTAssertEqual(table?.body.childCount, 1)
  }

  func testInlineFormattingKeepsBoldCodeAndLinks() {
    let text = markdownInlineText("**bold** `code` [docs](https://example.test)")
    XCTAssertEqual(String(text.characters), "bold code docs")
    XCTAssertTrue(
      text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    XCTAssertTrue(text.runs.contains { $0.font != nil })
    XCTAssertEqual(text.runs.first { $0.link != nil }?.link?.absoluteString, "https://example.test")
  }

  func testImagesBecomeLinksWithoutLoadingRemoteResources() {
    let document = Document(parsing: "![diagram](https://example.test/image.png)")
    let paragraph = document.child(at: 0)!
    let source = markdownInlineSource(paragraph)
    XCTAssertFalse(source.hasPrefix("!"))
    XCTAssertEqual(
      markdownInlineText(source).runs.first { $0.link != nil }?.link?.absoluteString,
      "https://example.test/image.png")
  }
}
