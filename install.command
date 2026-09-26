#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="codexusage"
BUNDLE_ID="com.local.codexusage"
BUILD_ROOT="$(mktemp -d /tmp/codexusage-build.XXXXXX)"
APP="$BUILD_ROOT/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"
trap 'rm -rf "$BUILD_ROOT"' EXIT

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "正在编译 codexusage（Objective-C/AppKit）…"

# 先找到本机实际 Codex CLI。ChatGPT Desktop 当前也内置 Codex CLI，
# GUI App 的 PATH 与终端不同，所以不能只依赖 command -v。
CODEX_CLI=""
for candidate in \
  "/Applications/ChatGPT.app/Contents/Resources/codex" \
  "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" \
  "/Applications/Codex.app/Contents/Resources/codex" \
  "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" \
  "$HOME/Applications/ChatGPT.app/Contents/Resources/codex" \
  "$HOME/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" \
  "$HOME/Applications/Codex.app/Contents/Resources/codex" \
  "$HOME/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" \
  "/opt/homebrew/bin/codex" \
  "/usr/local/bin/codex" \
  "$HOME/.local/bin/codex" \
  "$HOME/.volta/bin/codex" \
  "$HOME/.npm-global/bin/codex"; do
  if [[ -x "$candidate" ]]; then CODEX_CLI="$candidate"; break; fi
done

# 兼容 App 改名/Beta：扫描 /Applications 和 ~/Applications 顶层的所有 .app。
if [[ -z "$CODEX_CLI" ]]; then
  for app in /Applications/*.app "$HOME"/Applications/*.app; do
    [[ -d "$app" ]] || continue
    for relative_path in \
      "Contents/Resources/codex" \
      "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"; do
      candidate="$app/$relative_path"
      if [[ -x "$candidate" ]]; then CODEX_CLI="$candidate"; break 2; fi
    done
  done
fi

# 再尝试 Spotlight；最后才依赖 Shell PATH。
if [[ -z "$CODEX_CLI" ]] && command -v mdfind >/dev/null 2>&1; then
  while IFS= read -r candidate; do
    case "$candidate" in
      */Contents/Resources/codex|*/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex) ;;
      *) continue ;;
    esac
    if [[ -x "$candidate" ]]; then CODEX_CLI="$candidate"; break; fi
  done < <(mdfind "kMDItemFSName == 'codex'" 2>/dev/null || true)
fi
if [[ -z "$CODEX_CLI" ]]; then
  CODEX_CLI="$(/bin/zsh -lc 'command -v codex 2>/dev/null' | head -n 1 || true)"
fi

if [[ -n "$CODEX_CLI" && -x "$CODEX_CLI" ]]; then
  echo "检测到 Codex CLI：$CODEX_CLI"
  "$CODEX_CLI" --version 2>/dev/null | head -n 1 || true
  # 把已验证路径写进 App Resources，运行时优先读取，避免 GUI PATH 差异。
  printf '%s\n' "$CODEX_CLI" > "$APP/Contents/Resources/CodexCLIPath.txt"
else
  echo "警告：安装阶段仍未检测到 Codex CLI。"
  echo "请确认 ChatGPT/Codex Desktop 已安装；应用仍会在运行时继续自动扫描。"
fi
# 使用 clang 编译单文件原生 AppKit 程序。
xcrun clang \
  -fobjc-arc -Os -Wall -Wextra \
  -Werror \
  -arch arm64 \
  -mmacosx-version-min=13.0 \
  -framework Cocoa \
  Sources/main.m \
  -o "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleVersion</key><string>14</string>
  <key>CFBundleShortVersionString</key><string>1.13.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 图标：Codex/终端主体 + 环形额度语义（绿色剩余、灰色已用），不使用电池外形。
ICONSET="$BUILD_ROOT/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16     Assets/AppIconSource.png --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32     Assets/AppIconSource.png --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32     Assets/AppIconSource.png --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64     Assets/AppIconSource.png --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128   Assets/AppIconSource.png --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256   Assets/AppIconSource.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   Assets/AppIconSource.png --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512   Assets/AppIconSource.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   Assets/AppIconSource.png --out "$ICONSET/icon_512x512.png" >/dev/null
cp Assets/AppIconSource.png "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$APP" >/dev/null

pkill -x "$APP_NAME" 2>/dev/null || true
pkill -x "CodexQuotaBar" 2>/dev/null || true
pkill -x "CodexUsageBar" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"

# 同一 bundle id 多次覆盖安装时，macOS 可能继续显示旧图标。
# 提升 bundle version 后再刷新 LaunchServices 注册，不重启 Finder/Dock。
touch "$DEST"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
fi
open "$DEST"

echo
echo "已安装并启动：$DEST"
echo "额度：Codex app-server → account/rateLimits/read"
echo "账号 Token：Codex app-server → account/usage/read（当天 / 全部）"
echo "程序不读取 auth.json，不保存 Codex Token。"
