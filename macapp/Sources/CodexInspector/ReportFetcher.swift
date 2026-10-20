import Combine
import Foundation

struct FetchError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { self.description = message }
}

/// 定时调用 Rust 检查引擎，读取 JSON 快照；日志和 Skill 分词均复用本地增量缓存。
final class ReportFetcher: ObservableObject {
  @Published var report: [String: Any] = [
    "generated_at": "", "process_count": 0, "processes": [], "process_errors": [],
  ]
  @Published var lastError: String?
  @Published var lastUpdated: Date?
  @Published var isRefreshing = false
  @Published var isSessionLoading = false

  private struct InspectionRequest: Equatable {
    var sessionID: String?
    var turnID: String?
    var includeArchived = false
    var includeOtherSources = false
  }
  private var inspectionRequest = InspectionRequest()

  func selectSession(
    _ sessionID: String?, turnID: String?, includeArchived: Bool = false,
    includeOtherSources: Bool = false
  ) {
    let request = InspectionRequest(
      sessionID: sessionID, turnID: turnID, includeArchived: includeArchived,
      includeOtherSources: includeOtherSources)
    guard request != inspectionRequest else { return }
    inspectionRequest = request
    isSessionLoading = sessionID != nil
    refresh()
  }

  private var timer: Timer?
  private let interval: TimeInterval
  private let inspectorExecutable: URL

  init(interval: TimeInterval = 3.0) {
    self.interval = interval
    self.inspectorExecutable = Bundle.main.bundleURL
      .appendingPathComponent("Contents/MacOS/codex-inspector-core")

    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      self?.refresh()
    }
  }

  deinit { timer?.invalidate() }

  func refresh() {
    guard !isRefreshing else { return }
    isRefreshing = true
    let request = inspectionRequest
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let result = self.runInspector(request: request)
      DispatchQueue.main.async {
        self.isRefreshing = false
        // 快速切换聊天时丢弃旧请求，避免上一聊天的内容闪现在新选择下。
        guard request == self.inspectionRequest else {
          self.refresh()
          return
        }
        self.isSessionLoading = false
        switch result {
        case .success(let dict):
          self.report = dict
          self.lastError = nil
          self.lastUpdated = Date()
        case .failure(let error):
          self.lastError = error.description
        }
      }
    }
  }

  private func runInspector(request: InspectionRequest) -> Result<[String: Any], FetchError> {
    guard FileManager.default.isExecutableFile(atPath: inspectorExecutable.path) else {
      return .failure(FetchError("找不到 Rust 检查引擎:\n\(inspectorExecutable.path)\n请检查应用打包是否完整。"))
    }

    let process = Process()
    process.executableURL = inspectorExecutable
    var arguments = ["--json", "--sessions"]
    if let sessionID = request.sessionID { arguments += ["--session-id", sessionID] }
    if let turnID = request.turnID { arguments += ["--turn-id", turnID] }
    if request.includeArchived { arguments.append("--include-archived") }
    if request.includeOtherSources { arguments.append("--include-other-sources") }
    process.arguments = arguments

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
      try process.run()
    } catch {
      return .failure(FetchError("无法启动探测进程: \(error.localizedDescription)"))
    }

    // 并发读两个管道再 wait,而不是顺序 readDataToEndOfFile:如果子进程往 stderr 写的量
    // 超过管道缓冲区(macOS 上通常 64KB),顺序读 stdout 会在 stdout 读完前一直卡住,
    // 而子进程这时候正卡在写 stderr 上——谁也过不去,死锁。
    var outData = Data()
    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      outData = outPipe.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      errData = errPipe.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    group.wait()
    process.waitUntilExit()

    if process.terminationStatus != 0 || !errData.isEmpty {
      DebugLog.write(
        "exit=\(process.terminationStatus) stdoutBytes=\(outData.count) "
          + "stderr: \(String(data: errData, encoding: .utf8) ?? "<非 utf8>")"
      )
    }

    guard process.terminationStatus == 0 else {
      let errText = String(data: errData, encoding: .utf8) ?? "unknown error"
      return .failure(FetchError("探测进程退出码 \(process.terminationStatus):\n\(errText)"))
    }

    do {
      guard let obj = try JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
        DebugLog.write(
          "顶层不是对象, 原始输出前 500 字节: \(String(data: outData.prefix(500), encoding: .utf8) ?? "<非 utf8>")"
        )
        return .failure(FetchError("JSON 解析失败:顶层不是对象"))
      }
      return .success(obj)
    } catch {
      let raw = String(data: outData, encoding: .utf8) ?? "<非 utf8, \(outData.count) 字节>"
      DebugLog.write("JSON 解析异常: \(error.localizedDescription)\n完整原始输出:\n\(raw)")
      return .failure(
        FetchError("JSON 解析失败: \(error.localizedDescription)\n输出: \(raw.prefix(300))"))
    }
  }
}
