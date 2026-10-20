import Combine
import Foundation

struct FetchError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) { self.description = message }
}

final class ReportFetcher: ObservableObject {
  @Published var report: [String: Any] = [
    "generated_at": "", "process_count": 0, "processes": [], "process_errors": [],
  ]
  @Published var lastError: String?
  @Published var lastUpdated: Date?
  @Published var isRefreshing = false
  @Published var isSessionLoading = false
  @Published var requestedDetailSessionID: String?

  private struct InspectionRequest: Equatable {
    var sessionID: String?
    var turnID: String?
    var includeArchived = false
    var includeOtherSources = false
    var menuPID: Int?
    var menuSessionID: String?

    var payload: [String: Any] {
      var result: [String: Any] = [
        "sessions": true, "menu": true, "include_archived": includeArchived,
        "include_other_sources": includeOtherSources,
      ]
      if let sessionID { result["session_id"] = sessionID }
      if let turnID { result["turn_id"] = turnID }
      if let menuPID { result["menu_pid"] = menuPID }
      if let menuSessionID { result["menu_session_id"] = menuSessionID }
      return result
    }
  }
  private var inspectionRequest = InspectionRequest()
  private var timer: Timer?
  private var eventRefresh: DispatchWorkItem?
  private var lastStarted = Date.distantPast
  private var isRequestRunning = false
  private var needsRefresh = false
  private let queue = DispatchQueue(label: "CodexInspector.engine", qos: .userInitiated)
  private let engine: InspectorEngine
  private lazy var monitor = InspectionMonitor { [weak self] in self?.scheduleEventRefresh() }

  init(interval: TimeInterval = 1.0) {
    engine = InspectorEngine(
      executable: Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/codex-inspector-core"))
    refresh()
    timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      self?.fetch(showProgress: false)
    }
    timer?.tolerance = 0.1
    if let timer { RunLoop.main.add(timer, forMode: .common) }
  }

  deinit {
    timer?.invalidate()
    eventRefresh?.cancel()
  }

  func selectSession(
    _ sessionID: String?, turnID: String?, includeArchived: Bool = false,
    includeOtherSources: Bool = false
  ) {
    var request = inspectionRequest
    request.sessionID = sessionID
    request.turnID = turnID
    request.includeArchived = includeArchived
    request.includeOtherSources = includeOtherSources
    guard request != inspectionRequest else { return }
    inspectionRequest = request
    isSessionLoading = sessionID != nil
    refresh()
  }

  func selectMenuProcess(_ pid: Int?) {
    guard pid != inspectionRequest.menuPID else { return }
    inspectionRequest.menuPID = pid
    inspectionRequest.menuSessionID = nil
    refresh()
  }

  func selectMenuSession(_ id: String?) {
    guard id != inspectionRequest.menuSessionID else { return }
    inspectionRequest.menuSessionID = id
    refresh()
  }

  func showMenuSessionInDetail() {
    requestedDetailSessionID = report.subDict("menu_session").str("id")
  }

  func refresh() { fetch(showProgress: true) }

  private func scheduleEventRefresh() {
    // Coalesce bursts without postponing forever during continuous token output.
    guard eventRefresh == nil else { return }
    let delay = max(0.05, 0.3 - Date().timeIntervalSince(lastStarted))
    let work = DispatchWorkItem { [weak self] in
      self?.eventRefresh = nil
      self?.fetch(showProgress: false)
    }
    eventRefresh = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func fetch(showProgress: Bool) {
    if isRequestRunning {
      needsRefresh = true
      if showProgress { isRefreshing = true }
      return
    }
    isRequestRunning = true
    if showProgress { isRefreshing = true }
    needsRefresh = false
    lastStarted = Date()
    let request = inspectionRequest
    queue.async { [weak self] in
      guard let self else { return }
      let result = autoreleasepool { self.engine.request(request.payload) }
      DispatchQueue.main.async {
        self.isRequestRunning = false
        if self.isRefreshing { self.isRefreshing = false }
        guard request == self.inspectionRequest else {
          self.fetch(showProgress: self.isSessionLoading)
          return
        }
        if self.isSessionLoading { self.isSessionLoading = false }
        switch result {
        case .success(let dict):
          self.report = dict
          if self.lastError != nil { self.lastError = nil }
          self.lastUpdated = Date()
          self.monitor.watch(report: dict)
          MemoryReclaimer.afterActivity()
        case .failure(let error): self.lastError = error.description
        }
        if self.needsRefresh { self.scheduleEventRefresh() }
      }
    }
  }
}
