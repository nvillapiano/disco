#!/bin/bash
# build.sh — builds Disco.app and wraps it in a distributable Disco.dmg
# Usage: bash build.sh
# Requirements: Xcode Command Line Tools (xcode-select --install)

set -e

APP_NAME="Disco"
BUNDLE_ID="com.yourname.disco"
VERSION="1.0"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
STAGING_DIR=".dmg_staging"

echo "🪩  Building ${APP_NAME}…"

# ── 1. Compile ──────────────────────────────────────────────────────────────
swift build -c release 2>&1

# ── 2. Assemble .app bundle ─────────────────────────────────────────────────
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}"          "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist"              "${APP_BUNDLE}/Contents/Info.plist"
cp "Resources/emoji.json"              "${APP_BUNDLE}/Contents/Resources/emoji.json"

# Copy emoji.json from SPM build products if present there too
if [ -f "${BUILD_DIR}/Disco_Disco.bundle/Contents/Resources/emoji.json" ]; then
    cp "${BUILD_DIR}/Disco_Disco.bundle/Contents/Resources/emoji.json" \
       "${APP_BUNDLE}/Contents/Resources/emoji.json"
fi

# Make executable
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "✅  ${APP_BUNDLE} assembled."

# ── 3. Sign + strip quarantine ───────────────────────────────────────────────
# "Disco Dev" is a self-signed code-signing cert created once in Keychain Access.
# A stable certificate identity lets TCC (Accessibility permissions) survive
# reinstalls — without it, macOS revokes the grant every time the binary changes.
SIGN_IDENTITY="Disco Dev"
if security find-certificate -c "${SIGN_IDENTITY}" &>/dev/null; then
    codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}" 2>&1 \
      && echo "✍️   Signed with '${SIGN_IDENTITY}'" \
      || echo "⚠️   Signing failed — Accessibility permission may reset on reinstall"
else
    echo "⚠️   '${SIGN_IDENTITY}' cert not found — run: Keychain Access → Certificate Assistant → Create a Certificate (Code Signing)"
    codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || true
fi

xattr -cr "${APP_BUNDLE}" 2>/dev/null || true

# ── 4. Build DMG ────────────────────────────────────────────────────────────
echo "💿  Creating ${DMG_NAME}…"

rm -rf  "${STAGING_DIR}" "${DMG_NAME}"
mkdir   "${STAGING_DIR}"
cp -R   "${APP_BUNDLE}" "${STAGING_DIR}/"

# Symlink to /Applications so the user can drag-install
ln -s /Applications "${STAGING_DIR}/Applications"

if hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_NAME}" 2>/dev/null; then
  echo "created: $(pwd)/${DMG_NAME}"
else
  echo "⚠️   DMG creation failed (skipping — .app is still valid)"
fi

rm -rf "${STAGING_DIR}"

echo ""
echo "🎉  Done!"
echo ""
echo "   ${APP_BUNDLE}  — drag to /Applications to install locally"
echo "   ${DMG_NAME}    — share this file with friends/colleagues"
echo ""
echo "   First launch: right-click ${APP_BUNDLE} → Open  (bypasses unsigned warning)"
echo "   Then grant Accessibility in: System Settings → Privacy & Security → Accessibility"
