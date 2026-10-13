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
  @Environment(\.displayScale) private var displayScale
  @State private var imagePixelSize: CGSize?
  @State private var isHovered = false

  private var isSelected: Bool { store.selectedURLs.contains(asset.url) }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      OverviewNumberedImageLayout(
        imageHeight: size, imagePixels: imagePixelSize, showsNumber: store.showsOverviewNumbers
      ) {
        ThumbnailImageView(
          asset: asset, thumbnailPipeline: store.thumbnailPipeline, pipeline: store.pipeline,
          maxPixelSize: OverviewThumbnailSizing.requestedPixelSize(for: size, displayScale: displayScale),
          adjustments: store.adjustments(for: asset), prefersPreciseImage: true,
          defersLoading: isAdjustingSize,
          onDisplayedImageSizeChange: { imagePixelSize = $0 }
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
          if asset.isVideo {
            Image(systemName: "play.fill")
              .font(.caption.weight(.semibold)).foregroundStyle(.white)
              .padding(8).background(.black.opacity(0.7), in: Circle()).padding(6)
              .allowsHitTesting(false)
          }
        }

        Text("\(index + 1)")
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(.white)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(.black.opacity(0.85), in: Capsule())
          .opacity(store.showsOverviewNumbers ? 1 : 0)
          .accessibilityHidden(true)
      }

      HStack(spacing: 3) {
        if store.isPhotoMarking {
          PhotoMarkSelectionToggle(asset: asset, isSelected: isSelected) {
            focusCard()
            store.selectForBatch(index: index, modifiers: .command)
          }
        }
        Text(asset.filename)
          .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
          .foregroundStyle(Color.primary.opacity(isSelected ? 1 : 0.85))
          .lineLimit(1)
          .truncationMode(.middle)
        if isSelected && !store.isPhotoMarking {
          // 선택 표식도 작은 사진을 가리지 않도록 파일 이름 옆에 둡니다.
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(ViewerTheme.accent)
            .font(.caption2)
            .accessibilityHidden(true)
        }
      }
      PhotoMarkThumbnailBadges(marks: store.photoMarks, asset: asset)
      if store.isPhotoMarking {
        PhotoMarkCardMenu(store: store, asset: asset)
          .font(.caption)
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
          isSelected ? ViewerTheme.selectionBorder
            : ViewerTheme.controlBorder.opacity(isHovered ? 1 : 0.65), lineWidth: 1)
        .allowsHitTesting(false)
    }
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture(count: 2) {
      guard store.overviewSelectionSession == nil else { return }
      focusCard()
      store.select(index: index)
      if asset.isVideo { store.openVideoFullScreen(asset) }
      else { store.presentationMode = .viewer }
    }
    .onTapGesture {
      focusCard()
      store.selectForBatch(index: index, modifiers: NSEvent.modifierFlags)
    }
    .contextMenu { BatchAssetContextMenu(store: store, url: asset.url) }
    .accessibilityElement(children: store.isPhotoMarking ? .contain : .ignore)
    .accessibilityLabel(asset.filename)
    .accessibilityValue(accessibilityValue)
    .accessibilityActions {
      if asset.isVideo {
        Button(MotionMediaL10n.text("video.fullscreen")) { store.openVideoFullScreen(asset) }
      }
    }
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction {
      focusCard()
      store.selectForBatch(index: index, modifiers: [])
    }
  }

  private func focusCard() {
    guard let window = NSApp.keyWindow, window.firstResponder is NSTextView else { return }
    window.makeFirstResponder(nil)
  }

  private var accessibilityValue: String {
    let selection = L10n.text(isSelected ? "선택됨" : "선택 안 됨")
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
