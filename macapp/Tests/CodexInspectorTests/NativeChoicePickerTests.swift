import AppKit
import SwiftUI
import XCTest

@testable import CodexInspector

final class NativeChoicePickerTests: XCTestCase {
  func testHistoryMenuKeepsSelectionAndReleasesClosedItems() {
    var selection: String? = "old"
    let picker = NativeChoicePicker(
      title: "轮次",
      choices: [
        PickerChoice(id: nil, title: "最新"), PickerChoice(id: "old", title: "历史轮次"),
      ], selection: Binding(get: { selection }, set: { selection = $0 }))
    let coordinator = picker.makeCoordinator()
    let button = NSPopUpButton()
    coordinator.button = button
    coordinator.compactMenu()
    XCTAssertEqual(button.numberOfItems, 1)
    XCTAssertEqual(button.titleOfSelectedItem, "历史轮次")
    coordinator.menuNeedsUpdate(button.menu!)
    XCTAssertEqual(button.numberOfItems, 2)
    XCTAssertEqual(button.indexOfSelectedItem, 1)
    button.selectItem(at: 0)
    coordinator.select(button)
    XCTAssertNil(selection)
    coordinator.compactMenu()
    XCTAssertEqual(button.numberOfItems, 1)
    XCTAssertEqual(button.titleOfSelectedItem, "最新")
  }
}
