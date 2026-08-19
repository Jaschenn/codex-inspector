import AppKit
import SwiftUI

/// 目录用 `open` 直接在 Finder 里打开进去看内容,文件用 "显示简介式" 的
/// activateFileViewerSelecting 在其所在文件夹里高亮选中——都是 Finder 里最符合直觉的行为。
func revealInFinder(_ path: String?) {
    guard let path, !path.isEmpty else { return }
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
    if isDir.boolValue {
        NSWorkspace.shared.open(url)
    } else {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

struct RevealButton: View {
    let path: String?

    var body: some View {
        if let path, !path.isEmpty {
            Button {
                revealInFinder(path)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("在访达中显示")
        }
    }
}
