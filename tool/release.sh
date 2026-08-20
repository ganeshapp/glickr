#!/usr/bin/env bash
# Build every APK a release ships and stage them under their published names.
#
#   tool/release.sh            # build and stage only
#   tool/release.sh --upload   # ...and attach them to the tag for this version
#
# This exists because the asset list is easy to get wrong by hand: `flutter
# build apk --release` on its own produces ONE universal APK, and 1.0.1 first
# shipped with only that, silently dropping the per-ABI downloads 1.0.0 had.
# The version comes from pubspec.yaml, so it can't drift from the tag either.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(grep '^version:' pubspec.yaml | sed 's/^version:[[:space:]]*//' | cut -d+ -f1)
OUT=build/release/$VERSION
APK=build/app/outputs/flutter-apk

if [ -z "$VERSION" ]; then
  echo "Could not read version from pubspec.yaml" >&2
  exit 1
fi

echo "==> glickr $VERSION"

# Splits first, then the universal build: they share an output directory and
# the universal pass leaves the split APKs in place, but not the reverse.
flutter build apk --release --split-per-abi
flutter build apk --release

rm -rf "$OUT" && mkdir -p "$OUT"
cp "$APK/app-arm64-v8a-release.apk"   "$OUT/glickr-$VERSION-arm64-v8a.apk"
cp "$APK/app-armeabi-v7a-release.apk" "$OUT/glickr-$VERSION-armeabi-v7a.apk"
cp "$APK/app-x86_64-release.apk"      "$OUT/glickr-$VERSION-x86_64.apk"
cp "$APK/app-release.apk"             "$OUT/glickr-$VERSION-universal.apk"

# Trust the contents, not the filename: a split that quietly picked up every
# ABI would be a 56 MB "arm64" download that still works, so nothing else
# would catch it.
echo
for f in "$OUT"/*.apk; do
  abis=$(unzip -l "$f" | grep -o 'lib/[^/]*' | sort -u | sed 's|lib/||' | paste -sd, -)
  printf '%-34s %6s MB  %s\n' "$(basename "$f")" \
    "$(( $(stat -f%z "$f") / 1048576 ))" "$abis"
done
echo

if [ "${1:-}" = "--upload" ]; then
  echo "==> uploading to v$VERSION"
  gh release upload "v$VERSION" "$OUT"/*.apk --clobber
fi

echo "Staged in $OUT"
