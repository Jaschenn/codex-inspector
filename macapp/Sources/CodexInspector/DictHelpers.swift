import Foundation

/// codex_inspector 的 core.build_report() 输出结构在 README 里明确说明"以后可能演进",
/// 所以这里不建强类型 Codable model,统一用弱类型字典 + 安全取值,
/// 万一 Python 那边加/改字段,App 顶多某个区块显示不全,而不是直接崩溃。
extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? {
        if let v = self[key] as? Int { return v }
        if let v = self[key] as? NSNumber { return v.intValue }
        return nil
    }
    func bool(_ key: String) -> Bool? { self[key] as? Bool }
    func dictArray(_ key: String) -> [[String: Any]] { (self[key] as? [[String: Any]]) ?? [] }
    func subDict(_ key: String) -> [String: Any] { (self[key] as? [String: Any]) ?? [:] }
    func stringArray(_ key: String) -> [String] { (self[key] as? [String]) ?? [] }
}
