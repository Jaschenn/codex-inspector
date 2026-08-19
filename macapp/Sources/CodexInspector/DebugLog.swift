import Foundation

/// 临时诊断用:把每次探测子进程的结果追加写到一个日志文件里,方便在双击运行的场景下
/// (没法直接看 App 的 stdout)排查"为什么有时候解析失败"这类间歇性问题。
enum DebugLog {
    private static let path = NSHomeDirectory() + "/Library/Logs/CodexInspectorDebug.log"

    static func write(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
