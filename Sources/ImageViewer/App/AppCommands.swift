import SwiftUI

struct AppCommands: Commands {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("폴더 열기…  \(shortcuts.binding(for: .openFolder).displayText)") {
        store.chooseFolder()
      }
      Button("이미지 파일 열기…") {
        store.chooseFiles()
      }
    }

    CommandMenu("탐색") {
      Button("이전 이미지/페이지  \(shortcuts.binding(for: .previousPage).displayText)") {
        store.navigatePage(-1)
      }
      Button("다음 이미지/페이지  \(shortcuts.binding(for: .nextPage).displayText)") {
        store.navigatePage(1)
      }
      Divider()
      Button("전체 보기 전환  \(shortcuts.binding(for: .toggleOverview).displayText)") {
        store.toggleOverview()
      }
      Button("집중 모드 전환  \(shortcuts.binding(for: .toggleFocus).displayText)") {
        store.toggleFocusMode()
      }
      Button("전체 화면") {
        store.toggleFullScreen()
      }
      .keyboardShortcut("f", modifiers: [.command, .control])
      Divider()
      Menu("썸네일 패널 위치") {
        Picker("위치", selection: $store.thumbnailPanelPlacement) {
          ForEach(ThumbnailPanelPlacement.allCases) { placement in
            Text(placement.title).tag(placement)
          }
        }
      }
      Menu("파일 이름 표시") {
        Picker("크기", selection: $store.filenameDisplaySize) {
          ForEach(FilenameDisplaySize.allCases) { size in
            Text(size.title).tag(size)
          }
        }
      }
      Button("이미지 정보 패널") { store.toggleInspector(.information) }
      Button("이미지 편집 패널") { store.toggleInspector(.editing) }
    }

    CommandMenu("이미지") {
      Button("왼쪽으로 회전") { store.rotateCounterclockwise() }
      Button("오른쪽으로 회전") { store.rotateClockwise() }
      Button("조정 초기화") { store.resetAdjustments() }
      Divider()
      Button("내보내기…  \(shortcuts.binding(for: .exportImage).displayText)") {
        store.exportCurrentImage()
      }
      .disabled(store.currentAsset == nil)
    }

    CommandMenu("확대/축소") {
      Button("확대  \(shortcuts.binding(for: .zoomIn).displayText)") { store.zoomIn() }
      Button("축소  \(shortcuts.binding(for: .zoomOut).displayText)") { store.zoomOut() }
      Divider()
      Button("화면 맞춤  \(shortcuts.binding(for: .fitToWindow).displayText)") {
        store.setFitToWindow()
      }
      Button("실제 크기  \(shortcuts.binding(for: .actualPixels).displayText)") {
        store.setActualPixels()
      }
    }
  }
}
