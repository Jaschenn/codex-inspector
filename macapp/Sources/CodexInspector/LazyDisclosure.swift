import SwiftUI

/// DisclosureGroup may evaluate collapsed content; defer native text views until opened.
struct LazyDisclosure<Content: View>: View {
  let title: String
  let content: () -> Content
  @State private var expanded = false

  init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.content = content
  }

  var body: some View {
    DisclosureGroup(title, isExpanded: $expanded) {
      if expanded { content() }
    }
  }
}
