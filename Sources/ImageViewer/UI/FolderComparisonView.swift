import SwiftUI

struct FolderComparisonView: View {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore
  @ObservedObject var comparison: FolderComparisonStore

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Rectangle().fill(ViewerTheme.separator).frame(height: 1)

      let layout: AnyLayout = comparison.arrangement == .horizontal
        ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
      layout {
        ForEach(FolderComparisonSide.allCases) { side in
          if side == .second {
            ComparisonPaneSeparator(arrangement: comparison.arrangement)
          }
          FolderComparisonPaneView(store: store, shortcuts: shortcuts, comparison: comparison,
            pane: comparison.pane(side), side: side)
        }
      }
      // A/B 이름과 물리적 좌우를 일치시킵니다. 아랍어에서도 A가 오른쪽으로 바뀌지 않습니다.
      .environment(\.layoutDirection, .leftToRight)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(ViewerTheme.separator)

      Rectangle().fill(ViewerTheme.separator).frame(height: 1)
      statusBar
    }
    .background(ViewerTheme.chromeGradient)
    .alert(item: $comparison.alert) { alert in
      Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("확인")))
    }
    .sheet(isPresented: $comparison.isEditingNames) {
      ComparisonNamesEditor(comparison: comparison)
    }
    .onAppear {
      comparison.resumeMatching()
    }
    .onDisappear {
      comparison.resetLiveInput()
      comparison.editingPhotoMarkSide = nil
    }
  }

  private var toolbar: some View {
    VStack(spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 18) {
          openAndLayoutControls
          Spacer(minLength: 12)
          viewportControls
        }
        VStack(spacing: 12) {
          HStack(spacing: 12) {
            openAndLayoutControls
            Spacer(minLength: 0)
          }
          HStack { viewportControls; Spacer(minLength: 0) }
        }
      }
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 20) {
          navigationControls
          Spacer(minLength: 12)
          matchingAndThumbnailControls
        }
        VStack(alignment: .leading, spacing: 10) {
          navigationControls
          matchingAndThumbnailControls
        }
      }
      LibraryQueryControls(query: $comparison.query,
        isWorking: comparison.isMatching || comparison.first.isFiltering || comparison.second.isFiltering,
        availableExtensions: comparison.first.availableExtensions + comparison.second.availableExtensions)
        .disabled(comparison.first.isLocked || comparison.second.isLocked)
    }
    .controlSize(.small)
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ViewerTheme.chromeGradient)
  }

  private var navigationControls: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 12) {
        Label("이미지 넘기기", systemImage: "arrow.left.arrow.right")
          .font(.system(size: 12, weight: .medium))
        ComparisonNavigationSelector(comparison: comparison)
        .frame(width: 330)
        .environment(\.layoutDirection, .leftToRight)
        .disabled(hasLockedPane)
        .help(L10n.text(hasLockedPane
          ? "잠금에 맞춰 이동 대상이 바뀝니다. 잠금을 모두 풀면 양쪽으로 돌아갑니다."
          : "방향키와 공통 이동 버튼으로 넘길 사진을 고릅니다. A/B만 선택하면 목록 순서로 전환합니다."))
        Button { comparison.isEditingNames = true } label: {
          Image(systemName: "pencil")
        }
        .help(ComparisonNamesL10n.text("editor.open"))
        .accessibilityLabel(ComparisonNamesL10n.text("editor.open"))
        if hasLockedPane {
          Label("잠금에 따라 자동 선택", systemImage: "lock.fill")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      if comparison.navigationTarget == .both {
        HStack(spacing: 10) {
          Toggle("적은 쪽 반복", isOn: Binding(
            get: { comparison.endBehavior == .loop },
            set: { comparison.endBehavior = $0 ? .loop : .hold }))
            .toggleStyle(.switch)
            .fixedSize()
            .disabled(comparison.alignment == .filename || hasLockedPane)
            .help(L10n.text(comparison.alignment == .filename
              ? "파일명 비교에서는 같은 이름의 쌍으로 이동합니다. 반복은 목록 순서에서 사용할 수 있습니다."
              : "켜면 적은 쪽은 처음부터 반복하고, 끄면 마지막 이미지에 머뭅니다. 많은 쪽의 끝까지 함께 넘깁니다."))
          Text(comparison.alignment == .filename
            ? ComparisonAlignment.filename.title : comparison.endBehavior.title)
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .frame(minHeight: 56, alignment: .topLeading)
  }

  private var hasLockedPane: Bool { comparison.first.isLocked || comparison.second.isLocked }

  private var matchingAndThumbnailControls: some View {
    HStack(spacing: 16) {
      matchingControls
      Toggle("썸네일 표시", isOn: $comparison.showsThumbnails)
        .toggleStyle(.checkbox)
        .fixedSize()
    }
    .controlSize(.regular)
    .font(.system(size: 13, weight: .medium))
  }

  private var matchingControls: some View {
    HStack(spacing: 12) {
      Picker("이미지 맞추기", selection: $comparison.alignment) {
        ForEach(ComparisonAlignment.allCases) { Text($0.title).tag($0) }
      }
      .fixedSize()
      .disabled(comparison.first.isLocked || comparison.second.isLocked)
      .help(L10n.text(comparison.alignment == .filename
        ? "확장자를 제외한 같은 이름을 짝지으며, 없는 쪽은 빈칸으로 표시합니다."
        : "양쪽 폴더를 목록 순서대로 비교합니다. 각 칸의 사진을 따로 고를 수 있습니다."))
      if comparison.alignment == .filename {
        Text(L10n.format("비교 %1$@", comparison.matchedPosition))
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
    }
  }

  private var openAndLayoutControls: some View {
    HStack(spacing: 12) {
      Button { comparison.choosePair() } label: {
        Label("비교할 폴더 선택…", systemImage: "folder.badge.plus")
      }
      .disabled(comparison.first.isLocked || comparison.second.isLocked)
      Button { store.compareCurrentCollectionByMarks() } label: {
        Label(PhotoMarkL10n.text("comparison.open"), systemImage: "tag")
      }
      .disabled(!store.canCompareCurrentCollectionByMarks)
      .help(PhotoMarkL10n.text("comparison.openHelp"))
      Divider().frame(height: 20)
      Picker("비교 화면 배치", selection: $comparison.arrangement) {
        ForEach(FolderComparisonArrangement.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .fixedSize()
    }
  }

  private var viewportControls: some View {
    HStack(spacing: 12) {
      Toggle("확대·이동 함께", isOn: $comparison.linksViewport)
        .toggleStyle(.switch)
        .help("같은 위치를 함께 확대·이동합니다. 잠긴 칸은 유지합니다.")
        .fixedSize()
      Divider().frame(height: 28)
      HStack(spacing: 8) {
        Button { comparison.updateZoom(1 / 1.25) } label: {
          Image(systemName: "minus.magnifyingglass")
            .font(.system(size: 18, weight: .medium))
            .frame(width: 22, height: 22)
        }
        .help("축소")
        .accessibilityLabel("축소")
        .accessibilityIdentifier("comparison.zoomOut")
        Button { comparison.updateZoom(1.25) } label: {
          Image(systemName: "plus.magnifyingglass")
            .font(.system(size: 18, weight: .medium))
            .frame(width: 22, height: 22)
        }
        .help("확대")
        .accessibilityLabel("확대")
        .accessibilityIdentifier("comparison.zoomIn")
        Button("화면 맞춤") { comparison.setScale(.fit) }
          .accessibilityIdentifier("comparison.fit")
        Menu {
          Button("화면 맞춤") { comparison.setScale(.fit) }
          Button(L10n.text("가로 맞춤")) { comparison.setScale(.fitWidth) }
          Button(L10n.text("세로 맞춤")) { comparison.setScale(.fitHeight) }
          Divider()
          Button(L10n.text("가운데 정렬")) { comparison.centerImage() }
        } label: {
          Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            .frame(width: 18, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.text("맞춤 옵션"))
        .accessibilityLabel(L10n.text("맞춤 옵션"))
        .accessibilityIdentifier("comparison.fitOptions")
        Button("1:1") { comparison.setScale(.actualPixels) }
          .help("실제 픽셀 크기")
          .accessibilityIdentifier("comparison.actualPixels")
      }
      .buttonStyle(ViewerActionButtonStyle())
      .disabled(comparison.pane(comparison.activeSide).isLocked
        || comparison.pane(comparison.activeSide).currentAsset == nil)
    }
    .controlSize(.regular)
    .font(.system(size: 13, weight: .medium))
  }

  private var statusBar: some View {
    HStack(spacing: 12) {
      Text(L10n.text(comparison.first.folderURL == nil && comparison.second.folderURL == nil
        ? "A와 B에 이미지나 폴더를 열어 비교하세요." : "두 손가락으로 이동 · 핀치로 확대 · 한쪽을 잠그면 다른 쪽만 조작"))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 8)
      HStack(spacing: 10) {
        Text(L10n.format("이동 대상: %@", comparison.navigationTitle(for: comparison.navigationTarget)))
          .lineLimit(1).truncationMode(.middle).frame(maxWidth: 220)
          .help(comparison.navigationTitle(for: comparison.navigationTarget))
          .font(.caption.weight(.medium)).foregroundStyle(ViewerTheme.accent)
        Button { comparison.navigateSelection(-1) } label: {
          Image(systemName: "backward.end")
        }
        .disabled(!comparison.canNavigateSelection(-1))
        .help("이전 비교 이미지")
        Text(L10n.format("이미지 이동: %@ / %@", shortcuts.binding(for: .previousPage).displayText,
          shortcuts.binding(for: .nextPage).displayText))
          .font(.caption).foregroundStyle(.secondary)
          .lineLimit(1)
        Button { comparison.navigateSelection(1) } label: {
          Image(systemName: "forward.end")
        }
        .disabled(!comparison.canNavigateSelection(1))
        .help("다음 비교 이미지")
      }
      .help(L10n.text("잠금에 맞춰 이동 대상이 바뀝니다. 잠금을 모두 풀면 양쪽으로 돌아갑니다."))
    }
    .controlSize(.small)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(ViewerTheme.chromeGradient)
  }

}

private struct ComparisonPaneSeparator: View {
  let arrangement: FolderComparisonArrangement
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  private var isSideBySide: Bool { arrangement == .horizontal }

  private var lineColor: Color {
    if contrast == .increased {
      return Color(white: colorScheme == .dark ? 0.72 : 0.28)
    }
    return Color(white: colorScheme == .dark ? 0.46 : 0.43)
  }

  var body: some View {
    Rectangle()
      .fill(Color(white: colorScheme == .dark ? 0.085 : 0.88))
      .overlay {
        Rectangle()
          .fill(lineColor)
          .frame(width: isSideBySide ? 2 : nil, height: isSideBySide ? nil : 2)
      }
      .frame(width: isSideBySide ? 8 : nil, height: isSideBySide ? nil : 8)
      .frame(maxWidth: isSideBySide ? nil : .infinity,
        maxHeight: isSideBySide ? .infinity : nil)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

private struct FolderComparisonPaneView: View {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore
  @ObservedObject var comparison: FolderComparisonStore
  @ObservedObject var pane: FolderComparisonPane
  let side: FolderComparisonSide
  @State private var jumpNumber = 1

  private var previousAction: ShortcutAction { side == .first ? .previousFirstFolder : .previousSecondFolder }
  private var nextAction: ShortcutAction { side == .first ? .nextFirstFolder : .nextSecondFolder }
  private var sideTitle: String { comparison.namedSideTitle(for: side) }

  var body: some View {
    VStack(spacing: 0) {
      paneHeader
      Rectangle()
        .fill(comparison.activeSide == side ? ViewerTheme.accent.opacity(0.65) : ViewerTheme.separator)
        .frame(height: 1)

      ComparisonImageCanvas(store: store, shortcuts: shortcuts, comparison: comparison,
        pane: pane, side: side, firstViewport: comparison.first.viewport,
        secondViewport: comparison.second.viewport, liveInput: comparison.liveInput)
      if comparison.showsThumbnails && !pane.assets.isEmpty {
        Divider()
        ComparisonFilmstrip(store: store, comparison: comparison, pane: pane, side: side,
          compact: comparison.arrangement == .vertical)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: pane.index, initial: true) { _, index in jumpNumber = index + 1 }
    .onChange(of: pane.folderURL) { _, _ in jumpNumber = pane.index + 1 }
  }

  private var paneHeader: some View {
    VStack(spacing: 9) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 18) {
          folderControls
          navigationControls
        }
        VStack(spacing: 10) {
          folderControls
          navigationControls
        }
      }
      ComparisonPhotoMarkControls(comparison: comparison, pane: pane,
        marks: store.photoMarks, side: side)
    }
    .controlSize(.small)
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(ViewerTheme.panelGradient)
  }

  private var sourceLabelURL: URL? {
    pane.folderURL ?? (pane.sourceURLs.count == 1 && pane.sourceURLs.first?.pathExtension.lowercased() == "zip"
      ? pane.sourceURLs.first : nil)
  }

  private var folderControls: some View {
    HStack(spacing: 9) {
        Text(side == .first ? "A" : "B")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(comparison.activeSide == side ? ViewerTheme.accent : .secondary)
          .frame(width: 23, height: 23)
          .background(comparison.activeSide == side ? ViewerTheme.selection : Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 6))
          .overlay {
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(comparison.activeSide == side ? ViewerTheme.selectionBorder
                : ViewerTheme.separator, lineWidth: 0.75)
              .allowsHitTesting(false)
          }
          .help(sideTitle)
        Text(comparison.customName(for: side).isEmpty
          ? (sourceLabelURL?.lastPathComponent ?? L10n.text(pane.assets.isEmpty ? "이미지 또는 폴더를 선택하세요." : "선택한 이미지"))
          : comparison.displayName(for: side))
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1).truncationMode(.middle)
          .help([comparison.displayName(for: side), sourceLabelURL?.path].compactMap { $0 }.joined(separator: "\n"))
        Spacer(minLength: 4)
        ComparisonZoomReadout(viewport: pane.viewport)
        lockButton
        Button { comparison.chooseItems(for: side) } label: { Label("열기…", systemImage: "folder") }
          .disabled(pane.isLocked)
          .help(L10n.format("%@ 열기", sideTitle))
      }
      .frame(minWidth: 220)
  }

  private var navigationControls: some View {
    HStack(spacing: 8) {
        Button { comparison.navigate(side, direction: -1) } label: { Image(systemName: "chevron.left") }
          .disabled(!comparison.canNavigate(side, direction: -1))
          .help(L10n.format("%@  %@", previousAction.title, shortcuts.binding(for: previousAction).displayText))
        Text(pane.position)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Button { comparison.navigate(side, direction: 1) } label: { Image(systemName: "chevron.right") }
          .disabled(!comparison.canNavigate(side, direction: 1))
          .help(L10n.format("%@  %@", nextAction.title, shortcuts.binding(for: nextAction).displayText))
        Spacer(minLength: 4)
        TextField("이미지 번호", value: $jumpNumber, format: .number.grouping(.never))
          .textFieldStyle(.roundedBorder).frame(width: 54)
          .onSubmit { comparison.jump(side, number: jumpNumber); jumpNumber = pane.index + 1 }
          .disabled(pane.isLocked || pane.assets.isEmpty || pane.isLoading)
        Button("이동") { comparison.jump(side, number: jumpNumber); jumpNumber = pane.index + 1 }
          .disabled(pane.isLocked || pane.assets.isEmpty || pane.isLoading)
      }
      .fixedSize(horizontal: true, vertical: false)
  }

  private var lockButton: some View {
    Button { comparison.toggleLock(on: side) } label: {
      Label(L10n.text(pane.isLocked ? "잠김" : "잠금"), systemImage: pane.isLocked ? "lock.fill" : "lock.open")
    }
    .tint(pane.isLocked ? ViewerTheme.accent : nil)
    .disabled(!pane.isLocked && (pane.isLoading || pane.isFiltering || comparison.isMatching
      || pane.currentAsset == nil || !pane.canMarkPresentedAsset))
    .help(pane.isLocked ? L10n.text("잠금 해제") : L10n.text("이 칸의 이미지와 확대·이동 위치를 고정합니다."))
  }
}

// Only image canvases subscribe to frequent viewport/gesture changes. Folder
// controls, filmstrips, and the classification panel keep their structural state.
private struct ComparisonImageCanvas: View {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore
  @ObservedObject var comparison: FolderComparisonStore
  @ObservedObject var pane: FolderComparisonPane
  let side: FolderComparisonSide
  @ObservedObject var firstViewport: FolderComparisonViewport
  @ObservedObject var secondViewport: FolderComparisonViewport
  @ObservedObject var liveInput: ComparisonLiveInput

  private var canPan: Bool { comparison.canPan(on: side) }
  private var sideTitle: String { comparison.namedSideTitle(for: side) }

  var body: some View {
    ZStack {
      ViewerTheme.canvas
      if pane.isLoading {
        ProgressView("폴더 읽는 중…")
          .controlSize(.small)
      } else if let asset = pane.currentAsset {
        ViewerImageTile(asset: asset, itemCount: 2, thumbnailPipeline: store.thumbnailPipeline,
          pipeline: store.pipeline, adjustments: .identity, prefersHDR: store.prefersHDR,
          interpolationMode: store.imageInterpolationMode, comparisonLayout: .off,
          filenameDisplaySize: store.filenameDisplaySize, baseScaleMode: pane.scaleMode,
          committedZoom: pane.zoom, effectiveZoom: comparison.effectiveZoom(on: side),
          effectivePan: comparison.effectivePan(on: side),
          showsTileBoundary: false, highlightsSelection: false,
          onDisplayedAssetChange: { asset in
            pane.recordPresentedAsset(asset)
            if let asset { store.recordRecentlyViewed(asset) }
          },
          onPanGeometryChange: { presentedAsset, geometry in
            comparison.updatePanGeometry(geometry, on: side, assetID: presentedAsset.id)
          })
          // Keep one loader per pane, just as the normal viewer keeps one per slot.
          // Navigation replaces the pending destination while the last completed
          // image stays visible; folder loading/missing matches still remove the tile.
      } else {
        emptyPane
      }
    }
    .environment(\.colorScheme, .dark)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
    .contentShape(Rectangle())
    .onAppear { pane.beginTrackingPresentation() }
    .onDisappear { pane.endTrackingPresentation() }
    .onTapGesture {
      if comparison.activeSide != side { comparison.activeSide = side }
    }
    .simultaneousGesture(MagnificationGesture()
      .onChanged { value in
        comparison.updateLiveMagnification(value, on: side)
      }
      .onEnded { value in
        comparison.endLiveMagnification(value, on: side)
      })
    .simultaneousGesture(DragGesture(minimumDistance: 3)
      .onChanged { value in
        guard canPan, store.panInteractionMode == .primaryDrag else { return }
        comparison.updateLiveTranslation(value.translation, on: side)
      }
      .onEnded { value in
        if store.panInteractionMode == .primaryDrag {
          comparison.endLiveTranslation(value.translation, on: side)
        }
      })
    .background {
      InputEventMonitor(onKeyDown: { event in
        // 두 칸이 같은 창을 감시하므로 키보드는 A 감시자 한 곳에서만 처리합니다.
        guard side == .first else { return false }
        return store.handleViewerKeyDown(event, shortcuts: shortcuts)
      }, onPointerPan: { input, delta in
        comparison.handlePointerPan(input, delta: delta, on: side,
          preferredMode: store.panInteractionMode)
      }, onHorizontalSwipe: { delta in
        comparison.navigate(side, direction: delta < 0 ? 1 : -1)
      })
    }
  }

  private var canRecoverMissingMatch: Bool {
    pane.showsMissingCounterpart && pane.errorMessage == nil && !pane.assets.isEmpty
  }

  private var emptyPaneMessage: String {
    if let error = pane.errorMessage { return error }
    if canRecoverMissingMatch { return L10n.text("이 폴더에 같은 이름의 사진이 없습니다.") }
    if !pane.sourceURLs.isEmpty { return PhotoMarkL10n.text("comparison.empty") }
    return L10n.text("이미지 또는 폴더를 선택하세요.")
  }

  private var emptyPane: some View {
    ViewThatFits(in: .vertical) {
      VStack(spacing: 14) {
        Image(systemName: canRecoverMissingMatch ? "photo.badge.exclamationmark" : "folder")
          .font(.system(size: 38, weight: .ultraLight))
          .foregroundStyle(.white.opacity(0.35))
        VStack(spacing: 7) {
          Text(sideTitle)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
          Text(emptyPaneMessage)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.55))
            .multilineTextAlignment(.center)
          if canRecoverMissingMatch {
            Text("폴더는 그대로 열려 있습니다. 파일명과 관계없이 보려면 목록 순서로 전환하세요.")
              .font(.caption)
              .foregroundStyle(.white.opacity(0.55))
              .multilineTextAlignment(.center)
          } else if !pane.sourceURLs.isEmpty && pane.errorMessage == nil {
            Text(PhotoMarkL10n.text("comparison.emptyHelp"))
              .font(.caption).foregroundStyle(.white.opacity(0.55))
              .multilineTextAlignment(.center)
          }
        }
        emptyPaneAction
      }
      .padding(24)
      .fixedSize(horizontal: false, vertical: true)
      VStack(spacing: 8) {
        Text(emptyPaneMessage)
          .font(.caption)
          .foregroundStyle(.white.opacity(0.55))
          .multilineTextAlignment(.center)
        emptyPaneAction
      }
      .padding(8)
    }
    .frame(maxWidth: 320)
  }

  @ViewBuilder private var emptyPaneAction: some View {
    if canRecoverMissingMatch {
      Button("목록 순서로 비교") { comparison.alignment = .sequence }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(comparison.first.isLocked || comparison.second.isLocked)
    } else if pane.photoMarkFilter.isActive && !pane.sourceURLs.isEmpty && pane.errorMessage == nil {
      Button(PhotoMarkL10n.text("comparison.reset")) { pane.photoMarkFilter = PhotoMarkFilter() }
        .controlSize(.regular)
        .disabled(pane.isLocked)
    } else {
      Button { comparison.chooseItems(for: side) } label: { Label("열기…", systemImage: "folder") }
        .controlSize(.regular)
        .disabled(pane.isLocked)
    }
  }

}

private struct ComparisonZoomReadout: View {
  @ObservedObject var viewport: FolderComparisonViewport

  var body: some View {
    Text("\(Int(viewport.zoom * 100))%")
      .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
  }
}

struct FolderComparisonMenuItems: View {
  @ObservedObject var comparison: FolderComparisonStore
  @ObservedObject var shortcuts: ShortcutStore
  var body: some View {
    Button("비교할 폴더 선택…") { comparison.choosePair() }
      .disabled(comparison.first.isLocked || comparison.second.isLocked)
    ForEach(FolderComparisonSide.allCases) { side in
      Button(L10n.format("%@ 열기", comparison.namedSideTitle(for: side))) { comparison.chooseItems(for: side) }
        .disabled(comparison.pane(side).isLocked)
    }
    Divider()
    Button(L10n.format("%@  %@", L10n.text("이전 비교 이미지"), shortcuts.binding(for: .previousPage).displayText)) {
      comparison.navigateSelection(-1)
    }.disabled(!comparison.canNavigateSelection(-1))
    Button(L10n.format("%@  %@", L10n.text("다음 비교 이미지"), shortcuts.binding(for: .nextPage).displayText)) {
      comparison.navigateSelection(1)
    }.disabled(!comparison.canNavigateSelection(1))
    ForEach([ShortcutAction.previousFirstFolder, .nextFirstFolder, .previousSecondFolder, .nextSecondFolder]) { action in
      let side: FolderComparisonSide = [.previousFirstFolder, .nextFirstFolder].contains(action) ? .first : .second
      let direction = [ShortcutAction.previousFirstFolder, .previousSecondFolder].contains(action) ? -1 : 1
      Button(L10n.format("%@  %@", action.title, shortcuts.binding(for: action).displayText)) {
        comparison.navigate(side, direction: direction)
      }.disabled(!comparison.canNavigate(side, direction: direction))
    }
    Divider()
    Picker("방향키로 넘길 대상", selection: $comparison.navigationTarget) {
      ForEach(ComparisonNavigationTarget.allCases) { Text(comparison.navigationTitle(for: $0)).tag($0) }
    }
    .disabled(comparison.first.isLocked || comparison.second.isLocked)
    Button(ComparisonNamesL10n.text("editor.open")) { comparison.isEditingNames = true }
    Picker("비교 화면 배치", selection: $comparison.arrangement) {
      ForEach(FolderComparisonArrangement.allCases) { Text($0.title).tag($0) }
    }
    Toggle("확대·이동 함께", isOn: $comparison.linksViewport)
    Picker("이미지 맞추기", selection: $comparison.alignment) {
      ForEach(ComparisonAlignment.allCases) { Text($0.title).tag($0) }
    }
    .disabled(comparison.first.isLocked || comparison.second.isLocked)
    Toggle("적은 쪽 반복", isOn: Binding(
      get: { comparison.endBehavior == .loop },
      set: { comparison.endBehavior = $0 ? .loop : .hold }))
      .disabled(comparison.navigationTarget != .both || comparison.alignment == .filename
        || comparison.first.isLocked || comparison.second.isLocked)
    Toggle("썸네일 표시", isOn: $comparison.showsThumbnails)
  }
}
