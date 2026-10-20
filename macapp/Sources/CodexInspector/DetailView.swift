import SwiftUI

struct DetailView: View {
  let proc: [String: Any]
  let onBack: () -> Void

  @State private var showOverview = true
  @State private var showConfigLayers = false
  @State private var showAgents = false
  @State private var showSkills = false
  @State private var showMcp = false
  @State private var showWarnings = true

  private var configLayers: [[String: Any]] { proc.dictArray("config_layers") }
  private var agentsChain: [[String: Any]] { proc.dictArray("agents_chain") }
  private var skills: [[String: Any]] { proc.dictArray("skills") }
  private var mcpServers: [[String: Any]] { proc.dictArray("mcp_servers") }
  private var warnings: [String] { proc.stringArray("warnings") }
  private var trust: TrustPresentation { trustPresentation(for: proc) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Button(action: onBack) {
          Label("返回", systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        Text("PID \(String(proc.int("pid") ?? 0))")
          .font(.headline)
        Spacer()
        Text(trust.label)
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(trust.color)
          .help(trust.explanation)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          section("概览", isExpanded: $showOverview) { overviewSection }
          section("配置层 (\(appliedLayerCount)/\(configLayers.count))", isExpanded: $showConfigLayers)
          { configLayersSection }
          section("AGENTS.md (\(agentsChain.count))", isExpanded: $showAgents) { agentsSection }
          section("Skills (\(enabledSkillCount)/\(skills.count))", isExpanded: $showSkills) {
            skillsSection
          }
          section("MCP 服务器 (\(mcpServers.count))", isExpanded: $showMcp) { mcpSection }
          if !warnings.isEmpty {
            section("诊断提示 (\(warnings.count))", isExpanded: $showWarnings) { warningsSection }
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
    }
  }

  private var appliedLayerCount: Int { configLayers.filter { $0.bool("applied") == true }.count }
  private var enabledSkillCount: Int { skills.filter { $0.bool("enabled") == true }.count }

  // MARK: - 区块容器

  private func section<Content: View>(
    _ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      DisclosureGroup(isExpanded: isExpanded) {
        content().padding(.top, 4)
      } label: {
        Text(title).font(.system(size: 13, weight: .semibold))
      }
    }
    .padding(.vertical, 4)
  }

  // MARK: - 概览

  private var overviewSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      row("命令行", proc.str("cmdline") ?? "-", mono: true)
      row("用户 / 运行时长", "\(proc.str("user") ?? "-") / \(proc.str("etime") ?? "-")")
      if let cwd = proc.str("cwd") {
        row("工作目录", shortenPath(cwd), mono: true, revealPath: cwd)
      } else {
        row("工作目录", "未知: \(proc.str("cwd_error") ?? "?")", color: .red)
      }
      row(
        "CODEX_HOME", shortenPath(proc.str("codex_home")), mono: true,
        revealPath: proc.str("codex_home"))
      row("环境读取状态", proc.str("env_status") ?? "-")
      if let projectRoot = proc.str("project_root") {
        row("项目根", shortenPath(projectRoot), mono: true, revealPath: projectRoot)
      } else {
        row("项目根", "(未识别到 Git 项目)", mono: true)
      }
      row("信任状态说明", trust.explanation)

      if let line = cliOverridesLine {
        row("CLI 覆盖", line, mono: true)
      }
    }
  }

  private var cliOverridesLine: String? {
    let co = proc.subDict("cli_overrides")
    let cOverrides = (co["c_overrides"] as? [[Any]]) ?? []
    var bits: [String] = []
    if let v = co.str("profile") { bits.append("profile=\(v)") }
    if let v = co.str("cd") { bits.append("cd=\(shortenPath(v))") }
    if let v = co.str("config_path") { bits.append("config=\(shortenPath(v))") }
    for pair in cOverrides where pair.count == 2 {
      bits.append("-c \(pair[0])=\(pair[1])")
    }
    return bits.isEmpty ? nil : bits.joined(separator: "  ")
  }

  // MARK: - 配置层

  private var configLayersSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      if configLayers.isEmpty {
        emptyHint("没有配置层信息")
      }
      ForEach(Array(configLayers.enumerated()), id: \.offset) { _, layer in
        let note = layer.str("skip_reason") ?? layer.str("parse_error")
        let hasError = layer.str("parse_error") != nil
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 6) {
            Text(layer.str("kind") ?? "?")
              .font(.system(size: 11, weight: .medium))
              .frame(width: 60, alignment: .leading)
            Text(layer.bool("exists") == true ? "已找到" : "未找到")
              .font(.system(size: 11)).foregroundColor(.secondary)
            Text(layer.bool("applied") == true ? "已应用" : "未应用")
              .font(.system(size: 11)).foregroundColor(.secondary)
          }
          HStack(spacing: 4) {
            Text(layer.str("path").map(shortenPath) ?? "(CLI 覆盖)")
              .font(.system(size: 11, design: .monospaced))
              .foregroundColor(.secondary)
              .textSelection(.enabled)
            RevealButton(path: layer.str("path"))
          }
          if let note {
            Text(note)
              .font(.system(size: 11))
              .foregroundColor(hasError ? .red : .orange)
          }
        }
      }
    }
  }

  // MARK: - AGENTS.md

  private var agentsSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      if agentsChain.isEmpty {
        emptyHint("没有找到 AGENTS.md,当前进程没有额外的项目指令")
      }
      ForEach(Array(agentsChain.enumerated()), id: \.offset) { _, doc in
        HStack(spacing: 6) {
          Text("[\(doc.str("scope") ?? "?")]")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.blue)
          Text(shortenPath(doc.str("path")))
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
          RevealButton(path: doc.str("path"))
        }
      }
    }
  }

  // MARK: - Skills

  private var skillsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      if skills.isEmpty {
        emptyHint("没有发现 Skills")
      }
      ForEach(Array(skills.enumerated()), id: \.offset) { _, s in
        let enabled = s.bool("enabled") ?? false
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 6) {
            Text("[\(s.str("scope") ?? "?")]")
              .font(.system(size: 11)).foregroundColor(.secondary)
            Text(s.str("name") ?? "(未命名/解析失败)")
              .font(.system(size: 11, weight: .medium))
            Text(enabled ? "启用" : "禁用\(s.str("disabled_reason").map { "(\($0))" } ?? "")")
              .font(.system(size: 11))
              .foregroundColor(enabled ? .green : .red)
            if let count = s.int("token_count") {
              Text("≈ \(count.formatted()) tokens")
                .font(.system(size: 11)).foregroundColor(.blue)
            }
          }
          if let desc = s.str("description"), !desc.isEmpty {
            Text(desc).font(.system(size: 11)).foregroundColor(.secondary)
          }
          HStack(spacing: 4) {
            Text(shortenPath(s.str("path")))
              .font(.system(size: 11, design: .monospaced))
              .foregroundColor(.secondary)
              .textSelection(.enabled)
            RevealButton(path: s.str("path"))
          }
        }
      }
    }
  }

  // MARK: - MCP

  private var mcpSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      if mcpServers.isEmpty {
        emptyHint("没有配置 MCP 服务器")
      }
      ForEach(Array(mcpServers.enumerated()), id: \.offset) { _, m in
        let raw = m.subDict("raw")
        let detailLine = mcpDetailLine(raw)
        let enabledTools = raw.stringArray("enabled_tools")
        let disabledTools = raw.stringArray("disabled_tools")

        VStack(alignment: .leading, spacing: 5) {
          Text(m.str("name") ?? "?")
            .font(.system(size: 11, weight: .medium))
          if let detailLine {
            HStack(spacing: 4) {
              Text(detailLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
              if let cmd = raw.str("command"), cmd.hasPrefix("/") {
                RevealButton(path: cmd)
              }
            }
          }
          if !enabledTools.isEmpty {
            Text("仅启用: \(enabledTools.joined(separator: ", "))")
              .font(.system(size: 11)).foregroundColor(.green)
          }
          if !disabledTools.isEmpty {
            Text("禁用: \(disabledTools.joined(separator: ", "))")
              .font(.system(size: 11)).foregroundColor(.red)
          }
        }
      }
    }
  }

  private func mcpDetailLine(_ raw: [String: Any]) -> String? {
    var bits: [String] = []
    if let cmd = raw.str("command") { bits.append("command=\(cmd)") }
    if let url = raw.str("url") { bits.append("url=\(url)") }
    return bits.isEmpty ? nil : bits.joined(separator: "  ")
  }

  // MARK: - 警告

  private var warningsSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(warnings.enumerated()), id: \.offset) { _, w in
        Text(w)
          .font(.system(size: 11))
          .foregroundColor(.orange)
          .textSelection(.enabled)
      }
    }
  }

  // MARK: - 小工具

  private func row(
    _ label: String, _ value: String, mono: Bool = false, color: Color? = nil,
    revealPath: String? = nil
  ) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Text(label)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .frame(width: 84, alignment: .leading)
      Text(value)
        .font(.system(size: 11, design: mono ? .monospaced : .default))
        .foregroundColor(color ?? .primary)
        .textSelection(.enabled)
      RevealButton(path: revealPath)
      Spacer(minLength: 0)
    }
  }

  private func emptyHint(_ text: String) -> some View {
    Text(text).font(.system(size: 11)).foregroundColor(.secondary)
  }
}
