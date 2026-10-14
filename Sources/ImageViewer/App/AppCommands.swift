import SwiftUI

struct AppCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore
  @ObservedObject var appearance: AppearanceStore
  @ObservedObject var language: LanguageStore
  @ObservedObject private var comparison: FolderComparisonStore

  init(store: AppStore, shortcuts: ShortcutStore, appearance: AppearanceStore, language: LanguageStore) {
    self.store = store
    self.shortcuts = shortcuts
    self.appearance = appearance
    self.language = language
    self.comparison = store.folderComparison
  }

  var body: some Commands {
    CommandMenu(LanguageSettings.text("menu")) {
      Picker(LanguageSettings.text("menu"), selection: $language.selection) {
        Text(verbatim: LanguageSettings.text("system")).tag("system")
        Divider()
        ForEach(L10n.supportedLocalizations, id: \.self) { identifier in
          Text(verbatim: LanguageSettings.languageName(for: identifier)).tag(identifier)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
      .accessibilityIdentifier("app.language")
    }

    CommandGroup(after: .toolbar) {
      Divider()
      Picker(L10n.text("appearance.title"), selection: $appearance.mode) {
        ForEach(AppAppearance.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
    }

    CommandGroup(replacing: .appInfo) {
      Button(L10n.text("알맹Re 정보")) {
        store.pauseSlideshow()
        openWindow(id: AboutView.windowID)
      }
    }

    CommandGroup(replacing: .help) {
      Button(L10n.text("기본 사용법")) {
        store.pauseSlideshow()
        openWindow(id: BasicUsageView.windowID)
      }
      Button(L10n.text("상세 사용설명서 (GitHub)")) {
        store.pauseSlideshow()
        UserGuide.openDetailedGuide()
      }
      Divider()
      Button(L10n.text("앱 소개")) {
        store.pauseSlideshow()
        openWindow(id: AboutView.windowID)
      }
    }

    CommandGroup(replacing: .newItem) {
      Button(L10n.text("열기…")) { store.chooseItems() }
        .keyboardShortcut(shortcuts.binding(for: .openFolder).menuShortcut)
        .disabled(!store.canOpenFolderFromTree)
      Button(L10n.text("home.show")) { store.showHome() }
        .disabled(!store.canShowHome)
      Button(L10n.text("home.resume")) { Task { await store.resumeWorkspace() } }
        .disabled(!store.showsHome || !store.canResumeWorkspace || !store.canShowHome)
    }

    CommandMenu(L10n.text("탐색")) {
      Group {
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
        Button(L10n.text("전체 화면")) {
          store.toggleFullScreen()
        }
        .keyboardShortcut("f", modifiers: [.command, .control])
        Menu(L10n.text("전자 앨범")) {
          SlideshowMenuItems(store: store, shortcuts: shortcuts)
        }
        Divider()
        Toggle(L10n.text("폴더 트리 표시"), isOn: $store.showsFolderTree)
        Toggle(MotionMediaL10n.text("showVideos"), isOn: $store.showsVideos)
          .disabled(!store.canOpenFolderFromTree)
        Menu(L10n.text("썸네일 패널 위치")) {
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
        Menu(L10n.text("파일 이름 표시")) {
          Picker(L10n.text("크기"), selection: $store.filenameDisplaySize) {
            ForEach(FilenameDisplaySize.allCases) { size in
              Text(size.title).tag(size)
            }
          }
        }
        Toggle(L10n.text("몽땅보기 번호 표시"), isOn: $store.showsOverviewNumbers)
        Button(L10n.text("이미지 정보 패널")) { store.toggleInspector(.information) }
        Button(L10n.text("이미지 편집 패널")) { store.toggleInspector(.editing) }
      }.disabled(store.isVideoFullScreenPresented || store.showsHome || comparison.isEditingNames)
    }

    CommandMenu(PhotoMarkL10n.text("menu.title")) {
      Group {
        Toggle(PhotoMarkL10n.text("mode.toggle"), isOn: Binding(
          get: { store.isPhotoMarking },
          set: { _ in store.togglePhotoMarking() }))
          .keyboardShortcut("m", modifiers: [.command, .shift])
          .disabled(!store.canTogglePhotoMarking)
        Button(PhotoMarkL10n.text("menu.edit")) {
          store.presentPhotoMarkEditor()
        }
        .disabled(!store.canEditPhotoMarkLabels)
        Button(BatchActionsL10n.text("report.menu")) { store.showsPhotoMarkTrackingReport = true }
          .disabled(!store.canEditPhotoMarkLabels)
        Divider()
        ForEach(PhotoMarkSlot.allCases, id: \.self) { slot in
          let state = store.photoMarkSelectionState(for: slot)
          Toggle(isOn: Binding(
            get: { store.photoMarkSelectionState(for: slot) == .all },
            set: { _ in store.togglePhotoMark(slot) }
          )) {
            PhotoMarkMenuLabel(name: "\(state == .mixed ? "− " : "")\(slot.keyLabel)  \(store.photoMarks.label(for: slot))",
              color: store.photoMarks.color(for: slot))
          }
          .disabled(!store.canMarkPhoto)
          .accessibilityValue(state == .mixed ? PhotoMarkL10n.text("target.mixed")
            : L10n.text(state == .all ? "선택됨" : "선택 안 됨"))
        }
      }.disabled(store.showsHome || comparison.isEditingNames)
    }

    CommandMenu(L10n.text("이미지 비교")) {
      Group {
        if store.presentationMode != .folderComparison {
          Button(L10n.text("비교할 폴더 선택…")) {
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
      }.disabled(store.isVideoFullScreenPresented || store.showsHome || comparison.isEditingNames)
    }

    CommandMenu(L10n.text("이미지")) {
      Group {
      Button(L10n.text("AI 확대…")) {
        store.pauseSlideshow()
        store.showsAIUpscaling = true
      }
      .disabled(store.currentAsset == nil || store.currentAsset?.isVideo == true || store.motionMediaAsset != nil || store.isBatchBusy)
      Divider()
      Button(L10n.format("%@…  %@", ShortcutAction.setWallpaper.title,
        shortcuts.binding(for: .setWallpaper).displayText)) {
        store.presentWallpaperSettings()
      }
      .disabled(!store.canSetWallpaper)
      Divider()
      Button(L10n.text("모두 선택")) { store.selectAllAssets() }
        .disabled(store.assets.isEmpty || store.batchSheet != nil || store.isBatchBusy)
      Button(L10n.text("선택 해제")) { store.clearSelection() }
        .disabled(store.selectedURLs.isEmpty || store.batchSheet != nil || store.isBatchBusy)
      Divider()
      Button(FileOperationsL10n.text("copy.menu")) { store.presentFileOperation(.copy) }
        .disabled(!store.canPerformFileOperation(.copy))
      Button(FileOperationsL10n.text("move.menu")) { store.presentFileOperation(.move) }
        .disabled(!store.canPerformFileOperation(.move))
      Button(FileOperationsL10n.text("trash.menu"), role: .destructive) {
        store.presentFileOperation(.trash)
      }
      .keyboardShortcut(.delete, modifiers: .command)
      .disabled(!store.canPerformFileOperation(.trash))
      Divider()
      Button(L10n.text("이름 일괄 변경…")) { store.presentBatchRename() }
        .disabled(!store.canStartBatchOperation || store.selectedAssets.contains(where: \.isReadOnly))
      Button(BatchActionsL10n.text("export.menu")) { store.presentBatchExport() }
        .disabled(!store.canExportBatchImages() || ExportFormat.available.isEmpty)
      Button(WatermarkL10n.text("menu")) { store.presentWatermark() }
        .disabled(!store.canExportBatchImages() || ExportFormat.available.isEmpty)
      Button(MotionMediaL10n.text("editor.open")) { store.presentMotionMedia() }
        .disabled(!store.canOpenMotionMedia)
      Divider()
      Button(BatchActionsL10n.text("share.menu")) { store.shareSelectedFiles() }
        .disabled(!store.canStartBatchOperation)
      Divider()
      Button(L10n.text("왼쪽으로 회전")) { store.rotateCounterclockwise() }
      Button(L10n.text("오른쪽으로 회전")) { store.rotateClockwise() }
      Button(L10n.text("좌우 반전하기")) { store.flipHorizontally() }
        .disabled(store.currentAsset == nil)
      Button(L10n.text("상하 반전하기")) { store.flipVertically() }
        .disabled(store.currentAsset == nil)
      Button(L10n.text("조정 초기화")) { store.resetAdjustments() }
      Divider()
      Button(
        L10n.format(
          "%@…  %@", ShortcutAction.exportImage.title,
          shortcuts.binding(for: .exportImage).displayText)
      ) {
        store.exportCurrentImage()
      }
      .disabled(store.currentAsset == nil || store.currentAsset?.isVideo == true)
      }.disabled(store.isVideoFullScreenPresented || store.showsHome || store.presentationMode == .folderComparison)
    }

    CommandMenu(L10n.text("확대/축소")) {
      Group {
        Menu(L10n.text("확대 이미지 이동")) {
          PanModeMenuItems(store: store, shortcuts: shortcuts)
        }
        Menu(L10n.text("고화질 확대 및 비교")) {
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
            "%@  %@", store.isMultiImageViewer ? L10n.text("프레임 맞춤") : ShortcutAction.fitToWindow.title,
            shortcuts.binding(for: .fitToWindow).displayText)
        ) {
          store.setFitToWindow()
        }
        if !store.isMultiImageViewer {
          Button(L10n.text("가로 맞춤")) { store.setScaleMode(.fitWidth) }
          Button(L10n.text("세로 맞춤")) { store.setScaleMode(.fitHeight) }
        }
        Button(L10n.text("가운데 정렬")) { store.centerImage() }
        if !store.isMultiImageViewer {
          Button(
            L10n.format(
              "%@  %@", ShortcutAction.actualPixels.title,
              shortcuts.binding(for: .actualPixels).displayText)
          ) {
            store.setActualPixels()
          }
        }
      }.disabled(store.isVideoFullScreenPresented || store.showsHome || comparison.isEditingNames)
    }
  }
}
