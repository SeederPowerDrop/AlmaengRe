#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIRECTORY="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
SOURCE_IMAGE="$PROJECT_DIRECTORY/Packaging/AppIcon.png"
OUTPUT_ICON="$PROJECT_DIRECTORY/Packaging/AppIcon.icns"

if [[ ! -s "$SOURCE_IMAGE" ]]; then
  echo "확정된 아이콘 원본을 찾을 수 없습니다: $SOURCE_IMAGE" >&2
  exit 1
fi

ICON_TEMP_ROOT="${TMPDIR:-/tmp}"
ICON_WORK_DIRECTORY="$(mktemp -d "${ICON_TEMP_ROOT%/}/almaengre-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK_DIRECTORY"' EXIT
ICONSET_DIRECTORY="$ICON_WORK_DIRECTORY/AppIcon.iconset"
mkdir -p "$ICONSET_DIRECTORY"

# 확정된 그림과 투명 알파 채널을 유지하며 macOS의 1x/2x 크기만 만듭니다.
for POINT_SIZE in 16 32 128 256 512; do
  /usr/bin/sips --resampleHeightWidth "$POINT_SIZE" "$POINT_SIZE" \
    "$SOURCE_IMAGE" --out "$ICONSET_DIRECTORY/icon_${POINT_SIZE}x${POINT_SIZE}.png" >/dev/null
  PIXEL_SIZE=$((POINT_SIZE * 2))
  /usr/bin/sips --resampleHeightWidth "$PIXEL_SIZE" "$PIXEL_SIZE" \
    "$SOURCE_IMAGE" --out "$ICONSET_DIRECTORY/icon_${POINT_SIZE}x${POINT_SIZE}@2x.png" >/dev/null
done

/usr/bin/iconutil --convert icns --output "$ICON_WORK_DIRECTORY/AppIcon.icns" \
  "$ICONSET_DIRECTORY"
cp "$ICON_WORK_DIRECTORY/AppIcon.icns" "$OUTPUT_ICON"
echo "$OUTPUT_ICON"
