import Darwin
import Foundation

/// A single pipe-owned Rust process reuses indexes and configuration caches.
/// All requests are serialized by ReportFetcher; no socket or background service.
final class InspectorEngine {
  private let executable: URL
  private var process: Process?
  private var input: FileHandle?
  private var output: FileHandle?
  private var stderr: FileHandle?

  init(executable: URL) { self.executable = executable }

  deinit { stop() }

  private func stop() {
    try? input?.close()
    if process?.isRunning == true { process?.terminate() }
    try? output?.close()
    stderr?.readabilityHandler = nil
    try? stderr?.close()
    process = nil
    input = nil
    output = nil
    stderr = nil
  }

  private func start() throws {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw FetchError("找不到 Rust 检查引擎：\(executable.path)")
    }
    let child = Process()
    child.executableURL = executable
    child.arguments = ["--serve"]
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    child.standardInput = stdinPipe
    child.standardOutput = stdoutPipe
    child.standardError = stderrPipe
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if !data.isEmpty {
        DebugLog.write("Rust: \(String(decoding: data.prefix(2000), as: UTF8.self))")
      } else {
        handle.readabilityHandler = nil
      }
    }
    try child.run()
    process = child
    input = stdinPipe.fileHandleForWriting
    output = stdoutPipe.fileHandleForReading
    stderr = stderrPipe.fileHandleForReading
  }

  func request(_ payload: [String: Any]) -> Result<[String: Any], FetchError> {
    do {
      if process?.isRunning != true {
        stop()
        try start()
      }
      guard let child = process, let input, let output else {
        throw FetchError("检查引擎未就绪")
      }
      // A broken or suspended engine must not leave the UI loading forever.
      let timeout = DispatchWorkItem {
        // SIGKILL also releases the pipe if the child was suspended with SIGSTOP.
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
      defer { timeout.cancel() }
      var data = try JSONSerialization.data(withJSONObject: payload)
      data.append(10)
      try input.write(contentsOf: data)
      var response = Data()
      while response.last != 10 {
        let chunk = output.availableData
        guard !chunk.isEmpty else { throw FetchError("检查引擎已退出或响应超时，将自动重启") }
        response.append(chunk)
        guard response.count <= 32 * 1024 * 1024 else { throw FetchError("检查快照超过 32 MB") }
      }
      guard let report = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
        throw FetchError("检查引擎返回了无效的 JSON 对象")
      }
      if let error = report.str("error") { throw FetchError(error) }
      return .success(report)
    } catch {
      stop()
      // Do not write raw snapshots to diagnostics: they contain private chat text.
      DebugLog.write("检查引擎请求失败：\(error.localizedDescription)")
      return .failure(FetchError((error as? FetchError)?.description ?? error.localizedDescription))
    }
  }
}
