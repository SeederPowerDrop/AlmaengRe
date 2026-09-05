# 아키텍처

## 큰 흐름

    Folder / Files
          │
          ▼
    ImageLibrary ── 가벼운 파일 메타데이터와 자연 정렬
          │
          ▼
    AppStore ── 현재 위치, 1~10장 배치, 패널, 확대/팬, 조정값
          │
          ├──────────────► ThumbnailPipeline actor
          │                  └─ macOS Quick Look 디스크 캐시
          │                         └─ Overview / 썸네일 패널 / 선행 미리보기
          │
          ▼
    ImagePipeline actor
          ├─ Image I/O / Core Image / RAW
          ├─ QOI·PCX 자체 디코더
          ├─ AppKit 표현 폴백
          └─ 축소·필터·색상 변환·프레임 캐시
          │
          ├──────────────► SwiftUI HDR/EDR 화면
          ├──────────────► EXIF/TIFF/GPS ── i 정보 패널 ── 지도 링크
          ├──────────────► i 정보 수정 ── ImageMetadataWriter ── 원본 경로 갱신
          └──────────────► ImageExporter ── 새 파일

## 왜 핵심 엔진이 Rust가 아닌가

이 앱의 주 경로는 이미 Apple이 C/C++·GPU 수준에서 최적화한 Image I/O, Core Image와 Metal입니다. 같은 파일을 Rust로 다시 디코딩한 뒤 SwiftUI로 복사하면 메모리 복사와 컬러 프로파일 변환이 하나 더 생기고, 최신 macOS RAW/HDR 지원을 중복 구현해야 합니다.

따라서 UI 상태는 Swift, 디코딩/색상/필터는 Apple 프레임워크, 시스템에 없는 작은 오픈 포맷만 독립 코덱으로 둡니다. 이후 libjxl/libheif/LibRaw 같은 외부 엔진이 실제 측정에서 필요해지면 ImagePipeline 뒤에 어댑터로 추가할 수 있습니다.

## 성능 설계

- 폴더 스캔과 이미지 파이프라인은 actor로 UI 스레드에서 분리합니다.
- 그리드 셀은 화면에 보일 때만 작업을 요청하며 사라지면 취소됩니다.
- 목록은 Finder와 같은 Quick Look 썸네일 캐시를 사용합니다. 큰 이미지도 빠른 미리보기를 먼저 표시하고 정밀 렌더가 완료되면 교체합니다.
- 화면 크기가 정해진 SDR 이미지는 Image I/O에서 먼저 축소하고, HDR/gain-map 이미지만 16-bit Core Image 경로를 유지합니다.
- 현재 페이지를 제외한 앞뒤 파일만 선읽기하며, 탐색이 바뀌면 이전 작업을 취소하고 각 이미지 사이에서 actor를 양보합니다.
- 요청 크기는 256픽셀 버킷으로 묶어 확대 중 캐시 파편화를 줄입니다.
- 정밀 렌더 캐시는 물리 메모리의 1/24(최소 128MB, 최대 512MB), 썸네일 캐시는 최대 128MB입니다.
- HDR 경로는 Core Image RGBAh, extended-linear Display P3와 EDR이 활성화된 전용 CALayer를 사용합니다.
- 집중 보기의 1:1 모드는 현재 8K 미리보기 상한을 둡니다. 초대형 이미지의 완전한 1:1 이동은 다음 단계의 타일 피라미드 렌더러가 담당합니다.

Quick Look, Image I/O, Core Image는 macOS 동적 프레임워크이므로 앱 번들에 대형 코덱 바이너리를 복제하지 않습니다. 시스템 미지원 형식만 작은 독립 디코더로 추가하는 것이 용량 원칙입니다.

## 입력과 패널

- 썸네일 패널 배치는 ThumbnailPanelPlacement 하나로 관리하며, 위·아래에서는 가로 지연 그리드, 좌·우에서는 세로 지연 그리드를 재사용합니다.
- 팬 방식은 PanInteractionMode로 저장합니다. AppKit 이벤트 감시 영역은 이미지 캔버스에만 붙어 정보 패널이나 설정 창의 스크롤을 가로채지 않습니다.
- 오른쪽 보조 패널은 정보와 편집 중 하나만 열어 좁은 창에서도 이미지 영역을 보존합니다.
- i 정보 패널의 수정 시트는 파일 이름·수정일과 TIFF/EXIF/GPS 표준 태그를 편집합니다. 픽셀 크기·포맷·비트 심도·UTI처럼 파일에서 계산되는 속성은 읽기 전용입니다.
- 지도 버튼은 EXIF GPS가 유효할 때만 보이며, 클릭할 때만 [Apple 지도 링크](https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/MapLinks/MapLinks.html) 또는 [Google Maps URL](https://developers.google.com/maps/documentation/urls/get-started)을 엽니다. API 키나 위치 업로드는 없습니다.

## 비파괴 조정

조정값은 파일 URL별 ImageAdjustments에만 저장됩니다. 화면에서는 Core Image 필터 체인으로 적용하고, 사용자가 내보내기를 선택했을 때 같은 체인을 원본 해상도로 평가합니다. 밝기·채도·회전 같은 픽셀 편집은 원본 파일을 덮어쓰지 않습니다.

## 메타데이터 편집 안전성

- 정보 수정은 사용자가 i 패널에서 저장을 명시적으로 선택할 때만 실행합니다.
- 확장자 변경, 중복 파일명과 숫자·GPS 범위를 먼저 검증합니다.
- ImageMetadataWriter는 Image I/O의 무손실 복사 경로로 임시 파일을 완성한 뒤 원본 경로를 교체하므로 픽셀을 다시 압축하지 않습니다.
- 지원하지 않는 형식에서는 내장 태그 입력을 잠그고 파일 이름과 파일 시스템 수정일만 허용합니다.
- 저장 후 소스·렌더·Quick Look 캐시를 폐기하고 폴더를 다시 스캔해 변경된 이름과 정보를 즉시 반영합니다.
