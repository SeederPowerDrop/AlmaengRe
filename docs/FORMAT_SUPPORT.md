# 이미지 포맷 지원

## 원칙

“모든 이미지 포맷”은 운영체제·카메라 모델·특허·라이선스에 따라 경계가 바뀝니다. 따라서 알맹Re는 아래 세 단계로 지원 범위를 넓힙니다.

1. Apple Image I/O/Core Image: 시스템 업데이트와 함께 새 RAW 및 현대 포맷 지원을 얻습니다.
2. AppKit 폴백: SVG처럼 벡터 표현으로 제공되는 형식을 래스터화합니다.
3. 앱 자체 오픈 코덱: 시스템이 모르는 형식만 격리된 디코더로 추가합니다.

## 현재 범위

| 계층 | 대표 포맷 | 상태 |
|---|---|---|
| Image I/O | JPEG, PNG/APNG, GIF, TIFF, BMP, JPEG 2000 | 지원 |
| 현대 포맷 | HEIC/HEIF, AVIF, JPEG XL, WebP | OS가 제공하는 범위에서 지원 |
| 전문가 포맷 | PSD, DDS, OpenEXR, Radiance HDR, TGA | 지원 |
| GPU 텍스처 | KTX/KTX2, ASTC, PVR | OS가 제공하는 범위에서 지원 |
| 카메라 RAW | DNG, CR2/CR3, NEF/NRW, ARW/SR2, ORF, RW2, RAF, PEF 등 | 설치된 macOS RAW 디코더 기준 지원 |
| 앱 자체 | QOI, PCX(8-bit indexed, 24-bit RGB, 기본 저비트 변형) | 지원 |
| AppKit 폴백 | SVG/SVGZ 및 시스템 이미지 플러그인 | 지원 |
| 추가 필요 | BPG, Clip Studio `.clip`, 일부 희귀/전용 포맷 | 예정 |

실제 지원 UTI 목록은 앱 설정의 **디코더** 항목에서 확인할 수 있습니다. 확장자만 신뢰하지 않고 디코더가 파일 헤더를 최종 검증합니다.

## 안전성

- 폴더 스캔 단계에서는 픽셀을 읽지 않습니다.
- 목록과 첫 표시는 macOS Quick Look 캐시를 우선 사용하고, 정밀 화면은 필요한 크기로 축소합니다.
- HDR/gain-map 감지 파일은 16-bit float 경로를 보존하고 일반 SDR 파일은 Image I/O에서 먼저 축소합니다.
- QOI/PCX 자체 디코더는 최대 1억 픽셀 제한과 헤더/길이 검사를 수행합니다.
- 프레임과 이미지 소스 캐시는 메모리 압박 시 자동 퇴거되는 `NSCache`를 사용합니다.
- 원본 해상도 렌더는 사용자가 내보내기를 실행한 경우에만 수행합니다.
