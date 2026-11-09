import Foundation

/// Engine diagnostics for the double-clicked app, which has no visible stdout. Writes are
/// serialized (stderr handler and engine queue both log) and the file is capped in size.
enum DebugLog {
  private static let path = NSHomeDirectory() + "/Library/Logs/CodexInspectorDebug.log"
  private static let limit: UInt64 = 1024 * 1024
  private static let queue = DispatchQueue(label: "CodexInspector.DebugLog")

  static func write(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    queue.async {
      if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64,
        size > limit
      {
        // Keep one previous generation; diagnostics are only for recent failures.
        let previous = path + ".1"
        try? FileManager.default.removeItem(atPath: previous)
        try? FileManager.default.moveItem(atPath: path, toPath: previous)
      }
      if let handle = FileHandle(forWritingAtPath: path) {
        // Diagnostic failure must not crash the inspector during engine recovery.
        defer { try? handle.close() }
        do {
          try handle.seekToEnd()
          try handle.write(contentsOf: data)
        } catch { return }
      } else {
        try? data.write(to: URL(fileURLWithPath: path))
      }
    }
  }
}
