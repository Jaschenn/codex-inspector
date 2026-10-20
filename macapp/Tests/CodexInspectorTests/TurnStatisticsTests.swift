import XCTest

@testable import CodexInspector

final class TurnStatisticsTests: XCTestCase {
  func testTokenPercentagesUseTheirRespectiveTotals() {
    XCTAssertEqual(tokenPercentage(900, of: 1000), "90.0%")
    XCTAssertEqual(tokenPercentage(100, of: 1000), "10.0%")
    XCTAssertEqual(tokenPercentage(300, of: 600), "50.0%")
  }

  func testTokenPercentageDoesNotInventZeroForMissingOrInvalidTotals() {
    XCTAssertNil(tokenPercentage(0, of: 0))
    XCTAssertNil(tokenPercentage(100, of: nil))
    XCTAssertNil(tokenPercentage(nil, of: 100))
    XCTAssertNil(tokenPercentage(200, of: 100))
  }
  func testTimelineSegmentKeepsExactDurationAndCategory() {
    let segment = TimingSegment(
      index: 0,
      data: ["start_ms": 100, "end_ms": 400, "category": "command", "components": ["command"]])
    XCTAssertEqual(segment?.duration, 300)
    XCTAssertEqual(segment?.category, .command)
  }

  func testUnknownCategoryRemainsUnknown() {
    let segment = TimingSegment(
      index: 0, data: ["start_ms": 0, "end_ms": 100, "category": "unrecognized"])
    XCTAssertEqual(segment?.category, .unknown)
    XCTAssertNil(TimingSegment(index: 1, data: [:]))
    XCTAssertNil(TimingSegment(index: 2, data: ["start_ms": 200, "end_ms": 100]))
  }

  func testDurationFormattingHandlesMissingAndLongDurations() {
    XCTAssertEqual(formattedDuration(-1), "未记录")
    XCTAssertEqual(formattedDuration(0), "0 毫秒")
    XCTAssertEqual(formattedDuration(65000), "1 分 5 秒")
    XCTAssertEqual(formattedDuration(3_600_000), "1 小时 0 分")
  }
}
