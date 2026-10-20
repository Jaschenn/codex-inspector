import AppKit
import SwiftUI

final class CodeEditorController: ObservableObject {
  weak var textView: NSTextView?

  func showFind() {
    guard let textView else { return }
    textView.window?.makeFirstResponder(textView)
    let item = NSMenuItem()
    item.tag = NSTextFinder.Action.showFindInterface.rawValue
    textView.performFindPanelAction(item)
  }

  func undo() { textView?.undoManager?.undo() }
  func redo() { textView?.undoManager?.redo() }
}

struct CodeEditorView: NSViewRepresentable {
  @Binding var text: String
  let language: CodeLanguage
  var isEditable = false
  var wrapsLines = true
  var fontSize: CGFloat = 13
  var controller: CodeEditorController? = nil
  var onSelectionChange: ((Int, Int) -> Void)? = nil

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    makeScrollView(coordinator: context.coordinator)
  }

  func makeScrollView(coordinator: Coordinator) -> NSScrollView {
    let scroll = EditorScrollView()
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = !wrapsLines
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    let textView = IndentedTextView(frame: .zero)
    textView.isRichText = false
    textView.isSelectable = true
    textView.isEditable = isEditable
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.textContainerInset = NSSize(width: 12, height: 14)
    textView.backgroundColor = .textBackgroundColor
    textView.delegate = coordinator
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.layoutManager?.allowsNonContiguousLayout = true
    textView.layoutManager?.backgroundLayoutEnabled = false
    // The scroll view owns width negotiation, including the ruler; automatic document
    // resizing can re-expand it after AppKit lays out the clip view.
    textView.autoresizingMask = []
    scroll.documentView = textView
    scroll.verticalRulerView = LineNumberRuler(textView: textView, scrollView: scroll)
    scroll.hasVerticalRuler = true
    scroll.rulersVisible = true
    coordinator.textView = textView
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      coordinator, selector: #selector(Coordinator.viewportChanged),
      name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    controller?.textView = textView
    updateScrollView(scroll, coordinator: coordinator)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    updateScrollView(scroll, coordinator: context.coordinator)
  }

  func updateScrollView(_ scroll: NSScrollView, coordinator: Coordinator) {
    guard let textView = scroll.documentView as? NSTextView else { return }
    let textChanged = coordinator.source != text
    let syntaxChanged = textChanged || coordinator.language != language
    let fontChanged = coordinator.fontSize != fontSize
    let wrapChanged = coordinator.wrapsLines != wrapsLines
    coordinator.parent = self
    coordinator.isUpdating = true
    textView.isEditable = isEditable
    if textChanged {
      let selection = textView.selectedRange()
      textView.string = text
      coordinator.updateSource(text)
      let length = (text as NSString).length
      textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }
    if wrapChanged {
      textView.isHorizontallyResizable = !wrapsLines
      scroll.hasHorizontalScroller = !wrapsLines
      textView.textContainer?.widthTracksTextView = wrapsLines
      textView.textContainer?.containerSize = NSSize(
        width: wrapsLines
          ? max(100, scroll.contentView.bounds.width - 24) : CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude)
      coordinator.wrapsLines = wrapsLines
    }
    if let editorScroll = scroll as? EditorScrollView {
      editorScroll.wrapsLines = wrapsLines
      editorScroll.synchronizeTextWidth()
    }
    if fontChanged {
      let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
      textView.font = font
      textView.textColor = .labelColor
      textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
    }
    coordinator.language = language
    coordinator.fontSize = fontSize
    if syntaxChanged { coordinator.scheduleHighlight() }
    controller?.textView = textView
    coordinator.isUpdating = false
    scroll.verticalRulerView?.needsDisplay = true
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: CodeEditorView
    weak var textView: NSTextView?
    var isUpdating = false
    var language: CodeLanguage?
    var fontSize: CGFloat = 0
    var wrapsLines: Bool?
    var source = ""
    var lineIndex = TextLineIndex()
    private var highlightWork: DispatchWorkItem?
    private var operation: BlockOperation?
    private var generation = 0
    private var matches: [SyntaxHighlighter.Matches] = []
    private var highlightedRange = NSRange(location: 0, length: 0)
    private static let syntaxQueue: OperationQueue = {
      let queue = OperationQueue()
      queue.maxConcurrentOperationCount = 1
      queue.qualityOfService = .userInitiated
      return queue
    }()

    init(_ parent: CodeEditorView) { self.parent = parent }

    deinit {
      highlightWork?.cancel()
      operation?.cancel()
      NotificationCenter.default.removeObserver(self)
    }

    func updateSource(_ text: String) {
      source = text
      lineIndex = TextLineIndex(text)
      (textView?.enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.lineIndex = lineIndex
    }

    func textDidChange(_ notification: Notification) {
      guard !isUpdating, let textView else { return }
      updateSource(textView.string)
      parent.text = source
      textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
      scheduleHighlight(delay: 0.12)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView else { return }
      let position = min(textView.selectedRange().location, (source as NSString).length)
      let line = lineIndex.line(at: position)
      let prefix = (source as NSString).substring(
        with: NSRange(location: lineIndex.starts[line], length: position - lineIndex.starts[line]))
      parent.onSelectionChange?(line + 1, prefix.count + 1)
    }

    func scheduleHighlight(delay: TimeInterval = 0) {
      generation += 1
      let revision = generation
      highlightWork?.cancel()
      operation?.cancel()
      matches = []
      clearHighlight()
      let source = source
      let language = parent.language
      let work = DispatchWorkItem { [weak self] in
        guard let self, self.generation == revision else { return }
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
          let result = SyntaxHighlighter.matches(in: source, language: language) {
            operation?.isCancelled != false
          }
          guard operation?.isCancelled == false else { return }
          DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == revision else { return }
            self.matches = result
            self.highlightViewport()
          }
        }
        self.operation = operation
        Self.syntaxQueue.addOperation(operation)
      }
      highlightWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @objc func viewportChanged(_ notification: Notification) {
      highlightViewport()
    }

    private func clearHighlight() {
      guard let textView, let layout = textView.layoutManager else { return }
      let range = NSIntersectionRange(
        highlightedRange, NSRange(location: 0, length: (source as NSString).length))
      layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
      highlightedRange = NSRange(location: 0, length: 0)
    }

    func highlightViewport() {
      guard !matches.isEmpty, let textView, let layout = textView.layoutManager,
        let container = textView.textContainer
      else { return }
      let rect = textView.visibleRect.offsetBy(
        dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y
      )
      .insetBy(dx: 0, dy: -120)
      let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
      let range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      guard range != highlightedRange else { return }
      clearHighlight()
      // Temporary foreground attributes invalidate drawing only, never glyph layout.
      for group in matches {
        for match in group.intersecting(range) {
          layout.addTemporaryAttribute(
            .foregroundColor, value: group.color,
            forCharacterRange: NSIntersectionRange(match, range))
        }
      }
      highlightedRange = range
    }
  }
}

private final class EditorScrollView: NSScrollView {
  var wrapsLines = true

  override func tile() {
    super.tile()
    synchronizeTextWidth()
  }

  override func layout() {
    super.layout()
    synchronizeTextWidth()
  }

  func synchronizeTextWidth() {
    guard wrapsLines, let textView = documentView as? NSTextView else { return }
    // contentSize includes space occupied by the line-number ruler on some macOS versions.
    // Use the actual clip view and follow native resizes, so wrapped text never hides behind
    // the right edge while SwiftUI is still negotiating the sheet or card size.
    let rulerWidth = rulersVisible ? (verticalRulerView?.ruleThickness ?? 0) : 0
    let width = min(contentView.bounds.width, bounds.width - rulerWidth)
    guard width > 0 else { return }
    if textView.frame.width != width {
      textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
    }
    let size = NSSize(
      width: max(100, width - textView.textContainerInset.width * 2),
      height: CGFloat.greatestFiniteMagnitude)
    if textView.textContainer?.containerSize != size {
      textView.textContainer?.containerSize = size
    }
  }
}

private final class IndentedTextView: NSTextView {
  override func insertTab(_ sender: Any?) {
    insertText("  ", replacementRange: selectedRange())
  }

  override func insertNewline(_ sender: Any?) {
    let source = string as NSString
    let position = min(selectedRange().location, source.length)
    let lineRange = source.lineRange(for: NSRange(location: position, length: 0))
    let prefix = source.substring(
      with: NSRange(location: lineRange.location, length: position - lineRange.location))
    let indentation = String(prefix.prefix { $0 == " " || $0 == "\t" })
    let extra =
      prefix.trimmingCharacters(in: .whitespaces).last.map { "{[:".contains($0) } == true
      ? "  " : ""
    insertText("\n" + indentation + extra, replacementRange: selectedRange())
  }
}

private final class LineNumberRuler: NSRulerView {
  weak var textView: NSTextView?
  var lineIndex = TextLineIndex()

  init(textView: NSTextView, scrollView: NSScrollView) {
    self.textView = textView
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = textView
    ruleThickness = 52
  }

  required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let textView, let layout = textView.layoutManager, let container = textView.textContainer
    else { return }
    NSColor.controlBackgroundColor.setFill()
    bounds.fill()
    let string = textView.string as NSString
    let visible = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
    let characters = layout.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
    var number = lineIndex.line(at: min(characters.location, string.length))
    var index = lineIndex.starts[number]
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    let end = min(string.length, NSMaxRange(characters))
    while index < end {
      let glyph = layout.glyphIndexForCharacter(at: index)
      let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      let position = convert(
        NSPoint(x: 0, y: line.minY + textView.textContainerOrigin.y), from: textView)
      let label = String(number + 1) as NSString
      label.draw(
        at: NSPoint(
          x: ruleThickness - label.size(withAttributes: attributes).width - 10, y: position.y),
        withAttributes: attributes)
      number += 1
      guard number < lineIndex.starts.count else { break }
      index = lineIndex.starts[number]
    }
    if lineIndex.starts.last == string.length && layout.extraLineFragmentRect.height > 0 {
      let finalLine = layout.extraLineFragmentRect
      let position = convert(
        NSPoint(x: 0, y: finalLine.minY + textView.textContainerOrigin.y), from: textView)
      let label = String(lineIndex.starts.count) as NSString
      label.draw(
        at: NSPoint(
          x: ruleThickness - label.size(withAttributes: attributes).width - 10, y: position.y),
        withAttributes: attributes)
    }
  }
}

struct CodeBlockView: View, Equatable {
  let text: String
  let language: CodeLanguage
  var maxHeight: CGFloat = 440
  @State private var wrapsLines = true
  @StateObject private var controller = CodeEditorController()

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.text == rhs.text && lhs.language == rhs.language && lhs.maxHeight == rhs.maxHeight
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Text(language.rawValue).font(.caption.weight(.medium)).foregroundColor(.secondary)
        Spacer()
        Toggle("自动换行", isOn: $wrapsLines).toggleStyle(.checkbox).font(.caption)
        Button {
          controller.showFind()
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .help("查找内容")
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        } label: {
          Label("复制", systemImage: "doc.on.doc")
        }
        .font(.caption)
      }
      .padding(10)
      Divider()
      CodeEditorView(
        text: .constant(text), language: language, wrapsLines: wrapsLines, controller: controller
      )
      .frame(
        height: min(
          maxHeight, max(110, CGFloat(text.components(separatedBy: "\n").count) * 18 + 32)))
    }
    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
  }
}
