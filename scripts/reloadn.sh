#!/usr/bin/env bash
set -euo pipefail

APP_NAME="cmux NIGHTLY MP"
BUNDLE_ID="com.cmuxterm.app.nightly.mattpetters"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/cmux-forked-nightly"
LAUNCH=0

usage() {
  cat <<'EOF'
Usage: ./scripts/reloadn.sh [options]

Build a local Release app that identifies as a forked nightly. It uses the
upstream nightly icon, app name/plist shape, isolated bundle ID, and isolated
socket paths while staying local/ad-hoc signed.

Options:
  --launch               Launch the app after building.
  --name <app name>      Override app display/bundle name.
  --bundle-id <id>       Override bundle identifier. Must start with
                         com.cmuxterm.app.nightly for nightly socket routing.
  --derived-data <path>  Override derived data path.
  -h, --help             Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --launch)
      LAUNCH=1
      shift
      ;;
    --name)
      APP_NAME="${2:-}"
      if [[ -z "$APP_NAME" ]]; then
        echo "error: --name requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      if [[ -z "$BUNDLE_ID" ]]; then
        echo "error: --bundle-id requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA="${2:-}"
      if [[ -z "$DERIVED_DATA" ]]; then
        echo "error: --derived-data requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$BUNDLE_ID" != com.cmuxterm.app.nightly* ]]; then
  echo "error: forked nightly bundle id must start with com.cmuxterm.app.nightly" >&2
  echo "       got: $BUNDLE_ID" >&2
  exit 1
fi

sanitize_socket_suffix() {
  local raw="$1"
  raw="${raw#com.cmuxterm.app.nightly}"
  raw="${raw#.}"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="nightly"
  fi
  echo "$cleaned"
}

SOCKET_SUFFIX="$(sanitize_socket_suffix "$BUNDLE_ID")"
CMUX_SOCKET_PATH_VALUE="/tmp/cmux-nightly-${SOCKET_SUFFIX}.sock"
CMUXD_SOCKET="$HOME/Library/Application Support/cmux/cmuxd-nightly-${SOCKET_SUFFIX}.sock"
SHORT_SHA="$(git rev-parse --short HEAD)"
BASE_MARKETING="$(python3 - <<'PY'
import re
from pathlib import Path
text = Path('GhosttyTabs.xcodeproj/project.pbxproj').read_text()
match = re.search(r'\bMARKETING_VERSION = ([^;]+);', text)
print(match.group(1).strip().strip('"') if match else '0.0.0')
PY
)"
NIGHTLY_BUILD="$(date -u +%Y%m%d%H%M%S)"
NIGHTLY_VERSION="${BASE_MARKETING}-nightly.local.${NIGHTLY_BUILD}.${SHORT_SHA}"
FEED_URL="https://github.com/mattpetters/cmux/releases/download/nightly/appcast.xml"

if [[ ! -d GhosttyKit.xcframework ]]; then
  ./scripts/download-prebuilt-ghosttykit.sh
fi

xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon-Nightly \
  CMUX_SKIP_ZIG_BUILD="${CMUX_SKIP_ZIG_BUILD:-1}" \
  SPARKLE_PUBLIC_KEY="" \
  build

BASE_APP_PATH="$DERIVED_DATA/Build/Products/Release/cmux.app"
if [[ ! -d "$BASE_APP_PATH" ]]; then
  echo "error: built app not found: $BASE_APP_PATH" >&2
  exit 1
fi

APP_PATH="$DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"
rm -rf "$APP_PATH"
cp -R "$BASE_APP_PATH" "$APP_PATH"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NIGHTLY_VERSION" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $NIGHTLY_VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NIGHTLY_BUILD" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $NIGHTLY_BUILD" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED_URL" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Delete :CMUXCommit" "$INFO_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CMUXCommit string $SHORT_SHA" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$INFO_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUXD_UNIX_PATH \"${CMUXD_SOCKET}\"" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUXD_UNIX_PATH string \"${CMUXD_SOCKET}\"" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :LSEnvironment:CMUX_SOCKET_PATH \"${CMUX_SOCKET_PATH_VALUE}\"" "$INFO_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CMUX_SOCKET_PATH string \"${CMUX_SOCKET_PATH_VALUE}\"" "$INFO_PLIST"

if [[ -S "$CMUXD_SOCKET" ]]; then
  for PID in $(lsof -t "$CMUXD_SOCKET" 2>/dev/null); do
    kill "$PID" 2>/dev/null || true
  done
  rm -f "$CMUXD_SOCKET"
fi
rm -f "$CMUX_SOCKET_PATH_VALUE"

/usr/bin/codesign --force --deep --sign - --timestamp=none --generate-entitlement-der "$APP_PATH" >/dev/null

cat <<EOF
Forked nightly app:
  $APP_PATH
Bundle ID:
  $BUNDLE_ID
Version:
  $NIGHTLY_VERSION
Socket:
  $CMUX_SOCKET_PATH_VALUE
Icon:
  AppIcon-Nightly
EOF

if [[ "$LAUNCH" -eq 1 ]]; then
  /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  pkill -f "${APP_NAME}.app/Contents/MacOS/cmux" >/dev/null 2>&1 || true
  sleep 0.3
  env \
    -u CMUX_SOCKET_PATH \
    -u CMUX_TAB_ID \
    -u CMUX_PANEL_ID \
    -u CMUXD_UNIX_PATH \
    -u CMUX_TAG \
    -u CMUX_BUNDLE_ID \
    -u GIT_PAGER \
    -u GH_PAGER \
    open -g "$APP_PATH"
fi
