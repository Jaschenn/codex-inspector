import XCTest

@testable import CodexInspector

final class TurnActivityTests: XCTestCase {
  func testSamePathMergesActionsAndPreservesFailureEvidence() {
    let targets = activityTargets([
      "targets": [
        ["path": "/project/src/a.swift", "action": "read", "count": 2],
        ["path": "/project/src/a.swift", "action": "modify", "failed": 1],
        ["path": "/project/b.swift", "action": "read"],
      ]
    ])
    XCTAssertEqual(targets.count, 2)
    XCTAssertEqual(targets[0].name, "a.swift")
    XCTAssertEqual(targets[0].actions, ["read", "modify"])
    XCTAssertEqual(targets[0].failed, 1)
    XCTAssertEqual(targets[0].records.count, 2)
  }

  func testRelativeDirectoriesRespectPathBoundaries() {
    let nested = ActivityTarget(path: "/project/src/a.swift", records: [])
    XCTAssertEqual(nested.parent(relativeTo: "/project"), "src")
    let root = ActivityTarget(path: "/project/a.swift", records: [])
    XCTAssertEqual(root.parent(relativeTo: "/project"), "项目根目录")
    let external = ActivityTarget(path: "/project-other/a.swift", records: [])
    XCTAssertEqual(external.parent(relativeTo: "/project"), "/project-other")
  }

  func testFailedChangesAreNotPresentedAsSuccessfulWrites() {
    let text = activityTargetDescription([
      "action": "modify", "evidence": "file_change", "count": 1,
      "completed": 0, "failed": 1, "tools": ["apply_patch"],
    ])
    XCTAssertTrue(text.contains("完成 0"))
    XCTAssertTrue(text.contains("失败／未批准 1"))
    XCTAssertTrue(text.contains("apply_patch"))
  }

  func testReadTargetDoesNotClaimSuccess() {
    let text = activityTargetDescription([
      "action": "read", "evidence": "command_target", "count": 2,
      "completed": 2, "tools": ["exec_command"],
    ])
    XCTAssertTrue(text.contains("命令／工具目标"))
    XCTAssertFalse(text.contains("完成"))
    XCTAssertEqual(activityStatus("returned"), "已返回")
    XCTAssertEqual(activityStatus("unexpected"), "状态未确认")
  }
}
