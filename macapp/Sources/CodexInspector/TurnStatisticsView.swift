import SwiftUI

enum TimelineCategory: String {
  case firstToken = "first_token_wait"
  case reasoning, output, command, tool, overlap, unknown

  var title: String {
    switch self {
    case .firstToken: return "首 Token 前等待"
    case .reasoning: return "推理输出（可观测）"
    case .output: return "回复输出"
    case .command: return "命令执行 / 等待"
    case .tool: return "工具调用 / 等待返回"
    case .overlap: return "活动重叠"
    case .unknown: return "未分类时间"
    }
  }

  var color: Color {
    switch self {
    case .firstToken: return .orange
    case .reasoning: return .purple
    case .output: return .blue
    case .command: return .green
    case .tool: return .teal
    case .overlap: return .pink
    case .unknown: return .gray
    }
  }

  var explanation: String {
    switch self {
    case .unknown:
      return "这段时间缺少细粒度日志，可能包含模型内部推理、网络传输或服务排队、运行时调度、审批等待以及未记录的工作。无法确定具体原因，也不等于模型一直在思考。"
    case .reasoning: return "日志可观测的推理事件区间，不代表完整的模型内部思考时间。"
    case .command: return "命令的可观测执行区间，包含命令内部的等待，不等于 CPU 运行时间。"
    case .tool: return "工具调用到返回的可观测区间，包含等待返回。"
    case .overlap: return "同一时间存在多个活动记录；重叠部分只计一次。"
    case .firstToken: return "首个可观测 Token 出现前的等待，可能包含请求处理、网络和模型服务等待。"
    case .output: return "日志记录的回复或进度文本输出区间。"
    }
  }
}

func tokenPercentage(_ count: Int?, of total: Int?) -> String? {
  guard let count, let total, count >= 0, total > 0, count <= total else { return nil }
  return String(format: "%.1f%%", Double(count) / Double(total) * 100)
}

struct TimingSegment: Identifiable {
  let id: Int
  let start: Double
  let end: Double
  let category: TimelineCategory
  let components: [TimelineCategory]

  var duration: Double { max(0, end - start) }

  init?(index: Int, data: [String: Any]) {
    guard let start = data["start_ms"] as? NSNumber, let end = data["end_ms"] as? NSNumber else {
      return nil
    }
    guard start.doubleValue.isFinite, end.doubleValue.isFinite,
      start.doubleValue >= 0, end.doubleValue > start.doubleValue
    else { return nil }
    self.id = index
    self.start = start.doubleValue
    self.end = end.doubleValue
    self.category = TimelineCategory(rawValue: data.str("category") ?? "") ?? .unknown
    self.components = data.stringArray("components").compactMap(TimelineCategory.init(rawValue:))
  }
}

func formattedDuration(_ milliseconds: Double) -> String {
  guard milliseconds.isFinite, milliseconds >= 0 else { return "未记录" }
  if milliseconds < 1000 { return "\(Int(milliseconds.rounded())) 毫秒" }
  if milliseconds < 60000 { return String(format: "%.1f 秒", milliseconds / 1000) }
  let seconds = Int(milliseconds / 1000)
  if seconds < 3600 { return "\(seconds / 60) 分 \(seconds % 60) 秒" }
  return "\(seconds / 3600) 小时 \((seconds % 3600) / 60) 分"
}

struct TurnStatisticsView: View {
  let statistics: [String: Any]
  @State private var hoveredTime: Double?

  private var tokens: [String: Any] { statistics.subDict("tokens") }
  private var usage: [String: Any] { tokens.subDict("usage") }
  private var timing: [String: Any] { statistics.subDict("timing") }
  private var duration: Double { (timing["span_duration_ms"] as? NSNumber)?.doubleValue ?? 0 }
  private var segments: [TimingSegment] {
    timing.dictArray("segments").enumerated().compactMap {
      TimingSegment(index: $0.offset, data: $0.element)
    }
  }
  private var hoveredSegment: TimingSegment? {
    guard let hoveredTime else { return nil }
    return segments.first { hoveredTime >= $0.start && hoveredTime < $0.end }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      tokenCard
      timelineCard
    }
    .onChange(of: duration) { _ in hoveredTime = nil }
  }

  private var tokenCard: some View {
    InspectionCard(title: "本轮 Token 用量", icon: "number") {
      if usage.isEmpty {
        Text(
          tokens.bool("counter_reset") == true ? "累计计数发生回退，无法可靠还原本轮用量。" : "日志没有提供可归属于本轮的 Token 用量。"
        )
        .font(.system(size: 13)).foregroundColor(.secondary)
      } else {
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
          spacing: 12
        ) {
          tokenMetric("总量", key: "total_tokens")
          tokenMetric("输入", key: "input_tokens")
          tokenMetric("输出", key: "output_tokens")
        }
        Divider()
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
          spacing: 12
        ) {
          tokenDetail("缓存命中", key: "cached_input_tokens", denominator: "input_tokens", basis: "输入")
          tokenDetail(
            "缓存写入", key: "cache_write_input_tokens", denominator: "input_tokens", basis: "输入")
          tokenDetail(
            "推理输出", key: "reasoning_output_tokens", denominator: "output_tokens", basis: "输出")
        }
        if timing.str("source") == "partial" {
          Text("轮次尚未结束，仅显示已报告用量。")
            .font(.system(size: 12)).foregroundColor(.secondary)
        }
        DisclosureGroup("用量口径与来源") {
          VStack(alignment: .leading, spacing: 8) {
            Text("缓存用量属于输入，推理用量属于输出，不再额外加到总量中。")
            Text(tokenSourceDescription)
            if timing.str("source") == "partial" {
              Text("进行中的模型调用可能尚未回报用量。")
            }
            if let count = tokens.int("response_count"), count > 0 {
              Text("已记录 \(count) 次模型响应")
            }
          }
          .font(.system(size: 12)).foregroundColor(.secondary).padding(.top, 8)
        }
        .font(.system(size: 12))
      }
    }
  }

  private var tokenSourceDescription: String {
    switch tokens.str("source") {
    case "turn_record": return "采用日志中的本轮累计值；多次模型调用合计，包含重复发送的上下文。"
    case "response_records": return "按响应 ID 去重后求和；仅覆盖日志已报告的响应。"
    case "thread_delta": return "旧格式：按会话累计值的前后差计算本轮用量。"
    default: return "用量未记录"
    }
  }

  private func tokenMetric(_ title: String, key: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(usage.int(key)?.formatted() ?? "—").font(
        .system(size: 25, weight: .semibold, design: .rounded))
      Text(title).font(.system(size: 12)).foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func tokenDetail(_ title: String, key: String, denominator: String, basis: String)
    -> some View
  {
    let count = usage.int(key)
    let percentage = tokenPercentage(count, of: usage.int(denominator))
    return VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.system(size: 12)).foregroundColor(.secondary)
      Text(count?.formatted() ?? "未提供").font(.system(size: 14, weight: .medium)).monospacedDigit()
      Text("占\(basis) \(percentage ?? "—")").font(.caption).foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .help("\(title)比例 = \(title) Token ÷ \(basis) Token。分母为零、字段缺失或计数不一致时不显示比例。")
  }

  private var timelineCard: some View {
    InspectionCard(title: "本轮耗时分布", icon: "chart.bar.xaxis") {
      if duration <= 0 || segments.isEmpty {
        Text("日志没有足够的时间信息，暂时无法绘制分布。")
          .font(.system(size: 13)).foregroundColor(.secondary)
      } else {
        HStack(alignment: .firstTextBaseline) {
          Text(formattedDuration(duration)).font(
            .system(size: 23, weight: .semibold, design: .rounded))
          Text(timing.str("source") == "partial" ? "已记录区间 · 轮次未结束" : "轮次开始 → 结束")
            .font(.caption).foregroundColor(.secondary)
          Spacer()
          if let first = timing["first_token_ms"] as? NSNumber {
            Text("首 Token：\(formattedDuration(first.doubleValue))").font(.caption).foregroundColor(
              .secondary)
          }
        }
        timeline
        HStack {
          Text("0 秒")
          Spacer()
          Text(formattedDuration(duration))
        }
        .font(.caption).foregroundColor(.secondary)
        Group {
          if let segment = hoveredSegment {
            HStack(spacing: 8) {
              Circle().fill(segment.category.color).frame(width: 8, height: 8)
              Text(segment.category.title).help(segment.category.explanation)
              Text(
                "\(formattedDuration(segment.start)) → \(formattedDuration(segment.end)) · \(formattedDuration(segment.duration))"
              )
              .foregroundColor(.secondary)
            }
          } else {
            Text("悬停时间线，查看阶段、起止时间和耗时。").foregroundColor(.secondary)
          }
        }
        .font(.caption).frame(height: 20, alignment: .leading)
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], alignment: .leading,
          spacing: 14
        ) {
          ForEach(Array(timing.dictArray("category_totals").enumerated()), id: \.offset) {
            _, entry in
            let category = TimelineCategory(rawValue: entry.str("category") ?? "") ?? .unknown
            let amount = (entry["duration_ms"] as? NSNumber)?.doubleValue ?? 0
            VStack(alignment: .leading, spacing: 5) {
              HStack(spacing: 7) {
                Circle().fill(category.color).frame(width: 8, height: 8)
                Text(category.title).font(.system(size: 12, weight: .medium))
              }
              Text(
                "\(formattedDuration(amount)) · \(String(format: "%.1f%%", amount / duration * 100))"
              )
              .font(.caption).foregroundColor(.secondary)
            }
            .help(category.explanation)
          }
        }
        DisclosureGroup("统计口径与限制") {
          VStack(alignment: .leading, spacing: 8) {
            Text("推理和回复段仅表示可观测事件；日志无法完整区分内部思考、网络等待、服务排队与调度。未分类时间保留为未知原因，不推测成思考。")
            Text("命令与工具段包含等待返回。包装调用不与其内部命令重复计时；不同活动重叠的部分只计一次，因此所有分类之和等于图中的总时长。")
            Text(
              "总时长优先使用日志 duration_ms，否则使用起止时间差。用户点击发送到执行器接收之间的未记录延迟不包含在内。首 Token 前区间只补充未被其他活动记录覆盖的部分。"
            )
            if (timing.int("pending_tool_count") ?? 0) > 0 {
              Text("有工具调用未记录返回，未推算其结束时间。")
            }
          }
          .font(.caption).foregroundColor(.secondary).padding(.top, 8)
        }
        .font(.caption)
      }
    }
  }

  private var timeline: some View {
    GeometryReader { geometry in
      Canvas { context, size in
        for segment in segments {
          let rect = CGRect(
            x: size.width * segment.start / duration, y: 0,
            width: size.width * segment.duration / duration, height: size.height)
          context.fill(Path(rect), with: .color(segment.category.color))
          if segment.id == hoveredSegment?.id && rect.width >= 1 {
            context.stroke(
              Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.primary), lineWidth: 1)
          }
        }
      }
      .onContinuousHover { phase in
        switch phase {
        case .active(let location):
          hoveredTime = min(
            duration - 0.001, max(0, location.x / max(1, geometry.size.width) * duration))
        case .ended: hoveredTime = nil
        }
      }
    }
    .frame(height: 26)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .accessibilityLabel("本轮耗时分布，分类总和等于记录总时长")
    .help(
      hoveredSegment.map { segment in
        segment.category.explanation
          + (segment.category == .overlap
            ? " 重叠记录：" + segment.components.map(\.title).joined(separator: "、") : "")
      } ?? "悬停查看各时间段的含义。")
  }
}
