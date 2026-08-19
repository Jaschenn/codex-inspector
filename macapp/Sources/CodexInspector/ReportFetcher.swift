import Foundation
import Combine

struct FetchError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

/// 定时跑一次 `python3 -m codex_inspector --json`,拿到 core.build_report() 的原始快照。
///
/// 之所以不常驻一个本地 HTTP 服务、而是每次都起一个新的 Python 子进程:build_report()
/// 本身就是一次性、无状态的探测(ps/lsof/读文件),耗时通常在几十毫秒量级,没有必要维护一个
/// 常驻进程的生命周期。README 里也提到"轮询是目前唯一能发现新 codex 进程的办法"。
final class ReportFetcher: ObservableObject {
    @Published var report: [String: Any] = [
        "generated_at": "", "process_count": 0, "processes": [], "process_errors": [],
    ]
    @Published var lastError: String?
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false

    private var timer: Timer?
    private let interval: TimeInterval
    private let pythonExecutable: URL
    private let pythonHome: URL
    private let pyLib: URL

    init(interval: TimeInterval = 3.0) {
        self.interval = interval
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/dev/null")
        self.pythonHome = resources.appendingPathComponent("python")
        self.pythonExecutable = pythonHome.appendingPathComponent("bin/python3.13")
        self.pyLib = resources.appendingPathComponent("pylib")

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.runInspector()
            DispatchQueue.main.async {
                self.isRefreshing = false
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

    private func runInspector() -> Result<[String: Any], FetchError> {
        guard FileManager.default.isExecutableFile(atPath: pythonExecutable.path) else {
            return .failure(FetchError("找不到内置的 Python 运行时:\n\(pythonExecutable.path)\n(App 打包是否完整?)"))
        }

        let process = Process()
        process.executableURL = pythonExecutable
        process.arguments = ["-m", "codex_inspector", "--json"]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONHOME"] = pythonHome.path
        env["PYTHONPATH"] = pyLib.path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env

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
                DebugLog.write("顶层不是对象, 原始输出前 500 字节: \(String(data: outData.prefix(500), encoding: .utf8) ?? "<非 utf8>")")
                return .failure(FetchError("JSON 解析失败:顶层不是对象"))
            }
            return .success(obj)
        } catch {
            let raw = String(data: outData, encoding: .utf8) ?? "<非 utf8, \(outData.count) 字节>"
            DebugLog.write("JSON 解析异常: \(error.localizedDescription)\n完整原始输出:\n\(raw)")
            return .failure(FetchError("JSON 解析失败: \(error.localizedDescription)\n输出: \(raw.prefix(300))"))
        }
    }
}
