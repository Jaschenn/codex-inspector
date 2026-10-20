import AppKit
import XCTest

@testable import CodexInspector

final class FileDocumentStoreTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  func testUTF8ContentAndPermissionsSurviveSaving() throws {
    let url = directory.appendingPathComponent("SKILL.md")
    try "# 你好 🌍\r\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let original = try FileDocumentStore.load(url)
    XCTAssertEqual(original.text, "# 你好 🌍\r\n")
    let saved = try FileDocumentStore.save("# Updated\n", over: original)
    XCTAssertEqual(saved.text, "# Updated\n")
    XCTAssertEqual(saved.permissions, 0o600)
  }

  func testConcurrentModificationIsNotOverwritten() throws {
    let url = directory.appendingPathComponent("config.toml")
    try "model = 'original'".write(to: url, atomically: true, encoding: .utf8)
    let original = try FileDocumentStore.load(url)
    try "model = 'external'".write(to: url, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try FileDocumentStore.save("model = 'edited'", over: original))
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "model = 'external'")
  }

  func testDeletedFileIsNotSilentlyRecreated() throws {
    let url = directory.appendingPathComponent("config.toml")
    try "model = 'original'".write(to: url, atomically: true, encoding: .utf8)
    let original = try FileDocumentStore.load(url)
    try FileManager.default.removeItem(at: url)
    XCTAssertThrowsError(try FileDocumentStore.save("model = 'edited'", over: original))
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testNewFileDraftDoesNotWriteUntilSave() throws {
    let url = directory.appendingPathComponent(".codex/config.toml")
    let draft = try FileDocumentStore.load(url)
    XCTAssertNil(draft.originalData)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    _ = try FileDocumentStore.save("model = 'example'", over: draft)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "model = 'example'")
  }

  func testSymbolicLinkIsPreserved() throws {
    let target = directory.appendingPathComponent("actual.md")
    let link = directory.appendingPathComponent("SKILL.md")
    try "before".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let snapshot = try FileDocumentStore.load(link)
    _ = try FileDocumentStore.save("after", over: snapshot)
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "after")
  }

  func testBinaryDataIsRejected() throws {
    let url = directory.appendingPathComponent("binary")
    try Data([0xff, 0xfe, 0xff]).write(to: url)
    XCTAssertThrowsError(try FileDocumentStore.load(url))
  }

  func testInvalidJSONIsRejectedAndJSONLinesAreSupported() throws {
    XCTAssertThrowsError(try FileSyntaxValidator.validateJSON("{\"enabled\":}"))
    XCTAssertNoThrow(
      try FileSyntaxValidator.validate(
        "{\"a\":1}\n{\"b\":2}\n", for: URL(fileURLWithPath: "/example.jsonl")))
  }

  func testFormattedCommandPreservesQuotedArguments() {
    let command = "'/path with spaces/codex' -c 'model=\"example\"' app-server --listen stdio://"
    let formatted = formattedShellCommand(command)
    XCTAssertTrue(formatted.contains("'/path with spaces/codex'"))
    XCTAssertTrue(formatted.contains("-c 'model=\"example\"'"))
    XCTAssertTrue(formatted.contains("--listen stdio://"))
    XCTAssertTrue(formatted.contains("\\\n"))
  }

  func testAllLanguageRulesCompile() {
    for language in CodeLanguage.allCases where language != .plain {
      XCTAssertFalse(SyntaxHighlighter.rules(for: language).isEmpty)
    }
  }

  func testCommentMarkersInsideQuotedStringsKeepStringHighlighting() {
    let text = "url = \"https://example.test/#section\" # comment"
    let storage = NSTextStorage(string: text)
    SyntaxHighlighter.apply(
      to: storage, language: .toml, font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    let marker = (text as NSString).range(of: "#section").location
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: marker, effectiveRange: nil) as? NSColor, .systemGreen
    )
    let comment = (text as NSString).range(of: "# comment").location
    XCTAssertEqual(
      storage.attribute(.foregroundColor, at: comment, effectiveRange: nil) as? NSColor,
      .secondaryLabelColor)
  }
}
