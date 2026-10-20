import Foundation

enum FileSyntaxError: LocalizedError {
  case invalid(String)
  case unavailable

  var errorDescription: String? {
    switch self {
    case .invalid(let message): return "语法检查未通过：\(message)"
    case .unavailable: return "找不到 Rust 检查引擎，无法校验 TOML；请检查应用打包是否完整。"
    }
  }
}

enum FileSyntaxValidator {
  static func validate(_ text: String, for url: URL) throws {
    switch url.pathExtension.lowercased() {
    case "json":
      try validateJSON(text)
    case "jsonl":
      for (index, line) in text.components(separatedBy: .newlines).enumerated()
      where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        do { try validateJSON(line) } catch {
          throw FileSyntaxError.invalid("第 \(index + 1) 行：\(error.localizedDescription)")
        }
      }
    case "toml":
      try validateTOML(text)
    default: break
    }
  }

  static func validateJSON(_ text: String) throws {
    do {
      _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    } catch {
      let detail = (error as NSError).userInfo["NSDebugDescription"] as? String
      throw FileSyntaxError.invalid(detail ?? error.localizedDescription)
    }
  }

  private static func validateTOML(_ text: String) throws {
    let executable = Bundle.main.bundleURL
      .appendingPathComponent("Contents/MacOS/codex-inspector-core")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw FileSyntaxError.unavailable
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--validate-toml"]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    try input.fileHandleForWriting.close()
    let response = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      throw FileSyntaxError.invalid(String(data: response, encoding: .utf8) ?? "TOML 解析失败")
    }
  }
}
