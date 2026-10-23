#!/usr/bin/env bash
# Package "Serpentine.app" into a drag-to-install DMG for distribution.
#
#   ./Scripts/make-dmg.sh            # builds the app, then writes ./dist/Serpentine.dmg
#                                     # plus a versioned copy, e.g. ./dist/Serpentine-0.1.5.dmg
#   ./Scripts/make-dmg.sh --adhoc    # the same, with the app ad-hoc signed (`build-app.sh
#                                     # --adhoc`): for a DMG others download, so it never
#                                     # carries this Mac's Apple Development certificate
#
# Both files have identical contents. "Serpentine.dmg" is the canonical name links download by,
# through GitHub's /releases/latest/download/<name> shortcut, which only works if the filename
# is the same on every release, so it must keep this exact name. The versioned copy
# is just so the filename is self-describing for anyone browsing the Releases page directly;
# attach both as separate assets on the GitHub release.
#
# The app is unsigned/self-signed (no paid Apple Developer ID), so macOS Gatekeeper will
# warn on first launch. That is expected; see the "Install" section in README.md for the
# one-time bypass instructions to put in the release notes.
set -euo pipefail

BUILD_ARGS=()
for arg in "$@"; do
    case "${arg}" in
        --adhoc) BUILD_ARGS+=(--adhoc) ;;
        *) echo "Unknown option: ${arg} (the only one is --adhoc)" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."

APP="Serpentine.app"
VOLNAME="Serpentine"
OUT_DIR="dist"
OUT_DMG="${OUT_DIR}/Serpentine.dmg"

echo "▸ Building ${APP}…"
./Scripts/build-app.sh ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
VERSIONED_DMG="${OUT_DIR}/Serpentine-${VERSION}.dmg"

echo "▸ Staging DMG contents…"
STAGE="$(mktemp -d)"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

mkdir -p "${OUT_DIR}"
rm -f "${OUT_DMG}" "${VERSIONED_DMG}"

echo "▸ Writing ${OUT_DMG}…"
hdiutil create -volname "${VOLNAME}" -srcfolder "${STAGE}" -ov -format UDZO "${OUT_DMG}"
cp "${OUT_DMG}" "${VERSIONED_DMG}"

rm -rf "${STAGE}"

echo "✓ Built ${OUT_DMG} and ${VERSIONED_DMG}"
echo "  This app is unsigned/self-signed — first launch will trigger a Gatekeeper warning."
echo "  See the 'Install' section in README.md for the bypass steps to include in release notes."
