import SwiftUI

struct AppCommands: Commands {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("열기…") { store.chooseItems() }
        .keyboardShortcut(shortcuts.binding(for: .openFolder).menuShortcut)
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
      Menu("전자 앨범") {
        SlideshowMenuItems(store: store, shortcuts: shortcuts)
      }
      Divider()
      Toggle("폴더 트리 표시", isOn: $store.showsFolderTree)
      Menu("썸네일 패널 위치") {
        ForEach(ThumbnailPanelPlacement.quickSelectionOrder) { placement in
          Button {
            store.thumbnailPanelPlacement = placement
          } label: {
            Label(
              placement.menuTitle,
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
      Toggle("몽땅보기 번호 표시", isOn: $store.showsOverviewNumbers)
      Button("이미지 정보 패널") { store.toggleInspector(.information) }
      Button("이미지 편집 패널") { store.toggleInspector(.editing) }
    }

    CommandMenu("이미지 비교") {
      if store.presentationMode != .folderComparison {
        Button("비교할 폴더 선택…") {
          store.presentationMode = .folderComparison
          store.folderComparison.choosePair()
        }
        .disabled(store.folderComparison.first.isLocked || store.folderComparison.second.isLocked)
        Divider()
      }
      Button(L10n.format("%@  %@", ShortcutAction.toggleFolderComparison.title,
        shortcuts.binding(for: .toggleFolderComparison).displayText)) { store.toggleFolderComparison() }
      if store.presentationMode == .folderComparison {
        FolderComparisonMenuItems(comparison: store.folderComparison, shortcuts: shortcuts)
      }
    }

    CommandMenu("이미지") {
      Group {
      Button("AI 확대…") {
        store.pauseSlideshow()
        store.showsAIUpscaling = true
      }
      .disabled(store.currentAsset == nil || store.isBatchBusy)
      Divider()
      Button(L10n.format("%@…  %@", ShortcutAction.setWallpaper.title,
        shortcuts.binding(for: .setWallpaper).displayText)) {
        store.presentWallpaperSettings()
      }
      .disabled(!store.canSetWallpaper)
      Divider()
      Button("모두 선택") { store.selectAllAssets() }
        .disabled(store.assets.isEmpty || store.batchSheet != nil || store.isBatchBusy)
      Button("선택 해제") { store.clearSelection() }
        .disabled(store.selectedURLs.isEmpty || store.batchSheet != nil || store.isBatchBusy)
      Button("이름 일괄 변경…") { store.presentBatchRename() }
        .disabled(!store.canStartBatchOperation || store.selectedAssets.contains(where: \.isReadOnly))
      Button("형식 일괄 변환…") { store.presentBatchExport() }
        .disabled(!store.canStartBatchOperation || ExportFormat.available.isEmpty)
      Divider()
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
      }.disabled(store.presentationMode == .folderComparison)
    }

    CommandMenu("확대/축소") {
      Menu("확대 이미지 이동") {
        PanModeMenuItems(store: store, shortcuts: shortcuts)
      }
      Menu("고화질 확대 및 비교") {
        MagnificationMenuItems(store: store, shortcuts: shortcuts)
      }
      Divider()
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
