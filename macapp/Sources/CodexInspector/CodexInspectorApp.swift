import SwiftUI

@main
struct CodexInspectorApp: App {
  @StateObject private var fetcher = ReportFetcher()

  var body: some Scene {
    Window("Codex Inspector", id: "inspector") {
      InspectorWindowView(fetcher: fetcher)
    }
    .defaultSize(width: 1160, height: 780)
    .windowResizability(.contentMinSize)

    // Keep the same compact summary available from the Window menu, including
    // when macOS hides a status item because the menu bar has insufficient space.
    Window("活动统计", id: "activity") {
      MenuContentView(fetcher: fetcher)
    }
    .windowResizability(.contentSize)

    MenuBarExtra {
      MenuContentView(fetcher: fetcher)
    } label: {
      MenuBarLabel(state: fetcher.menuBarState)
    }
    .menuBarExtraStyle(.window)
  }
}

struct MenuBarLabel: View {
  @ObservedObject var state: MenuBarState

  var body: some View {
    MenuBarStatusLabel(count: state.count, failed: state.failed).equatable()
  }
}

/// A live token/turn refresh does not change the menu-bar icon. Keep it outside
/// that invalidation path: macOS captures status-item replicants when it redraws.
struct MenuBarStatusLabel: View, Equatable {
  let count: Int
  let failed: Bool

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: failed ? "exclamationmark.triangle" : "terminal")
      if !failed {
        Text("\(count)")
      }
    }
  }

}
