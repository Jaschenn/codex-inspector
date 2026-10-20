import Markdown
import SwiftUI

func markdownInlineSource(_ node: any Markup) -> String {
  node.children.map { child in
    let formatted = child.format()
    // 图片转为普通链接，原生文本不会自动加载远程资源。
    if child is Markdown.Image, formatted.hasPrefix("!") { return String(formatted.dropFirst()) }
    return formatted
  }.joined()
}

func markdownInlineText(_ source: String) -> AttributedString {
  var text =
    (try? AttributedString(
      markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
    ?? AttributedString(source)
  for run in Array(text.runs) where run.inlinePresentationIntent?.contains(.code) == true {
    text[run.range].font = .system(size: 12, design: .monospaced)
    text[run.range].backgroundColor = Color.secondary.opacity(0.1)
  }
  return text
}

struct MarkdownContentView: View, Equatable {
  let source: String
  @Environment(\.openInspectedFile) private var openFile

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.source == rhs.source }

  var body: some View {
    MarkdownBlocks(nodes: Array(Document(parsing: source).children), depth: 0)
      .font(.system(size: 14))
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .environment(
        \.openURL,
        OpenURLAction { url in
          if url.isFileURL || (url.scheme == nil && url.path.hasPrefix("/")) {
            let file = url.isFileURL ? url : URL(fileURLWithPath: url.path)
            if ["png", "jpg", "jpeg", "gif", "webp", "pdf", "svg"].contains(
              file.pathExtension.lowercased())
            {
              NSWorkspace.shared.open(file)
            } else if FileManager.default.fileExists(atPath: file.path) {
              openFile(file)
            }
            return .handled
          }
          if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            return .systemAction
          }
          return .discarded
        })
  }
}

private struct MarkdownBlocks: View {
  let nodes: [any Markup]
  let depth: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
        MarkdownBlock(node: node, depth: depth)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MarkdownBlock: View {
  let node: any Markup
  let depth: Int

  var body: AnyView {
    if depth > 32 { return AnyView(Text(node.format())) }
    switch node {
    case let heading as Markdown.Heading:
      return AnyView(
        Text(markdownInlineText(markdownInlineSource(heading)))
          .font(
            .system(
              size: heading.level == 1 ? 22 : (heading.level == 2 ? 18 : 15), weight: .semibold)
          )
          .padding(.top, 5).frame(maxWidth: .infinity, alignment: .leading))
    case let paragraph as Markdown.Paragraph:
      return AnyView(
        Text(markdownInlineText(markdownInlineSource(paragraph)))
          .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading))
    case let code as Markdown.CodeBlock:
      return AnyView(
        CodeBlockView(text: code.code, language: codeLanguage(code.language), maxHeight: 340)
          .equatable())
    case let quote as Markdown.BlockQuote:
      return AnyView(
        HStack(alignment: .top, spacing: 12) {
          RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.5)).frame(width: 3)
          MarkdownBlocks(nodes: Array(quote.children), depth: depth + 1)
        }.fixedSize(horizontal: false, vertical: true).padding(12)
          .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6)))
    case let list as Markdown.UnorderedList:
      return AnyView(MarkdownList(items: Array(list.children), start: nil, depth: depth + 1))
    case let list as Markdown.OrderedList:
      return AnyView(
        MarkdownList(items: Array(list.children), start: Int(list.startIndex), depth: depth + 1))
    case let table as Markdown.Table:
      return AnyView(MarkdownTable(table: table))
    case is Markdown.ThematicBreak:
      return AnyView(Divider().padding(.vertical, 4))
    case let html as Markdown.HTMLBlock:
      return AnyView(Text(html.rawHTML).foregroundColor(.secondary))
    default:
      return AnyView(
        Text(markdownInlineText(node.format())).frame(maxWidth: .infinity, alignment: .leading))
    }
  }

  private func codeLanguage(_ name: String?) -> CodeLanguage {
    switch name?.lowercased() {
    case "python", "py": return .python
    case "typescript", "ts", "tsx": return .typescript
    case "javascript", "js", "jsx", "mjs": return .javascript
    case "shell", "bash", "sh", "zsh", "console": return .shell
    case "json", "jsonl": return .json
    case "toml": return .toml
    case "yaml", "yml": return .yaml
    case "swift": return .swift
    case "markdown", "md": return .markdown
    default: return .plain
    }
  }
}

private struct MarkdownList: View {
  let items: [any Markup]
  let start: Int?
  let depth: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, node in
        if let item = node as? Markdown.ListItem {
          HStack(alignment: .top, spacing: 8) {
            if let checkbox = item.checkbox {
              SwiftUI.Image(systemName: checkbox == .checked ? "checkmark.square" : "square")
                .foregroundColor(.secondary).frame(width: 22)
            } else {
              Text(start.map { "\($0 + index)." } ?? "•").foregroundColor(.secondary).frame(
                width: 22, alignment: .trailing)
            }
            MarkdownBlocks(nodes: Array(item.children), depth: depth)
          }
        }
      }
    }
  }
}

private struct MarkdownTable: View {
  let table: Markdown.Table

  var body: some View {
    ScrollView(.horizontal) {
      Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        GridRow {
          ForEach(Array(table.head.children.enumerated()), id: \.offset) { index, cell in
            tableCell(cell, column: index, header: true)
          }
        }
        ForEach(Array(table.body.children.enumerated()), id: \.offset) { rowIndex, row in
          GridRow {
            ForEach(Array(row.children.enumerated()), id: \.offset) { index, cell in
              tableCell(cell, column: index, header: false)
            }
          }
          .background(rowIndex.isMultiple(of: 2) ? Color.secondary.opacity(0.03) : .clear)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.18)))
    }
  }

  private func tableCell(_ cell: any Markup, column: Int, header: Bool) -> some View {
    let alignment: Alignment
    let textAlignment: TextAlignment
    let columnAlignment =
      column < table.columnAlignments.count ? table.columnAlignments[column] : nil
    switch columnAlignment {
    case .right:
      alignment = .trailing
      textAlignment = .trailing
    case .center:
      alignment = .center
      textAlignment = .center
    default:
      alignment = .leading
      textAlignment = .leading
    }
    return Text(markdownInlineText(markdownInlineSource(cell)))
      .font(.system(size: 13, weight: header ? .semibold : .regular))
      .multilineTextAlignment(textAlignment)
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: table.maxColumnCount <= 2 ? 240 : 170, alignment: alignment)
      .padding(10)
      .background(header ? Color.secondary.opacity(0.09) : .clear)
      .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.1), lineWidth: 0.5))
  }
}
