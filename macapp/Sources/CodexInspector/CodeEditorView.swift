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
    let scroll = NSScrollView()
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
    textView.delegate = context.coordinator
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    scroll.documentView = textView
    scroll.verticalRulerView = LineNumberRuler(textView: textView, scrollView: scroll)
    scroll.hasVerticalRuler = true
    scroll.rulersVisible = true
    context.coordinator.textView = textView
    controller?.textView = textView
    updateNSView(scroll, context: context)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let textView = scroll.documentView as? NSTextView else { return }
    let coordinator = context.coordinator
    let needsHighlight =
      textView.string != text || coordinator.language != language
      || coordinator.fontSize != fontSize
    coordinator.parent = self
    coordinator.isUpdating = true
    textView.isEditable = isEditable
    if textView.string != text {
      let selection = textView.selectedRange()
      textView.string = text
      let length = (text as NSString).length
      textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }
    textView.isHorizontallyResizable = !wrapsLines
    scroll.hasHorizontalScroller = !wrapsLines
    textView.textContainer?.widthTracksTextView = wrapsLines
    textView.textContainer?.containerSize = NSSize(
      width: wrapsLines ? max(100, scroll.contentSize.width - 24) : CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude)
    if wrapsLines {
      textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: textView.frame.height))
    }
    if needsHighlight { coordinator.highlight() }
    coordinator.language = language
    coordinator.fontSize = fontSize
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
    private var highlightWork: DispatchWorkItem?

    init(_ parent: CodeEditorView) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard !isUpdating, let textView else { return }
      parent.text = textView.string
      textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
      highlightWork?.cancel()
      // 短暂合并连续输入，避免每个按键都对整个文件重新高亮。
      let work = DispatchWorkItem { [weak self] in self?.highlight() }
      highlightWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView else { return }
      let prefix = (textView.string as NSString).substring(
        to: min(textView.selectedRange().location, (textView.string as NSString).length))
      let parts = prefix.components(separatedBy: "\n")
      parent.onSelectionChange?(parts.count, (parts.last ?? "").count + 1)
    }

    func highlight() {
      guard let textView, let storage = textView.textStorage else { return }
      isUpdating = true
      let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
      SyntaxHighlighter.apply(to: storage, language: parent.language, font: font)
      textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
      isUpdating = false
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
    var index = string.lineRange(
      for: NSRange(location: min(characters.location, string.length), length: 0)
    ).location
    var number = string.substring(to: index).filter { $0 == "\n" }.count + 1
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
      let label = String(number) as NSString
      label.draw(
        at: NSPoint(
          x: ruleThickness - label.size(withAttributes: attributes).width - 10, y: position.y),
        withAttributes: attributes)
      let next = NSMaxRange(string.lineRange(for: NSRange(location: index, length: 0)))
      guard next > index else { break }
      index = next
      number += 1
    }
    if string.length == 0 || textView.string.hasSuffix("\n") {
      let finalLine = layout.extraLineFragmentRect
      let position = convert(
        NSPoint(x: 0, y: finalLine.minY + textView.textContainerOrigin.y), from: textView)
      let label = String(textView.string.filter { $0 == "\n" }.count + 1) as NSString
      label.draw(
        at: NSPoint(
          x: ruleThickness - label.size(withAttributes: attributes).width - 10, y: position.y),
        withAttributes: attributes)
    }
  }
}

struct CodeBlockView: View {
  let text: String
  let language: CodeLanguage
  var maxHeight: CGFloat = 440
  @State private var wrapsLines = true
  @StateObject private var controller = CodeEditorController()

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
