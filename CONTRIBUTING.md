# 기여하기

알맹Re는 읽고 배우고 수정하기 쉬운 무료 macOS 이미지 뷰어를 목표로 합니다.

## 개발 환경

- macOS 14 이상, Xcode 16 이상, Swift 6
- Rust 1.94 이상과 Cargo
- Universal 앱 빌드에는 `aarch64-apple-darwin`, `x86_64-apple-darwin` Rust target

기존 0.10.2는 `main`과 `v0.10.2` 태그에 보관합니다. 0.11 기능과 Rust 엔진 전환은 `codex/rust-engine-library-upgrade`에서 진행합니다.

새 clone은 Swift 실행·테스트 전에 Rust 정적 라이브러리를 만들어야 합니다. Rust 코드가 바뀌면 이 단계도 다시 실행하세요. Xcode 실행에도 같은 준비가 필요합니다.

```sh
./scripts/build-rust-engine.sh native
cargo test --manifest-path Engine/almeng-core/Cargo.toml --locked
swift test --disable-sandbox
```

변경 전 기준 검증을 실행하고 변경 후 관련 검증을 반복합니다. SwiftPM 테스트에 사용하는 네이티브 Rust 라이브러리는 `.build/rust/lib`에 생성되며 저장소에 커밋하지 않습니다. `Cargo.lock`은 커밋하고 빌드 시 `--locked`를 유지합니다.

Universal 배포본은 두 Rust target을 준비한 뒤 앱 빌드 스크립트를 사용합니다. 이 스크립트가 Rust와 Swift의 각 아키텍처를 빌드하고 Universal 앱과 ZIP을 만듭니다.

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
./scripts/build-app.sh release universal
```

포함된 AI 모델은 일반 빌드에 Python이나 네트워크 모델 다운로드가 필요하지 않습니다. 모델 변경 시에만 [재현 문서](Sources/ImageViewer/Resources/AIModels/README.md)의 고정 변환 환경을 사용하고 체크섬·실제 추론 일치 검증·라이선스 기록을 갱신합니다.

## 구현 경계

- Rust: 폴더 열거, 파일명 매칭, 검색·필터·정렬, ZIP, QOI/PCX, 로딩·캐시·픽셀 예산과 적응 정책.
- Swift/네이티브: SwiftUI·AppKit, 접근 권한·북마크, ImageIO의 포맷·RAW·메타데이터, CoreImage/CoreGraphics의 색 관리·HDR, Core ML 추론, actor 스케줄링과 네이티브 이미지 객체 수명.

Rust 로직을 Swift에 중복 구현하지 않습니다. C ABI에서 입력 버퍼는 호출 중에만 빌리고, Rust가 반환한 버퍼는 정해진 해제 함수로 한 번만 해제합니다. 이미지 픽셀을 JSON으로 왕복시키지 않습니다. 자세한 계약은 [엔진 문서](Engine/README.md)에 있습니다.

## 코드 원칙

- 원본 파일을 암묵적으로 수정하거나 덮어쓰지 않습니다. ZIP 이미지는 읽기 전용이며 수정 결과는 외부 사본으로 저장합니다.
- 파일 헤더·ZIP 경로·크기를 신뢰하지 않습니다. 디렉터리 파싱 전에 항목 수와 메타데이터 한도를, 해제 중 실제 바이트 수를 검사합니다.
- 메인 스레드에서 폴더 열거, 검색·정렬, 원본 디코딩, 포맷 변환을 실행하지 않습니다. 취소·세대 번호로 이전 결과가 현재 선택을 덮지 않게 합니다.
- 임시 ZIP 경로를 세션 식별자로 저장하지 않습니다. 원본 archive URL과 내부 경로를 사용하고, 이미지 참조가 남아 있는 동안 임시 파일 수명을 유지합니다.
- 파일명 매칭은 확장자를 제외한 정규화 이름을 사용하고, 중복·누락 항목을 버리지 않습니다. GPS가 없는 항목은 양방향 정렬에서 모두 뒤에 둡니다.
- 공개 타입과 성능·안전상 중요한 코드에는 “무엇”보다 “왜”를 설명하는 주석을 남깁니다.
- 새 코덱·모델·의존성은 라이선스와 출처를 문서화합니다. Rust 의존성 변경 시 [고지문](Engine/THIRD_PARTY_NOTICES.txt)도 갱신하며 앱 번들에 포함합니다.
- Rust 사용만으로 속도 향상이나 메모리 누수 부재를 주장하지 않습니다. 성능 개선은 측정하고 네이티브 프레임워크·FFI·캐시 수명을 함께 검증합니다.

## 검증과 Pull Request

UI 변경은 밝은/어두운 이미지, 세로/가로 이미지, 1장/10장 보기에서 확인하세요. 비교 변경은 이름 누락·중복 확장자·다른 개수·잠금·기존 목록 순서 모드를 확인합니다. 검색·정렬은 검색 결과가 없을 때, GPS가 없을 때, 필터 해제 후 선택 복원까지 확인합니다. 즐겨찾기와 세션은 재실행, 권한 실패, ZIP 임시 경로 변경을 포함합니다.

파서 변경은 정상 파일, 손상·잘린 파일, 비정상적으로 큰 헤더를 검증합니다. ZIP은 경로 탈출·symlink·중복·압축률·개수·실제 해제 한도를 포함합니다. AI는 모델 추론, 경계가 겹치는 타일, 투명도, 취소, 출력 크기 상한과 원본 덮어쓰기 차단을 확인합니다. 지원 범위는 현재 2배 SDR sRGB·첫 프레임·PNG 사본이며 HDR 출력이나 다른 배율을 검증 없이 지원한다고 표시하지 않습니다.

작은 단위로 변경하고 사용자에게 보이는 차이와 검증 방법을 PR 본문에 적어 주세요. 실제 검증한 OS·아키텍처와 남은 제약을 명시하고, Universal 빌드 성공을 실제 Intel 하드웨어 실행 검증으로 대신하지 않습니다.
