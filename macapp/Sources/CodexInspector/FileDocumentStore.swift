import Foundation

struct FileSnapshot {
  let url: URL
  let targetURL: URL
  let originalData: Data?
  let text: String
  let permissions: Int?
}

enum FileDocumentError: LocalizedError {
  case tooLarge, notUTF8, conflict, directory

  var errorDescription: String? {
    switch self {
    case .tooLarge: return "文件超过 2 MB，请使用外部编辑器打开。"
    case .notUTF8: return "文件不是 UTF-8 文本，无法在这里编辑。"
    case .conflict: return "文件已被其他应用修改或删除。为避免覆盖其他修改，请重新载入后再编辑。"
    case .directory: return "这是目录，请在 Finder 中打开，或选择其中的文本文件。"
    }
  }
}

enum FileDocumentStore {
  static let maximumBytes = 2 * 1024 * 1024

  static func load(_ url: URL) throws -> FileSnapshot {
    let logicalURL = url.standardizedFileURL
    let target = logicalURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
    if isDirectory.boolValue { throw FileDocumentError.directory }
    guard exists else {
      return FileSnapshot(
        url: logicalURL, targetURL: target, originalData: nil, text: "", permissions: nil)
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
    if (attributes[.size] as? NSNumber)?.intValue ?? 0 > maximumBytes {
      throw FileDocumentError.tooLarge
    }
    let data = try Data(contentsOf: target)
    guard data.count <= maximumBytes else { throw FileDocumentError.tooLarge }
    guard let text = String(data: data, encoding: .utf8) else { throw FileDocumentError.notUTF8 }
    return FileSnapshot(
      url: logicalURL, targetURL: target, originalData: data, text: text,
      permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue)
  }

  static func save(_ text: String, over snapshot: FileSnapshot) throws -> FileSnapshot {
    let target = snapshot.url.resolvingSymlinksInPath()
    guard target == snapshot.targetURL else { throw FileDocumentError.conflict }
    let exists = FileManager.default.fileExists(atPath: target.path)
    let current = exists ? try Data(contentsOf: target) : nil
    guard current == snapshot.originalData else { throw FileDocumentError.conflict }
    let data = Data(text.utf8)
    guard data.count <= maximumBytes else { throw FileDocumentError.tooLarge }
    // 对解析后的目标写入，保留符号链接；原子替换避免写入中断留下半份配置。
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: target, options: .atomic)
    if let permissions = snapshot.permissions {
      try FileManager.default.setAttributes(
        [.posixPermissions: permissions], ofItemAtPath: target.path)
    }
    return try load(snapshot.url)
  }
}

struct InspectedFile: Identifiable {
  let url: URL
  var id: String { url.path }
}
