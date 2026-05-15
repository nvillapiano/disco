#!/bin/bash
# install.sh — quit any running Disco, then install Disco.app to /Applications
# Usage: bash install.sh  OR  npm run migrate  OR  npm run build:full

set -e

APP_NAME="Disco"
APP_BUNDLE="${APP_NAME}.app"
DEST="/Applications/${APP_BUNDLE}"

if [ ! -d "${APP_BUNDLE}" ]; then
  echo "❌  ${APP_BUNDLE} not found — run 'npm run build' first."
  exit 1
fi

# ── 1. Quit running instance ─────────────────────────────────────────────────
if pgrep -xq "${APP_NAME}"; then
  echo "🛑  Quitting running ${APP_NAME}…"
  osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || pkill -x "${APP_NAME}" || true
  # Give the process a moment to exit cleanly
  sleep 1
else
  echo "ℹ️   ${APP_NAME} is not running."
fi

# ── 2. Install to /Applications ──────────────────────────────────────────────
echo "📦  Installing ${APP_BUNDLE} → /Applications…"
rm -rf "${DEST}"
cp -R "${APP_BUNDLE}" "${DEST}"
xattr -cr "${DEST}" 2>/dev/null || true

# Relaunch so the fresh binary picks up any already-granted AX permissions.
sleep 0.5
open "${DEST}"

echo ""
echo "✅  Done! ${APP_NAME} installed to /Applications and relaunched."
