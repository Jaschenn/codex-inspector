import Foundation

/// UTF-16 offsets match TextKit. Built once per edit, never once per scroll frame.
struct TextLineIndex {
  private(set) var starts = [0]

  init(_ text: String = "") {
    let units = Array(text.utf16)
    for index in units.indices {
      let unit = units[index]
      if unit == 10 || unit == 0x2028 || unit == 0x2029
        || (unit == 13 && (index + 1 == units.count || units[index + 1] != 10))
      {
        starts.append(index + 1)
      }
    }
  }

  func line(at offset: Int) -> Int {
    var low = 0
    var high = starts.count
    while low < high {
      let mid = (low + high) / 2
      if starts[mid] <= offset { low = mid + 1 } else { high = mid }
    }
    return max(0, low - 1)
  }
}
