import AppKit
import SwiftUI

/// Core Graphics avoids a Metal-backed Canvas and one view/layer per segment.
struct NativeTimelineView: NSViewRepresentable {
  let segments: [TimingSegment]
  let duration: Double
  var onHover: ((Double?) -> Void)? = nil

  func makeNSView(context: Context) -> Plot {
    let view = Plot()
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.image)
    return view
  }

  func updateNSView(_ view: Plot, context: Context) {
    if view.segments != segments || view.duration != duration {
      view.segments = segments
      view.duration = duration
      view.needsDisplay = true
    }
    view.onHover = onHover
    view.setAccessibilityLabel("本轮耗时分布，\(formattedDuration(duration))")
  }

  final class Plot: NSView {
    var segments: [TimingSegment] = []
    var duration: Double = 0
    var onHover: ((Double?) -> Void)?
    private var tracking: NSTrackingArea?
    private var hoveredID: Int?

    override func updateTrackingAreas() {
      if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(
        rect: .zero,
        options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
        owner: self, userInfo: nil)
      addTrackingArea(area)
      tracking = area
      super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
      let x = convert(event.locationInWindow, from: nil).x
      let time = min(max(0, x / max(1, bounds.width) * duration), max(0, duration - 0.001))
      let segment = segments.first { $0.start <= time && time < $0.end }
      if hoveredID != segment?.id {
        hoveredID = segment?.id
        toolTip = segment.map {
          "\($0.category.title) · \(formattedDuration($0.duration))\n\($0.category.explanation)"
        }
        needsDisplay = true
        onHover?(time)
      }
    }

    override func mouseExited(with event: NSEvent) {
      hoveredID = nil
      toolTip = nil
      onHover?(nil)
      needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
      guard duration > 0 else { return }
      NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).addClip()
      for segment in segments {
        let rect = NSRect(
          x: bounds.width * segment.start / duration, y: 0,
          width: bounds.width * segment.duration / duration, height: bounds.height)
        guard rect.intersects(dirtyRect) else { continue }
        segment.category.nativeColor.setFill()
        rect.fill()
        if segment.id == hoveredID && rect.width >= 1 {
          NSColor.labelColor.setStroke()
          NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
      }
    }
  }
}

extension TimelineCategory {
  var nativeColor: NSColor {
    switch self {
    case .firstToken: return .systemOrange
    case .reasoning: return .systemPurple
    case .output: return .systemBlue
    case .command: return .systemGreen
    case .tool: return .systemTeal
    case .overlap: return .systemPink
    case .unknown: return .systemGray
    }
  }
}
