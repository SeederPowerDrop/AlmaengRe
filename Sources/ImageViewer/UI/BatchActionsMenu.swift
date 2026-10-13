import SwiftUI

/// 몽땅보기와 좁은 썸네일 패널에서 같은 선택 작업을 제공합니다.
struct BatchActionsMenu: View {
  @ObservedObject var store: AppStore
  var compact = false

  var body: some View {
    Menu {
      FileOperationMenuItems(store: store)
      Divider()

      Button {
        store.presentBatchRename()
      } label: {
        Label(L10n.text("이름 일괄 변경…"), systemImage: "pencil.line")
      }
      .disabled(!store.canStartBatchOperation || store.selectedAssets.contains(where: \.isReadOnly))

      Button {
        store.presentBatchExport()
      } label: {
        Label(BatchActionsL10n.text("export.menu"), systemImage: "photo.on.rectangle.angled")
      }
      .disabled(!store.canExportBatchImages() || ExportFormat.available.isEmpty)

      Button { store.presentWatermark() } label: {
        Label(WatermarkL10n.text("menu"), systemImage: "signature")
      }.disabled(!store.canExportBatchImages() || ExportFormat.available.isEmpty)

      Button { store.shareSelectedFiles() } label: {
        Label(BatchActionsL10n.text("share.menu"), systemImage: "square.and.arrow.up")
      }
      .disabled(!store.canStartBatchOperation)

      Divider()

      Button(L10n.text("모두 선택")) {
        store.selectAllAssets()
      }
      .disabled(store.assets.isEmpty || store.isBatchBusy)

      Button(L10n.text("선택 해제")) {
        store.clearSelection()
      }
      .disabled(store.selectedURLs.isEmpty || store.isBatchBusy)
    } label: {
      if compact {
        Image(systemName: "ellipsis.circle")
      } else {
        Label(L10n.format("%d개 선택", store.selectedURLs.count), systemImage: "checkmark.circle")
          .monospacedDigit()
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel(L10n.text("선택한 사진 작업"))
    .accessibilityValue(L10n.format("%d개 선택", store.selectedURLs.count))
    .help(L10n.text("⌘ 클릭으로 추가 선택, ⇧ 클릭으로 범위 선택"))
  }
}

/// Keep file management in one compact menu alongside the image tools.
struct BatchQuickActionsView: View {
  enum Layout { case labels, icons, twoRows }

  @ObservedObject var store: AppStore
  var layout: Layout = .labels

  private enum Action: String, CaseIterable {
    case rename, export, watermark, share

    var symbol: String {
      switch self {
      case .rename: "pencil.line"
      case .export: "photo.on.rectangle.angled"
      case .watermark: "signature"
      case .share: "square.and.arrow.up"
      }
    }

    var title: String { BatchActionsL10n.text("quick.\(rawValue)") }
  }

  var body: some View {
    Group {
      if layout == .twoRows {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
          GridRow { actionButton(.rename); actionButton(.export) }
          GridRow { actionButton(.watermark); actionButton(.share) }
          GridRow { fileManagementMenu.gridCellColumns(2) }
        }
      } else {
        HStack(spacing: 6) {
          ForEach(Action.allCases, id: \.self) { actionButton($0) }
          fileManagementMenu
        }
      }
    }
    .buttonStyle(ViewerActionButtonStyle())
    .fixedSize(horizontal: true, vertical: true)
  }

  private var fileManagementMenu: some View {
    Menu {
      FileOperationMenuItems(store: store)
    } label: {
      Group {
        if layout == .labels {
          Label(FileOperationsL10n.text("menu.title"), systemImage: "folder.badge.gearshape")
        } else {
          Image(systemName: "folder.badge.gearshape").frame(width: 16)
        }
      }
      .lineLimit(1)
      .frame(height: 38)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(!store.canPerformFileOperation(.copy))
    .help(FileOperationsL10n.text("menu.title"))
    .accessibilityLabel(FileOperationsL10n.text("menu.title"))
    .accessibilityIdentifier("batch.quick.files")
  }

  private func actionButton(_ action: Action) -> some View {
    Button {
      switch action {
      case .rename: store.presentBatchRename()
      case .export: store.presentBatchExport()
      case .watermark: store.presentWatermark()
      case .share: store.shareSelectedFiles()
      }
    } label: {
      Group {
        if layout == .labels {
          Label(action.title, systemImage: action.symbol)
        } else {
          Image(systemName: action.symbol)
            .frame(width: 16)
        }
      }
      .lineLimit(1)
      .frame(height: 38)
    }
    .disabled(isDisabled(action))
    .help(action.title)
    .accessibilityLabel(action.title)
    .accessibilityIdentifier("batch.quick.\(action.rawValue)")
  }

  private func isDisabled(_ action: Action) -> Bool {
    switch action {
    case .rename:
      !store.canStartBatchOperation || store.selectedAssets.contains(where: \.isReadOnly)
    case .export, .watermark:
      !store.canExportBatchImages() || ExportFormat.available.isEmpty
    case .share:
      !store.canStartBatchOperation
    }
  }
}

/// 이미 선택한 사진에서는 전체 선택을 유지하고, 다른 사진에서는 해당 사진을 대상으로 합니다.
struct BatchAssetContextMenu: View {
  @ObservedObject var store: AppStore
  let url: URL

  var body: some View {
    FileOperationMenuItems(store: store, contextURL: url)
    Divider()

    Button {
      guard store.prepareBatchContextSelection(url: url) else { return }
      store.presentBatchRename()
    } label: {
      Label(L10n.text("이름 일괄 변경…"), systemImage: "pencil.line")
    }
    .disabled(!store.canStartBatchOperation(urls: [url]) || isReadOnlySelection)

    Button {
      guard store.prepareBatchContextSelection(url: url) else { return }
      store.presentBatchExport()
    } label: {
      Label(BatchActionsL10n.text("export.menu"), systemImage: "photo.on.rectangle.angled")
    }
    .disabled(!store.canExportBatchImages(urls: store.selectedURLs.contains(url) ? store.selectedURLs : [url]))

    Button {
      guard store.prepareBatchContextSelection(url: url) else { return }
      store.presentWatermark()
    } label: {
      Label(WatermarkL10n.text("menu"), systemImage: "signature")
    }.disabled(!store.canExportBatchImages(urls: store.selectedURLs.contains(url) ? store.selectedURLs : [url]))

    if store.currentAsset?.url == url && store.canOpenMotionMedia {
      Button(MotionMediaL10n.text("editor.open")) { store.presentMotionMedia() }
    }

    Button {
      guard store.prepareBatchContextSelection(url: url) else { return }
      store.shareSelectedFiles()
    } label: {
      Label(BatchActionsL10n.text("share.menu"), systemImage: "square.and.arrow.up")
    }
    .disabled(!store.canStartBatchOperation(urls: [url]))
  }

  private var isReadOnlySelection: Bool {
    guard let asset = store.assets.first(where: { $0.url == url }) else { return true }
    return asset.isReadOnly || (store.selectedURLs.contains(asset.url)
      && store.selectedAssets.contains(where: \.isReadOnly))
  }
}

/// A context action keeps an existing multi-selection when its item is already selected.
struct FileOperationMenuItems: View {
  @ObservedObject var store: AppStore
  var contextURL: URL? = nil

  var body: some View {
    action(.copy, key: "copy.menu", symbol: "doc.on.doc")
    action(.move, key: "move.menu", symbol: "folder")
    action(.trash, key: "trash.menu", symbol: "trash")
  }

  private var targetURLs: Set<URL>? {
    guard let contextURL else { return nil }
    return store.selectedURLs.contains(contextURL) ? store.selectedURLs : [contextURL]
  }

  private func action(_ operation: BatchFileOperation, key: String, symbol: String) -> some View {
    Button(role: operation == .trash ? .destructive : nil) {
      if let contextURL, !store.prepareBatchContextSelection(url: contextURL) { return }
      store.presentFileOperation(operation)
    } label: {
      Label(FileOperationsL10n.text(key), systemImage: symbol)
    }
    .disabled(!store.canPerformFileOperation(operation, urls: targetURLs))
  }
}

/// Map actions use the explicitly indicated area or pin, never a hidden thumbnail selection.
struct MapBatchActionsMenu: View {
  @ObservedObject var store: AppStore
  let urls: Set<URL>
  let title: String

  var body: some View {
    Menu {
      Button(L10n.text("이름 일괄 변경…")) { store.presentBatchRename(urls: urls) }
        .disabled(store.batchTargets(urls: urls).contains(where: \.isReadOnly))
      Button(BatchActionsL10n.text("export.menu")) { store.presentBatchExport(urls: urls) }
        .disabled(!store.canExportBatchImages(urls: urls) || ExportFormat.available.isEmpty)
      Button(WatermarkL10n.text("menu")) { store.presentWatermark(urls: urls) }
        .disabled(!store.canExportBatchImages(urls: urls) || ExportFormat.available.isEmpty)
      Button(BatchActionsL10n.text("share.menu")) { store.shareSelectedFiles(urls: urls) }
    } label: {
      Label(title, systemImage: "ellipsis.circle")
    }
    .disabled(!store.canStartBatchOperation(urls: urls))
  }
}
