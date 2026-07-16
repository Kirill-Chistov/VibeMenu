#!/usr/bin/env bash
#
# package-github-release.sh — build and zip a VibeMenu.app for a GitHub release.
#
# This produces an UNSIGNED, NOT-notarized .app zip for direct GitHub Releases
# distribution. It deliberately does NOT sign, notarize, staple, build a DMG, or touch
# any Apple Developer credentials — those are future work (see docs/ROADMAP.md /
# docs/RELEASE_CHECKLIST.md). Early testers will see a Gatekeeper "unidentified developer"
# warning; docs/INSTALL.md explains the "Open Anyway" workaround (System Settings →
# Privacy & Security) for these macOS 15+ builds.
#
# Usage:
#   scripts/package-github-release.sh [VERSION]
#   VERSION=0.1.0 scripts/package-github-release.sh
#
# VERSION defaults to 0.1.0. It is used only to name the output zip; it does not rewrite
# the app's Info.plist version.
#
# Output:
#   dist/VibeMenu-v<VERSION>-macos-arm64.zip
set -euo pipefail

# --- Config -----------------------------------------------------------------
# Argument wins over env var wins over default.
VERSION="${1:-${VERSION:-0.1.0}}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/App/VibeMenu.xcodeproj"
SCHEME="VibeMenu"
CONFIG="Release"
APP_NAME="VibeMenu.app"

DERIVED="$REPO_ROOT/build/DerivedData"       # deterministic build output location
PRODUCTS_DIR="$DERIVED/Build/Products/$CONFIG"
DIST_DIR="$REPO_ROOT/dist"
ZIP_NAME="VibeMenu-v${VERSION}-macos-arm64.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

echo "==> VibeMenu GitHub release packaging"
echo "    version : $VERSION"
echo "    project : $PROJECT"
echo "    config  : $CONFIG"
echo

# --- Preflight --------------------------------------------------------------
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Full Xcode is required to build the .app." >&2
  exit 1
fi
if [[ ! -d "$PROJECT" ]]; then
  echo "error: Xcode project not found at $PROJECT" >&2
  exit 1
fi

# --- Build ------------------------------------------------------------------
echo "==> Building $SCHEME ($CONFIG) with xcodebuild…"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  build

# --- Locate the built app ---------------------------------------------------
APP_PATH="$PRODUCTS_DIR/$APP_NAME"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app not found at $APP_PATH" >&2
  echo "       (build succeeded but the .app is not where we expected)" >&2
  exit 1
fi
echo "==> Built app: $APP_PATH"

# --- Verify bundle version matches the requested package version -------------
# The zip is named after $VERSION, but the .app's version comes from App/Info.plist
# (GENERATE_INFOPLIST_FILE = NO). If they drift, testers get a "v0.1.0" download that
# reports a different version in About/Get Info. Warn loudly rather than fail — the
# human owns the release decision (AGENTS.md).
BUNDLE_PLIST="$APP_PATH/Contents/Info.plist"
BUNDLE_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUNDLE_PLIST" 2>/dev/null || echo '?')"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUNDLE_PLIST" 2>/dev/null || echo '?')"
echo "==> Bundle version: CFBundleShortVersionString=$BUNDLE_SHORT_VERSION CFBundleVersion=$BUNDLE_VERSION"
if [[ "$BUNDLE_SHORT_VERSION" != "$VERSION" ]]; then
  echo "warning: bundle CFBundleShortVersionString ($BUNDLE_SHORT_VERSION) != requested package version ($VERSION)." >&2
  echo "         Update App/Info.plist's CFBundleShortVersionString before releasing," >&2
  echo "         or the '$ZIP_NAME' download will report a different version." >&2
fi

# --- Package ----------------------------------------------------------------
mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"

# `ditto -c -k --keepParent` preserves the .app bundle structure, symlinks, and
# resource forks — the Apple-recommended way to zip a macOS app bundle (plain `zip`
# can mangle bundles).
echo "==> Zipping app bundle…"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo
echo "==> Done. Created:"
echo "    $ZIP_PATH"
du -h "$ZIP_PATH" | awk '{print "    size: " $1}'

# --- Next steps -------------------------------------------------------------
cat <<EOF

Next steps for the GitHub Release (see docs/RELEASE_CHECKLIST.md):

  1. Run the manual smoke checklist in docs/RELEASE_CHECKLIST.md.
  2. Create the release and tag:
       gh release create v${VERSION} \\
         "${ZIP_PATH}" \\
         --title "VibeMenu v${VERSION}" \\
         --notes-file <(printf '%s\\n' "See docs/RELEASE_CHECKLIST.md for the notes template.")
     …or create it in the GitHub UI and attach:
       ${ZIP_NAME}
  3. In the release notes, keep the caveat:
       "Unsigned / not notarized build (macOS 15+). Try opening
        VibeMenu.app once; if macOS blocks it, go to System Settings →
        Privacy & Security → Open Anyway (see docs/INSTALL.md)."

This build is UNSIGNED and NOT notarized. Do not describe it as signed/notarized.
EOF
