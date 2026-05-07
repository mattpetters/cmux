#!/usr/bin/env bash
set -euo pipefail

# Build Release, save workspace state with crex, swap into the installed app, and relaunch.
# Defaults to ~/Applications/cmux.app because that is the writable app location used
# by this dev machine. Override with CMUX_INSTALL_APP_PATH=/Applications/cmux.app.

echo "==> Ensuring GhosttyKit..."
"$(dirname "$0")/ensure-ghosttykit.sh"

: "${CMUX_SKIP_ZIG_BUILD:=1}"
if [[ "$CMUX_SKIP_ZIG_BUILD" == "1" ]]; then
  echo "==> Skipping Ghostty CLI helper Zig build (CMUX_SKIP_ZIG_BUILD=1)"
fi

echo "==> Building Release (unsigned for local upgrade)..."
xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CMUX_SKIP_ZIG_BUILD="$CMUX_SKIP_ZIG_BUILD" \
  build

APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/cmux.app" -print0 \
  | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
  | sort -nr \
  | head -n 1 \
  | cut -d' ' -f2-
)"
if [[ -z "${APP_PATH}" ]]; then
  echo "error: cmux.app not found in DerivedData" >&2
  exit 1
fi
echo "    Built: ${APP_PATH}"

CREX_LAYOUT_PATH="${CREX_LAYOUT_PATH:-$HOME/.config/crex/layouts/default.toml}"
CREX_BACKUP_PATH=""
if [[ -f "$CREX_LAYOUT_PATH" ]]; then
  CREX_BACKUP_PATH="${CREX_LAYOUT_PATH}.pre-upgrade.$(date +%Y%m%d%H%M%S).bak"
  cp "$CREX_LAYOUT_PATH" "$CREX_BACKUP_PATH"
fi

restore_crex_backup() {
  if [[ -n "$CREX_BACKUP_PATH" && -f "$CREX_BACKUP_PATH" ]]; then
    cp "$CREX_BACKUP_PATH" "$CREX_LAYOUT_PATH"
  fi
}
trap restore_crex_backup ERR

echo "==> Saving workspace state (crex save)..."
PATH="$APP_PATH/Contents/Resources/bin:$PATH" crex save
if [[ -f "$CREX_LAYOUT_PATH" ]]; then
  SAVED_WORKSPACE_COUNT="$(/usr/bin/grep -c '^\[\[workspace\]\]' "$CREX_LAYOUT_PATH" || true)"
  if [[ "${SAVED_WORKSPACE_COUNT:-0}" -lt "${CMUX_MIN_CREX_WORKSPACES:-2}" ]]; then
    echo "error: crex save captured only ${SAVED_WORKSPACE_COUNT:-0} workspace(s); restoring ${CREX_BACKUP_PATH:-previous layout}" >&2
    restore_crex_backup
    exit 1
  fi
fi
trap - ERR

INSTALL_APP_PATH="${CMUX_INSTALL_APP_PATH:-$HOME/Applications/cmux.app}"
APP_PROCESS_PATH="$INSTALL_APP_PATH/Contents/MacOS/cmux"

POST_UPGRADE_SCRIPT="$(mktemp /tmp/cmux-upgrade.XXXXXX)"
cat > "$POST_UPGRADE_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
APP_PATH="$APP_PATH"
INSTALL_APP_PATH="$INSTALL_APP_PATH"
APP_PROCESS_PATH="$APP_PROCESS_PATH"
INSTALL_DIR="\$(dirname "\$INSTALL_APP_PATH")"
mkdir -p "\$INSTALL_DIR"

echo "==> Stopping running cmux..."
/usr/bin/osascript -e 'tell application id "com.cmuxterm.app" to quit' >/dev/null 2>&1 || true
pkill -x cmux || true
pkill -f "\$INSTALL_APP_PATH/Contents/MacOS/cmux" || true
sleep 0.5

if [[ -d "\$INSTALL_APP_PATH" ]] && command -v xattr >/dev/null 2>&1; then
  xattr -cr "\$INSTALL_APP_PATH" || true
fi

echo "==> Swapping into \$INSTALL_APP_PATH..."
rm -rf "\$INSTALL_APP_PATH"
cp -R "\$APP_PATH" "\$INSTALL_APP_PATH"
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "\$INSTALL_APP_PATH" || true
fi
if [[ -d "\$INSTALL_APP_PATH/Contents/Resources/bin" ]]; then
  for helper in "\$INSTALL_APP_PATH/Contents/Resources/bin"/*; do
    [[ -f "\$helper" && -x "\$helper" ]] || continue
    /usr/bin/codesign --force --sign - --timestamp=none "\$helper"
  done
fi
if [[ -d "\$INSTALL_APP_PATH/Contents/PlugIns" ]]; then
  while IFS= read -r -d '' plugin; do
    /usr/bin/codesign --force --sign - --timestamp=none --deep "\$plugin"
  done < <(/usr/bin/find "\$INSTALL_APP_PATH/Contents/PlugIns" -mindepth 1 -maxdepth 1 -print0)
fi
if [[ -d "\$INSTALL_APP_PATH/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' framework; do
    /usr/bin/codesign --force --sign - --timestamp=none --deep "\$framework"
  done < <(/usr/bin/find "\$INSTALL_APP_PATH/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print0)
fi
/usr/bin/codesign --force --sign - --timestamp=none "\$INSTALL_APP_PATH"
/usr/bin/codesign --verify --deep --strict "\$INSTALL_APP_PATH"

echo "==> Launching \$INSTALL_APP_PATH..."
open -g "\$INSTALL_APP_PATH"

ATTEMPT=0
MAX_ATTEMPTS=20
while [[ "\$ATTEMPT" -lt "\$MAX_ATTEMPTS" ]]; do
  if pgrep -f "\$APP_PROCESS_PATH" >/dev/null 2>&1; then
    echo "==> Running: \${APP_PROCESS_PATH}"
    exit 0
  fi
  ATTEMPT=\$((ATTEMPT + 1))
  sleep 0.25
done

echo "warning: app launch requested but no running process detected" >&2
exit 1
EOF
chmod +x "$POST_UPGRADE_SCRIPT"

if [[ -n "${CMUX_SOCKET_PATH:-}" || -n "${CMUXD_UNIX_PATH:-}" || -n "${CMUX_TAG:-}" ]]; then
  LOG_PATH="/tmp/cmux-upgrade.log"
  echo "==> Running final swap in detached process because this shell appears to be inside cmux"
  echo "    Log: ${LOG_PATH}"
  nohup "$POST_UPGRADE_SCRIPT" >"$LOG_PATH" 2>&1 &
  echo "==> Detached upgrader started (pid $!)"
  exit 0
fi

exec "$POST_UPGRADE_SCRIPT"
