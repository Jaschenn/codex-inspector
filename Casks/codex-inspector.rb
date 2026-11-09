cask "codex-inspector" do
  arch arm: "arm64", intel: "x86_64"

  version "0.5.0"
  sha256 arm:   "97ab6a07c801d25ca6b104aa26b20dc9d43b6a1886ecbcb47bfcd242f5cb79f6",
         intel: "e10a1e9faffbef817000982f21404739c21eecad28e542ce6613a3e1f2dc7d24"

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
