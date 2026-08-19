import SwiftUI

@main
struct CodexInspectorApp: App {
    @StateObject private var fetcher = ReportFetcher(interval: 3.0)

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(fetcher: fetcher)
        } label: {
            MenuBarLabel(fetcher: fetcher)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var fetcher: ReportFetcher

    private var count: Int { fetcher.report.int("process_count") ?? 0 }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
            if fetcher.lastError == nil {
                Text("\(count)")
            }
        }
    }

    private var iconName: String {
        if fetcher.lastError != nil { return "exclamationmark.triangle" }
        return count > 0 ? "bolt.fill" : "bolt.slash"
    }
}
