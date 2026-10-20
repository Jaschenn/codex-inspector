import SwiftUI

func shortenPath(_ path: String?) -> String {
  guard let path, !path.isEmpty else { return "-" }
  let home = NSHomeDirectory()
  if path == home { return "~" }
  if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
  return path
}

struct TrustPresentation {
  let label: String
  let color: Color
  let explanation: String
}

func trustPresentation(for proc: [String: Any]) -> TrustPresentation {
  switch proc.str("trust_level") {
  case "trusted":
    return TrustPresentation(
      label: "已信任", color: .green,
      explanation: "全局配置中记录该 Git 项目为 trusted。"
    )
  case "untrusted":
    return TrustPresentation(
      label: "未信任", color: .red,
      explanation: "全局配置中记录该 Git 项目为 untrusted。"
    )
  default:
    // 后台服务的 cwd 可能是 /，不能把未识别到 Git 项目当成信任警告。
    // cwd 读取失败时仍显示未知，避免把探测失败误报为没有项目。
    let hasKnownDirectory =
      proc.str("cwd") != nil
      || proc.subDict("cli_overrides").str("cd") != nil
    if proc.bool("is_git_repo") == false && hasKnownDirectory {
      return TrustPresentation(
        label: "未关联 Git 项目", color: .secondary,
        explanation: "未从进程工作目录识别到 Git 项目；App Server 可服务多个会话，此进程快照无法确定各会话项目的信任状态。"
      )
    }
    if !hasKnownDirectory {
      return TrustPresentation(
        label: "信任状态未知", color: .orange,
        explanation: "无法读取进程工作目录，不能可靠确定项目及其信任状态。"
      )
    }
    let globalLayer = proc.dictArray("config_layers").first { $0.str("kind") == "global" }
    let explanation: String
    if let error = globalLayer?.str("parse_error") {
      explanation = "无法读取全局配置中的信任记录：\(error)"
    } else {
      explanation = "未找到该 Git 项目的有效 trust_level 记录；这表示配置中的信任状态未知，不代表 Codex 进程异常。"
    }
    return TrustPresentation(label: "信任状态未知", color: .orange, explanation: explanation)
  }
}
