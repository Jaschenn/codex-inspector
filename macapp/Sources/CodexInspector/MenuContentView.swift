import SwiftUI

/// The menu follows recent activity independently of historical detail browsing.
struct MenuContentView: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var fetcher: ReportFetcher
  @State private var selectedPID: Int?
  @State private var selectedSessionID: String?

  private var processes: [[String: Any]] { fetcher.report.dictArray("processes") }
  private var session: [String: Any] { fetcher.report.subDict("menu_session") }
  private var candidates: [[String: Any]] { fetcher.report.dictArray("menu_candidates") }
  private var turn: [String: Any] { session.subDict("selected_turn") }
  private var statistics: [String: Any] { turn.subDict("statistics") }
  private var conversation: [String: Any] { session.subDict("conversation_tokens") }
  private var usage: [String: Any] { conversation.subDict("usage") }
  private var timing: [String: Any] { statistics.subDict("timing") }
  private var duration: Double { (timing["span_duration_ms"] as? NSNumber)?.doubleValue ?? 0 }
  private var segments: [TimingSegment] {
    timing.dictArray("segments").enumerated().compactMap {
      TimingSegment(index: $0.offset, data: $0.element)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable().frame(width: 28, height: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text("Codex Inspector").font(.system(size: 14, weight: .semibold))
          Text("当前活动摘要").font(.system(size: 11)).foregroundColor(.secondary)
        }
        Spacer()
        Button {
          fetcher.refresh()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain).help("立即刷新")
        Button {
          openDetail()
        } label: {
          Image(systemName: "macwindow")
        }
        .buttonStyle(.plain).help("打开应用详情")
      }
      .padding(16)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let error = fetcher.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
              .font(.system(size: 12)).foregroundColor(.red)
          }
          if processes.isEmpty {
            VStack(spacing: 10) {
              Image(systemName: "terminal").font(.system(size: 28))
              Text("没有正在运行的 Codex 进程").font(.system(size: 13))
              Text("启动 Codex 后，将在这里显示对话用量和本轮耗时。")
                .font(.system(size: 12)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 60)
          } else {
            objectSelector
            if let error = session.str("error") {
              Text(error).font(.system(size: 12)).foregroundColor(.secondary)
            } else if turn.isEmpty {
              Text("这个进程尚无可读取的聊天轮次。").font(.system(size: 13)).foregroundColor(.secondary)
            } else {
              conversationCard
              turnCard
            }
          }
        }
        .padding(16)
      }
      .frame(height: 530)
      Divider()
      HStack {
        Text("自动更新 · 每秒兜底").font(.system(size: 11)).foregroundColor(.secondary)
          .help("日志和数据库 WAL 变更触发更新；每秒检查进程和文件状态，弥补漏报事件。用量以已写入本地日志的记录为准。")
        Spacer()
        Button("查看详情") { openDetail() }.buttonStyle(.plain).font(.system(size: 12, weight: .medium))
        Divider().frame(height: 12)
        Button("退出") { NSApplication.shared.terminate(nil) }
          .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.secondary)
      }
      .padding(.horizontal, 16).padding(.vertical, 12)
    }
    .frame(width: 420)
    .onChange(of: selectedPID) { pid in
      selectedSessionID = nil
      fetcher.selectMenuProcess(pid)
    }
    .onChange(of: selectedSessionID) { fetcher.selectMenuSession($0) }
    .onChange(of: processes.compactMap { $0.int("pid") }) { pids in
      if let selectedPID, !pids.contains(selectedPID) { self.selectedPID = nil }
    }
    .onChange(of: candidates.compactMap { $0.str("id") }) { ids in
      if let selectedSessionID, !ids.contains(selectedSessionID) { self.selectedSessionID = nil }
    }
  }

  private var objectSelector: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("进程").font(.system(size: 12)).foregroundColor(.secondary)
        Picker("进程", selection: $selectedPID) {
          Text("自动 · PID \(String(fetcher.report.int("menu_pid") ?? 0))").tag(Int?.none)
          ForEach(processes.compactMap { $0.int("pid") }, id: \.self) { pid in
            Text("PID \(String(pid))").tag(Optional(pid))
          }
        }
        .labelsHidden().frame(maxWidth: .infinity)
      }
      NativeChoicePicker(
        title: "当前对话",
        choices: [PickerChoice(id: nil, title: "自动跟随最近活动")]
          + candidates.map { PickerChoice(id: $0.str("id"), title: $0.str("title") ?? "未命名聊天") },
        selection: $selectedSessionID)
      Text(session.str("title") ?? "等待关联聊天")
        .font(.system(size: 14, weight: .semibold)).lineLimit(2)
      Text(shortenPath(session.str("cwd")))
        .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
      Text(associationLabel).font(.system(size: 11)).foregroundColor(.secondary)
        .help(
          "App Server 可以同时处理多个聊天，本地日志无法证明前台窗口选中了哪个聊天。自动关联优先选择相同 Codex Home 和工作目录中的最近聊天，没有目录匹配时使用同一 Home 的最近聊天；可手动指定。"
        )
    }
  }

  private var associationLabel: String {
    switch fetcher.report.str("menu_association") {
    case "manual": return "已手动指定聊天"
    case "cwd": return "按进程工作目录关联最近聊天"
    default: return "按 Codex Home 关联最近聊天"
    }
  }

  private var conversationCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("当前对话 Token").font(.system(size: 13, weight: .semibold))
        Spacer()
        Text(conversation.bool("partial") == true ? "已记录用量" : "累计用量")
          .font(.system(size: 11)).foregroundColor(.secondary)
      }
      HStack(alignment: .firstTextBaseline, spacing: 20) {
        metric("总量", count: usage.int("total_tokens"), prominent: true)
        metric("输入", count: usage.int("input_tokens"))
        metric("输出", count: usage.int("output_tokens"))
      }
      Divider()
      HStack(alignment: .top, spacing: 20) {
        metric("缓存命中", count: usage.int("cached_input_tokens"))
        metric("缓存写入", count: usage.int("cache_write_input_tokens"))
        Spacer(minLength: 0)
        VStack(alignment: .trailing, spacing: 5) {
          Text("缓存命中率").font(.system(size: 11)).foregroundColor(.secondary)
          Text(
            tokenPercentage(usage.int("cached_input_tokens"), of: usage.int("input_tokens")) ?? "—"
          )
          .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundColor(.teal)
        }
        .help("缓存命中率 = 缓存命中 Token ÷ 输入 Token。缓存用量已包含在输入中。")
      }
      Text(
        "\(conversation.int("recorded_turns") ?? 0) / \(conversation.int("total_turns") ?? 0) 轮有用量记录 · 进行中的调用可能尚未回报"
      )
      .font(.system(size: 11)).foregroundColor(.secondary)
      .help("累计值按日志中能归属于各轮次的用量求和，不含无法归属的记录。缺失字段不当成零；分叉聊天不叠加继承的会话计数。")
    }
    .padding(14).background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private var turnCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("本轮 · 第 \(turn.int("number") ?? 0) 轮").font(.system(size: 13, weight: .semibold))
        Spacer()
        Text(
          turn.str("status") == "in_progress"
            ? "进行中" : (turn.str("status") == "interrupted" ? "已中断" : "已结束")
        )
        .font(.system(size: 11)).foregroundColor(
          turn.str("status") == "in_progress" ? .blue : .secondary)
      }
      HStack(spacing: 20) {
        metric("本轮 Token", count: statistics.subDict("tokens").subDict("usage").int("total_tokens"))
        Spacer()
        VStack(alignment: .trailing, spacing: 5) {
          Text(formattedDuration(duration)).font(
            .system(size: 18, weight: .semibold, design: .rounded))
          Text(timing.str("source") == "partial" ? "日志已记录时长" : "总耗时")
            .font(.system(size: 11)).foregroundColor(.secondary)
        }
      }
      if duration > 0, !segments.isEmpty {
        NativeTimelineView(segments: segments, duration: duration).frame(height: 16)
        LazyVGrid(
          columns: [
            GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading),
          ], spacing: 8
        ) {
          ForEach(Array(timing.dictArray("category_totals").enumerated()), id: \.offset) {
            _, entry in
            let category = TimelineCategory(rawValue: entry.str("category") ?? "") ?? .unknown
            let milliseconds = (entry["duration_ms"] as? NSNumber)?.doubleValue ?? 0
            HStack(spacing: 5) {
              Circle().fill(category.color).frame(width: 6, height: 6)
              Text(shortTitle(category)).lineLimit(1)
              Spacer(minLength: 0)
              Text(String(format: "%.0f%%", milliseconds / duration * 100)).monospacedDigit()
                .foregroundColor(.secondary)
            }
            .font(.system(size: 11))
            .help("\(category.title) · \(formattedDuration(milliseconds))\n\(category.explanation)")
          }
        }
      } else {
        Text("尚无足够的时间记录").font(.system(size: 12)).foregroundColor(.secondary)
      }
    }
    .padding(14).background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private func metric(_ title: String, count: Int?, prominent: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(count?.formatted() ?? "—")
        .font(.system(size: prominent ? 23 : 16, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.7)
      Text(title).font(.system(size: 11)).foregroundColor(.secondary)
    }
  }

  private func shortTitle(_ category: TimelineCategory) -> String {
    switch category {
    case .firstToken: return "首 Token 等待"
    case .reasoning: return "推理输出"
    case .output: return "回复输出"
    case .command: return "命令 / 等待"
    case .tool: return "工具 / 等待"
    case .compaction: return "上下文压缩"
    case .sleep: return "主动等待"
    case .responseGap: return "响应间隔 · 原因未知"
    case .overlap: return "活动重叠"
    case .unknown: return "未分类时间"
    }
  }

  private func openDetail() {
    fetcher.showMenuSessionInDetail()
    openWindow(id: "inspector")
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}
