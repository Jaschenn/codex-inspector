cask "codex-inspector" do
  arch arm: "arm64", intel: "x86_64"

  version "0.3.0"
  sha256 arm:   "c38e04ef24bdbd6ab62623fdb2f385c4a1e934ee6a3247d110a32e70714718a5",
         intel: "1a4a42a9fa0f83c54fd696f07e9f2d44627a591f33fa81890960091b9aa3b7de"

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
