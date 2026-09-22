import SwiftUI

/// 몽땅보기와 좁은 썸네일 패널에서 같은 선택 작업을 제공합니다.
struct BatchActionsMenu: View {
  @ObservedObject var store: AppStore
  var compact = false

  var body: some View {
    Menu {
      Button {
        store.presentBatchRename()
      } label: {
        Label(L10n.text("이름 일괄 변경…"), systemImage: "pencil.line")
      }
      .disabled(!store.canStartBatchOperation)

      Button {
        store.presentBatchExport()
      } label: {
        Label(L10n.text("형식 일괄 변환…"), systemImage: "photo.on.rectangle.angled")
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

/// 이미 선택한 사진에서는 전체 선택을 유지하고, 다른 사진에서는 해당 사진을 대상으로 합니다.
struct BatchAssetContextMenu: View {
  @ObservedObject var store: AppStore
  let index: Int

  var body: some View {
    Button {
      prepareSelection()
      store.presentBatchRename()
    } label: {
      Label(L10n.text("이름 일괄 변경…"), systemImage: "pencil.line")
    }
    .disabled(store.isBatchBusy || store.isLoading)

    Button {
      prepareSelection()
      store.presentBatchExport()
    } label: {
      Label(L10n.text("형식 일괄 변환…"), systemImage: "photo.on.rectangle.angled")
    }
    .disabled(store.isBatchBusy || store.isLoading)
  }

  private func prepareSelection() {
    guard store.assets.indices.contains(index) else { return }
    if !store.selectedURLs.contains(store.assets[index].url) {
      store.selectForBatch(index: index, modifiers: [])
    }
  }
}
