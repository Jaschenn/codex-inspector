import SwiftUI

enum InspectionSection: String, CaseIterable, Identifiable {
  case overview, configurations, agents, skills, mcp, mergedConfig, warnings

  var id: Self { self }

  var title: String {
    switch self {
    case .overview: return "概览"
    case .configurations: return "配置层"
    case .agents: return "AGENTS.md"
    case .skills: return "Skills"
    case .mcp: return "MCP"
    case .mergedConfig: return "合并配置"
    case .warnings: return "诊断"
    }
  }

}

/// 按 PID 保持选择，刷新后只有原进程退出才切换，避免列表重排打断阅读。
func reconciledProcessSelection(_ selectedPID: Int?, processIDs: [Int]) -> Int? {
  if let selectedPID, processIDs.contains(selectedPID) { return selectedPID }
  return processIDs.first
}

enum InspectionScope: String, CaseIterable {
  case session = "聊天"
  case process = "进程"
}

func reconciledSessionSelection(_ selectedID: String?, sessionIDs: [String]) -> String? {
  if let selectedID, sessionIDs.contains(selectedID) { return selectedID }
  return sessionIDs.first
}

struct InspectorWindowView: View {
  @ObservedObject var fetcher: ReportFetcher
  @State private var selectedPID: Int?
  @State private var selectedSection: InspectionSection = .overview
  @State private var searchText = ""
  @State private var selectedFile: InspectedFile?
  @State private var scope: InspectionScope = .session
  @State private var selectedSessionID: String?
  @State private var selectedTurnID: String?
  @State private var objectSearchText = ""
  @State private var includeArchived = false
  @State private var includeOtherSources = false

  private var processes: [[String: Any]] { fetcher.report.dictArray("processes") }
  private var processIDs: [Int] { processes.compactMap { $0.int("pid") } }
  private var selectedProcess: [String: Any]? {
    processes.first { $0.int("pid") == selectedPID }
  }
  private var section: InspectionSection { selectedSection }
  private var sessions: [[String: Any]] { fetcher.report.dictArray("sessions") }
  private var sessionIDs: [String] { sessions.compactMap { $0.str("id") } }
  private var filteredSessions: [SessionListItem] {
    sessions.filter { session in
      objectSearchText.isEmpty
        || [session.str("title"), session.str("cwd")].compactMap { $0 }
          .contains { $0.localizedCaseInsensitiveContains(objectSearchText) }
    }.compactMap { session in
      guard let id = session.str("id") else { return nil }
      return SessionListItem(
        id: id, title: session.str("title") ?? "未命名聊天",
        path: session.str("cwd") ?? "", archived: session.bool("archived") == true)
    }
  }
  private var filteredProcesses: [[String: Any]] {
    processes.filter { process in
      objectSearchText.isEmpty
        || String(process.int("pid") ?? 0).contains(objectSearchText)
        || [process.str("cwd"), process.str("cmdline")].compactMap { $0 }
          .contains { $0.localizedCaseInsensitiveContains(objectSearchText) }
    }
  }
  private var selectedSession: [String: Any]? {
    sessions.first { $0.str("id") == selectedSessionID }
  }
  private var sessionDetail: [String: Any]? {
    let detail = fetcher.report.subDict("selected_session")
    guard detail.str("id") == selectedSessionID,
      detail.str("requested_turn_id") == selectedTurnID
    else { return nil }
    return detail.isEmpty ? nil : detail
  }
  private var currentInspection: [String: Any]? {
    if scope == .process { return selectedProcess }
    guard let detail = sessionDetail, let inspection = detail["inspection"] as? [String: Any] else {
      return nil
    }
    return inspection
  }

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
    } detail: {
      VStack(spacing: 0) {
        if let error = fetcher.lastError {
          diagnosticBanner(error, color: .red)
            .padding(.horizontal, 28)
            .padding(.top, 16)
        }
        if scope == .session {
          sessionContent
        } else if let proc = selectedProcess {
          processContent(proc)
        } else {
          emptyState
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(minWidth: 980, minHeight: 640)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          let panel = NSOpenPanel()
          panel.title = "打开配置或指令文件"
          panel.canChooseDirectories = false
          panel.allowsMultipleSelection = false
          panel.begin { [weak panel] response in
            if response == .OK, let url = panel?.url { selectedFile = InspectedFile(url: url) }
          }
        } label: {
          Label("打开文件", systemImage: "doc.badge.plus")
        }
        .keyboardShortcut("o", modifiers: .command)
        if fetcher.isRefreshing { ProgressView().controlSize(.small) }
        Button {
          fetcher.refresh()
        } label: {
          Label("刷新", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
        .help("立即刷新 · 日志变更触发更新，每秒兜底检查")
      }
    }
    .onAppear {
      reconcileSelection()
      reconcileSession()
    }
    .onChange(of: processIDs) { _ in reconcileSelection() }
    .onChange(of: selectedPID) { _ in searchText = "" }
    .onChange(of: fetcher.requestedDetailSessionID) { id in
      if let id {
        scope = .session
        includeArchived = false
        includeOtherSources = false
        objectSearchText = ""
        selectedSessionID = id
        selectedTurnID = nil
        updateSessionRequest()
        fetcher.requestedDetailSessionID = nil
      }
    }
    .onChange(of: selectedSection) { _ in searchText = "" }
    .onChange(of: sessionIDs) { _ in reconcileSession() }
    .onChange(of: selectedSessionID) { _ in
      selectedTurnID = nil
      searchText = ""
      updateSessionRequest()
    }
    .onChange(of: selectedTurnID) { _ in updateSessionRequest() }
    .onChange(of: includeArchived) { _ in updateSessionRequest() }
    .onChange(of: includeOtherSources) { _ in updateSessionRequest() }
    .onChange(of: scope) { _ in
      objectSearchText = ""
      searchText = ""
      updateSessionRequest()
    }
    .environment(\.openInspectedFile) { url in selectedFile = InspectedFile(url: url) }
    .sheet(item: $selectedFile) { file in
      FileEditorView(file: file) { fetcher.refresh() }
    }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        Text("检测对象").font(.headline)
        Picker("检测对象类型", selection: $scope) {
          Text("聊天").tag(InspectionScope.session)
          Text("进程").tag(InspectionScope.process)
        }
        .pickerStyle(.segmented).labelsHidden()
        TextField(scope == .session ? "搜索聊天或项目" : "搜索 PID、目录或命令", text: $objectSearchText)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel(scope == .session ? "搜索聊天或项目" : "搜索进程")
        HStack {
          Text(scope == .session ? "聊天记录 · \(sessions.count)" : "正在运行 · \(processes.count)")
            .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
          Spacer()
          if scope == .session {
            Menu {
              Toggle("显示归档聊天", isOn: $includeArchived)
              Toggle("显示其他来源记录", isOn: $includeOtherSources)
              Divider()
              Text("默认显示可识别的桌面与 CLI 聊天")
            } label: {
              Image(
                systemName: includeArchived || includeOtherSources
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton).frame(width: 22)
            .accessibilityLabel("筛选聊天")
            .help("归档与来源筛选；默认显示可识别的桌面与 CLI 聊天")
          }
        }
      }
      .padding(16)
      Divider()
      if scope == .session {
        sessionBrowser
      } else {
        processBrowser
      }
      Divider()
      HStack(spacing: 8) {
        Circle().fill(fetcher.lastError == nil ? Color.green : Color.orange)
          .frame(width: 6, height: 6)
        VStack(alignment: .leading, spacing: 4) {
          Text(fetcher.lastError == nil ? "自动更新 · 每秒兜底" : "刷新失败，正在重试")
          ReportUpdatedLabel(clock: fetcher.updateClock)
        }
        Spacer(minLength: 0)
      }
      .font(.system(size: 11)).foregroundColor(.secondary).padding(16)
    }
  }

  private var sessionBrowser: some View {
    NativeSessionList(items: filteredSessions, selection: $selectedSessionID)
      .overlay {
        if filteredSessions.isEmpty {
          objectListEmpty(
            sessions.isEmpty ? "暂无聊天记录" : "没有匹配的聊天",
            detail: sessions.isEmpty ? "等待读取本地 Codex 日志。" : "试试其他标题或项目名称。")
        }
      }
  }

  private var processBrowser: some View {
    List(selection: $selectedPID) {
      ForEach(filteredProcesses.compactMap { $0.int("pid") }, id: \.self) { pid in
        if let process = processes.first(where: { $0.int("pid") == pid }) {
          let trust = trustPresentation(for: process)
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
              Circle().fill(trust.color).frame(width: 6, height: 6).help(trust.explanation)
              Text("PID \(String(pid))").font(.system(size: 13, weight: .medium)).monospacedDigit()
              Spacer()
            }
            Text(shortenPath(process.str("cwd")))
              .font(.system(size: 12)).foregroundColor(.secondary)
              .lineLimit(2).truncationMode(.middle)
          }
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .tag(pid)
          .help(process.str("cmdline") ?? "Codex 进程")
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("选择进程 PID \(String(pid))")
        }
      }
    }
    .listStyle(.sidebar)
    .overlay {
      if filteredProcesses.isEmpty {
        objectListEmpty(
          processes.isEmpty ? "未发现 Codex 进程" : "没有匹配的进程",
          detail: processes.isEmpty ? "启动 Codex 后会自动显示。" : "试试其他 PID 或目录。")
      }
    }
  }

  private func objectListEmpty(_ title: String, detail: String) -> some View {
    VStack(spacing: 8) {
      Text(title).font(.system(size: 13, weight: .medium))
      Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
    }
    .multilineTextAlignment(.center).padding(20)
  }

  private var contentSelector: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("检查内容", selection: $selectedSection) {
        ForEach(InspectionSection.allCases) { item in
          Text(item.title).tag(item)
        }
      }
      .pickerStyle(.segmented).controlSize(.large).labelsHidden()
      .accessibilityLabel("检查内容")
      if [.skills, .mcp, .agents].contains(section) {
        HStack {
          TextField("搜索名称、描述或路径", text: $searchText)
            .textFieldStyle(.roundedBorder).frame(maxWidth: 380)
            .accessibilityLabel("搜索检查内容")
          Spacer()
          if let count = sectionCount(section) {
            Text(
              searchText.isEmpty
                ? "\(count) \(section == .agents ? "个文件" : "项")"
                : "\(matchingSectionCount) / \(count) \(section == .agents ? "个文件" : "项")"
            )
            .font(.system(size: 12)).foregroundColor(.secondary)
          }
        }
      }
    }
  }

  @ViewBuilder private var sessionContent: some View {
    if let session = selectedSession {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text(session.str("title") ?? "未命名聊天")
              .font(.system(size: 20, weight: .semibold)).lineLimit(2).textSelection(.enabled)
            Text(shortenPath(sessionDetail?.str("cwd") ?? session.str("cwd")))
              .font(.system(size: 13)).foregroundColor(.secondary)
              .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
          }
          HStack(spacing: 12) {
            NativeChoicePicker(
              title: "轮次",
              choices: [PickerChoice(id: nil, title: "最新轮次 · 自动跟随")]
                + (sessionDetail?.dictArray("turns") ?? []).reversed().map { turn in
                  PickerChoice(
                    id: turn.str("id"),
                    title:
                      "第 \(turn.int("number") ?? 0) 轮 · \(String((turn.str("user_preview") ?? "无用户消息预览").prefix(38)).replacingOccurrences(of: "\n", with: " "))"
                  )
                }, selection: $selectedTurnID
            )
            .frame(maxWidth: 520).disabled(fetcher.isSessionLoading)
            Spacer(minLength: 0)
          }
          contentSelector
        }
        .padding(24)
        Divider()
        if fetcher.isSessionLoading || (sessionDetail == nil && fetcher.isRefreshing) {
          VStack(spacing: 12) {
            ProgressView()
            Text("正在加载轮次与项目目录…").foregroundColor(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail = sessionDetail {
          ScrollView {
            if section == .overview {
              VStack(alignment: .leading, spacing: 16) {
                if let error = detail.str("error") { diagnosticBanner(error, color: .orange) }
                if detail.subDict("selected_turn").isEmpty {
                  hint("选择其他聊天，或等待本地日志记录新的轮次。")
                } else {
                  ReportRevisionView(
                    revision: fetcher.report.subDict("_view_revisions").int("overview") ?? 0
                  ) {
                    sessionOverview(detail)
                  }.equatable()
                }
              }
              .frame(maxWidth: 1120, alignment: .leading)
              .padding(24).frame(maxWidth: .infinity)
            } else {
              LazyVStack(alignment: .leading, spacing: 16) {
                if let error = detail.str("error") { diagnosticBanner(error, color: .orange) }
                if detail.subDict("selected_turn").isEmpty {
                  hint("选择其他聊天，或等待本地日志记录新的轮次。")
                } else if section == .agents {
                  hint("按所选轮次目录扫描磁盘当前文件；不是历史文件快照。")
                  if let inspection = currentInspection { agentCards(inspection) }
                  recordedInstructionCards(detail)
                } else if let inspection = currentInspection {
                  hint("按所选轮次目录扫描磁盘当前配置；不代表当时的生效配置或模型请求内容。")
                  switch section {
                  case .configurations: configurationCards(inspection)
                  case .skills: skillCards(inspection)
                  case .mcp: mcpCards(inspection)
                  case .mergedConfig: mergedConfiguration(inspection)
                  case .warnings: warningCards(inspection)
                  case .overview, .agents: EmptyView()
                  }
                }
              }
              .frame(maxWidth: 1120, alignment: .leading)
              .padding(24).frame(maxWidth: .infinity)
            }
          }
          .id(
            "session-\(selectedSessionID ?? "")-\(selectedTurnID ?? "latest")-\(section.rawValue)")
        } else {
          VStack(spacing: 12) {
            Text("轮次信息暂不可用").font(.headline)
            Text("可以重试，或选择其他聊天。").foregroundColor(.secondary)
            Button("重试") { fetcher.refresh() }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    } else {
      VStack(spacing: 14) {
        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 38)).foregroundColor(
          .secondary)
        Text("选择聊天开始检查").font(.title2.bold())
        Text("从本地会话记录自动获取项目和轮次，无需手动选择项目。")
          .foregroundColor(.secondary)
      }
      .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder private func sessionOverview(_ detail: [String: Any]) -> some View {
    let turn = detail.subDict("selected_turn")
    // The overview has a bounded number of cards. Keep their layout alive while
    // scrolling instead of recreating cards from lazy height estimates.
    Group {
      ReportRevisionView(revision: fetcher.report.subDict("_view_revisions").int("statistics") ?? 0)
      {
        TurnStatisticsView(statistics: turn.subDict("statistics"))
      }.equatable()
      InspectionCard(title: "轮次与目录", icon: "clock.arrow.circlepath") {
        HStack(spacing: 12) {
          Text("第 \(turn.int("number") ?? 0) 轮").font(.system(size: 13, weight: .medium))
          Text(
            turn.str("status") == "completed"
              ? "已完成"
              : (turn.str("status") == "interrupted" ? "已中断" : "未记录结束")
          )
          .foregroundColor(.secondary)
          Spacer()
          Text(turn.str("model") ?? "模型未记录").foregroundColor(.secondary)
        }
        .font(.system(size: 13))
        InspectionField(
          label: "工作目录", value: shortenPath(detail.str("cwd")), path: detail.str("cwd"))
        DisclosureGroup("轮次时间与目录来源") {
          VStack(alignment: .leading, spacing: 14) {
            InspectionField(
              label: "记录状态",
              value: turn.str("status") == "completed"
                ? "已完成" : (turn.str("status") == "interrupted" ? "已中断" : "未记录结束"), monospaced: false
            )
            InspectionField(label: "模型", value: turn.str("model") ?? "记录未提供")
            InspectionField(
              label: "开始时间", value: recordedDate(turn.str("started_at")), monospaced: false)
            InspectionField(
              label: "结束时间", value: recordedDate(turn.str("completed_at")), monospaced: false)
            InspectionField(
              label: "模型工具调用", value: "\(turn.int("tool_count") ?? 0) 次", monospaced: false)
            InspectionField(
              label: "轮次工作目录", value: shortenPath(detail.str("cwd")), path: detail.str("cwd"))
            InspectionField(
              label: "目录来源",
              value: detail.str("directory_source") == "turn_context"
                ? "本轮 turn_context" : "会话元数据（本轮未记录目录）", monospaced: false)
            if let inspection = currentInspection {
              InspectionField(
                label: "Git 项目根",
                value: inspection.str("project_root").map(shortenPath) ?? "未识别到 Git 项目",
                path: inspection.str("project_root"))
            }
            hint("配置和指令文件按此目录自动检查；显示的是磁盘当前版本。")
          }
          .padding(.top, 14)
        }
        .font(.system(size: 13))
      }
      InspectionCard(title: "本轮活动", icon: "square.stack.3d.up") {
        ReportRevisionView(revision: fetcher.report.subDict("_view_revisions").int("activity") ?? 0)
        {
          TurnActivityView(activity: turn.subDict("activity"), cwd: detail.str("cwd"))
        }.equatable().id(turn.str("id") ?? "latest")
      }
      InspectionCard(title: "用户消息预览", icon: "person.bubble") {
        MarkdownContentView(
          source: turn.str("user_preview").flatMap { $0.isEmpty ? nil : $0 } ?? "本轮没有可显示的用户文本"
        )
        .equatable()
      }
      if let answer = turn.str("assistant_preview"), !answer.isEmpty {
        InspectionCard(title: "回复预览", icon: "bubble.left") {
          MarkdownContentView(source: answer).equatable()
        }
      }
      if let path = detail.str("rollout_path") {
        HStack {
          Text("会话记录").font(.caption).foregroundColor(.secondary)
          Text(shortenPath(path)).font(.caption).textSelection(.enabled)
          RevealButton(path: path)
        }
      }
    }
  }

  private func recordedInstructionCards(_ detail: [String: Any]) -> some View {
    LazyVStack(alignment: .leading, spacing: 16) {
      Text("会话记录中的指令文本").font(.headline)
      hint("这是日志中出现过的文本，可能由用户或宿主注入；不把它自动认定为某个磁盘文件，也不保证在后续模型请求中仍保留。")
      let instructions = detail.dictArray("recorded_instructions")
      if instructions.isEmpty { hint("截至所选轮次，没有可识别的 AGENTS.md 指令文本记录。") }
      ForEach(Array(instructions.enumerated()), id: \.offset) { _, instruction in
        InspectionCard(title: instruction.str("title") ?? "指令文本", icon: "text.quote") {
          Text("首次出现在第 \(instruction.int("first_turn_number") ?? 0) 轮").font(.caption)
            .foregroundColor(.secondary)
          LazyDisclosure("查看记录文本") {
            CodeBlockView(text: instruction.str("text") ?? "", language: .markdown, maxHeight: 420)
              .equatable()
          }
          if instruction.bool("truncated") == true { hint("文本过长，仅展示前 128,000 字符。") }
        }
      }
    }
  }

  private func reconcileSession() {
    selectedSessionID = reconciledSessionSelection(selectedSessionID, sessionIDs: sessionIDs)
    updateSessionRequest()
  }

  private func updateSessionRequest() {
    fetcher.selectSession(
      scope == .session ? selectedSessionID : nil, turnID: scope == .session ? selectedTurnID : nil,
      includeArchived: includeArchived, includeOtherSources: includeOtherSources)
  }

  private func recordedDate(_ text: String?) -> String {
    guard let text else { return "未记录" }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = formatter.date(from: text)
    if date == nil {
      formatter.formatOptions = [.withInternetDateTime]
      date = formatter.date(from: text)
    }
    return date?.formatted(date: .abbreviated, time: .standard) ?? text
  }

  private func processContent(_ proc: [String: Any]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text("PID \(String(proc.int("pid") ?? 0))").font(.system(size: 20, weight: .semibold))
            Text(shortenPath(proc.str("cwd")))
              .font(.system(size: 13)).foregroundColor(.secondary)
              .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Text("\(proc.str("user") ?? "—") · 运行 \(proc.str("etime") ?? "—")")
              .font(.system(size: 12)).foregroundColor(.secondary).monospacedDigit()
          }
          Spacer()
          let trust = trustPresentation(for: proc)
          InspectionBadge(text: trust.label, color: trust.color).help(trust.explanation)
        }
        contentSelector
      }
      .padding(24)
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          switch section {
          case .overview: overview(proc)
          case .configurations: configurationCards(proc)
          case .agents: agentCards(proc)
          case .skills: skillCards(proc)
          case .mcp: mcpCards(proc)
          case .mergedConfig: mergedConfiguration(proc)
          case .warnings: warningCards(proc)
          }
        }
        .frame(maxWidth: 1120, alignment: .leading)
        .padding(24).frame(maxWidth: .infinity)
      }
      .id("process-\(selectedPID ?? 0)-\(section.rawValue)")
    }
  }

  private func overview(_ proc: [String: Any]) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(minimum: 100), spacing: 14), count: 4),
        spacing: 14
      ) {
        metric(
          "已应用配置层",
          value: proc.dictArray("config_layers").filter { $0.bool("applied") == true }.count)
        metric("指令文件", value: proc.dictArray("agents_chain").count)
        metric(
          "启用的 Skills", value: proc.dictArray("skills").filter { $0.bool("enabled") == true }.count)
        metric("MCP 服务器", value: proc.dictArray("mcp_servers").count)
      }
      InspectionCard(title: "进程与目录", icon: "terminal") {
        InspectionField(label: "工作目录", value: shortenPath(proc.str("cwd")), path: proc.str("cwd"))
        if let error = proc.str("cwd_error") { diagnosticBanner(error, color: .orange) }
        InspectionField(
          label: "CODEX_HOME", value: shortenPath(proc.str("codex_home")),
          path: proc.str("codex_home"))
        InspectionField(
          label: "Git 项目根", value: proc.str("project_root").map(shortenPath) ?? "未识别到 Git 项目",
          path: proc.str("project_root"))
        InspectionField(label: "环境变量读取", value: proc.str("env_status") ?? "未知", monospaced: false)
        diagnosticBanner(trustPresentation(for: proc).explanation, color: .secondary)
      }
      InspectionCard(title: "启动命令", icon: "chevron.left.forwardslash.chevron.right") {
        CodeBlockView(
          text: formattedShellCommand(proc.str("cmdline") ?? "—"), language: .shell, maxHeight: 320)
      }
      InspectionCard(title: "命令行覆盖", icon: "slider.horizontal.3") {
        let overrides = proc.subDict("cli_overrides")
        if let profile = overrides.str("profile") {
          InspectionField(label: "Profile", value: profile)
        }
        if let directory = overrides.str("cd") {
          InspectionField(label: "指定工作目录", value: directory, path: directory)
        }
        let pairs = overrides["c_overrides"] as? [[Any]] ?? []
        if !pairs.isEmpty {
          CodeBlockView(text: formattedOverrides(pairs), language: .toml, maxHeight: 320)
        }
        if pairs.isEmpty && overrides.str("profile") == nil && overrides.str("cd") == nil {
          hint("没有命令行覆盖项")
        }
      }
    }
  }

  private func configurationCards(_ proc: [String: Any]) -> some View {
    ForEach(Array(proc.dictArray("config_layers").enumerated()), id: \.offset) { index, layer in
      InspectionCard(
        title: "\(index + 1). \(configurationTitle(layer.str("kind")))", icon: "square.3.layers.3d"
      ) {
        HStack {
          InspectionBadge(
            text: layer.bool("applied") == true
              ? "已应用" : (layer.bool("exists") == true ? "已跳过" : "未找到"),
            color: layer.bool("applied") == true ? .green : .secondary
          )
          Spacer()
        }
        InspectionField(
          label: "位置", value: layer.str("path").map(shortenPath) ?? "命令行参数", path: layer.str("path")
        )
        if let error = layer.str("parse_error") { diagnosticBanner(error, color: .red) }
        if let reason = layer.str("skip_reason") { diagnosticBanner(reason, color: .orange) }
      }
    }
  }

  private func agentCards(_ proc: [String: Any]) -> some View {
    let docs = filtered(proc.dictArray("agents_chain"), fields: ["path", "scope"])
    return VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("磁盘当前指令文件").font(.headline)
        Spacer()
        if scope == .session, let directory = proc.str("project_root") ?? proc.str("cwd"),
          directory != "/"
        {
          let target = URL(fileURLWithPath: directory).appendingPathComponent("AGENTS.md")
          let override = URL(fileURLWithPath: directory).appendingPathComponent(
            "AGENTS.override.md")
          if !FileManager.default.fileExists(atPath: target.path)
            && !FileManager.default.fileExists(atPath: override.path)
          {
            Button("创建项目 AGENTS.md") { selectedFile = InspectedFile(url: target) }
              .font(.caption)
          }
        }
      }
      hint("列出扫描发现的指令文件；是否用于某次模型调用，需要结合会话记录或请求追踪确认。")
      if docs.isEmpty { hint(searchText.isEmpty ? "没有发现 AGENTS.md" : "没有匹配的指令文件") }
      ForEach(Array(docs.enumerated()), id: \.offset) { index, doc in
        InspectionCard(
          title:
            "\(index + 1). \(doc.str("path").map { URL(fileURLWithPath: $0).lastPathComponent } ?? "AGENTS.md")",
          icon: "doc.text"
        ) {
          InspectionField(label: "范围", value: doc.str("scope") ?? "—", monospaced: false)
          InspectionField(label: "文件", value: shortenPath(doc.str("path")), path: doc.str("path"))
          if doc.bool("truncated") == true {
            diagnosticBanner(
              "指令长度达到配置上限，仅纳入文件前 \(doc.int("included_bytes") ?? 0) 字节。", color: .orange)
          }
        }
      }
    }
  }

  private func skillCards(_ proc: [String: Any]) -> some View {
    let skills = filtered(
      proc.dictArray("skills"), fields: ["name", "description", "path", "scope"])
    return LazyVStack(alignment: .leading, spacing: 16) {
      hint("Token 估算统计 SKILL.md 全文（含 frontmatter），不含引用文件和消息包装；不代表当前会话的实际用量。")
      if skills.isEmpty { hint(searchText.isEmpty ? "没有发现 Skills" : "没有匹配的 Skills") }
      ForEach(Array(skills.enumerated()), id: \.offset) { _, skill in
        InspectionCard(title: skill.str("name") ?? "未命名 Skill", icon: "doc.text") {
          HStack(spacing: 10) {
            InspectionBadge(
              text: skill.bool("enabled") == true ? "启用" : "禁用",
              color: skill.bool("enabled") == true ? .green : .secondary)
            Text(skill.str("scope") ?? "—").foregroundColor(.secondary)
            Spacer()
            if let count = skill.int("token_count") {
              InspectionBadge(text: "≈ \(count.formatted()) tokens", color: .blue)
                .help(
                  skill.str("token_method") == "tiktoken"
                    ? "tiktoken · \(skill.str("token_encoding") ?? "o200k_base") · SKILL.md 全文，含 frontmatter；不含引用文件与消息包装，非实际调用用量。"
                    : "缺少本地分词表，当前按字符粗估；不代表实际模型调用用量。")
            } else {
              Text("Token 估算不可用").font(.caption).foregroundColor(.secondary)
            }
          }
          if let description = skill.str("description"), !description.isEmpty {
            Text(description).font(.system(size: 13)).textSelection(.enabled)
          }
          InspectionField(
            label: "位置", value: shortenPath(skill.str("path")), path: skill.str("path"))
          if let reason = skill.str("disabled_reason") { diagnosticBanner(reason, color: .orange) }
          if let error = skill.str("parse_error") { diagnosticBanner(error, color: .red) }
        }
      }
    }
  }

  private func mcpCards(_ proc: [String: Any]) -> some View {
    let servers = proc.dictArray("mcp_servers").filter {
      searchText.isEmpty || jsonText($0).localizedCaseInsensitiveContains(searchText)
    }
    return LazyVStack(alignment: .leading, spacing: 16) {
      if servers.isEmpty { hint(searchText.isEmpty ? "没有配置 MCP 服务器" : "没有匹配的 MCP 服务器") }
      ForEach(Array(servers.enumerated()), id: \.offset) { _, server in
        InspectionCard(
          title: server.str("name") ?? "MCP 服务器", icon: "point.3.connected.trianglepath.dotted"
        ) {
          // 完整配置面板使用报告中已经遮蔽敏感字段的副本。
          let raw = proc.subDict("merged_config").subDict("mcp_servers")
            .subDict(server.str("name") ?? "")
          if let command = raw.str("command") {
            InspectionField(
              label: "启动命令", value: command, path: command.hasPrefix("/") ? command : nil)
          }
          if let url = raw.str("url") { InspectionField(label: "服务地址", value: url) }
          CodeBlockView(text: jsonText(raw), language: .json, maxHeight: 360).equatable()
        }
      }
    }
  }

  private func mergedConfiguration(_ proc: [String: Any]) -> some View {
    InspectionCard(title: "合并配置 · 敏感字段已遮蔽", icon: "curlybraces") {
      CodeBlockView(text: jsonText(proc.subDict("merged_config")), language: .json, maxHeight: 580)
        .equatable()
    }
  }

  private func warningCards(_ proc: [String: Any]) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      let warnings = proc.stringArray("warnings")
      if warnings.isEmpty { hint("当前检测对象没有诊断警告") }
      ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
        diagnosticBanner(warning, color: .orange)
      }
      ForEach(Array(fetcher.report.dictArray("process_errors").enumerated()), id: \.offset) {
        _, error in
        diagnosticBanner(
          "PID \(error.int("pid") ?? 0) 分析失败：\(error.str("error") ?? "未知错误")", color: .red)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 16) {
      Image(systemName: "terminal").font(.system(size: 44)).foregroundColor(.secondary)
      Text("等待 Codex 进程").font(.title2.bold())
      Text("启动 Codex CLI 或桌面应用后，检查结果会自动显示在这里。")
        .foregroundColor(.secondary)
      Button("立即检查") { fetcher.refresh() }
      ForEach(Array(fetcher.report.dictArray("process_errors").enumerated()), id: \.offset) {
        _, error in
        diagnosticBanner(
          "PID \(error.int("pid") ?? 0)：\(error.str("error") ?? "分析失败")", color: .red)
      }
    }
    .padding(36)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func metric(_ title: String, value: Int) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("\(value)").font(.system(size: 28, weight: .semibold, design: .rounded))
      Text(title).font(.system(size: 12)).foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
  }

  private func diagnosticBanner(_ message: String, color: Color) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "info.circle").foregroundColor(color)
      Text(message).font(.system(size: 13)).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(14)
    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
  }

  private func hint(_ text: String) -> some View {
    Text(text).font(.system(size: 13)).foregroundColor(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func filtered(_ items: [[String: Any]], fields: [String]) -> [[String: Any]] {
    guard !searchText.isEmpty else { return items }
    return items.filter { item in
      fields.contains { item.str($0)?.localizedCaseInsensitiveContains(searchText) == true }
    }
  }

  private var matchingSectionCount: Int {
    guard let inspection = currentInspection else { return 0 }
    switch section {
    case .agents:
      return filtered(inspection.dictArray("agents_chain"), fields: ["path", "scope"]).count
    case .skills:
      return filtered(
        inspection.dictArray("skills"), fields: ["name", "description", "path", "scope"]
      ).count
    case .mcp:
      return inspection.dictArray("mcp_servers").filter {
        searchText.isEmpty || jsonText($0).localizedCaseInsensitiveContains(searchText)
      }.count
    default: return 0
    }
  }

  private func sectionCount(_ section: InspectionSection) -> Int? {
    guard let proc = currentInspection else { return nil }
    switch section {
    case .overview, .mergedConfig: return nil
    case .configurations: return proc.dictArray("config_layers").count
    case .agents: return proc.dictArray("agents_chain").count
    case .skills: return proc.dictArray("skills").count
    case .mcp: return proc.dictArray("mcp_servers").count
    case .warnings: return proc.stringArray("warnings").count
    }
  }

  private func configurationTitle(_ kind: String?) -> String {
    switch kind {
    case "system": return "系统配置"
    case "global": return "全局配置"
    case "project": return "项目配置"
    case "profile": return "Profile 配置"
    case "cli": return "命令行覆盖"
    default: return kind ?? "配置"
    }
  }

  private func jsonText(_ value: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      let text = String(data: data, encoding: .utf8)
    else {
      return "无法显示配置内容"
    }
    return text
  }

  private func reconcileSelection() {
    selectedPID = reconciledProcessSelection(selectedPID, processIDs: processIDs)
  }

  private func formattedOverrides(_ pairs: [[Any]]) -> String {
    pairs.compactMap { pair in
      guard pair.count == 2 else { return nil }
      let value: String
      if let data = try? JSONSerialization.data(
        withJSONObject: pair[1], options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]),
        let json = String(data: data, encoding: .utf8)
      {
        value = json
      } else {
        value = String(describing: pair[1])
      }
      return "\(pair[0]) = \(value)"
    }.joined(separator: "\n")
  }
}

struct InspectionCard<Content: View>: View {
  let title: String
  let icon: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label(title, systemImage: icon).font(.system(size: 15, weight: .semibold))
      content()
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
  }
}

private struct InspectionField: View {
  let label: String
  let value: String
  var path: String? = nil
  var monospaced = true

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Text(label).font(.system(size: 13)).foregroundColor(.secondary)
        .frame(width: 112, alignment: .leading)
        .textSelection(.enabled)
      Text(value).font(.system(size: 13, design: monospaced ? .monospaced : .default))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      RevealButton(path: path)
      BrowseFileButton(path: path)
    }
  }
}

private struct InspectionBadge: View {
  let text: String
  let color: Color

  var body: some View {
    Text(text).font(.system(size: 12, weight: .medium))
      .foregroundColor(color)
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(color.opacity(0.1), in: Capsule())
  }
}
