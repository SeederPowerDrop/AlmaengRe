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
        ? AnyLayout(HStackLayout(spacing: 1)) : AnyLayout(VStackLayout(spacing: 1))
      layout {
        ForEach(FolderComparisonSide.allCases) { side in
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
    .background(ViewerTheme.chrome)
    .alert(item: $comparison.alert) { alert in
      Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("확인")))
    }
    .onDisappear { comparison.resetLiveInput() }
  }

  private var toolbar: some View {
    VStack(spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 18) {
          openAndLayoutControls
          Spacer(minLength: 12)
          viewportControls
          closeButton
        }
        VStack(spacing: 12) {
          HStack(spacing: 12) {
            openAndLayoutControls
            Spacer(minLength: 0)
            closeButton
          }
          HStack { viewportControls; Spacer(minLength: 0) }
        }
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) {
          endBehaviorPicker
          Spacer(minLength: 12)
          Toggle("썸네일 표시", isOn: $comparison.showsThumbnails)
            .toggleStyle(.checkbox)
            .fixedSize()
        }
        VStack(alignment: .leading, spacing: 8) {
          endBehaviorPicker
          Toggle("썸네일 표시", isOn: $comparison.showsThumbnails).toggleStyle(.checkbox)
        }
      }
    }
    .controlSize(.small)
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ViewerTheme.chrome)
  }

  private var endBehaviorPicker: some View {
    Picker("적은 쪽 이미지", selection: $comparison.endBehavior) {
      ForEach(ComparisonEndBehavior.allCases) { Text($0.title).tag($0) }
    }
    .fixedSize()
    .help("이미지가 많은 쪽의 끝까지 이동합니다. 적은 쪽은 마지막 이미지를 유지하거나 반복합니다.")
  }

  private var openAndLayoutControls: some View {
    HStack(spacing: 12) {
      Button { comparison.choosePair() } label: {
        Label("비교할 폴더 선택…", systemImage: "folder.badge.plus")
      }
      .disabled(comparison.first.isLocked || comparison.second.isLocked)
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
      Divider().frame(height: 20)
      HStack(spacing: 6) {
        Button { comparison.updateZoom(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
          .help("축소")
        Button { comparison.updateZoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
          .help("확대")
        Button("화면 맞춤") { comparison.setScale(.fit) }
        Button("1:1") { comparison.setScale(.actualPixels) }.help("실제 픽셀 크기")
      }
      .disabled(comparison.pane(comparison.activeSide).isLocked
        || comparison.pane(comparison.activeSide).currentAsset == nil)
    }
  }

  private var closeButton: some View {
    Button { store.toggleFolderComparison() } label: {
      Image(systemName: "xmark")
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help("이미지 비교 종료 (Esc)")
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
        Button { comparison.navigateBoth(-1) } label: {
          Image(systemName: "backward.end")
        }
        .disabled(!comparison.canNavigateBoth(-1))
        .help("이전 비교 이미지")
        Text(L10n.format("이미지 이동: %@ / %@", shortcuts.binding(for: .previousPage).displayText,
          shortcuts.binding(for: .nextPage).displayText))
          .font(.caption).foregroundStyle(.secondary)
          .lineLimit(1)
        Button { comparison.navigateBoth(1) } label: {
          Image(systemName: "forward.end")
        }
        .disabled(!comparison.canNavigateBoth(1))
        .help("다음 비교 이미지")
      }
      .help("양쪽이 열려 있으면 함께 이동하고, 한쪽을 잠그면 다른 쪽만 이동합니다.")
    }
    .controlSize(.small)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(ViewerTheme.chrome)
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
  private var canPan: Bool { comparison.canPan(on: side) }

  var body: some View {
    VStack(spacing: 0) {
      paneHeader
      Rectangle()
        .fill(comparison.activeSide == side ? ViewerTheme.accent.opacity(0.65) : ViewerTheme.separator)
        .frame(height: 1)

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
            onBaseImageSizeChange: { comparison.updateBaseImageSize($0, on: side, assetID: asset.id) })
            .id(asset.id)
        } else {
          emptyPane
        }
      }
      .environment(\.colorScheme, .dark)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
      .contentShape(Rectangle())
      .onTapGesture { comparison.activeSide = side }
      .simultaneousGesture(MagnificationGesture()
        .onChanged { value in
          comparison.updateLiveMagnification(value, on: side)
        }
        .onEnded { value in
          comparison.updateZoom(value, on: side)
          comparison.resetLiveInput()
        })
      .simultaneousGesture(DragGesture(minimumDistance: 3)
        .onChanged { value in
          guard canPan, store.panInteractionMode == .primaryDrag else { return }
          comparison.updateLiveTranslation(value.translation, on: side)
        }
        .onEnded { value in
          if canPan, store.panInteractionMode == .primaryDrag { comparison.pan(value.translation, on: side) }
          comparison.resetLiveInput()
        })
      .background {
        InputEventMonitor(onKeyDown: { event in
          // 두 칸이 같은 창을 감시하므로 키보드는 A 감시자 한 곳에서만 처리합니다.
          guard side == .first else { return false }
          if event.keyCode == 53 { return store.handleEscapeKey() }
          guard let action = shortcuts.action(matching: event) else { return false }
          store.perform(action)
          return true
        }, onPointerPan: { input, delta in
          comparison.handlePointerPan(input, delta: delta, on: side,
            preferredMode: store.panInteractionMode)
        }, onHorizontalSwipe: { delta in
          comparison.navigate(side, direction: delta < 0 ? 1 : -1)
        })
      }
      if comparison.showsThumbnails && !pane.assets.isEmpty {
        Divider()
        ComparisonFilmstrip(store: store, comparison: comparison, pane: pane, side: side,
          compact: comparison.arrangement == .vertical)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: pane.index) { _, index in jumpNumber = index + 1 }
    .onChange(of: pane.folderURL) { _, _ in jumpNumber = pane.index + 1 }
  }

  private var paneHeader: some View {
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
    .controlSize(.small)
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(ViewerTheme.panel)
  }

  private var folderControls: some View {
    HStack(spacing: 9) {
        Text(side == .first ? "A" : "B")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(comparison.activeSide == side ? ViewerTheme.accent : .secondary)
          .frame(width: 23, height: 23)
          .background(comparison.activeSide == side ? ViewerTheme.selection : Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 6))
          .help(side.title)
        Text(pane.folderURL?.lastPathComponent ?? L10n.text(pane.assets.isEmpty ? "이미지 또는 폴더를 선택하세요." : "선택한 이미지"))
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1).truncationMode(.middle)
          .help(pane.folderURL?.path ?? "")
        Spacer(minLength: 4)
        Text("\(Int(pane.zoom * 100))%")
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        lockButton
        Button { comparison.chooseItems(for: side) } label: { Label("열기…", systemImage: "folder") }
          .disabled(pane.isLocked)
          .help(L10n.format("%@ 열기", side.title))
      }
      .frame(minWidth: 220)
  }

  private var navigationControls: some View {
    HStack(spacing: 8) {
        Button { comparison.navigate(side, direction: -1) } label: { Image(systemName: "chevron.left") }
          .disabled(!pane.canStep(-1))
          .help(L10n.format("%@  %@", previousAction.title, shortcuts.binding(for: previousAction).displayText))
        Text(pane.position)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Button { comparison.navigate(side, direction: 1) } label: { Image(systemName: "chevron.right") }
          .disabled(!pane.canStep(1))
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
    .disabled(!pane.isLocked && (pane.isLoading || pane.currentAsset == nil))
    .help(pane.isLocked ? L10n.text("잠금 해제") : L10n.text("이 칸의 이미지와 확대·이동 위치를 고정합니다."))
  }

  private var emptyPane: some View {
    VStack(spacing: 14) {
      Image(systemName: "folder")
        .font(.system(size: 38, weight: .ultraLight))
        .foregroundStyle(.white.opacity(0.35))
      VStack(spacing: 7) {
        Text(side.title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
        Text(pane.errorMessage ?? L10n.text("이미지 또는 폴더를 선택하세요."))
          .font(.callout)
          .foregroundStyle(.white.opacity(0.55))
          .multilineTextAlignment(.center)
      }
      Button { comparison.chooseItems(for: side) } label: { Label("열기…", systemImage: "folder") }
        .controlSize(.regular)
        .disabled(pane.isLocked)
    }
    .padding(24)
    .frame(maxWidth: 320)
  }

}

struct FolderComparisonMenuItems: View {
  @ObservedObject var comparison: FolderComparisonStore
  @ObservedObject var shortcuts: ShortcutStore
  var body: some View {
    Button("비교할 폴더 선택…") { comparison.choosePair() }
      .disabled(comparison.first.isLocked || comparison.second.isLocked)
    ForEach(FolderComparisonSide.allCases) { side in
      Button(L10n.format("%@ 열기", side.title)) { comparison.chooseItems(for: side) }
        .disabled(comparison.pane(side).isLocked)
    }
    Divider()
    Button(L10n.format("%@  %@", L10n.text("이전 비교 이미지"), shortcuts.binding(for: .previousPage).displayText)) {
      comparison.navigateBoth(-1)
    }.disabled(!comparison.canNavigateBoth(-1))
    Button(L10n.format("%@  %@", L10n.text("다음 비교 이미지"), shortcuts.binding(for: .nextPage).displayText)) {
      comparison.navigateBoth(1)
    }.disabled(!comparison.canNavigateBoth(1))
    ForEach([ShortcutAction.previousFirstFolder, .nextFirstFolder, .previousSecondFolder, .nextSecondFolder]) { action in
      let side: FolderComparisonSide = [.previousFirstFolder, .nextFirstFolder].contains(action) ? .first : .second
      let direction = [ShortcutAction.previousFirstFolder, .previousSecondFolder].contains(action) ? -1 : 1
      Button(L10n.format("%@  %@", action.title, shortcuts.binding(for: action).displayText)) {
        comparison.navigate(side, direction: direction)
      }.disabled(!comparison.pane(side).canStep(direction))
    }
    Divider()
    Picker("비교 화면 배치", selection: $comparison.arrangement) {
      ForEach(FolderComparisonArrangement.allCases) { Text($0.title).tag($0) }
    }
    Toggle("확대·이동 함께", isOn: $comparison.linksViewport)
    Picker("적은 쪽 이미지", selection: $comparison.endBehavior) {
      ForEach(ComparisonEndBehavior.allCases) { Text($0.title).tag($0) }
    }
    Toggle("썸네일 표시", isOn: $comparison.showsThumbnails)
  }
}
