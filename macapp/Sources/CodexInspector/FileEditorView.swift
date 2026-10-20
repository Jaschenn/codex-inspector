import SwiftUI

final class FileEditorModel: ObservableObject {
  @Published var text = ""
  @Published var error: String?
  @Published var status = ""
  @Published var isLoaded = false
  private(set) var snapshot: FileSnapshot?

  var isDirty: Bool { snapshot.map { $0.text != text } ?? false }
  var isNewFile: Bool { snapshot?.originalData == nil }

  func load(_ url: URL) {
    do {
      let loaded = try FileDocumentStore.load(url)
      snapshot = loaded
      text = loaded.text
      isLoaded = true
      error = nil
      status = loaded.originalData == nil ? "新文件 · 保存后创建" : "已载入"
    } catch {
      self.error = error.localizedDescription
      DebugLog.write("file-load failed: \(error.localizedDescription)")
    }
  }

  func save() -> Bool {
    guard let snapshot else { return false }
    do {
      try FileSyntaxValidator.validate(text, for: snapshot.url)
      self.snapshot = try FileDocumentStore.save(text, over: snapshot)
      error = nil
      status = "已保存 · \(Date().formatted(date: .omitted, time: .standard))"
      return true
    } catch {
      self.error = error.localizedDescription
      DebugLog.write("file-save failed: \(error.localizedDescription)")
      return false
    }
  }

  func validateSyntax() {
    guard let snapshot else { return }
    do {
      try FileSyntaxValidator.validate(text, for: snapshot.url)
      error = nil
      status = "语法检查通过"
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct FileEditorView: View {
  let file: InspectedFile
  let onSaved: () -> Void
  @Environment(\.dismiss) private var dismiss
  @StateObject private var model = FileEditorModel()
  @StateObject private var controller = CodeEditorController()
  @State private var isEditing = false
  @State private var wrapsLines = true
  @State private var fontSize: CGFloat = 13
  @State private var line = 1
  @State private var column = 1
  @State private var confirmDiscard = false
  @State private var reloadAfterDiscard = false

  private var language: CodeLanguage { CodeLanguage.forFile(file.url) }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "doc.text").font(.title2).foregroundColor(.accentColor)
        VStack(alignment: .leading, spacing: 4) {
          Text(file.url.lastPathComponent).font(.headline)
          Text(shortenPath(file.url.path)).font(.caption).foregroundColor(.secondary).textSelection(
            .enabled)
        }
        Spacer()
        if model.isDirty { Text("未保存").font(.caption).foregroundColor(.orange) }
        Button("关闭") { requestClose() }.keyboardShortcut(.cancelAction)
      }
      .padding(18)
      Divider()
      HStack(spacing: 12) {
        Picker("模式", selection: $isEditing) {
          Text("浏览").tag(false)
          Text("编辑").tag(true)
        }
        .pickerStyle(.segmented).frame(width: 140)
        .disabled(!model.isLoaded || (model.isDirty && isEditing))
        Button {
          controller.showFind()
        } label: {
          Label(isEditing ? "查找 / 替换" : "查找", systemImage: "magnifyingglass")
        }
        .keyboardShortcut("f", modifiers: .command)
        Button {
          controller.undo()
        } label: {
          Image(systemName: "arrow.uturn.backward")
        }.help("撤销 · ⌘Z")
          .disabled(!isEditing)
        Button {
          controller.redo()
        } label: {
          Image(systemName: "arrow.uturn.forward")
        }.help("重做 · ⇧⌘Z")
          .disabled(!isEditing)
        Spacer()
        Toggle("自动换行", isOn: $wrapsLines).toggleStyle(.checkbox)
        Button {
          fontSize = max(10, fontSize - 1)
        } label: {
          Image(systemName: "textformat.size.smaller")
        }
        .help("缩小字体")
        Button {
          fontSize = min(24, fontSize + 1)
        } label: {
          Image(systemName: "textformat.size.larger")
        }
        .help("放大字体")
        Button("重新载入") {
          if model.isDirty {
            reloadAfterDiscard = true
            confirmDiscard = true
          } else {
            model.load(file.url)
          }
        }
        if ["json", "jsonl", "toml"].contains(file.url.pathExtension.lowercased()) {
          Button("检查语法") { model.validateSyntax() }.disabled(!model.isLoaded)
        }
        Button(model.isNewFile ? "创建并保存" : "保存") {
          if model.save() { onSaved() }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!model.isLoaded || !isEditing || (!model.isDirty && !model.isNewFile))
      }
      .controlSize(.small).padding(12)
      Divider()
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.system(size: 12)).foregroundColor(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12).background(Color.red.opacity(0.07))
      }
      CodeEditorView(
        text: $model.text, language: language, isEditable: isEditing && model.isLoaded,
        wrapsLines: wrapsLines, fontSize: fontSize, controller: controller
      ) { newLine, newColumn in
        line = newLine
        column = newColumn
      }
      Divider()
      HStack(spacing: 14) {
        Text(language.rawValue)
        Text("UTF-8")
        Text("行 \(line)，列 \(column)")
        Text("\(model.text.count.formatted()) 字符")
        Spacer()
        Text(model.status + (model.isDirty ? " · 未保存" : ""))
      }
      .font(.caption).foregroundColor(.secondary).padding(12)
    }
    .frame(minWidth: 900, idealWidth: 960, minHeight: 560, idealHeight: 700)
    .onAppear {
      model.load(file.url)
      if model.isLoaded && model.isNewFile { isEditing = true }
    }
    .onChange(of: model.text) { _ in
      if model.isDirty { model.status = "编辑中" }
    }
    .interactiveDismissDisabled(model.isDirty)
    .alert("放弃未保存的修改？", isPresented: $confirmDiscard) {
      Button("继续编辑", role: .cancel) { reloadAfterDiscard = false }
      Button("放弃修改", role: .destructive) {
        if reloadAfterDiscard {
          model.load(file.url)
          reloadAfterDiscard = false
        } else {
          dismiss()
        }
      }
    } message: {
      Text("\(file.url.lastPathComponent) 的修改尚未写入文件。")
    }
  }

  private func requestClose() {
    if model.isDirty {
      reloadAfterDiscard = false
      confirmDiscard = true
    } else {
      dismiss()
    }
  }
}

struct BrowseFileButton: View {
  let path: String?
  @Environment(\.openInspectedFile) private var openFile

  var body: some View {
    if let path, !path.isEmpty {
      let url = URL(fileURLWithPath: path)
      let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      if !isDirectory {
        Button {
          openFile(url)
        } label: {
          Label("浏览 / 编辑", systemImage: "doc.text.magnifyingglass")
        }
        .font(.caption).help("在应用内浏览和编辑文件")
      }
    }
  }
}

private struct OpenInspectedFileKey: EnvironmentKey {
  static let defaultValue: (URL) -> Void = { _ in }
}

extension EnvironmentValues {
  var openInspectedFile: (URL) -> Void {
    get { self[OpenInspectedFileKey.self] }
    set { self[OpenInspectedFileKey.self] = newValue }
  }
}
