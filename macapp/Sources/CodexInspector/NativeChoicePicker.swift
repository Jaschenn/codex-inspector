import AppKit
import SwiftUI

struct PickerChoice: Equatable {
  let id: String?
  let title: String
}

/// Build long history menus only while open; SwiftUI otherwise retains every option view.
struct NativeChoicePicker: NSViewRepresentable {
  let title: String
  let choices: [PickerChoice]
  @Binding var selection: String?

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.controlSize = .small
    button.font = .systemFont(ofSize: 12)
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    button.target = context.coordinator
    button.action = #selector(Coordinator.select(_:))
    button.menu?.delegate = context.coordinator
    button.setAccessibilityLabel(title)
    context.coordinator.button = button
    return button
  }

  func updateNSView(_ button: NSPopUpButton, context: Context) {
    context.coordinator.parent = self
    guard !context.coordinator.menuOpen else { return }
    context.coordinator.compactMenu()
  }

  final class Coordinator: NSObject, NSMenuDelegate {
    var parent: NativeChoicePicker
    var menuOpen = false
    weak var button: NSPopUpButton?
    init(_ parent: NativeChoicePicker) { self.parent = parent }

    func menuNeedsUpdate(_ menu: NSMenu) {
      menu.removeAllItems()
      for choice in parent.choices {
        let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
        item.representedObject = choice.id
        item.state = choice.id == parent.selection ? .on : .off
        menu.addItem(item)
      }
      if let index = parent.choices.firstIndex(where: { $0.id == parent.selection }) {
        button?.selectItem(at: index)
      }
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) {
      menuOpen = false
      // The pop-up action may be delivered after menuDidClose.
      DispatchQueue.main.async { [weak self] in self?.compactMenu() }
    }

    func compactMenu() {
      guard !menuOpen, let button else { return }
      let label =
        parent.choices.first { $0.id == parent.selection }?.title
        ?? parent.choices.first?.title ?? parent.title
      if button.numberOfItems != 1 || button.titleOfSelectedItem != label {
        button.removeAllItems()
        button.addItem(withTitle: label)
      }
      button.lastItem?.representedObject = parent.selection
    }

    @objc func select(_ button: NSPopUpButton) {
      parent.selection = button.selectedItem?.representedObject as? String
    }
  }
}
