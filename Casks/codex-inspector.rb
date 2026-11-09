cask "codex-inspector" do
  arch arm: "arm64", intel: "x86_64"

  version "0.5.1"
  sha256 arm:   "5a0645e517a33858697097a28c640405d3a28993f235b4b8d735e14230a49ffb",
         intel: "3e57c0ad8b6d994a423bc55245dc3ff7865850b0b6eb6c7b99ca6168f85678f2"

  url "https://github.com/Jaschenn/codex-inspector/releases/download/v#{version}/CodexInspector-macos-#{arch}.zip"
  name "Codex Inspector"
  desc "Inspect Codex configuration, sessions and token usage"
  homepage "https://github.com/Jaschenn/codex-inspector"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "CodexInspector.app"
  # Expose the bundled Rust engine so `codex-inspector-core` works without a
  # separate formula or a source build.
  binary "#{appdir}/CodexInspector.app/Contents/MacOS/codex-inspector-core"

  uninstall quit: "local.codex-inspector.menubar"

  zap trash: [
    "~/Library/Caches/CodexInspector",
    "~/Library/Logs/CodexInspectorDebug.log",
    "~/Library/Preferences/local.codex-inspector.menubar.plist",
  ]

  caveats <<~EOS
    Codex Inspector is ad-hoc signed and not notarized by Apple. If macOS blocks
    the first launch, allow it under System Settings -> Privacy & Security, or run:
      xattr -dr com.apple.quarantine "#{appdir}/CodexInspector.app"
  EOS
end
