import SwiftUI

enum InspectionSection: String, CaseIterable, Identifiable {
  case overview, configurations, agents, skills, mcp, mergedConfig, warnings

  var id: Self { self }

  var title: String {
    switch self {
    case .overview: return "进程概览"
    case .configurations: return "配置层"
    case .agents: return "AGENTS.md"
    case .skills: return "Skills"
    case .mcp: return "MCP 服务器"
    case .mergedConfig: return "合并配置"
    case .warnings: return "诊断提示"
    }
  }

  var icon: String {
    switch self {
    case .overview: return "square.grid.2x2"
    case .configurations: return "square.3.layers.3d"
    case .agents: return "doc.text"
    case .skills: return "sparkles"
    case .mcp: return "point.3.connected.trianglepath.dotted"
    case .mergedConfig: return "curlybraces"
    case .warnings: return "exclamationmark.bubble"
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
  @State private var selectedSection: InspectionSection? = .overview
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
  private var section: InspectionSection { selectedSection ?? .overview }
  private var sessions: [[String: Any]] { fetcher.report.dictArray("sessions") }
  private var sessionIDs: [String] { sessions.compactMap { $0.str("id") } }
  private var filteredSessionIDs: [String] {
    sessions.filter { session in
      objectSearchText.isEmpty
        || [session.str("title"), session.str("cwd")].compactMap { $0 }
          .contains { $0.localizedCaseInsensitiveContains(objectSearchText) }
    }.compactMap { $0.str("id") }
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
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
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
    .frame(minWidth: 900, minHeight: 620)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          let panel = NSOpenPanel()
          panel.title = "打开配置或指令文件"
          panel.canChooseDirectories = false
          panel.allowsMultipleSelection = false
          panel.begin { response in
            if response == .OK, let url = panel.url { selectedFile = InspectedFile(url: url) }
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
        .help("立即刷新 · 每 3 秒自动检查")
      }
    }
    .onAppear {
      reconcileSelection()
      reconcileSession()
    }
    .onChange(of: processIDs) { _ in reconcileSelection() }
    .onChange(of: selectedPID) { _ in searchText = "" }
    .onChange(of: selectedSection) { _ in searchText = "" }
    .onChange(of: sessionIDs) { _ in reconcileSession() }
    .onChange(of: selectedSessionID) { _ in
      selectedTurnID = nil
      updateSessionRequest()
    }
    .onChange(of: selectedTurnID) { _ in updateSessionRequest() }
    .onChange(of: includeArchived) { _ in updateSessionRequest() }
    .onChange(of: includeOtherSources) { _ in updateSessionRequest() }
    .onChange(of: scope) { _ in
      objectSearchText = ""
      updateSessionRequest()
    }
    .environment(\.openInspectedFile) { url in selectedFile = InspectedFile(url: url) }
    .sheet(item: $selectedFile) { file in
      FileEditorView(file: file) { fetcher.refresh() }
    }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      Picker("检查对象", selection: $scope) {
        Text("聊天").tag(InspectionScope.session)
        Text("进程").tag(InspectionScope.process)
      }
      .pickerStyle(.segmented).padding(12)
      if scope == .session {
        sessionBrowser
        Divider()
      }
      List(selection: $selectedSection) {
        if scope == .process {
          Section("正在运行 · \(processes.count)") {
            ForEach(processIDs, id: \.self) { pid in
              if let proc = processes.first(where: { $0.int("pid") == pid }) {
                Button {
                  selectedPID = pid
                } label: {
                  HStack(alignment: .top, spacing: 8) {
                    Circle().fill(trustPresentation(for: proc).color)
                      .frame(width: 7, height: 7).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 4) {
                      Text("PID \(pid)").font(.system(size: 13, weight: .semibold))
                      Text(shortenPath(proc.str("cwd")))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if selectedPID == pid {
                      Image(systemName: "checkmark").foregroundColor(.accentColor)
                    }
                  }
                  .padding(.vertical, 5)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择进程 PID \(pid)")
              }
            }
            if processes.isEmpty {
              Text("未发现 Codex 进程").foregroundColor(.secondary)
            }
          }
        }
        Section("检查内容") {
          ForEach(InspectionSection.allCases) { item in
            HStack {
              Label(
                item == .overview && scope == .session ? "轮次概览" : item.title, systemImage: item.icon
              )
              Spacer()
              if let count = sectionCount(item), count > 0 {
                Text("\(count)").font(.caption).foregroundColor(.secondary)
              }
            }
            .tag(item)
          }
        }
      }
      .listStyle(.sidebar)
      Divider()
      VStack(alignment: .leading, spacing: 5) {
        Label("自动检查 · 3 秒", systemImage: "arrow.triangle.2.circlepath")
        if let updated = fetcher.lastUpdated {
          Text("更新于 \(updated.formatted(date: .omitted, time: .standard))")
        }
      }
      .font(.system(size: 11))
      .foregroundColor(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
    }
  }

  private var sessionBrowser: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("聊天记录 · \(sessions.count)").font(.caption.weight(.semibold)).foregroundColor(
          .secondary)
        Spacer()
        Menu {
          Toggle("显示归档聊天", isOn: $includeArchived)
          Toggle("显示其他来源记录", isOn: $includeOtherSources)
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton).frame(width: 20)
      }
      TextField("搜索聊天或项目", text: $objectSearchText)
        .textFieldStyle(.roundedBorder).accessibilityLabel("搜索聊天或项目")
      if !includeOtherSources {
        Text("桌面 / CLI · 其他来源可在筛选中显示").font(.system(size: 10)).foregroundColor(.secondary)
      }
      ScrollView {
        LazyVStack(spacing: 4) {
          ForEach(filteredSessionIDs, id: \.self) { id in
            if let session = sessions.first(where: { $0.str("id") == id }) {
              Button {
                selectedSessionID = id
                searchText = ""
              } label: {
                HStack(alignment: .top, spacing: 8) {
                  Image(systemName: session.bool("archived") == true ? "archivebox" : "bubble.left")
                    .foregroundColor(selectedSessionID == id ? .accentColor : .secondary)
                  VStack(alignment: .leading, spacing: 5) {
                    Text(session.str("title") ?? "未命名聊天").font(.system(size: 12, weight: .medium))
                      .lineLimit(2)
                    Text(shortenPath(session.str("cwd"))).font(.system(size: 10)).foregroundColor(
                      .secondary
                    )
                    .lineLimit(1).truncationMode(.middle)
                  }
                  Spacer(minLength: 0)
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(
                  selectedSessionID == id ? Color.accentColor.opacity(0.14) : .clear,
                  in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("选择聊天：\(session.str("title") ?? "未命名聊天")")
            }
          }
          if sessions.isEmpty {
            Text("暂无可读取的聊天记录").font(.caption).foregroundColor(.secondary).padding(12)
          } else if filteredSessionIDs.isEmpty {
            Text("没有匹配的聊天，试试其他标题或项目名称。").font(.caption).foregroundColor(.secondary).padding(12)
          }
        }
      }
      .frame(maxHeight: 240)
    }
    .padding(.horizontal, 12).padding(.bottom, 12)
  }

  @ViewBuilder private var sessionContent: some View {
    if let session = selectedSession {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 12) {
          Text(section == .overview ? "轮次概览" : section.title).font(.system(size: 27, weight: .bold))
          Text(session.str("title") ?? "未命名聊天").font(.system(size: 14, weight: .medium)).lineLimit(
            2)
          HStack {
            Picker("轮次", selection: $selectedTurnID) {
              Text("最新轮次 · 自动跟随").tag(nil as String?)
              ForEach(
                Array((sessionDetail?.dictArray("turns") ?? []).reversed().enumerated()),
                id: \.offset
              ) { _, turn in
                Text(
                  "第 \(turn.int("number") ?? 0) 轮 · \(String((turn.str("user_preview") ?? "无用户消息预览").prefix(38)).replacingOccurrences(of: "\n", with: " "))"
                )
                .tag(turn.str("id"))
              }
            }
            .frame(maxWidth: 480).disabled(fetcher.isSessionLoading)
            Spacer()
            Text("当前磁盘文件").font(.caption).foregroundColor(.secondary)
              .help("按所选轮次的目录扫描当前文件，不是历史文件快照。")
          }
        }
        .padding(28)
        Divider()
        if fetcher.isSessionLoading || (sessionDetail == nil && fetcher.isRefreshing) {
          VStack(spacing: 12) {
            ProgressView()
            Text("正在加载轮次与项目目录…").foregroundColor(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail = sessionDetail {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
              if let error = detail.str("error") { diagnosticBanner(error, color: .orange) }
              if detail.subDict("selected_turn").isEmpty {
                hint("选择其他聊天，或等待本地日志记录新的轮次。")
              } else if section == .overview {
                sessionOverview(detail)
              } else if section == .agents {
                if let inspection = currentInspection { agentCards(inspection) }
                recordedInstructionCards(detail)
              } else if let inspection = currentInspection {
                hint("以所选轮次目录为依据扫描当前配置；不代表当时的生效配置或模型请求内容。")
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
            .padding(28).frame(maxWidth: .infinity, alignment: .leading)
          }
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

  private func sessionOverview(_ detail: [String: Any]) -> some View {
    let turn = detail.subDict("selected_turn")
    return VStack(alignment: .leading, spacing: 18) {
      TurnStatisticsView(statistics: turn.subDict("statistics"))
      InspectionCard(title: "第 \(turn.int("number") ?? 0) 轮", icon: "clock.arrow.circlepath") {
        InspectionField(
          label: "记录状态",
          value: turn.str("status") == "completed"
            ? "已完成" : (turn.str("status") == "interrupted" ? "已中断" : "未记录结束"), monospaced: false)
        InspectionField(label: "模型", value: turn.str("model") ?? "记录未提供")
        InspectionField(
          label: "开始时间", value: recordedDate(turn.str("started_at")), monospaced: false)
        InspectionField(
          label: "结束时间", value: recordedDate(turn.str("completed_at")), monospaced: false)
        InspectionField(label: "工具调用", value: "\(turn.int("tool_count") ?? 0)", monospaced: false)
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
      InspectionCard(title: "用户消息预览", icon: "person.bubble") {
        MarkdownContentView(
          source: turn.str("user_preview").flatMap { $0.isEmpty ? nil : $0 } ?? "本轮没有可显示的用户文本")
      }
      if let answer = turn.str("assistant_preview"), !answer.isEmpty {
        InspectionCard(title: "回复预览", icon: "bubble.left") {
          MarkdownContentView(source: answer)
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
    VStack(alignment: .leading, spacing: 18) {
      Text("会话记录中的指令文本").font(.headline)
      hint("这是日志中出现过的文本，可能由用户或宿主注入；不把它自动认定为某个磁盘文件，也不保证在后续模型请求中仍保留。")
      let instructions = detail.dictArray("recorded_instructions")
      if instructions.isEmpty { hint("截至所选轮次，没有可识别的 AGENTS.md 指令文本记录。") }
      ForEach(Array(instructions.enumerated()), id: \.offset) { _, instruction in
        InspectionCard(title: instruction.str("title") ?? "指令文本", icon: "text.quote") {
          Text("首次出现在第 \(instruction.int("first_turn_number") ?? 0) 轮").font(.caption)
            .foregroundColor(.secondary)
          DisclosureGroup("查看记录文本") {
            CodeBlockView(text: instruction.str("text") ?? "", language: .markdown, maxHeight: 420)
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
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 7) {
            Text(section.title).font(.system(size: 27, weight: .bold))
            Text(
              "PID \(proc.int("pid") ?? 0)  ·  \(proc.str("user") ?? "—")  ·  运行 \(proc.str("etime") ?? "—")"
            )
            .font(.system(size: 13)).foregroundColor(.secondary)
          }
          Spacer()
          let trust = trustPresentation(for: proc)
          InspectionBadge(text: trust.label, color: trust.color)
            .help(trust.explanation)
        }
        if [.skills, .mcp, .agents].contains(section) {
          TextField("搜索名称、描述或路径", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 420)
            .accessibilityLabel("搜索检查内容")
        }
      }
      .padding(28)
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
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
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func overview(_ proc: [String: Any]) -> some View {
    VStack(alignment: .leading, spacing: 18) {
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
        if let config = overrides.str("config_path") {
          InspectionField(label: "指定配置文件", value: config, path: config)
        }
        let pairs = overrides["c_overrides"] as? [[Any]] ?? []
        if !pairs.isEmpty {
          CodeBlockView(text: formattedOverrides(pairs), language: .toml, maxHeight: 320)
        }
        if pairs.isEmpty && overrides.str("profile") == nil && overrides.str("cd") == nil
          && overrides.str("config_path") == nil
        {
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
    return VStack(alignment: .leading, spacing: 18) {
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
        }
      }
    }
  }

  private func skillCards(_ proc: [String: Any]) -> some View {
    let skills = filtered(
      proc.dictArray("skills"), fields: ["name", "description", "path", "scope"])
    return VStack(alignment: .leading, spacing: 18) {
      hint("Token 估算统计 SKILL.md 全文（含 frontmatter），不含引用文件和消息包装；不代表当前会话的实际用量。")
      if skills.isEmpty { hint(searchText.isEmpty ? "没有发现 Skills" : "没有匹配的 Skills") }
      ForEach(Array(skills.enumerated()), id: \.offset) { _, skill in
        InspectionCard(title: skill.str("name") ?? "未命名 Skill", icon: "sparkles") {
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
    return VStack(alignment: .leading, spacing: 18) {
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
          CodeBlockView(text: jsonText(raw), language: .json, maxHeight: 360)
        }
      }
    }
  }

  private func mergedConfiguration(_ proc: [String: Any]) -> some View {
    InspectionCard(title: "合并配置 · 敏感字段已遮蔽", icon: "curlybraces") {
      CodeBlockView(text: jsonText(proc.subDict("merged_config")), language: .json, maxHeight: 580)
    }
  }

  private func warningCards(_ proc: [String: Any]) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      let warnings = proc.stringArray("warnings")
      if warnings.isEmpty { hint("当前进程没有诊断警告") }
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
    .padding(22)
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
      Text(label).font(.system(size: 12)).foregroundColor(.secondary)
        .frame(width: 130, alignment: .leading)
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
