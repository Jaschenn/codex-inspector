import AppKit
import XCTest

@testable import CodexInspector

final class EditorPerformanceTests: XCTestCase {
  func testLineIndexHandlesUTF16AndAllTextKitLineEndings() {
    let text = "😀a\r\nb\rc\nd\u{2028}e\u{2029}"
    let index = TextLineIndex(text)
    XCTAssertEqual(index.starts, [0, 5, 7, 9, 11, 13])
    XCTAssertEqual(index.line(at: 4), 0)
    XCTAssertEqual(index.line(at: 5), 1)
    XCTAssertEqual(index.line(at: 13), 5)
    XCTAssertEqual(TextLineIndex().starts, [0])
    XCTAssertEqual(TextLineIndex("a").line(at: 1), 0)
  }

  func testViewportHighlightsPreserveMultilineStringsAndComments() {
    let source =
      "let value = \"https://example.test/#inside\"\n/* before\ninside comment\nafter */\nlet n = 10"
    let groups = SyntaxHighlighter.matches(in: source, language: .swift)
    let viewport = (source as NSString).range(of: "inside comment")
    let visible = groups.flatMap { $0.intersecting(viewport) }
    XCTAssertEqual(visible.count, 1)
    XCTAssertGreaterThan(visible[0].length, viewport.length)
    let stringMarker = (source as NSString).range(of: "#inside")
    let colors = groups.filter { !$0.intersecting(stringMarker).isEmpty }.map(\.color)
    XCTAssertEqual(colors.last, .systemGreen)
  }

  func testHighlightCancellationAndRangeBoundaries() {
    XCTAssertTrue(
      SyntaxHighlighter.matches(in: "let x = 1", language: .swift, cancelled: { true })
        .allSatisfy { $0.ranges.isEmpty })
    let matches = SyntaxHighlighter.Matches(
      color: .red,
      ranges: [
        NSRange(location: 0, length: 5), NSRange(location: 5, length: 2),
        NSRange(location: 12, length: 8),
      ])
    XCTAssertEqual(
      Array(matches.intersecting(NSRange(location: 5, length: 7))),
      [NSRange(location: 5, length: 2)])
    XCTAssertEqual(
      Array(matches.intersecting(NSRange(location: 15, length: 1))),
      [NSRange(location: 12, length: 8)])
  }

  func testIndexedScrollWorkload() throws {
    guard let output = ProcessInfo.processInfo.environment["CODEX_INSPECTOR_EDITOR_BENCHMARK"]
    else {
      throw XCTSkip("Run explicitly to record the release-mode editor benchmark")
    }
    let text = String(repeating: "setting = \"中文 UTF-8 preview\" # comment\n", count: 28000)
    let index = TextLineIndex(text)
    var oldTimes: [Double] = []
    var newTimes: [Double] = []
    var checksum = 0
    for step in 0..<100 {
      let offset = index.starts[step * 270]
      let start = CFAbsoluteTimeGetCurrent()
      let oldLine = (text as NSString).substring(to: offset).filter { $0 == "\n" }.count
      // The former ruler counted the entire file again for its trailing empty line.
      checksum += text.filter { $0 == "\n" }.count
      oldTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
      let next = CFAbsoluteTimeGetCurrent()
      let newLine = index.line(at: offset)
      checksum += index.starts.count - 1
      newTimes.append((CFAbsoluteTimeGetCurrent() - next) * 1000)
      XCTAssertEqual(oldLine, newLine)
    }
    let result: [String: Any] = [
      "fixture_utf8_bytes": text.utf8.count, "line_count": index.starts.count,
      "iterations": 100, "baseline_ms": oldTimes, "indexed_ms": newTimes,
      "checksum": checksum,
      "method":
        "Same UTF-16 scroll offsets; old per-frame prefix and full-file newline scans versus precomputed index. Excludes glyph drawing and UI frame latency.",
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: output))
  }
}
