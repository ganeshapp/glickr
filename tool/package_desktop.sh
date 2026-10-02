#!/usr/bin/env bash
# Package a desktop release build for GitHub: tool/package_desktop.sh linux|macos
#
# Run after `flutter build <target> --release`; .github/workflows/
# desktop-release.yml does both and uploads build/dist/*. Like release.sh, the
# version comes from pubspec.yaml, so the file names can't drift from the APKs.
set -euo pipefail

cd "$(dirname "$0")/.."

APP=glickr                                   # executable, .deb package, .app
ID=com.glickr.glickr                         # bundle id == Linux APPLICATION_ID
ICON=assets/brand/glickr_playstore_512.png   # 512x512
SUMMARY="Manage photo albums stored in a GitHub repo"
VERSION=$(grep '^version:' pubspec.yaml | sed 's/^version:[[:space:]]*//' | cut -d+ -f1)
: "${VERSION:?could not read version from pubspec.yaml}"
OUT=build/dist
rm -rf "$OUT" && mkdir -p "$OUT"

case "${1:-}" in
linux)
  BUNDLE=build/linux/x64/release/bundle
  tar -czf "$OUT/$APP-$VERSION-linux-x64.tar.gz" -C "$(dirname "$BUNDLE")" \
    --transform "s,^bundle,$APP," bundle

  ROOT=$PWD/build/deb && rm -rf "$ROOT"
  mkdir -p "$ROOT/DEBIAN" "$ROOT/opt" "$ROOT/usr/bin" \
    "$ROOT/usr/share/applications" "$ROOT/usr/share/icons/hicolor/512x512/apps"
  cp -r "$BUNDLE" "$ROOT/opt/$APP"
  ln -s "/opt/$APP/$APP" "$ROOT/usr/bin/$APP"   # the engine resolves /proc/self/exe
  cp "$ICON" "$ROOT/usr/share/icons/hicolor/512x512/apps/$ID.png"
  # Named after the application id, and StartupWMClass set to it: the runner
  # calls g_set_prgname(APPLICATION_ID), which is what the dock matches on.
  cat > "$ROOT/usr/share/applications/$ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$APP
Comment=$SUMMARY
Exec=$APP
Icon=$ID
Terminal=false
Categories=Graphics;Photography;
StartupWMClass=$ID
EOF
  # Depends straight from the ELF files: the right t64 package names and the
  # right glibc floor. dpkg-shlibdeps insists on a debian/control in its
  # working directory.
  mkdir -p build/shlibs/debian && : > build/shlibs/debian/control
  DEPS=$(cd build/shlibs && dpkg-shlibdeps -O --ignore-missing-info \
    -l"$ROOT/opt/$APP/lib" "$ROOT/opt/$APP/$APP" "$ROOT/opt/$APP"/lib/*.so \
    | sed 's/^shlibs:Depends=//')
  cat > "$ROOT/DEBIAN/control" <<EOF
Package: $APP
Version: $VERSION
Section: graphics
Priority: optional
Architecture: amd64
Maintainer: ganeshapp <ganeshapp@users.noreply.github.com>
Depends: $DEPS
Recommends: gnome-keyring
Description: $SUMMARY
 Staying signed in needs a Secret Service keyring (GNOME Keyring or KWallet).
EOF
  dpkg-deb --build --root-owner-group "$ROOT" "$OUT/$APP-$VERSION-linux-x64.deb"
  ;;
macos)
  BUNDLE="build/macos/Build/Products/Release/$APP.app"
  lipo "$BUNDLE/Contents/MacOS/$APP" -verify_arch x86_64 arm64   # universal
  codesign --verify --deep --strict "$BUNDLE"   # ad-hoc seal intact
  STAGE=build/dmg && rm -rf "$STAGE" && mkdir -p "$STAGE"
  ditto "$BUNDLE" "$STAGE/$APP.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP" -srcfolder "$STAGE" -format UDZO -ov \
    "$OUT/$APP-$VERSION-macos.dmg"
  ;;
*) echo "usage: $0 linux|macos" >&2; exit 2 ;;
esac
ls -l "$OUT"
