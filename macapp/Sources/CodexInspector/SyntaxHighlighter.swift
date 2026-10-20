import AppKit

enum CodeLanguage: String, CaseIterable {
  case plain = "Text"
  case markdown = "Markdown"
  case toml = "TOML"
  case json = "JSON"
  case shell = "Shell"
  case python = "Python"
  case swift = "Swift"
  case javascript = "JavaScript"
  case typescript = "TypeScript"
  case yaml = "YAML"

  static func forFile(_ url: URL) -> CodeLanguage {
    switch url.pathExtension.lowercased() {
    case "md", "markdown": return .markdown
    case "toml": return .toml
    case "json", "jsonl": return .json
    case "sh", "bash", "zsh": return .shell
    case "py": return .python
    case "swift": return .swift
    case "js", "mjs", "jsx": return .javascript
    case "ts", "tsx": return .typescript
    case "yaml", "yml": return .yaml
    default: return .plain
    }
  }
}

struct SyntaxRule {
  let expression: NSRegularExpression
  let color: NSColor
  var captureGroup = 0
}

enum SyntaxHighlighter {
  static func rules(for language: CodeLanguage) -> [SyntaxRule] {
    cachedRules[language] ?? []
  }

  private static let cachedRules = Dictionary(
    uniqueKeysWithValues: CodeLanguage.allCases.map { ($0, makeRules(for: $0)) })

  private static func makeRules(for language: CodeLanguage) -> [SyntaxRule] {
    var patterns: [(String, NSColor)] = []
    if language != .plain {
      patterns += [
        (#"\b(?:true|false|null|nil|None|True|False)\b"#, .systemPurple),
        (#"(?<![\w])[-+]?\d+(?:\.\d+)?\b"#, .systemOrange),
      ]
    }
    switch language {
    case .toml, .yaml:
      patterns += [
        (#"(?m)^\s*[\w.\-]+(?=\s*[=:])"#, .systemBlue), (#"(?m)^\s*\[\[?.*?\]\]?"#, .systemPurple),
      ]
    case .json:
      patterns += [(#"[{}\[\]:,]"#, .secondaryLabelColor)]
    case .shell:
      patterns += [(#"(?<!\w)--?[\w-]+"#, .systemPurple), (#"\$\{?[\w]+\}?"#, .systemTeal)]
    case .python, .swift, .javascript, .typescript:
      patterns += [
        (
          #"\b(?:import|from|def|class|func|struct|enum|let|var|const|return|if|else|for|while|try|catch|except|async|await|public|private|static|guard|in|throw|throws|interface|type|export|function)\b"#,
          .systemPurple
        )
      ]
    case .markdown:
      patterns += [
        (#"(?m)^#{1,6}\s+.*$"#, .systemBlue),
        (#"\*\*[^\n]+?\*\*|__[^\n]+?__"#, .systemPurple),
        (#"\[[^\]]+\]\([^\)]+\)"#, .systemTeal),
        (#"`[^`\n]+`|(?ms)^```.*?^```\s*$"#, .systemOrange),
      ]
    case .plain: break
    }
    let strings = #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#
    var commentPattern: String?
    if language != .plain && language != .markdown {
      // 字符串整体匹配后再着色，避免把 URL 中的 # 或 // 当成注释。
      patterns += [(strings, .systemGreen)]
      if language == .json {
        patterns += [(#"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#, .systemBlue)]
      } else {
        let comments =
          [.swift, .javascript, .typescript].contains(language)
          ? #"(?m)(?<!:)//.*$|/\*[\s\S]*?\*/"# : #"(?m)#.*$"#
        commentPattern = "(?:\(strings))|(\(comments))"
      }
    }
    var result: [SyntaxRule] = patterns.compactMap { pattern, color in
      guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
      return SyntaxRule(expression: expression, color: color)
    }
    if let commentPattern, let expression = try? NSRegularExpression(pattern: commentPattern) {
      result.append(
        SyntaxRule(expression: expression, color: .secondaryLabelColor, captureGroup: 1))
    }
    return result
  }

  struct Matches {
    let color: NSColor
    let ranges: [NSRange]

    func intersecting(_ visible: NSRange) -> ArraySlice<NSRange> {
      var low = 0
      var high = ranges.count
      while low < high {
        let mid = (low + high) / 2
        if NSMaxRange(ranges[mid]) <= visible.location { low = mid + 1 } else { high = mid }
      }
      let start = low
      while low < ranges.count && ranges[low].location < NSMaxRange(visible) { low += 1 }
      return ranges[start..<low]
    }
  }

  /// Parse away from the main thread; keep multiline matches intact across viewport boundaries.
  static func matches(
    in text: String, language: CodeLanguage, cancelled: () -> Bool = { false }
  ) -> [Matches] {
    let range = NSRange(location: 0, length: (text as NSString).length)
    return rules(for: language).map { rule in
      var ranges: [NSRange] = []
      rule.expression.enumerateMatches(in: text, options: .reportProgress, range: range) {
        match, _, stop in
        if cancelled() {
          stop.pointee = true
          return
        }
        if let match {
          let range = match.range(at: rule.captureGroup)
          if range.location != NSNotFound { ranges.append(range) }
        }
      }
      return Matches(color: rule.color, ranges: ranges)
    }
  }

  static func apply(to storage: NSTextStorage, language: CodeLanguage, font: NSFont) {
    let text = storage.string
    let range = NSRange(location: 0, length: (text as NSString).length)
    storage.beginEditing()
    storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: range)
    for rule in rules(for: language) {
      for match in rule.expression.matches(in: text, range: range) {
        let matchRange = match.range(at: rule.captureGroup)
        if matchRange.location != NSNotFound {
          storage.addAttribute(.foregroundColor, value: rule.color, range: matchRange)
        }
      }
    }
    storage.endEditing()
  }
}

/// 展示用拆分保留原始引号；绝不解析或执行命令替换。
func formattedShellCommand(_ command: String) -> String {
  var tokens: [String] = []
  var current = ""
  var quote: Character?
  var escaped = false
  for character in command {
    if escaped {
      current.append(character)
      escaped = false
    } else if character == "\\" && quote != "'" {
      current.append(character)
      escaped = true
    } else if character == "\"" || character == "'" {
      current.append(character)
      if quote == character { quote = nil } else if quote == nil { quote = character }
    } else if character.isWhitespace && quote == nil {
      if !current.isEmpty {
        tokens.append(current)
        current = ""
      }
    } else {
      current.append(character)
    }
  }
  if !current.isEmpty { tokens.append(current) }
  var groups: [String] = []
  var index = 0
  while index < tokens.count {
    if tokens[index].hasPrefix("-"), index + 1 < tokens.count, !tokens[index + 1].hasPrefix("-") {
      groups.append(tokens[index] + " " + tokens[index + 1])
      index += 2
    } else {
      groups.append(tokens[index])
      index += 1
    }
  }
  return groups.joined(separator: " \\\n  ")
}
