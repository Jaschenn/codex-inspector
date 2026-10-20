import AppKit
import SwiftUI

struct SessionListItem: Equatable {
  let id: String
  let title: String
  let path: String
  let archived: Bool
}

/// NSTableView reuses only the visible rows, including their accessibility objects.
struct NativeSessionList: NSViewRepresentable {
  let items: [SessionListItem]
  @Binding var selection: String?

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let table = NSTableView()
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 60
    table.style = .sourceList
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.allowsEmptySelection = true
    table.delegate = context.coordinator
    table.dataSource = context.coordinator
    table.reloadData()
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = table
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let table = scroll.documentView as? NSTableView else { return }
    let changed = context.coordinator.parent.items != items
    context.coordinator.parent = self
    context.coordinator.updating = true
    if changed { table.reloadData() }
    let index = items.firstIndex { $0.id == selection }
    let indexes = index.map { IndexSet(integer: $0) } ?? []
    if indexes != table.selectedRowIndexes {
      table.selectRowIndexes(indexes, byExtendingSelection: false)
    }
    context.coordinator.updating = false
  }

  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var parent: NativeSessionList
    var updating = false
    init(_ parent: NativeSessionList) { self.parent = parent }

    func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      let id = NSUserInterfaceItemIdentifier("SessionCell")
      let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SessionCell ?? SessionCell()
      cell.identifier = id
      let item = parent.items[row]
      cell.title.stringValue = (item.archived ? "▣ " : "") + item.title
      cell.path.stringValue = shortenPath(item.path)
      cell.toolTip = item.path
      cell.setAccessibilityLabel("选择聊天：\(item.title)")
      return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
      guard !updating, let table = notification.object as? NSTableView else { return }
      parent.selection =
        parent.items.indices.contains(table.selectedRow)
        ? parent.items[table.selectedRow].id : nil
    }
  }

  final class SessionCell: NSTableCellView {
    let title = NSTextField(labelWithString: "")
    let path = NSTextField(labelWithString: "")
    init() {
      super.init(frame: .zero)
      title.font = .systemFont(ofSize: 13, weight: .medium)
      title.maximumNumberOfLines = 2
      title.lineBreakMode = .byTruncatingTail
      path.font = .systemFont(ofSize: 11)
      path.textColor = .secondaryLabelColor
      path.lineBreakMode = .byTruncatingMiddle
      for field in [title, path] { addSubview(field) }
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
      super.layout()
      title.frame = NSRect(x: 8, y: 24, width: max(0, bounds.width - 16), height: 32)
      path.frame = NSRect(x: 8, y: 6, width: max(0, bounds.width - 16), height: 16)
    }
  }
}
