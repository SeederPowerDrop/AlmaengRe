#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
CONFIGURATION="${1:-release}"
ARCHITECTURE_MODE="${2:-universal}"
# 사용자에게 보이는 이름만 변경합니다. 실행 파일·번들 ID·설정 키는 이전 버전과 같습니다.
# 실행 중인 배포본을 건드리지 않고 검증할 때 별도 출력 폴더를 지정합니다.
DISTRIBUTION_DIRECTORY="${IMAGEVIEWER_DIST_DIRECTORY:-$PROJECT_DIRECTORY/dist}"
APP_DIRECTORY="$DISTRIBUTION_DIRECTORY/알맹Re.app"
CONTENTS_DIRECTORY="$APP_DIRECTORY/Contents"
APP_ICON_PATH="$PROJECT_DIRECTORY/Packaging/AppIcon.icns"

cd "$PROJECT_DIRECTORY"

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  echo "사용법: $0 [debug|release] [universal|native]" >&2
  exit 2
fi
if [[ "$ARCHITECTURE_MODE" != "universal" && "$ARCHITECTURE_MODE" != "native" ]]; then
  echo "사용법: $0 [debug|release] [universal|native]" >&2
  exit 2
fi
if [[ ! -s "$APP_ICON_PATH" ]]; then
  echo "앱 아이콘 파일을 찾을 수 없거나 비어 있습니다: $APP_ICON_PATH" >&2
  exit 1
fi

# 배포 전에 GitHub 설명서·번역 구조·검토한 앱 소스 지문을 확인합니다.
# 변경 검토와 설명서 갱신 없이 manifest를 자동으로 다시 기록하지 않습니다.
# AGENTS.md의 사용자 지시로 설명서 작업을 유예한 개발 빌드에만 명시적으로 사용합니다.
if [[ "${IMAGEVIEWER_DEFER_GUIDE_CHECK:-0}" == "1" ]]; then
  echo "사용자 요청으로 설명서 검사·갱신을 유예합니다. 기존 설명서와 검토 지문은 보존합니다."
else
  python3 "$SCRIPT_DIRECTORY/check-user-guide.py"
fi

"$SCRIPT_DIRECTORY/build-rust-engine.sh" "$ARCHITECTURE_MODE"

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
# 이전 빌드 폴더를 재사용해도 전체 설명서가 앱에 남지 않도록 정리합니다.
find "$CONTENTS_DIRECTORY/Resources" -maxdepth 1 -type f \
  \( -name 'UserGuide-*.html' -o -name 'UserGuide-*.jpg' \) -delete
ditto "$PROJECT_DIRECTORY/Sources/ImageViewer/Resources" "$CONTENTS_DIRECTORY/Resources"
cp "$APP_ICON_PATH" "$CONTENTS_DIRECTORY/Resources/AppIcon.icns"
cp "$PROJECT_DIRECTORY/Engine/THIRD_PARTY_NOTICES.txt" "$CONTENTS_DIRECTORY/Resources/RustThirdPartyNotices.txt"

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
  ZIP_PATH="$DISTRIBUTION_DIRECTORY/알맹Re-$APP_VERSION-macos-$ZIP_SUFFIX.zip"
  IMAGEVIEWER_TEMP_ROOT="${TMPDIR:-/tmp}"
  PACKAGE_TEMP_DIRECTORY="$(mktemp -d "${IMAGEVIEWER_TEMP_ROOT%/}/imageviewer-package.XXXXXX")"
  TEMP_ZIP_PATH="$PACKAGE_TEMP_DIRECTORY/$(basename "$ZIP_PATH")"

  # 기존 릴리스가 있어도 완성된 새 ZIP을 한 번에 교체해 중간 파일을 남기지 않습니다.
  ditto -c -k --sequesterRsrc --keepParent "$APP_DIRECTORY" "$TEMP_ZIP_PATH"
  mv -f "$TEMP_ZIP_PATH" "$ZIP_PATH"
  rmdir "$PACKAGE_TEMP_DIRECTORY"
  echo "$ZIP_PATH"
fi
