cask "codex-inspector" do
  arch arm: "arm64", intel: "x86_64"

  version "0.2.0"
  sha256 arm:   "c8d9f272cabfdeeb7881ae46f4b796c86588798e5f32ff8ac07653f2c76b112b",
         intel: "41bfa37646fdce4e2e77dbc20943e43a9a91d191035f9e83a8637f1ea5809335"

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
