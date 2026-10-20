import XCTest

@testable import CodexInspector

final class ProcessSelectionTests: XCTestCase {
  func testChatSelectionIsPreservedWhenRecentOrderChanges() {
    XCTAssertEqual(
      reconciledSessionSelection("selected", sessionIDs: ["new", "selected"]), "selected")
  }

  func testRemovedChatFallsBackToMostRecentChat() {
    XCTAssertEqual(reconciledSessionSelection("removed", sessionIDs: ["recent"]), "recent")
    XCTAssertNil(reconciledSessionSelection("removed", sessionIDs: []))
  }
  func testRefreshPreservesSelectionWhenProcessesReorder() {
    XCTAssertEqual(reconciledProcessSelection(42, processIDs: [99, 42, 7]), 42)
  }

  func testExitedProcessFallsBackToAvailableProcess() {
    XCTAssertEqual(reconciledProcessSelection(42, processIDs: [99, 7]), 99)
  }

  func testEmptyProcessListClearsSelection() {
    XCTAssertNil(reconciledProcessSelection(42, processIDs: []))
  }

  func testFirstDetectedProcessIsSelected() {
    XCTAssertEqual(reconciledProcessSelection(nil, processIDs: [42, 99]), 42)
  }

  func testBackgroundServerWithoutGitProjectHasNeutralPresentation() {
    let proc: [String: Any] = ["cwd": "/", "is_git_repo": false, "trust_level": "unknown"]
    XCTAssertEqual(trustPresentation(for: proc).label, "— 未关联 Git 项目")
  }

  func testDirectoryReadFailureRemainsUnknown() {
    let proc: [String: Any] = ["is_git_repo": false, "trust_level": "unknown"]
    XCTAssertEqual(trustPresentation(for: proc).label, "❔ 信任状态未知")
  }

  func testGitProjectWithMissingTrustRecordRemainsUnknown() {
    let proc: [String: Any] = ["cwd": "/project", "is_git_repo": true, "trust_level": "unknown"]
    XCTAssertEqual(trustPresentation(for: proc).label, "❔ 信任状态未知")
  }
}
