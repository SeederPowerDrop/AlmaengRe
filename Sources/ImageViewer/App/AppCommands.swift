import SwiftUI

struct AppCommands: Commands {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button(
        L10n.format(
          "%@…  %@", ShortcutAction.openFolder.title,
          shortcuts.binding(for: .openFolder).displayText)
      ) {
        store.chooseFolder()
      }
      Button("이미지 파일 열기…") {
        store.chooseFiles()
      }
    }

    CommandMenu("탐색") {
      Button(
        L10n.format(
          "%@  %@", ShortcutAction.previousPage.title,
          shortcuts.binding(for: .previousPage).displayText)
      ) {
        store.navigatePage(-1)
      }
      Button(
        L10n.format(
          "%@  %@", ShortcutAction.nextPage.title, shortcuts.binding(for: .nextPage).displayText)
      ) {
        store.navigatePage(1)
      }
      Divider()
      Button(
        L10n.format(
          "%@  %@", ShortcutAction.toggleOverview.title,
          shortcuts.binding(for: .toggleOverview).displayText)
      ) {
        store.toggleOverview()
      }
      Button(
        L10n.format(
          "%@  %@", ShortcutAction.toggleFocus.title,
          shortcuts.binding(for: .toggleFocus).displayText)
      ) {
        store.toggleFocusMode()
      }
      Button("전체 화면") {
        store.toggleFullScreen()
      }
      .keyboardShortcut("f", modifiers: [.command, .control])
      Divider()
      Menu("썸네일 패널 위치") {
        ForEach(ThumbnailPanelPlacement.quickSelectionOrder) { placement in
          Button {
            store.thumbnailPanelPlacement = placement
          } label: {
            Label(
              placement.title,
              systemImage: store.thumbnailPanelPlacement == placement
                ? "checkmark" : placement.systemImage
            )
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
      Button(
        L10n.format(
          "%@…  %@", ShortcutAction.exportImage.title,
          shortcuts.binding(for: .exportImage).displayText)
      ) {
        store.exportCurrentImage()
      }
      .disabled(store.currentAsset == nil)
    }

    CommandMenu("확대/축소") {
      Button(
        L10n.format(
          "%@  %@", ShortcutAction.zoomIn.title, shortcuts.binding(for: .zoomIn).displayText)
      ) { store.zoomIn() }
      Button(
        L10n.format(
          "%@  %@", ShortcutAction.zoomOut.title, shortcuts.binding(for: .zoomOut).displayText)
      ) { store.zoomOut() }
      Divider()
      Button(
        L10n.format(
          "%@  %@", ShortcutAction.fitToWindow.title,
          shortcuts.binding(for: .fitToWindow).displayText)
      ) {
        store.setFitToWindow()
      }
      Button(
        L10n.format(
          "%@  %@", ShortcutAction.actualPixels.title,
          shortcuts.binding(for: .actualPixels).displayText)
      ) {
        store.setActualPixels()
      }
    }
  }
}
