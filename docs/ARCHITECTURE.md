# 아키텍처

## 큰 흐름

```text
Folder / Files
      │
      ▼
ImageLibrary ── 가벼운 파일 메타데이터와 자연 정렬
      │
      ▼
AppStore ── 현재 위치, 1~10장 배치, 확대, 조정값, 단축키
      │
      ├──────────────► Overview / Sidebar (지연 로딩 썸네일)
      │
      ▼
ImagePipeline actor
      ├─ Image I/O / Core Image / RAW
      ├─ QOI·PCX 자체 디코더
      ├─ AppKit 표현 폴백
      └─ 축소·필터·색상 변환·프레임 캐시
      │
      ├──────────────► SwiftUI HDR/EDR 화면
      └──────────────► ImageExporter ── 새 파일
```

## 왜 핵심 엔진이 Rust가 아닌가

이 앱의 주 경로는 이미 Apple이 C/C++·GPU 수준에서 최적화한 Image I/O, Core Image와 Metal입니다. 같은 파일을 Rust로 다시 디코딩한 뒤 SwiftUI로 복사하면 메모리 복사와 컬러 프로파일 변환이 하나 더 생기고, 최신 macOS RAW/HDR 지원을 중복 구현해야 합니다.

따라서 UI 상태는 Swift, 디코딩/색상/필터는 Apple 프레임워크, 시스템에 없는 작은 오픈 포맷만 독립 코덱으로 둡니다. 이후 libjxl/libheif/LibRaw 같은 외부 엔진이 실제 측정에서 필요해지면 `ImagePipeline` 뒤에 어댑터로 추가할 수 있습니다.

## 성능 설계

- 폴더 스캔과 이미지 파이프라인은 actor로 UI 스레드에서 분리합니다.
- 그리드 셀은 화면에 보일 때만 `.task`로 디코딩하며 사라지면 취소됩니다.
- 요청 크기는 256픽셀 버킷으로 묶어 확대 중 캐시 파편화를 줄입니다.
- 캐시는 물리 메모리의 1/16(최소 256MB, 최대 768MB)을 목표로 합니다.
- HDR 경로는 Core Image `RGBAh`, extended-linear Display P3와 EDR이 활성화된 전용 `CALayer`를 사용합니다.
- 집중 보기의 1:1 모드는 현재 8K 미리보기 상한을 둡니다. 초대형 이미지의 완전한 1:1 이동은 다음 단계의 타일 피라미드 렌더러가 담당합니다.

## 비파괴 조정

조정값은 파일 URL별 `ImageAdjustments`에만 저장됩니다. 화면에서는 Core Image 필터 체인으로 적용하고, 사용자가 내보내기를 선택했을 때 같은 체인을 원본 해상도로 평가합니다. 원본 파일 덮어쓰기는 제공하지 않습니다.
