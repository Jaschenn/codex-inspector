import CoreServices
import Foundation

/// FSEvents sees appends to existing rollouts and SQLite WAL writes as well as
/// creation/rotation. One-second polling remains a fallback for dropped events.
final class InspectionMonitor {
  private var stream: FSEventStreamRef?
  private var paths: [String] = []
  private let onChange: () -> Void

  init(onChange: @escaping () -> Void) { self.onChange = onChange }

  deinit { stop() }

  private func stop() {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
    stream = nil
  }

  func watch(report: [String: Any]) {
    let manager = FileManager.default
    var candidates = Set([NSHomeDirectory() + "/.codex", "/etc/codex"])
    if let sqliteHome = ProcessInfo.processInfo.environment["CODEX_SQLITE_HOME"] {
      candidates.insert(sqliteHome)
    }
    let objects = report.dictArray("processes") + [report.subDict("selected_session")]
    for object in objects {
      if let home = object.str("codex_home") { candidates.insert(home) }
      if let rollout = object.str("rollout_path") {
        candidates.insert(URL(fileURLWithPath: rollout).deletingLastPathComponent().path)
      }
      let inspection = object.subDict("inspection").isEmpty ? object : object.subDict("inspection")
      for key in ["config_layers", "agents_chain", "skills"] {
        for entry in inspection.dictArray(key) {
          if let path = entry.str("path") {
            candidates.insert(URL(fileURLWithPath: path).deletingLastPathComponent().path)
            candidates.insert(
              URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent().path)
          }
        }
      }
      if let cwd = object.str("cwd"), cwd != "/" { candidates.insert(cwd) }
    }
    if let rollout = report.subDict("menu_session").str("rollout_path") {
      candidates.insert(URL(fileURLWithPath: rollout).deletingLastPathComponent().path)
    }
    // Watch the closest existing ancestor when configuration folders do not exist yet.
    let existing = Set(
      candidates.map { path -> String in
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while !manager.fileExists(atPath: url.path), url.path != "/" {
          url.deleteLastPathComponent()
        }
        return url.path
      }
    ).filter { $0 != "/" }.sorted()
    let next = existing.filter { path in
      !existing.contains { parent in parent != path && path.hasPrefix(parent + "/") }
    }
    guard next != paths else { return }
    stop()
    paths = next
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil, release: nil, copyDescription: nil)
    stream = FSEventStreamCreate(
      nil,
      { _, info, count, eventPaths, flags, _ in
        guard let info else { return }
        let monitor = Unmanaged<InspectionMonitor>.fromOpaque(info).takeUnretainedValue()
        let strings = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        let dropped = (0..<count).contains {
          flags[$0]
            & UInt32(
              kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
        }
        if dropped || strings.contains(where: InspectionMonitor.isRelevant) { monitor.onChange() }
      }, &context, next as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
      FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
    if let stream {
      FSEventStreamSetDispatchQueue(stream, .main)
      if !FSEventStreamStart(stream) { stop() }
    }
  }

  private static func isRelevant(_ path: String) -> Bool {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return path.contains("/sessions/") || path.contains("/archived_sessions/")
      || path.contains("/skills/") || path.contains("/.git/")
      || name.hasPrefix("state_") || name == "session_index.jsonl"
      || name.hasSuffix(".config.toml") || name == "config.toml"
      || name == "AGENTS.md" || name == "AGENTS.override.md"
      || [".codex", ".agents", ".git", "skills", "sessions"].contains(name)
  }
}
