# 使用 Homebrew 安装

Codex Inspector 是 macOS GUI 应用，应使用 **Cask** 而不是 Formula。应用当前为
ad-hoc 签名且未公证，因此不能提交到官方 `homebrew/homebrew-cask`，需要使用个人
tap。Cask 同时会把应用内置的 Rust CLI 链接到 `$(brew --prefix)/bin`。

## 1. 创建 tap 仓库（一次性）

tap 仓库名必须是 `homebrew-tap`，这样安装时才能简写为 `Jaschenn/tap`。

```bash
gh repo create Jaschenn/homebrew-tap --public \
  --description "Homebrew casks for Jaschenn"

git clone https://github.com/Jaschenn/homebrew-tap.git
mkdir -p homebrew-tap/Casks
cp Casks/codex-inspector.rb homebrew-tap/Casks/

cd homebrew-tap
git add Casks/codex-inspector.rb
git commit -m "Add Codex Inspector cask"
git push
```

## 2. 安装与升级

```bash
brew install --cask Jaschenn/tap/codex-inspector

# 检查安装结果
brew info --cask codex-inspector
codex-inspector-core --help

# 后续升级
brew upgrade --cask codex-inspector
```

首次安装时 Homebrew 会自动 tap `Jaschenn/homebrew-tap`，不需要手动 `brew tap`。
也可以显式执行：

```bash
brew tap Jaschenn/tap
brew install --cask codex-inspector
```

## 3. 配置 Release 自动更新 tap

Release workflow 中的 `homebrew` job 会在每次打 tag 并成功发布 GitHub Release 后，
用两个架构的 `.sha256` 重新渲染 cask 并推送到 `Jaschenn/homebrew-tap`。

首次需要完成两项配置：

1. 创建 `Jaschenn/homebrew-tap` 仓库，并至少包含 `Casks/` 目录。
2. 创建有该仓库 `Contents: Read and write` 权限的 fine-grained PAT，然后在
   `Jaschenn/codex-inspector` 仓库添加 Actions secret：

```bash
gh secret set HOMEBREW_TAP_TOKEN --repo Jaschenn/codex-inspector
```

未配置 secret 时，release 仍会成功，但 `homebrew` job 会输出 warning 并跳过。
配置完成后重新运行该 release workflow（或发布下一个 patch 版本）即可补上 tap。

workflow 使用的 token 只需要目标 tap 仓库的写权限，不需要主仓库或组织级权限。

## 4. 手动更新 Cask（可选）

GitHub Release 必须先上传两个架构的 ZIP 及对应的 `.sha256` 文件。然后运行：

```bash
bash scripts/update_homebrew_cask.sh 0.3.0
cp Casks/codex-inspector.rb ../homebrew-tap/Casks/
cd ../homebrew-tap && git add Casks/codex-inspector.rb \
  && git commit -m "Update Codex Inspector to 0.3.0" && git push
```

脚本会从 `v0.3.0` 的 Release 下载两个 `.sha256` 文件并校验格式；Release 或校验文件
不存在时会直接失败，避免发布一个下载不到或校验值错误的 Cask。

## 5. 卸载与清理

```bash
brew uninstall --cask codex-inspector

# 同时删除缓存、日志和偏好设置
brew uninstall --zap --cask codex-inspector
```

## 6. Gatekeeper 说明

应用使用 ad-hoc 签名，未经过 Apple 公证。如果 macOS 阻止首次启动，可在
“系统设置 → 隐私与安全性”中允许打开，或执行：

```bash
xattr -dr com.apple.quarantine /Applications/CodexInspector.app
```

长期方案是使用 Apple Developer ID 签名并公证构建产物。完成公证后，才符合提交官方
`homebrew/cask` 的基本要求；当前配置可以直接改为官方 Cask 的 URL 和校验值。

## 注意事项

- Cask 中的 `uninstall quit` 和 `zap` 路径依赖当前 Bundle ID
  `local.codex-inspector.menubar`。如果修改 Bundle ID，需要同步修改 cask。
- `version` 与两个架构的 `sha256` 必须成组更新，不要只改版本号。
- `binary` stanza 链接的是应用包内的 `codex-inspector-core`。若应用被手动移出
  `/Applications`，该链接会失效，重新执行 `brew reinstall --cask` 即可恢复。
