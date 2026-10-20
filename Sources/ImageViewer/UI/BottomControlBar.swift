import SwiftUI

/// 사진 위를 가리지 않는 고정 조작부. 탐색과 확대를 각각 묶어 위치를 예측할 수 있게 합니다.
struct BottomControlBar: View {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore
  var onHideControls: (() -> Void)? = nil

  var body: some View {
    ViewThatFits(in: .horizontal) {
      controls(compact: false)
      controls(compact: true)
    }
    .viewerPadding(.horizontal, 12)
    .viewerPadding(.vertical, 8)
    .background(ViewerTheme.chromeGradient)
  }

  private func controls(compact: Bool) -> some View {
    VStack(spacing: 6) {
      HStack(spacing: 6) {
        returnButton
        separator
        HStack(spacing: 2) {
          Button { store.navigatePage(-1) } label: { Image(systemName: "chevron.left") }
            .help(pageNavigationHelp(direction: -1))
          Text(store.positionDescription)
            .font(ViewerUIMetrics.font(size: 11, weight: .medium).monospacedDigit())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: ViewerUIMetrics.scale(58))
          Button { store.navigatePage(1) } label: { Image(systemName: "chevron.right") }
            .help(pageNavigationHelp(direction: 1))
        }
        .modifier(ViewerControlGroup())
        if store.isFocusMode && store.visibleAssets.count > 1 {
          ViewerFrameLayoutMenu(layout: store.frameLayout, count: store.visibleAssets.count)
        }
        Spacer(minLength: 12)
        HStack(spacing: 2) {
          Button { store.zoomOut() } label: { Image(systemName: "minus") }.help("축소")
          if !compact {
            Slider(value: $store.zoom, in: 0.1...8)
              .frame(width: ViewerUIMetrics.scale(96))
              .accessibilityLabel("확대/축소")
          }
          Text("\(Int(store.zoom * 100))%")
            .font(ViewerUIMetrics.font(size: 11).monospacedDigit())
            .frame(minWidth: ViewerUIMetrics.scale(42))
          Button { store.zoomIn() } label: { Image(systemName: "plus") }.help("확대")
        }
        .modifier(ViewerControlGroup())
        separator
        fitControls(compact: compact)
        if !compact { separator; detailControls }
      }
      .fixedSize(horizontal: false, vertical: true)
      if compact {
        HStack(spacing: 10) {
          fileSummary
          Spacer(minLength: 8)
          detailControls
        }
      }
      if store.isFocusMode {
        Divider()
        SlideshowPlaybackControls(store: store)
          .viewerPadding(.top, 4)
      }
    }
    .buttonStyle(ViewerToolButtonStyle())
  }

  private func fitControls(compact: Bool) -> some View {
    HStack(spacing: 2) {
      ImageFitMenu(mode: store.baseScaleMode, zoom: store.zoom,
        isFrameLimited: store.isMultiImageViewer, identifier: "viewer.fitOptions",
        setMode: store.setScaleMode, center: store.centerImage)
      if !store.isMultiImageViewer {
        Button { store.setActualPixels() } label: { Text(verbatim: "1:1") }
          .help("실제 픽셀 크기")
      }
    }
  }

  private func pageNavigationHelp(direction: Int) -> String {
    if store.presentationMode == .viewer, store.imagesPerPage > 1,
      let binding = shortcuts.viewerPageBinding(direction: direction) {
      let pageHelp = L10n.format(direction < 0 ? "이전 %d장 보기 (%@)" : "다음 %d장 보기 (%@)",
        store.imagesPerPage, "\u{2066}\(binding.displayText)\u{2069}")
      guard let selectionHelp = ViewerNavigationHintText.selectionHelp(shortcuts: shortcuts) else {
        return pageHelp
      }
      return pageHelp + "\n" + selectionHelp
    }
    return L10n.text(direction < 0 ? "이전 이미지/페이지" : "다음 이미지/페이지")
  }

  @ViewBuilder private var returnButton: some View {
    if store.isFocusMode, let onHideControls {
      Button(action: onHideControls) { Image(systemName: "xmark") }
        .help("조작창 숨기기")
        .accessibilityLabel("조작창 숨기기")
    } else {
      navigationReturnButton
    }
  }

  private var navigationReturnButton: some View {
    Button {
      if store.comparisonLayout != .off { store.setComparisonLayout(.off) }
      else if store.isFocusMode { store.exitFocusMode() }
      else { store.returnToOverview() }
    } label: {
      Image(systemName: store.comparisonLayout != .off || store.isFocusMode
        ? "xmark" : "square.grid.2x2")
    }
    .help(L10n.text(store.comparisonLayout != .off ? "비교 끄기"
      : store.isFocusMode ? "집중 보기 종료 (Esc)" : "몽땅보기로 돌아가기 (Esc)"))
  }

  private var fileSummary: some View {
    HStack(spacing: 8) {
      if let asset = store.currentAsset {
        Text(asset.fileExtension.uppercased())
        Text(asset.formattedFileSize)
      }
    }
    .font(ViewerUIMetrics.font(size: 10)).foregroundStyle(.secondary)
    .lineLimit(1)
  }

  private var separator: some View { Divider().frame(height: ViewerUIMetrics.scale(18)).viewerPadding(.horizontal, 3) }

  @ViewBuilder private var detailControls: some View {
    Menu {
      PanModeMenuItems(store: store, shortcuts: shortcuts)
    } label: {
      Image(systemName: "hand.draw")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help(L10n.format("팬 조작: %@", store.panInteractionMode.title))

    Menu {
      MagnificationMenuItems(store: store, shortcuts: shortcuts)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: store.isAntialiasingEnabled ? "checkmark" : "circle")
        Text("고화질 확대")
      }
      .font(ViewerUIMetrics.font(size: 11, weight: .medium))
      .foregroundStyle(store.isAntialiasingEnabled ? ViewerTheme.accent : Color.secondary)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("고화질 확대 및 비교")
    .accessibilityLabel("고화질 확대 및 비교")
  }
}
