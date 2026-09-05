# 이미지뷰어 (가제)

빠르고 단정한 macOS용 무료 오픈 소스 이미지 뷰어입니다. 반디뷰의 이미지 중심 흐름에서 영감을 받되, SwiftUI·트랙패드·Apple 컬러 파이프라인에 맞게 새로 설계합니다.

현재 버전은 **0.2.2 개발 기반(MVP)** 입니다. 폴더 탐색부터 다중 보기, 비파괴 보정과 형식 변환까지 핵심 흐름을 실제로 실행할 수 있으며, 초대형 이미지 타일 렌더링과 배포 서명 등은 후속 마일스톤에서 강화합니다.

## 지금 되는 것

- 폴더 전체 열기, Finder 파일 열기, 드래그 앤 드롭
- 파일명 자연 정렬과 위·아래·왼쪽·오른쪽·숨김 배치가 가능한 썸네일 패널
- 크기를 조절할 수 있는 전체 썸네일 보기
- 한 창에 1~10장 동시 보기와 창 비율 기반 자동 그리드
- 트랙패드 핀치 확대/축소와 가로 스와이프 탐색
- 왼쪽 드래그, Space+왼쪽 드래그, 오른쪽/가운데 버튼, 두 손가락 이동 중 선택 가능한 팬 조작
- 방향키를 포함한 키보드 탐색과 사용자 지정 단축키
- 화면 맞춤, 실제 크기, 집중 모드, 전체 화면
- 하단 돌아가기 버튼과 `Esc`를 이용한 집중 보기 종료 및 전체 보기 복귀
- GIF/APNG/Animated WebP 등 Image I/O 다중 프레임 재생
- 밝기, 대비, 채도, 하이라이트, 반전, 90도 회전
- JPEG, PNG, HEIC, TIFF 및 OS 인코더가 제공하는 WebP/AVIF/JPEG XL 내보내기
- HDR gain map 확장과 16-bit float Core Image 렌더 경로
- QOI 및 대표 PCX 변형을 위한 앱 자체 디코더
- i 정보 패널의 파일·색상·카메라 EXIF·GPS 정보와 Apple/Google 지도 열기
- e 편집 패널로 분리된 비파괴 조정 및 형식 변환
- Quick Look 캐시 미리보기 → 정밀 렌더의 2단계 로딩

## 포맷 지원 전략

지원 포맷은 실행 중인 macOS의 `CGImageSourceCopyTypeIdentifiers()` 결과를 동적으로 사용합니다. macOS 15 기준으로 JPEG/JPEG 2000, PNG/APNG, GIF, TIFF, BMP, HEIC/HEIF, AVIF, JPEG XL, WebP, PSD, TGA, DDS, OpenEXR, Radiance HDR, ICO/ICNS, KTX/KTX2, ASTC/PVR 및 폭넓은 카메라 RAW를 네이티브로 읽습니다.

Image I/O 밖의 QOI와 PCX는 자체 디코더로 보완하고, SVG/SVGZ는 AppKit 표현 폴백을 사용합니다. BPG와 Clip Studio `.clip`은 아직 포함되지 않았습니다. 자세한 범위와 원칙은 [포맷 문서](docs/FORMAT_SUPPORT.md)를 참고하세요.

## 실행

요구 환경은 macOS 14 이상과 Xcode 16 이상입니다.

```bash
swift run
```

또는 Finder에서 `Package.swift`를 Xcode로 열고 `ImageViewer` 실행 대상을 선택하세요.

일반 `.app` 번들을 만들려면 다음을 실행합니다.

```bash
./scripts/build-app.sh
open "dist/이미지뷰어.app"
```

기본 결과는 Apple Silicon과 Intel을 함께 지원하는 Universal 2 앱이며, 릴리스 빌드는 같은 버전의 GitHub 배포용 ZIP도 생성합니다. 빠른 로컬 빌드만 필요하면 `./scripts/build-app.sh debug native`를 사용하세요. 스크립트 결과는 로컬 실행용 ad-hoc 서명이며, GitHub Release로 배포할 때는 Apple Developer ID 서명과 공증이 별도로 필요합니다.

## 기본 단축키

| 동작 | 키 |
|---|---|
| 이전 / 다음 페이지 | `←` / `→` |
| 확대 / 축소 | `=` / `-` |
| 화면 맞춤 / 실제 크기 | `0` / `1` |
| 전체 보기 | `G` |
| 집중 모드 | `F` |
| 이전 보기로 돌아가기 | `Esc` |
| 한 화면 이미지 수 줄이기 / 늘리기 | `[` / `]` |
| 폴더 열기 | `⌘O` |
| 내보내기 | `⌘E` |

모든 키는 **이미지뷰어 → 설정 → 단축키**에서 변경할 수 있습니다.

썸네일 패널 위치와 확대 이미지 이동 방식은 툴바/하단 조작부에서 바로 바꾸거나 **이미지뷰어 → 설정 → 일반**에서 지정할 수 있습니다. 이 두 설정은 다음 실행에도 유지됩니다.

## 문서

- [아키텍처](docs/ARCHITECTURE.md)
- [요구사항 진행표](docs/REQUIREMENTS.md)
- [개발일지](docs/DEVELOPMENT_LOG.md)
- [기여 방법](CONTRIBUTING.md)

## 라이선스

[MIT License](LICENSE)로 공개합니다. 앱 이름, 번들 ID와 아이콘은 정식 이름을 정할 때 교체할 예정입니다.
