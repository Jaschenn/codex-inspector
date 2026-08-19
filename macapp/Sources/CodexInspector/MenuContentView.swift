import SwiftUI

struct MenuContentView: View {
    @ObservedObject var fetcher: ReportFetcher
    @State private var selectedPID: Int? = nil

    private var processes: [[String: Any]] { fetcher.report.dictArray("processes") }
    private var processErrors: [[String: Any]] { fetcher.report.dictArray("process_errors") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Group {
                if let pid = selectedPID, let proc = processes.first(where: { $0.int("pid") == pid }) {
                    DetailView(proc: proc, onBack: { selectedPID = nil })
                } else {
                    listView
                }
            }
            // MenuBarExtra 的 .window 样式里,ScrollView 报出的"理想高度"经常被算成 0,
            // 导致中间内容区完全塌陷、只剩上下两条(能看到 header/footer,中间空白)。
            // 给中间区域一个明确的固定高度,绕开这个尺寸协商问题。
            .frame(height: 420)

            Divider()
            footer
        }
        .frame(width: 440)
    }

    private var header: some View {
        HStack {
            Text("codex-inspector").font(.headline)
            Spacer()
            if fetcher.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                fetcher.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("立即刷新")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var listView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let error = fetcher.lastError {
                    errorBanner(error)
                }

                if processes.isEmpty && processErrors.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "moon.zzz")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary)
                        Text("当前没有检测到正在运行的 codex 进程")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    ForEach(Array(processes.enumerated()), id: \.offset) { _, proc in
                        processRow(proc)
                        Divider().padding(.leading, 12)
                    }
                    ForEach(Array(processErrors.enumerated()), id: \.offset) { _, err in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                            Text("pid=\(err.int("pid") ?? 0) 分析失败: \(err.str("error") ?? "")")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.red)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
    }

    private func processRow(_ proc: [String: Any]) -> some View {
        let pid = proc.int("pid") ?? 0
        let cwd = shortenPath(proc.str("cwd"))
        let trust = proc.str("trust_level")
        let etime = proc.str("etime") ?? "-"

        return Button {
            selectedPID = pid
        } label: {
            HStack(spacing: 8) {
                Circle().fill(trustColor(trust)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PID \(pid)  ·  运行 \(etime)")
                        .font(.system(size: 12, weight: .medium))
                    Text(cwd)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            if let updated = fetcher.lastUpdated {
                Text("更新于 \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
