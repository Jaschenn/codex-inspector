import Darwin
import Foundation

enum MemoryReclaimer {
  private static var lastScheduled = Date.distantPast

  /// Text layout and decoded snapshots create short-lived allocations. Return their
  /// unused pages after a burst, rather than retaining allocator high-water marks.
  /// This never discards live documents, undo history, or parsed application data.
  static func afterActivity() {
    guard Date().timeIntervalSince(lastScheduled) >= 15 else { return }
    lastScheduled = Date()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
      malloc_zone_pressure_relief(nil, 0)
    }
  }
}
