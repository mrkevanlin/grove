#!/usr/bin/env bash
# Builds Grove.app into ~/Applications and links the `grove` CLI into ~/.local/bin.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Grove.app"
BIN_DIR="$HOME/.local/bin"

cd "$ROOT"
swift build -c release
BUILD="$(swift build -c release --show-bin-path)"

# Quit a running copy. It stops the servers it manages; the marker tells the new copy to start
# everything that was on again (a normal Quit only brings back always-on servers).
if pgrep -xq GroveApp; then
  mkdir -p "$HOME/.config/grove"
  touch "$HOME/.config/grove/.restore-after-upgrade"
fi
BUNDLE_ID="$(sed -n 's/^[[:space:]]*public static let bundleID = "\([^"]*\)".*/\1/p' "$ROOT/Sources/GroveCore/Config.swift")"
if [ -z "$BUNDLE_ID" ]; then
  echo "Could not read bundle ID from Sources/GroveCore/Config.swift" >&2
  exit 1
fi
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

# One-time migration from the old "DevServers" name.
sleep 1
rm -rf "$HOME/Applications/DevServers.app"
if [ -d "$HOME/.config/devservers" ] && [ ! -d "$HOME/.config/grove" ]; then
  mv "$HOME/.config/devservers" "$HOME/.config/grove"
fi
if [ -d "$HOME/Library/Logs/DevServers" ] && [ ! -d "$HOME/Library/Logs/Grove" ]; then
  mv "$HOME/Library/Logs/DevServers" "$HOME/Library/Logs/Grove"
fi

rm -rf "$APP"
# The CLI lives in Helpers/: "grove" and "GroveApp" in one folder is fine, but "grove" next to a
# "Grove" binary would collide on a case-insensitive filesystem.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$BIN_DIR"
cp "$BUILD/GroveApp" "$APP/Contents/MacOS/GroveApp"
cp "$BUILD/grove" "$APP/Contents/Helpers/grove"
cp "$ROOT"/Sources/GroveApp/Resources/*.png "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Grove</string>
  <key>CFBundleDisplayName</key><string>Grove</string>
  <key>CFBundleExecutable</key><string>GroveApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

ln -sf "$APP/Contents/Helpers/grove" "$BIN_DIR/grove"
# Old name, kept as an alias for now.
ln -sf "$APP/Contents/Helpers/grove" "$BIN_DIR/devctl"

# One skill, linked where Claude Code, Cursor, and ChatGPT/Codex look for user skills.
link_skill() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    echo "Left existing skill in place: $dest"
    return
  fi
  ln -sfn "$ROOT/skills/grove" "$dest"
  echo "Skill -> $dest"
}
link_skill "$HOME/.claude/skills/grove"
link_skill "$HOME/.cursor/skills/grove"
link_skill "$HOME/.agents/skills/grove"
link_skill "$HOME/.codex/skills/grove"

open "$APP"

echo "Installed $APP"
echo "grove -> $BIN_DIR/grove (devctl is an alias)"
echo "Config: ~/.config/grove/config.json"
