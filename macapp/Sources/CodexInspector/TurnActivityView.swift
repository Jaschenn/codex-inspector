import SwiftUI

struct ActivityTarget: Identifiable {
  let path: String
  let records: [[String: Any]]
  let actions: Set<String>
  let failed: Int

  init(path: String, records: [[String: Any]]) {
    self.path = path
    self.records = records
    actions = Set(records.compactMap { $0.str("action") })
    failed = records.reduce(0) { $0 + ($1.int("failed") ?? 0) }
  }
  var id: String { path }
  var name: String { URL(fileURLWithPath: path).lastPathComponent }
  var changed: Bool { !actions.isDisjoint(with: ["write", "modify", "change", "delete"]) }

  func parent(relativeTo cwd: String?) -> String {
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    guard let cwd else { return shortenPath(parent) }
    if parent == cwd { return "项目根目录" }
    if parent.hasPrefix(cwd + "/") { return String(parent.dropFirst(cwd.count + 1)) }
    return shortenPath(parent)
  }
}

func activityTargets(_ activity: [String: Any]) -> [ActivityTarget] {
  Dictionary(grouping: activity.dictArray("targets"), by: { $0.str("path") ?? "" })
    .filter { !$0.key.isEmpty }
    .map { ActivityTarget(path: $0.key, records: $0.value) }
    .sorted {
      if $0.changed != $1.changed { return $0.changed }
      return $0.path.localizedStandardCompare($1.path) == .orderedAscending
    }
}

private enum ActivityTab: String, CaseIterable {
  case files = "文件活动"
  case tools = "工具调用"
  case records = "执行记录"
}

private enum ActivityFilter: String, CaseIterable {
  case all = "全部"
  case changes = "写入与修改"
  case reads = "读取"
  case directories = "目录与搜索"

  func includes(_ target: ActivityTarget) -> Bool {
    switch self {
    case .all: return true
    case .changes: return target.changed
    case .reads: return target.actions.contains("read")
    case .directories: return !target.actions.isDisjoint(with: ["directory", "search"])
    }
  }
}

/// Put the inventory first; provenance remains one click away from each path.
struct TurnActivityView: View {
  let activity: [String: Any]
  let cwd: String?
  private let targets: [ActivityTarget]
  @State private var tab = ActivityTab.files
  @State private var filter = ActivityFilter.all
  @State private var query = ""
  @State private var visibleLimit = 8

  init(activity: [String: Any], cwd: String?) {
    self.activity = activity
    self.cwd = cwd
    targets = activityTargets(activity)
  }
  private var filteredTargets: [ActivityTarget] {
    targets.filter {
      filter.includes($0) && (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query))
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      if activity.isEmpty {
        emptyState("没有活动明细", detail: "本轮日志未提供可显示的工具和文件记录。")
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 10)], spacing: 10) {
          metric(
            "读取文件", count: targets.filter { $0.actions.contains("read") }.count,
            unit: "个", icon: "doc.text", color: .blue, filter: .reads)
          metric(
            "写入与修改", count: targets.filter(\.changed).count,
            unit: "个", icon: "square.and.pencil", color: .orange, filter: .changes)
          metric(
            "目录与搜索", count: targets.filter { ActivityFilter.directories.includes($0) }.count,
            unit: "个", icon: "folder", color: .purple, filter: .directories)
          Button {
            tab = .tools
          } label: {
            metricLabel(
              "模型工具调用", count: activity.int("model_call_count") ?? 0,
              unit: "次", icon: "wrench.and.screwdriver", color: .secondary)
          }.buttonStyle(.plain)
        }
        Picker("活动视图", selection: $tab) {
          ForEach(ActivityTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden()
        switch tab {
        case .files: fileInventory
        case .tools: toolInventory
        case .records: executionInventory
        }
        Divider()
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "info.circle").foregroundColor(.secondary)
          VStack(alignment: .leading, spacing: 4) {
            let count = activity.int("unrecognized_command_count") ?? 0
            Text(count > 0 ? "文件记录可能不完整 · \(count) 条命令未完整识别目标" : "文件记录来自本轮日志")
              .font(.caption).foregroundColor(.secondary)
            DisclosureGroup("数据来源与识别范围") {
              Text(
                "来源为会话 JSONL。读取和搜索表示命令目标，不保证访问成功；变更状态由工具报告。脚本、子进程及远端工具的访问可能未被记录。模型调用与展开后的执行操作分别计数，不相加。Finder 显示当前磁盘文件。"
              )
              .font(.caption).foregroundColor(.secondary).padding(.top, 6)
            }.font(.caption)
          }
        }
      }
    }
    .onChange(of: query) { _ in visibleLimit = 8 }
    .onChange(of: filter) { _ in visibleLimit = 8 }
  }

  private var fileInventory: some View {
    let filtered = filteredTargets
    let visible = Array(filtered.prefix(visibleLimit))
    return VStack(alignment: .leading, spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          fileFilter
          searchField
        }
        VStack(alignment: .leading, spacing: 10) {
          fileFilter
          searchField
        }
      }
      if filtered.isEmpty {
        emptyState(
          query.isEmpty ? "没有这类文件记录" : "没有匹配的路径",
          detail: query.isEmpty ? "日志中未识别到目标，不代表没有访问。" : "试试文件名或目录名。")
      } else {
        VStack(spacing: 0) {
          ForEach(visible) { target in
            ActivityFileRow(target: target, cwd: cwd)
            if target.id != visible.last?.id {
              Divider().padding(.leading, 38)
            }
          }
        }
        .background(
          Color(nsColor: .textBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
        HStack {
          Text("\(filtered.count) 个路径 · 同一文件合并展示").font(.caption).foregroundColor(.secondary)
          Spacer()
          if filtered.count > visibleLimit {
            Button("再显示 \(min(20, filtered.count - visibleLimit)) 个") { visibleLimit += 20 }
              .font(.caption)
          }
        }
      }
    }
  }

  private var fileFilter: some View {
    Picker("文件类型", selection: $filter) {
      ForEach(ActivityFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
    }.labelsHidden().frame(maxWidth: 180)
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass").foregroundColor(.secondary)
      TextField("搜索文件或目录", text: $query).textFieldStyle(.plain)
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
        }
        .buttonStyle(.plain).help("清除搜索")
      }
    }.padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
  }

  private var toolInventory: some View {
    VStack(alignment: .leading, spacing: 16) {
      toolSection("模型发起的调用", subtitle: "包含 exec 等编排入口", tools: activity.dictArray("model_tools"))
      Divider()
      toolSection(
        "实际执行的操作", subtitle: "编排入口展开后的命令、文件变更及其他工具", tools: activity.dictArray("operation_tools"))
    }
  }

  private func toolSection(_ title: String, subtitle: String, tools: [[String: Any]]) -> some View {
    let sorted = tools.sorted { ($0.int("count") ?? 0) > ($1.int("count") ?? 0) }
    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(title).font(.system(size: 13, weight: .semibold))
        Spacer()
        Text("\(tools.reduce(0) { $0 + ($1.int("count") ?? 0) }) 次").font(.caption).foregroundColor(
          .secondary)
      }
      Text(subtitle).font(.caption).foregroundColor(.secondary)
      if sorted.isEmpty { Text("本轮未记录调用").font(.caption).foregroundColor(.secondary) }
      ForEach(Array(sorted.enumerated()), id: \.offset) { _, tool in
        HStack(spacing: 12) {
          Image(systemName: "wrench").foregroundColor(.secondary).frame(width: 20)
          Text(tool.str("name") ?? "未知工具").font(.system(size: 13, design: .monospaced))
            .textSelection(.enabled).lineLimit(2)
          Spacer()
          Text("\(tool.int("count") ?? 0)").font(.system(size: 14, weight: .semibold))
            .monospacedDigit()
          Text("次").font(.caption).foregroundColor(.secondary)
        }.padding(10).background(
          Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
      }
    }
  }

  private var executionInventory: some View {
    let operations = activity.dictArray("operations").sorted {
      ($0.str("timestamp") ?? "") > ($1.str("timestamp") ?? "")
    }
    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("最近执行在前").font(.caption).foregroundColor(.secondary)
        Spacer()
        Text("\(operations.count) 条").font(.caption).foregroundColor(.secondary)
      }
      if operations.isEmpty { emptyState("没有执行记录", detail: "本轮未记录展开后的工具操作。") }
      ForEach(Array(operations.prefix(visibleLimit).enumerated()), id: \.offset) { _, operation in
        HStack(alignment: .top, spacing: 12) {
          Text(activityTime(operation.str("timestamp"))).font(
            .system(.caption, design: .monospaced)
          )
          .foregroundColor(.secondary).frame(width: 70, alignment: .leading)
          VStack(alignment: .leading, spacing: 4) {
            Text(operation.str("tool") ?? "未知工具").font(.system(size: 13, design: .monospaced))
              .textSelection(.enabled)
            if let count = operation.int("target_count"), count > 0 {
              Text("\(count) 个文件／目录目标").font(.caption).foregroundColor(.secondary)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
          ActivityChip(
            text: activityStatus(operation.str("status")),
            color: operation.str("status") == "failed" ? .red : .secondary)
        }.padding(.vertical, 8)
        Divider()
      }
      if operations.count > visibleLimit { Button("显示更多记录") { visibleLimit += 20 }.font(.caption) }
    }
  }

  private func metric(
    _ title: String, count: Int, unit: String, icon: String, color: Color,
    filter selection: ActivityFilter
  ) -> some View {
    Button {
      filter = selection
      tab = .files
    } label: {
      metricLabel(title, count: count, unit: unit, icon: icon, color: color)
    }.buttonStyle(.plain).help("查看\(title)")
  }

  private func metricLabel(_ title: String, count: Int, unit: String, icon: String, color: Color)
    -> some View
  {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: icon).font(.caption).foregroundColor(.secondary)
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text("\(count)").font(.system(size: 24, weight: .semibold)).monospacedDigit()
          .foregroundColor(color)
        Text(unit).font(.caption).foregroundColor(.secondary)
      }
    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
      .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
  }

  private func emptyState(_ title: String, detail: String) -> some View {
    VStack(spacing: 6) {
      Image(systemName: "tray").font(.title2).foregroundColor(.secondary)
      Text(title).font(.system(size: 13, weight: .medium))
      Text(detail).font(.caption).foregroundColor(.secondary)
    }.frame(maxWidth: .infinity).padding(.vertical, 22)
  }
}

private struct ActivityFileRow: View {
  let target: ActivityTarget
  let cwd: String?
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        Button {
          expanded.toggle()
        } label: {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: target.actions.contains("directory") ? "folder" : "doc.text")
              .foregroundColor(target.changed ? .orange : .secondary).frame(width: 20).padding(
                .top, 2)
            VStack(alignment: .leading, spacing: 4) {
              Text(target.name).font(.system(size: 13, weight: .medium)).foregroundColor(.primary)
                .lineLimit(1).truncationMode(.middle)
              Text(target.parent(relativeTo: cwd)).font(.caption).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.contentShape(Rectangle())
        }.buttonStyle(.plain).help(target.path)
        VStack(alignment: .trailing, spacing: 5) {
          HStack(spacing: 4) {
            ForEach(
              ["write", "modify", "change", "delete", "read", "directory", "search"].filter {
                target.actions.contains($0)
              }, id: \.self
            ) { action in
              ActivityChip(
                text: activityAction(action),
                color: action == "delete"
                  ? .red : ["write", "modify", "change"].contains(action) ? .orange : .blue)
            }
          }
          if target.failed > 0 {
            Text("\(target.failed) 次失败／未批准").font(.caption).foregroundColor(.red)
          }
        }
        Button {
          expanded.toggle()
        } label: {
          Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
        }
        .buttonStyle(.plain).foregroundColor(.secondary).help("查看路径与识别依据")
      }
      if expanded {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .top) {
            Text(target.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(target.path, forType: .string)
            } label: {
              Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain).help("复制完整路径")
            RevealButton(path: target.path)
          }
          ForEach(Array(target.records.enumerated()), id: \.offset) { _, record in
            Text(activityTargetDescription(record)).font(.caption).foregroundColor(.secondary)
              .textSelection(.enabled)
          }
        }.padding(10).background(
          Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7)
        )
        .padding(.leading, 30)
      }
    }.padding(12)
  }
}

private struct ActivityChip: View {
  let text: String
  let color: Color
  var body: some View {
    Text(text).font(.system(size: 10, weight: .medium)).foregroundColor(color)
      .padding(.horizontal, 6).padding(.vertical, 3).background(color.opacity(0.09), in: Capsule())
  }
}

func activityAction(_ action: String?) -> String {
  switch action {
  case "read": return "读取"
  case "directory": return "列举"
  case "search": return "搜索"
  case "write": return "写入"
  case "modify": return "修改"
  case "delete": return "删除"
  default: return "变更"
  }
}

func activityStatus(_ status: String?) -> String {
  switch status {
  case "completed": return "已完成"
  case "failed": return "失败"
  case "declined": return "未批准"
  case "in_progress": return "进行中"
  case "returned": return "已返回"
  default: return "状态未确认"
  }
}

func activityTargetDescription(_ target: [String: Any]) -> String {
  let evidence = target.str("evidence") == "file_change" ? "日志文件变更" : "命令／工具目标"
  var result =
    "\(activityAction(target.str("action"))) · \(target.int("count") ?? 0) 次 · \(evidence)"
  if target.str("evidence") == "file_change" {
    result += " · 完成 \(target.int("completed") ?? 0)"
    if let failed = target.int("failed"), failed > 0 { result += " · 失败／未批准 \(failed)" }
  }
  let tools = target.stringArray("tools")
  if !tools.isEmpty { result += " · " + tools.joined(separator: "、") }
  return result
}

private func activityTime(_ timestamp: String?) -> String {
  guard let timestamp else { return "未记录" }
  let parser = ISO8601DateFormatter()
  parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let date = parser.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
  guard let date else { return "未记录" }
  return date.formatted(date: .omitted, time: .standard)
}
