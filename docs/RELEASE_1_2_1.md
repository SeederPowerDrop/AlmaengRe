# 알맹Re 1.2.1 (빌드 130)

사진·영상·음성을 함께 탐색하고 정리하는 작업 흐름을 개선했습니다. RAW 편집 중 메모리 사용과 HDR HEIC 내보내기도 다시 검증했습니다.

## 사진과 미디어 탐색

- 단일 보기에서 영상을 넘길 때 중복 재생 준비로 깜박이던 현상을 수정했습니다. 설정에서 자동 재생과 소리 동작을 조절할 수 있고, 소리를 세션 동안 유지하면 다른 파일로 넘어가도 이어집니다.
- 몽땅보기의 재생 버튼에 마우스를 올리면 영상은 무음으로, 음성은 소리와 함께 미리 재생합니다. 음성 썸네일에 오디오 아이콘을 표시하고 재생 중에는 움직이는 파형을 보여줍니다.
- 몽땅보기에서 고른 항목만 단일 보기나 다중보기로 열 수 있습니다. Delete 키는 단일 보기의 현재 항목이나 다중보기·몽땅보기의 선택 항목을 휴지통으로 보냅니다. 분류 및 EXIF·파일명·형식 필터로 좁힌 목록도 뷰어와 다른 보기에서 활용할 수 있습니다.
- VP9 영상의 정보·포스터·재생을 처음 요청할 때 macOS에서 제공하는 디코더가 준비되도록 수정했습니다.

## 검색, RAW 편집 및 저장

- 반복 검색에 이미 읽은 파일 정보를 재사용합니다. 탐색과 검색 조건을 빠르게 바꿔도 오래된 결과가 새 화면을 덮거나 취소된 작업이 캐시를 다시 채우는 경우를 줄였습니다.
- 보정하지 않은 RAW는 화면에 필요한 결과를 먼저 만들고, 첫 편집이 필요할 때 정밀 입력을 준비합니다. 지원되는 Apple GPU에서는 일부 RAW 편집 입력을 Metal로 재사용합니다. 기존 캐시 예산을 사용하며 캐시 정리 또는 자원 예산 축소 시 렌더링 컨텍스트를 해제합니다.
- HDR HEIC 내보내기에는 10비트 BT.2100 PQ 인코딩을 사용해 밝은 부분을 보존합니다. 실제 DNG 세 장에서 다시 연 HEIC를 검사했고 밝은 채널 표본 1,506개가 모두 유지됐습니다. 반투명 HDR과 축소한 광색역 SDR도 검사했습니다.

## 검증 범위

- macOS 15.7.5의 M3 MacBook Air에서 빌드 129의 관련 릴리스 테스트 77개가 통과했습니다. VP9 네이티브 재생은 첫 실행의 시간 초과 후 동일 검사에서 통과했습니다. 빌드 130은 이 앱 코드의 배포 버전입니다.
- 릴리스 구성의 DNG 4장 반복 편집에서 캐시 정리 후 프로세스 메모리 중앙값은 1.36GB에서 347MB로 줄었습니다. 처리 시간은 7.14초와 7.24초였고, 정리 후 메모리 감소에 가장 크게 기여한 변경은 컨텍스트 해제였습니다. 이 수치는 해당 구성요소 시험에 해당합니다.
- 장시간 시험 자동화와 로그 분석을 추가했습니다. 앞선 빌드 125의 약 31분 실행에서 발견한 VP9 문제를 빌드 126에서 수정했습니다. 빌드 130의 새 30분 전경 시험, 실제 잠자기·깨우기, GPU 복사량은 향후 검증 범위입니다.

## English

AlmaengRe 1.2.1 improves media browsing, repeated searches, and error recovery when navigating quickly. Preview videos silently or listen to audio by hovering over the play button in the overview. Open selected items in the single or multi-image viewer. This update also restores playback for affected VP9 files, releases rendering resources when caches are purged, and preserves highlights when exporting HDR HEIC.

The download is for Apple Silicon Macs running macOS 14 or later. The release was verified on macOS 15.7.5 with an Apple M3.
