import SwiftUI

struct ReportUpdatedLabel: View {
  @ObservedObject var clock: ReportUpdateClock

  var body: some View {
    if let updated = clock.date {
      Text("更新于 \(updated.formatted(date: .omitted, time: .standard))")
        .monospacedDigit()
    }
  }
}

/// A refresh of the sidebar or clock must not rebuild an unchanged detail card.
/// Include every external input in the snapshot; local SwiftUI state still updates.
struct ReportSnapshotView<Content: View>: View, Equatable {
  let snapshot: [String: Any]
  @ViewBuilder let content: () -> Content

  static func == (lhs: Self, rhs: Self) -> Bool {
    NSDictionary(dictionary: lhs.snapshot).isEqual(to: rhs.snapshot)
  }

  var body: some View { content() }
}

struct ReportRevisionView<Content: View>: View, Equatable {
  let revision: Int
  @ViewBuilder let content: () -> Content

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.revision == rhs.revision }
  var body: some View { content() }
}

/// Compute presentation revisions on the engine queue. Avoid deep comparisons of
/// historical instructions and activity evidence inside the main-thread view graph.
func reportWithViewRevisions(_ report: [String: Any], previous: [String: Any]) -> [String: Any] {
  func inputs(_ report: [String: Any]) -> [String: [String: Any]] {
    let detail = report.subDict("selected_session")
    let turn = detail.subDict("selected_turn")
    let identity = ["session": detail.str("id") ?? "", "turn": turn.str("id") ?? ""]
    var overview: [String: Any] = ["identity": identity, "turn": turn]
    for key in ["cwd", "error", "directory_source", "rollout_path"] {
      if let value = detail[key] { overview[key] = value }
    }
    overview["project_root"] = detail.subDict("inspection")["project_root"]
    return [
      "overview": overview,
      "statistics": ["identity": identity, "data": turn.subDict("statistics")],
      "activity": [
        "identity": identity, "cwd": detail.str("cwd") ?? "", "data": turn.subDict("activity"),
      ],
    ]
  }
  let oldInputs = inputs(previous)
  let oldRevisions = previous.subDict("_view_revisions")
  var revisions: [String: Any] = [:]
  for (key, input) in inputs(report) {
    let unchanged = NSDictionary(dictionary: input).isEqual(to: oldInputs[key] ?? [:])
    revisions[key] = (oldRevisions.int(key) ?? 0) + (unchanged ? 0 : 1)
  }
  var result = report
  result["_view_revisions"] = revisions
  return result
}

/// Only the report's generation timestamp is presentation metadata. All nested
/// fields, including statuses, errors and selected-turn contents, remain significant.
func reportsHaveSameContent(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
  var left = lhs
  var right = rhs
  left.removeValue(forKey: "generated_at")
  right.removeValue(forKey: "generated_at")
  left.removeValue(forKey: "_view_revisions")
  right.removeValue(forKey: "_view_revisions")
  return NSDictionary(dictionary: left).isEqual(to: right)
}
