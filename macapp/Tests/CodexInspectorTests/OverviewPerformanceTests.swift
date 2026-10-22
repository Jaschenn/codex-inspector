import AppKit
import Combine
import Darwin
import SwiftUI
import XCTest

@testable import CodexInspector

final class OverviewPerformanceTests: XCTestCase {
  func testRefreshTemporaryAllocationBenchmark() throws {
    guard let output = ProcessInfo.processInfo.environment["CODEX_INSPECTOR_REFRESH_BENCHMARK"]
    else { throw XCTSkip("Run explicitly to measure refresh temporary-object lifetimes") }
    let fixture: [String: Any] = [
      "generated_at": "fixture",
      "selected_session": [
        "id": "session", "cwd": "/fixture",
        "selected_turn": [
          "id": "turn",
          "activity": [
            "targets": (0..<5000).map { index in
              ["path": "/fixture/file\(index).swift", "action": "read", "count": 1]
            }
          ],
        ],
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: fixture)
    let previous = reportWithViewRevisions(fixture, previous: [:])
    func footprint() -> UInt64 {
      var usage = rusage_info_v2()
      let status = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
          proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
        }
      }
      XCTAssertEqual(status, 0)
      return usage.ri_phys_footprint
    }
    func run(pooled: Bool) throws -> [String: Any] {
      let before = footprint()
      var samples: [UInt64] = []
      let start = CFAbsoluteTimeGetCurrent()
      try autoreleasepool {
        for _ in 0..<40 {
          func legacy() throws -> Bool {
            let decoded = try autoreleasepool {
              try JSONSerialization.jsonObject(with: data) as! [String: Any]
            }
            return reportsHaveSameContent(previous, decoded)
          }
          let unchanged: Bool
          if pooled {
            unchanged = try autoreleasepool { try legacy() }
          } else {
            unchanged = try legacy()
          }
          XCTAssertTrue(unchanged)
          samples.append(footprint())
        }
      }
      return [
        "before_bytes": before, "peak_bytes": samples.max() ?? before,
        "after_pool_bytes": footprint(), "samples_bytes": samples,
        "elapsed_ms": (CFAbsoluteTimeGetCurrent() - start) * 1000,
      ]
    }
    var legacyRuns: [[String: Any]] = []
    var pooledRuns: [[String: Any]] = []
    if let strategy = ProcessInfo.processInfo.environment["CODEX_INSPECTOR_REFRESH_STRATEGY"] {
      // Separate test processes give each variant the same cold allocator state.
      if strategy == "legacy" {
        legacyRuns = [try run(pooled: false)]
      } else {
        pooledRuns = [try run(pooled: true)]
      }
    } else {
      // Alternate ordering for quick local checks; report each run separately.
      legacyRuns.append(try run(pooled: false))
      pooledRuns.append(try run(pooled: true))
      pooledRuns.append(try run(pooled: true))
      legacyRuns.append(try run(pooled: false))
    }
    let result: [String: Any] = [
      "fixture_bytes": data.count, "record_count": 5000,
      "iterations": 40, "legacy_runs": legacyRuns, "pooled_runs": pooledRuns,
      "method":
        "Same unchanged report comparison. Legacy pool covers decoding only; candidate also drains comparison temporaries each refresh. Synthetic background-preparation workload, excludes UI/engine and is not total app memory.",
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: output))
  }

  func testPresentationRevisionsIgnoreHistoryButTrackEvidenceAndDirectory() {
    let report: [String: Any] = [
      "selected_session": [
        "id": "session", "cwd": "/a", "turns": [["id": "history"]],
        "selected_turn": ["id": "turn", "activity": ["count": 1], "statistics": ["tokens": 3]],
      ]
    ]
    let first = reportWithViewRevisions(report, previous: [:])
    var next = report
    var detail = next.subDict("selected_session")
    detail["turns"] = [["id": "another-history"]]
    next["selected_session"] = detail
    let history = reportWithViewRevisions(next, previous: first)
    XCTAssertEqual(
      first.subDict("_view_revisions").int("overview"),
      history.subDict("_view_revisions").int("overview"))
    detail["cwd"] = "/b"
    next["selected_session"] = detail
    let moved = reportWithViewRevisions(next, previous: history)
    XCTAssertEqual(moved.subDict("_view_revisions").int("activity"), 2)
    XCTAssertEqual(moved.subDict("_view_revisions").int("statistics"), 1)
    var turn = detail.subDict("selected_turn")
    turn["activity"] = ["count": 2]
    detail["selected_turn"] = turn
    next["selected_session"] = detail
    let changed = reportWithViewRevisions(next, previous: moved)
    XCTAssertEqual(changed.subDict("_view_revisions").int("activity"), 3)
    XCTAssertEqual(changed.subDict("_view_revisions").int("statistics"), 1)
  }
  func testMenuBarStateDoesNotPublishUnchangedValues() {
    let state = MenuBarState()
    var changes = 0
    let subscription = state.objectWillChange.sink { changes += 1 }
    state.update(count: 2, failed: false)
    state.update(count: 2, failed: false)
    XCTAssertEqual(changes, 1)
    state.update(count: 2, failed: true)
    XCTAssertEqual(changes, 2)
    XCTAssertTrue(state.failed)
    withExtendedLifetime(subscription) {}
  }
  func testRefreshTimestampHasIndependentObservation() {
    let clock = ReportUpdateClock()
    var changes = 0
    let subscription = clock.objectWillChange.sink { changes += 1 }
    clock.date = Date(timeIntervalSince1970: 1)
    clock.date = Date(timeIntervalSince1970: 2)
    XCTAssertEqual(changes, 2)
    XCTAssertEqual(clock.date, Date(timeIntervalSince1970: 2))
    withExtendedLifetime(subscription) {}
  }
  func testMenuBarOnlyChangesForCountOrError() {
    let label = MenuBarStatusLabel(count: 2, failed: false)
    XCTAssertEqual(label, MenuBarStatusLabel(count: 2, failed: false))
    XCTAssertNotEqual(label, MenuBarStatusLabel(count: 3, failed: false))
    XCTAssertNotEqual(label, MenuBarStatusLabel(count: 2, failed: true))
  }
  func testSnapshotComparisonIgnoresOnlyGenerationTimestamp() {
    let first: [String: Any] = [
      "generated_at": "first",
      "selected_session": [
        "id": "session", "selected_turn": ["status": "completed", "count": 4],
      ],
    ]
    var next = first
    next["generated_at"] = "next"
    XCTAssertTrue(reportsHaveSameContent(first, next))
    next["selected_session"] = [
      "id": "session", "selected_turn": ["status": "failed", "count": 4],
    ]
    XCTAssertFalse(reportsHaveSameContent(first, next))
    next = first
    next["error"] = "engine failed"
    XCTAssertFalse(reportsHaveSameContent(first, next))
    XCTAssertFalse(reportsHaveSameContent(["turn": NSNull()], [:]))
    XCTAssertFalse(reportsHaveSameContent(["items": [1, 2]], ["items": [2, 1]]))
  }

  func testCardSnapshotIncludesDirectoryAndNestedEvidence() {
    let original = ReportSnapshotView(snapshot: [
      "cwd": "/a", "activity": ["targets": [["path": "/a/f", "failed": 0]]],
    ]) { Text("card") }
    let otherDirectory = ReportSnapshotView(snapshot: [
      "cwd": "/b", "activity": ["targets": [["path": "/a/f", "failed": 0]]],
    ]) { Text("card") }
    let failed = ReportSnapshotView(snapshot: [
      "cwd": "/a", "activity": ["targets": [["path": "/a/f", "failed": 1]]],
    ]) { Text("card") }
    XCTAssertEqual(original, original)
    XCTAssertNotEqual(original, otherDirectory)
    XCTAssertNotEqual(original, failed)
  }

  func testMalformedDurationCannotOverflowIntegerConversion() {
    XCTAssertEqual(formattedDuration(Double.greatestFiniteMagnitude), "超出可显示范围")
    XCTAssertEqual(formattedDuration(.infinity), "未记录")
    XCTAssertEqual(formattedDuration(.nan), "未记录")
    XCTAssertEqual(formattedDuration(-1), "未记录")
    XCTAssertEqual(formattedDuration(3_600_000), "1 小时 0 分")
  }

  func testTimelineUpdateClearsStaleTooltip() {
    let plot = NativeTimelineView.Plot()
    plot.toolTip = "old segment"
    plot.resetHover()
    XCTAssertNil(plot.toolTip)
  }

  func testActivityPreparationBenchmark() throws {
    guard let output = ProcessInfo.processInfo.environment["CODEX_INSPECTOR_OVERVIEW_BENCHMARK"]
    else { throw XCTSkip("Run explicitly to record the overview preparation benchmark") }
    // Multiple evidence records per path reproduce the inventory's grouping work.
    let records: [[String: Any]] = (0..<1000).flatMap { index in
      ["read", "modify"].map { action in
        ["path": "/fixture/src/file\(index).swift", "action": action, "count": 1]
      }
    }
    let activity: [String: Any] = ["targets": records]
    var repeated: [Double] = []
    var prepared: [Double] = []
    var checksum = 0
    for _ in 0..<20 {
      let start = CFAbsoluteTimeGetCurrent()
      // Eight visible rows plus metrics/summary caused repeated full-list access.
      for _ in 0..<12 { checksum += activityTargets(activity).count }
      repeated.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
      let next = CFAbsoluteTimeGetCurrent()
      let targets = activityTargets(activity)
      for _ in 0..<12 { checksum += targets.count }
      prepared.append((CFAbsoluteTimeGetCurrent() - next) * 1000)
      XCTAssertEqual(targets.count, 1000)
      XCTAssertEqual(targets.first?.actions, ["read", "modify"])
    }
    let result: [String: Any] = [
      "path_count": 1000, "record_count": records.count, "iterations": 20,
      "repeated_preparation_ms": repeated, "single_preparation_ms": prepared,
      "checksum": checksum,
      "method":
        "Same 12 inventory accesses per pass; repeated grouping/sorting versus one preparation. Excludes layout, drawing and display frame rate.",
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: output))
  }
}
