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
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
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
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 58)
          Button { store.navigatePage(1) } label: { Image(systemName: "chevron.right") }
            .help(pageNavigationHelp(direction: 1))
        }
        .modifier(ViewerControlGroup())
        Spacer(minLength: 12)
        HStack(spacing: 2) {
          Button { store.zoomOut() } label: { Image(systemName: "minus") }.help("축소")
          if !compact {
            Slider(value: $store.zoom, in: 0.1...8)
              .frame(width: 96)
              .accessibilityLabel("확대/축소")
          }
          Text("\(Int(store.zoom * 100))%")
            .font(.system(size: 11).monospacedDigit())
            .frame(minWidth: 42)
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
          .padding(.top, 4)
      }
    }
    .buttonStyle(ViewerToolButtonStyle())
  }

  private func fitControls(compact: Bool) -> some View {
    HStack(spacing: 2) {
      Button { store.setFitToWindow() } label: {
        if compact { Image(systemName: "arrow.down.right.and.arrow.up.left") }
        else {
          Text(verbatim: L10n.text(store.isMultiImageViewer ? "프레임 맞춤" : "화면 맞춤"))
            .fixedSize(horizontal: true, vertical: false)
        }
      }
      .help(L10n.text(store.isMultiImageViewer
        ? "각 이미지를 주어진 프레임 안에 맞춥니다." : "이미지 전체를 화면 안에 맞춥니다."))
      .accessibilityLabel(L10n.text(store.isMultiImageViewer ? "프레임 맞춤" : "화면 맞춤"))
      .accessibilityIdentifier("viewer.fit")
      Menu {
        Button(L10n.text(store.isMultiImageViewer ? "프레임 맞춤" : "화면 맞춤")) {
          store.setFitToWindow()
        }
        if !store.isMultiImageViewer {
          Button(L10n.text("가로 맞춤")) { store.setScaleMode(.fitWidth) }
            .help(L10n.text("이미지 너비를 화면에 맞춥니다."))
          Button(L10n.text("세로 맞춤")) { store.setScaleMode(.fitHeight) }
            .help(L10n.text("이미지 높이를 화면에 맞춥니다."))
          Divider()
        }
        Button(L10n.text("가운데 정렬")) { store.centerImage() }
          .help(L10n.text("확대 배율을 유지하고 이미지를 가운데로 옮깁니다."))
      } label: {
        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
          .frame(width: 18, height: 24)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help(L10n.text("맞춤 옵션"))
      .accessibilityLabel(L10n.text("맞춤 옵션"))
      .accessibilityIdentifier("viewer.fitOptions")
      if !store.isMultiImageViewer {
        Button { store.setActualPixels() } label: { Text(verbatim: "1:1") }
          .help("실제 픽셀 크기")
      }
    }
  }

  private func pageNavigationHelp(direction: Int) -> String {
    if store.presentationMode == .viewer, store.imagesPerPage > 1,
      let binding = shortcuts.viewerPageBinding(direction: direction) {
      return L10n.format(direction < 0 ? "이전 %d장 보기 (%@)" : "다음 %d장 보기 (%@)",
        store.imagesPerPage, binding.displayText)
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
    .font(.system(size: 10)).foregroundStyle(.secondary)
    .lineLimit(1)
  }

  private var separator: some View { Divider().frame(height: 18).padding(.horizontal, 3) }

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
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(store.isAntialiasingEnabled ? ViewerTheme.accent : Color.secondary)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("고화질 확대 및 비교")
    .accessibilityLabel("고화질 확대 및 비교")
  }
}
