import SwiftUI

/// Maps a context-budget component's Rust `category` key to a label/color for the stacked bar
/// and the row list. Kept separate from `TimelineCategory` (turn-timing) even though the visual
/// language matches: these are token-composition categories, not timing phases.
enum ContextBudgetCategory: String {
  case systemPrompt = "system_prompt"
  case agentsMD = "agents_md"
  case skillsCatalog = "skills_catalog"
  case mcpTools = "mcp_tools"
  case mcpInstructions = "mcp_instructions"
  case messagesAndUnmeasured = "messages_and_unmeasured"

  var color: Color {
    switch self {
    case .systemPrompt: return .blue
    case .agentsMD: return .green
    case .skillsCatalog: return .teal
    case .mcpTools: return .purple
    case .mcpInstructions: return .indigo
    case .messagesAndUnmeasured: return .gray
    }
  }
}

struct ContextBudgetView: View {
  @ObservedObject var fetcher: ReportFetcher

  private var budget: [String: Any] { fetcher.report.subDict("menu_context_budget") }
  private var components: [[String: Any]] { budget.dictArray("components") }
  private var usableWindow: Int? { budget.int("usable_context_window") }
  private var activeTokens: Int? { budget.int("active_context_tokens") }
  private var freeSpace: Int? { budget.int("free_space_tokens") }
  private var percentUsed: Double? { budget.double("percent_used") }
  private var modelLine: String {
    guard let model = budget.str("model") else { return "等待关联聊天" }
    guard let encoding = budget.str("token_encoding") else { return model }
    return "\(model) · \(encoding) 分词"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      if fetcher.report.dictArray("processes").isEmpty {
        placeholder("没有正在运行的 Codex 进程", detail: "启动 Codex 后，这里会显示当前对话的上下文用量分解。")
      } else if budget.isEmpty {
        placeholder("正在加载上下文用量…", detail: nil)
      } else if budget.bool("available") != true {
        placeholder(
          "暂时无法计算上下文用量", detail: budget.str("reason") ?? "原因未知。")
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            usageBar
            warningsSection
            VStack(alignment: .leading, spacing: 10) {
              ForEach(Array(components.enumerated()), id: \.offset) { _, component in
                componentRow(component)
              }
            }
          }
          .padding(16)
        }
      }
      Divider()
      footer
    }
    .frame(width: 460, height: 600)
    .onAppear { fetcher.setContextBudgetWindowOpen(true) }
    .onDisappear { fetcher.setContextBudgetWindowOpen(false) }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "chart.bar.doc.horizontal")
        .font(.system(size: 18)).foregroundColor(.accentColor)
      VStack(alignment: .leading, spacing: 2) {
        Text("上下文用量").font(.system(size: 14, weight: .semibold))
        Text(modelLine)
          .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
      }
      Spacer()
      Button { fetcher.refresh() } label: { Image(systemName: "arrow.clockwise") }
        .buttonStyle(.plain).help("立即刷新")
    }
    .padding(16)
  }

  private func placeholder(_ title: String, detail: String?) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 28))
        .foregroundColor(.secondary)
      Text(title).font(.system(size: 13))
      if let detail {
        Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
          .multilineTextAlignment(.center).padding(.horizontal, 24)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 60)
  }

  private var usageBar: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(activeTokens?.formatted() ?? "—")
          .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
        if let usableWindow {
          Text("/ \(usableWindow.formatted()) tokens")
            .font(.system(size: 12)).foregroundColor(.secondary)
        }
        Spacer()
        if let percentUsed {
          Text(String(format: "已使用 %.0f%%", percentUsed))
            .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
        }
      }
      GeometryReader { geometry in
        // Segments can exceed the window (e.g. just before compaction); scale so they still fit.
        let scale = max(usableWindow ?? 0, components.reduce(0) { $0 + max(0, $1.int("tokens") ?? 0) })
        HStack(spacing: 1.5) {
          ForEach(Array(components.enumerated()), id: \.offset) { _, component in
            let tokens = component.int("tokens") ?? 0
            if tokens > 0, usableWindow != nil, scale > 0 {
              let category = ContextBudgetCategory(rawValue: component.str("category") ?? "")
              RoundedRectangle(cornerRadius: 2)
                .fill(category?.color ?? .gray)
                .frame(width: max(2, geometry.size.width * CGFloat(tokens) / CGFloat(scale)))
            }
          }
          Spacer(minLength: 0)
        }
        .frame(height: 10)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)))
      }
      .frame(height: 10)
      if let freeSpace {
        Text("剩余约 \(freeSpace.formatted()) tokens")
          .font(.system(size: 11)).foregroundColor(.secondary)
      }
    }
  }

  private var warningsSection: some View {
    let warnings = budget.stringArray("warnings")
    return Group {
      if !warnings.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
            Label(warning, systemImage: "info.circle")
              .font(.system(size: 11)).foregroundColor(.secondary)
          }
        }
        .padding(10).background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private func componentRow(_ component: [String: Any]) -> some View {
    let category = ContextBudgetCategory(rawValue: component.str("category") ?? "")
    let tokens = component.int("tokens")
    let exact = component.bool("exact") ?? false
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Circle().fill(category?.color ?? .gray).frame(width: 8, height: 8)
        Text(component.str("label") ?? "—").font(.system(size: 12.5, weight: .medium))
        Spacer()
        Text(tokens?.formatted() ?? "未知")
          .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
        if !exact {
          Text("估算").font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
        }
      }
      if let note = component.str("note") {
        Text(note).font(.system(size: 11)).foregroundColor(.secondary)
      }
      if let source = component.str("source") {
        Text(source).font(.system(size: 11)).foregroundColor(.secondary)
      }
      if category == .mcpTools {
        mcpDetail(component)
      }
    }
    .padding(10).background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func mcpDetail(_ component: [String: Any]) -> some View {
    let servers = component.dictArray("servers")
    let age = component.int("result_age_seconds")
    return VStack(alignment: .leading, spacing: 6) {
      if servers.isEmpty {
        Button("刷新 MCP 工具") { fetcher.refreshMCPTools() }
          .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
          .foregroundColor(.accentColor)
      } else {
        ForEach(Array(servers.enumerated()), id: \.offset) { _, server in
          HStack {
            Image(systemName: server.str("status") == "ok" ? "checkmark.circle" : "xmark.circle")
              .foregroundColor(server.str("status") == "ok" ? .green : .red)
              .font(.system(size: 10))
            Text(server.str("name") ?? "—").font(.system(size: 11))
            Spacer()
            if server.str("status") == "ok" {
              Text("\(server.int("tool_count") ?? 0) 个工具 · \(server.int("tools_token_count") ?? 0) tokens")
                .font(.system(size: 10.5)).foregroundColor(.secondary)
            } else {
              Text(shortServerError(server))
                .font(.system(size: 10.5)).foregroundColor(.secondary).lineLimit(1)
            }
          }
        }
        HStack {
          if let age {
            Text(age > 0 ? "数据来自约 \(age) 秒前" : "刚刚探测")
              .font(.system(size: 10.5)).foregroundColor(.secondary)
          }
          Spacer()
          Button("重新探测") { fetcher.refreshMCPTools() }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
            .foregroundColor(.accentColor)
        }
      }
    }
  }

  private func shortServerError(_ server: [String: Any]) -> String {
    switch server.str("status") {
    case "timeout": return "超时未响应"
    case "error":
      if let errorString = server["error"] as? String { return errorString }
      return "启动失败"
    default: return "未知状态"
    }
  }

  private var footer: some View {
    HStack {
      Text("系统提示词/上下文窗口来自会话日志（旧日志回退到 codex debug models）；MCP 工具来自实际探测")
        .font(.system(size: 10.5)).foregroundColor(.secondary)
      Spacer()
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
  }
}
