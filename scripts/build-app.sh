#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
CONFIGURATION="${1:-release}"
ARCHITECTURE_MODE="${2:-universal}"
APP_DIRECTORY="$PROJECT_DIRECTORY/dist/이미지뷰어.app"
CONTENTS_DIRECTORY="$APP_DIRECTORY/Contents"

cd "$PROJECT_DIRECTORY"

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  echo "사용법: $0 [debug|release] [universal|native]" >&2
  exit 2
fi
if [[ "$ARCHITECTURE_MODE" != "universal" && "$ARCHITECTURE_MODE" != "native" ]]; then
  echo "사용법: $0 [debug|release] [universal|native]" >&2
  exit 2
fi

mkdir -p "$CONTENTS_DIRECTORY/MacOS" "$CONTENTS_DIRECTORY/Resources"

# 이 패키지는 빌드 플러그인이나 외부 스크립트를 사용하지 않습니다. SwiftPM의
# 중첩 sandbox가 제한된 CI 환경에서 실패하지 않도록 해당 계층만 끕니다.
if [[ "$ARCHITECTURE_MODE" == "universal" ]]; then
  ARM_SCRATCH="$PROJECT_DIRECTORY/.build/universal-arm64"
  INTEL_SCRATCH="$PROJECT_DIRECTORY/.build/universal-x86_64"

  swift build --disable-sandbox -c "$CONFIGURATION" \
    --triple arm64-apple-macosx14.0 --scratch-path "$ARM_SCRATCH"
  ARM_BIN_DIRECTORY="$(swift build --disable-sandbox -c "$CONFIGURATION" \
    --triple arm64-apple-macosx14.0 --scratch-path "$ARM_SCRATCH" --show-bin-path)"

  swift build --disable-sandbox -c "$CONFIGURATION" \
    --triple x86_64-apple-macosx14.0 --scratch-path "$INTEL_SCRATCH"
  INTEL_BIN_DIRECTORY="$(swift build --disable-sandbox -c "$CONFIGURATION" \
    --triple x86_64-apple-macosx14.0 --scratch-path "$INTEL_SCRATCH" --show-bin-path)"

  lipo -create \
    "$ARM_BIN_DIRECTORY/ImageViewer" \
    "$INTEL_BIN_DIRECTORY/ImageViewer" \
    -output "$CONTENTS_DIRECTORY/MacOS/ImageViewer"
else
  swift build --disable-sandbox -c "$CONFIGURATION"
  BIN_DIRECTORY="$(swift build --disable-sandbox -c "$CONFIGURATION" --show-bin-path)"
  cp "$BIN_DIRECTORY/ImageViewer" "$CONTENTS_DIRECTORY/MacOS/ImageViewer"
fi

cp "$PROJECT_DIRECTORY/Packaging/Info.plist" "$CONTENTS_DIRECTORY/Info.plist"

# SwiftPM 실행 파일의 언어 리소스를 실제 macOS 앱의 주 번들에도 넣습니다.
# SwiftUI의 기본 문자열 처리와 Finder의 앱 이름 현지화가 같은 .lproj를 사용합니다.
ditto "$PROJECT_DIRECTORY/Sources/ImageViewer/Resources" "$CONTENTS_DIRECTORY/Resources"

# 릴리스에는 디버그 심볼이 필요하지 않습니다. 서명 전에 제거해 Universal 2
# 실행 파일도 작게 유지합니다.
if [[ "$CONFIGURATION" == "release" ]]; then
  strip -S "$CONTENTS_DIRECTORY/MacOS/ImageViewer"
fi

# 로컬 실행용 ad-hoc 서명입니다. 공개 배포 때는 Developer ID 서명과 공증으로 교체합니다.
codesign --force --deep --sign - "$APP_DIRECTORY"

lipo -info "$CONTENTS_DIRECTORY/MacOS/ImageViewer"
echo "$APP_DIRECTORY"

if [[ "$CONFIGURATION" == "release" ]]; then
  APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$PROJECT_DIRECTORY/Packaging/Info.plist")"
  ZIP_SUFFIX="$ARCHITECTURE_MODE"
  ZIP_PATH="$PROJECT_DIRECTORY/dist/이미지뷰어-$APP_VERSION-macos-$ZIP_SUFFIX.zip"
  IMAGEVIEWER_TEMP_ROOT="${TMPDIR:-/tmp}"
  PACKAGE_TEMP_DIRECTORY="$(mktemp -d "${IMAGEVIEWER_TEMP_ROOT%/}/imageviewer-package.XXXXXX")"
  TEMP_ZIP_PATH="$PACKAGE_TEMP_DIRECTORY/$(basename "$ZIP_PATH")"

  # 기존 릴리스가 있어도 완성된 새 ZIP을 한 번에 교체해 중간 파일을 남기지 않습니다.
  ditto -c -k --sequesterRsrc --keepParent "$APP_DIRECTORY" "$TEMP_ZIP_PATH"
  mv -f "$TEMP_ZIP_PATH" "$ZIP_PATH"
  rmdir "$PACKAGE_TEMP_DIRECTORY"
  echo "$ZIP_PATH"
fi
