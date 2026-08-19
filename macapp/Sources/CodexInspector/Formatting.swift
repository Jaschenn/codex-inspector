import SwiftUI

func shortenPath(_ path: String?) -> String {
    guard let path, !path.isEmpty else { return "-" }
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

func trustLabel(_ t: String?) -> String {
    switch t {
    case "trusted": return "✅ trusted"
    case "untrusted": return "⛔ untrusted"
    default: return "❔ unknown"
    }
}

func trustColor(_ t: String?) -> Color {
    switch t {
    case "trusted": return .green
    case "untrusted": return .red
    default: return .yellow
    }
}

func fmtBool(_ b: Bool?) -> String { (b ?? false) ? "✅" : "❌" }
