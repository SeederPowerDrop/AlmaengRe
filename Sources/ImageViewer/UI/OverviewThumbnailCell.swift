import AppKit
import SwiftUI

/// 썸네일과 번호는 같은 디코딩 결과를 공유합니다. URL로 식별되는 셀 안에서만
/// 픽셀 크기를 기억하므로 폴더 전환이나 늦은 로딩 결과가 다른 셀에 섞이지 않습니다.
struct OverviewThumbnailCell: View {
  @ObservedObject var store: AppStore
  let index: Int
  let asset: ImageAsset
  let size: CGFloat
  var isAdjustingSize = false
  var defersLoadingForOcclusion = false
  var defersRefinement = false
  var overviewRefinementGate: OverviewRefinementGate? = nil
  var onBitmapStateApplied: (@MainActor (ThumbnailBitmapStateEvent) -> Void)? = nil
  var currentIndexForAsset: (@MainActor (URL) -> Int?)? = nil
  @Environment(\.displayScale) private var displayScale
  @State private var imagePixelSize: CGSize?
  @State private var isHovered = false

  private var isSelected: Bool { store.selectedURLs.contains(asset.url) }
  private var isCurrent: Bool { store.currentAsset?.url == asset.url }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      OverviewNumberedImageLayout(
        imageHeight: size, imagePixels: imagePixelSize, showsNumber: store.showsOverviewNumbers
      ) {
        ThumbnailImageView(
          asset: asset, thumbnailPipeline: store.thumbnailPipeline, pipeline: store.pipeline,
          maxPixelSize: OverviewThumbnailSizing.requestedPixelSize(for: size, displayScale: displayScale),
          adjustments: store.adjustments(for: asset), prefersPreciseImage: true,
          defersLoading: isAdjustingSize || defersLoadingForOcclusion, prefersCompactPreview: true,
          defersRefinement: defersRefinement,
          overviewRefinementGate: overviewRefinementGate,
          onDisplayedImageSizeChange: store.showsOverviewNumbers ? { size in
            if imagePixelSize != size { imagePixelSize = size }
          } : nil,
          onBitmapStateApplied: onBitmapStateApplied
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
          if asset.isPlaybackMedia {
            Image(systemName: asset.isAudio ? "waveform" : "play.fill")
              .font(ViewerUIMetrics.font(.caption).weight(.semibold)).foregroundStyle(.white)
              .viewerPadding(8).background(.black.opacity(0.7), in: Circle()).viewerPadding(6)
              .allowsHitTesting(false)
          }
        }

        // This URL-backed cell can survive an order change without recreation.
        // Read the current ordinal from the same lookup as viewport membership.
        Text("\((currentIndexForAsset?(asset.id) ?? index) + 1)")
          .font(ViewerUIMetrics.font(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(.white)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .viewerPadding(.horizontal, 6)
          .viewerPadding(.vertical, 3)
          .background(.black.opacity(0.85), in: Capsule())
          .opacity(store.showsOverviewNumbers ? 1 : 0)
          .accessibilityHidden(true)
      }

      HStack(spacing: 3) {
        if store.isPhotoMarking {
          PhotoMarkSelectionToggle(asset: asset, isSelected: isSelected) {
            selectCard(modifiers: .command)
          }
          .highPriorityGesture(modifiedSelectionGesture)
        }
        Text(asset.filename)
          .font(ViewerUIMetrics.font(size: 11, weight: isSelected ? .semibold : .medium))
          .foregroundStyle(Color.primary.opacity(isSelected ? 1 : 0.85))
          .lineLimit(1)
          .truncationMode(.middle)
        if isSelected && !store.isPhotoMarking {
          // 선택 표식도 작은 사진을 가리지 않도록 파일 이름 옆에 둡니다.
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(ViewerTheme.accent)
            .font(ViewerUIMetrics.font(.caption2))
            .accessibilityHidden(true)
        }
      }
      PhotoMarkThumbnailBadges(marks: store.photoMarks, asset: asset)
      if store.isPhotoMarking {
        PhotoMarkCardMenu(store: store, asset: asset)
          .font(ViewerUIMetrics.font(.caption))
      }
    }
    .padding(7)
    .background {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(ViewerTheme.panelGradient)
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isSelected ? ViewerTheme.selection : ViewerTheme.controlFill.opacity(isHovered ? 1 : 0))
        }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(
          isCurrent || isSelected ? ViewerTheme.selectionBorder
            : ViewerTheme.controlBorder.opacity(isHovered ? 1 : 0.65),
          style: StrokeStyle(lineWidth: isCurrent ? 2 : 1,
            dash: isCurrent && !isSelected ? [4, 3] : []))
        .allowsHitTesting(false)
    }
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .gesture(cardTapGesture)
    .contextMenu { BatchAssetContextMenu(store: store, url: asset.url) }
    .accessibilityElement(children: store.isPhotoMarking ? .contain : .ignore)
    .accessibilityLabel(asset.filename)
    .accessibilityIdentifier("overview.asset.\(asset.sessionID)")
    .accessibilityValue(accessibilityValue)
    .accessibilityActions {
      if asset.isAudio {
        Button(MotionMediaL10n.text("audio.play")) {
          store.openAudioForPlayback(asset)
        }
      } else if asset.isVideo {
        Button(MotionMediaL10n.text("video.fullscreen")) { store.openVideoFullScreen(asset) }
      }
    }
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction {
      selectCard(modifiers: [])
    }
  }

  /// Register modifier combinations explicitly. A plain SwiftUI tap does not
  /// reliably receive Command-click, and reading global flags after the
  /// double-click delay loses a modifier released immediately after mouse-up.
  private var modifiedSelectionGesture: some Gesture {
    TapGesture().modifiers([.command, .shift])
      .onEnded { selectCard(modifiers: [.command, .shift]) }
      .exclusively(before: TapGesture().modifiers(.shift)
        .onEnded { selectCard(modifiers: .shift) })
      .exclusively(before: TapGesture().modifiers(.command)
        .onEnded { selectCard(modifiers: .command) })
  }

  private var cardTapGesture: some Gesture {
    modifiedSelectionGesture.exclusively(before:
      TapGesture(count: 2).onEnded { openCard() }
        .exclusively(before: TapGesture().onEnded { selectCard(modifiers: []) }))
  }

  private func selectCard(modifiers: NSEvent.ModifierFlags) {
    focusCard()
    store.selectOverviewCard(url: asset.url, modifiers: modifiers)
  }

  private func openCard() {
    guard store.overviewSelectionSession == nil,
      store.selectOverviewCard(url: asset.url, modifiers: []) else { return }
    focusCard()
    if asset.isAudio { store.openAudioForPlayback(asset) }
    else if asset.isVideo { store.openVideoFullScreen(asset) }
    else { store.presentationMode = .viewer }
  }

  private func focusCard() {
    guard let window = NSApp.keyWindow, window.firstResponder is NSTextView else { return }
    window.makeFirstResponder(nil)
  }

  private var accessibilityValue: String {
    let selection = L10n.text(isSelected ? "선택됨" : "선택 안 됨")
      + (isCurrent ? ", " + BatchActionsL10n.text("selection.focused") : "")
    let assigned = store.photoMarks.marks(for: asset)
    let names = PhotoMarkSlot.allCases.filter { assigned.contains($0) }.map { slot in
      let name = store.photoMarks.label(for: slot)
      return name.isEmpty ? slot.keyLabel : name
    }
    guard !names.isEmpty else { return selection }
    return selection + ", " + PhotoMarkL10n.format("badge.accessibilityFormat", names.joined(separator: ", "))
  }
}

/// 실제 글자 크기로 배지 면적을 측정합니다. 외부 배지에는 독립된 윗줄을
/// 할당하므로 사진·파일 이름과 겹치지 않으며, 숨기면 그 줄도 사라집니다.
private struct OverviewNumberedImageLayout: Layout {
  let imageHeight: CGFloat
  let imagePixels: CGSize?
  let showsNumber: Bool

  private func metrics(width: CGFloat, subviews: Subviews) -> (badge: CGSize, image: CGSize?, top: CGFloat) {
    // Hidden numbers do not affect card geometry; avoid measuring an invisible
    // text subview for every intermediate grid width while the slider moves.
    guard showsNumber else { return (.zero, nil, 0) }
    let badge = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
    let image = OverviewNumberPlacement.fittedImageSize(
      pixels: imagePixels, in: CGSize(width: width, height: imageHeight))
    let outside = OverviewNumberPlacement.isOutside(badge: badge, image: image)
    return (badge, image, showsNumber && outside ? badge.height + 4 : 0)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = max(1, proposal.width ?? imageHeight)
    return CGSize(width: width, height: imageHeight + metrics(width: width, subviews: subviews).top)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let measured = metrics(width: bounds.width, subviews: subviews)
    subviews[0].place(
      at: CGPoint(x: bounds.minX, y: bounds.minY + measured.top), anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width, height: imageHeight))
    // 물리적 왼쪽 위 위치를 사용합니다. 세로 사진의 여백 대신 실제 이미지에 붙입니다.
    let inside = measured.top == 0 && showsNumber
    let image = measured.image ?? CGSize(width: bounds.width, height: imageHeight)
    subviews[1].place(
      at: CGPoint(
        x: bounds.minX + (inside ? (bounds.width - image.width) / 2 + 6 : 0),
        y: bounds.minY + (inside ? (imageHeight - image.height) / 2 + 6 : 0)),
      anchor: .topLeading, proposal: ProposedViewSize(measured.badge))
  }
}
