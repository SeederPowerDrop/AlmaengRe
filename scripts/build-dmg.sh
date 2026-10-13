#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "사용법: $0 <서명된 앱 경로.app> <새 출력 경로.dmg>" >&2
  exit 2
fi

APP_INPUT="${1%/}"
OUTPUT_INPUT="$2"
if [[ "$APP_INPUT" != *.app || ! -d "$APP_INPUT/Contents" ]]; then
  echo "유효한 앱 번들이 아닙니다: $APP_INPUT" >&2
  exit 2
fi
if [[ "$OUTPUT_INPUT" != *.dmg ]]; then
  echo "출력 파일의 확장자는 .dmg이어야 합니다: $OUTPUT_INPUT" >&2
  exit 2
fi
if [[ -e "$OUTPUT_INPUT" || -L "$OUTPUT_INPUT" ]]; then
  echo "기존 파일은 덮어쓰지 않습니다. 다른 출력 경로를 지정하세요: $OUTPUT_INPUT" >&2
  exit 2
fi

APP_DIRECTORY="$(cd "$APP_INPUT" && pwd -P)"
APP_NAME="$(basename "$APP_DIRECTORY")"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP_DIRECTORY/Contents/Info.plist")"
VOLUME_NAME="${APP_NAME%.app} $APP_VERSION"

# 원본의 서명을 유지합니다. Developer ID 서명·공증을 마친 앱도 그대로 담으며,
# ad-hoc 서명 앱을 이 스크립트가 공증된 앱으로 바꾸지는 않습니다.
/usr/bin/codesign --verify --deep --strict "$APP_DIRECTORY"
command -v python3 >/dev/null

mkdir -p "$(dirname "$OUTPUT_INPUT")"
OUTPUT_DIRECTORY="$(cd "$(dirname "$OUTPUT_INPUT")" && pwd -P)"
OUTPUT_PATH="$OUTPUT_DIRECTORY/$(basename "$OUTPUT_INPUT")"

# 최종 출력과 같은 파일시스템에 임시 이미지를 만들어 완성본만 원자 공개합니다.
PACKAGE_DIRECTORY="$(mktemp -d "$OUTPUT_DIRECTORY/.almaeng-dmg.XXXXXX")"
STAGING_DIRECTORY="$PACKAGE_DIRECTORY/content"
MOUNT_DIRECTORY="$PACKAGE_DIRECTORY/mounted"
TEMP_DMG_PATH="$PACKAGE_DIRECTORY/package.dmg"
IS_MOUNTED=0

cleanup() {
  local result=$?
  trap - EXIT
  if [[ "$IS_MOUNTED" == 1 ]]; then
    if ! /usr/bin/hdiutil detach "$MOUNT_DIRECTORY" -quiet; then
      if ! /usr/bin/hdiutil detach "$MOUNT_DIRECTORY" -force -quiet; then
        echo "임시 DMG를 분리하지 못했습니다. 확인 후 정리하세요: $PACKAGE_DIRECTORY" >&2
        exit 1
      fi
    fi
  fi
  /bin/rm -rf "$PACKAGE_DIRECTORY"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$STAGING_DIRECTORY" "$MOUNT_DIRECTORY"
/usr/bin/ditto "$APP_DIRECTORY" "$STAGING_DIRECTORY/$APP_NAME"
/bin/ln -s /Applications "$STAGING_DIRECTORY/Applications"
/usr/bin/codesign --verify --deep --strict "$STAGING_DIRECTORY/$APP_NAME"

# HFS+와 UDZO는 지원 대상인 macOS 14 이상의 Intel·Apple Silicon에서 열립니다.
# 앱과 설치 대상 링크 외에 작업 폴더나 로컬 검수 자료는 넣지 않습니다.
/usr/bin/hdiutil create -srcfolder "$STAGING_DIRECTORY" \
  -volname "$VOLUME_NAME" -fs HFS+ -format UDZO \
  -imagekey zlib-level=9 -nospotlight "$TEMP_DMG_PATH"
/usr/bin/hdiutil verify "$TEMP_DMG_PATH"
/usr/bin/hdiutil attach "$TEMP_DMG_PATH" -readonly -nobrowse -noautoopen \
  -mountpoint "$MOUNT_DIRECTORY" -quiet
IS_MOUNTED=1
/usr/bin/codesign --verify --deep --strict "$MOUNT_DIRECTORY/$APP_NAME"
if [[ "$(/usr/bin/readlink "$MOUNT_DIRECTORY/Applications")" != /Applications ]]; then
  echo "DMG의 Applications 설치 링크를 확인할 수 없습니다." >&2
  exit 1
fi
/usr/bin/hdiutil detach "$MOUNT_DIRECTORY" -quiet
IS_MOUNTED=0

# link(2)는 출력이 이미 존재하면 실패합니다. 검사 후 다른 작업이 같은 이름을
# 만들어도 덮어쓰지 않으며, 검증 중인 불완전한 이미지를 공개하지 않습니다.
python3 - "$TEMP_DMG_PATH" "$OUTPUT_PATH" <<'PY'
import os
import sys

try:
    os.link(sys.argv[1], sys.argv[2])
except FileExistsError:
    sys.exit(f"기존 파일은 덮어쓰지 않습니다: {sys.argv[2]}")
PY

/usr/bin/shasum -a 256 "$OUTPUT_PATH"
echo "$OUTPUT_PATH"
