import SwiftUI

enum PhotoMapDrawingMode: String, CaseIterable, Identifiable {
  case move, radius, rectangle, polygon
  var id: Self { self }

  var title: String {
    switch self {
    case .move: L10n.text("지도 이동")
    case .radius: L10n.text("반경")
    case .rectangle: L10n.text("사각형")
    case .polygon: L10n.text("자유 영역")
    }
  }

  var symbol: String {
    switch self {
    case .move: "hand.draw"
    case .radius: "circle.dashed"
    case .rectangle: "rectangle.dashed"
    case .polygon: "lasso"
    }
  }

  var instruction: String {
    switch self {
    case .move: L10n.text("사진 핀을 눌러 미리 보고, 영역을 선택해 사진을 모아 보세요.")
    case .radius: MapSelectionL10n.text("현재 지도 중심에 반경 영역을 추가합니다. 번호 손잡이를 드래그해 옮길 수 있습니다.")
    case .rectangle: MapSelectionL10n.text("현재 지도 중심에 사각형 영역을 추가합니다. 번호 손잡이를 드래그해 옮길 수 있습니다.")
    case .polygon: L10n.text("지도 위에 원하는 영역을 그리세요. 끝점은 자동으로 연결됩니다.")
    }
  }
}

struct PhotoMapView: View {
  @ObservedObject var store: AppStore
  let assets: [ImageAsset]
  let isLoading: Bool
  let scannedCount: Int
  let totalCount: Int
  let selection: GeographicSelection?
  let matchingAssetURLs: Set<URL>
  let thumbnailPipeline: ThumbnailPipeline
  let pipeline: ImagePipeline
  let onSelectionChange: (GeographicSelection?) -> Void
  let onOpenAsset: (ImageAsset) -> Void
  let onShowSelection: (PresentationMode) -> Void

  @State private var drawingMode: PhotoMapDrawingMode = .move
  @State private var fitRequest = 0
  @State private var viewportRequest = 0
  @State private var creationRequest = 0
  @State private var creationMode: PhotoMapDrawingMode = .radius
  @State private var activeAreaIndex: Int? = nil
  @State private var pickedAssets: [ImageAsset] = []
  @State private var pickedIndex = 0
  @State private var radiusKilometers = 1.0

  var body: some View {
    VStack(spacing: 0) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) { drawingTools; Spacer(minLength: 4); mapActions }
        VStack(alignment: .leading, spacing: 8) {
          drawingTools
          HStack { mapActions; Spacer(minLength: 0) }
        }
      }
      .viewerPadding(.horizontal, 14)
      .viewerPadding(.vertical, 10)

      if !areas.isEmpty { areaControls }

      if drawingMode == .polygon {
        HStack {
          Text(drawingMode.instruction).font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
          Spacer(minLength: 8)
          Button(MapSelectionL10n.text("그리기 취소")) { drawingMode = .move }
        }
        .viewerPadding(.horizontal, 14)
        .viewerPadding(.bottom, 10)
      }

      Divider()

      if selection != nil {
        selectionPanel
        Divider()
      }

      ZStack(alignment: .topLeading) {
        NativePhotoMapView(
          assets: assets, thumbnailPipeline: thumbnailPipeline,
          viewportState: store.photoMapViewport,
          isLoading: isLoading, selection: selection,
          matchingAssetURLs: matchingAssetURLs, drawingMode: isLoading ? .move : drawingMode,
          fitRequest: fitRequest, viewportRequest: viewportRequest,
          activeAreaIndex: activeAreaIndex, creationRequest: creationRequest,
          creationMode: creationMode,
          onSelectionChange: appendArea,
          onEditArea: replaceArea,
          onSelectArea: { activeAreaIndex = $0 },
          onPickAssets: { values in
            pickedAssets = values
            pickedIndex = 0
            store.photoMapPreview.focus(on: values.first?.id)
          })

        if selection == nil && drawingMode == .move {
          Text(drawingMode.instruction)
            .font(ViewerUIMetrics.font(.caption))
            .viewerPadding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .viewerPadding(12)
            .allowsHitTesting(false)
        }

        if !isLoading && assets.isEmpty {
          ContentUnavailableView(
            L10n.text("위치 정보가 있는 사진이 없습니다"), systemImage: "mappin.slash",
            description: Text(L10n.text("GPS 정보가 저장된 사진이 이 지도에 표시됩니다.")))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .allowsHitTesting(false)
        }
      }
      .overlay {
        GeometryReader { geometry in
          if let asset = pickedAsset {
            previewCard(asset, availableWidth: max(0, geometry.size.width - 28),
              availableHeight: max(0, geometry.size.height - 28))
              .padding(14)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
          }
        }
      }

      Divider()

      HStack(spacing: 10) {
        if isLoading {
          ProgressView().controlSize(.small)
          Text(L10n.format("위치 읽는 중 %lld / %lld", Int64(scannedCount), Int64(totalCount)))
        } else {
          Label(L10n.format("GPS 사진 %lld장", Int64(assets.count)), systemImage: "mappin.and.ellipse")
        }
        if selection != nil {
          Text(L10n.format("선택 %lld장", Int64(matchingAssetURLs.count)))
            .foregroundStyle(ViewerTheme.accent)
        }
        if let radiusLabel {
          Text(radiusLabel).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .font(ViewerUIMetrics.font(.caption))
      .viewerPadding(.horizontal, 14)
      .viewerPadding(.vertical, 9)
    }
    .background(ViewerTheme.chromeGradient)
    .onChange(of: selection, initial: true) { _, value in
      let count = value?.areas.count ?? 0
      if count == 0 { activeAreaIndex = nil }
      else if activeAreaIndex == nil || activeAreaIndex! >= count { activeAreaIndex = count - 1 }
      syncRadius()
      // Keep the completed areas and their actions visible after editing a selection.
      pickedAssets = []
      pickedIndex = 0
      store.photoMapPreview.clearSelection()
    }
    .onChange(of: activeAreaIndex) { _, _ in syncRadius() }
    .onChange(of: isLoading) { _, loading in
      if loading { drawingMode = .move }
    }
    .onChange(of: assets) { _, values in
      // Refresh the entire picked group, including metadata and files that disappeared.
      let pickedID = pickedAsset?.id
      let available = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      pickedAssets = pickedAssets.compactMap { available[$0.id] }
      pickedIndex = pickedAssets.firstIndex { $0.id == pickedID } ?? 0
    }
    .onChange(of: pickedAsset?.id, initial: true) { _, id in
      store.photoMapPreview.focus(on: id)
    }
    .onDisappear { store.photoMapPreview.clearSelection() }
  }

  /// Selection feedback belongs beside the map tools, with a full-sized primary action.
  /// It never floats over map pins or the location preview card.
  private var selectionPanel: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 20) {
        selectionSummary
        Spacer(minLength: 12)
        selectionActions
      }
      VStack(alignment: .leading, spacing: 12) {
        selectionSummary
        selectionActions
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .viewerPadding(.horizontal, 16)
    .viewerPadding(.vertical, 14)
    .background(ViewerTheme.panelGradient)
    .overlay(alignment: .leading) {
      Capsule().fill(ViewerTheme.accent.opacity(0.7))
        .frame(width: 3).viewerPadding(.vertical, 14)
        .allowsHitTesting(false)
    }
  }

  private var selectionSummary: some View {
    HStack(spacing: 12) {
      Image(systemName: matchingAssetURLs.isEmpty ? "viewfinder" : "checkmark.circle.fill")
        .font(ViewerUIMetrics.font(size: 25))
        .foregroundStyle(ViewerTheme.accent)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(L10n.text("선택한 영역의 사진"))
          .font(ViewerUIMetrics.font(.headline))
        if isLoading {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(L10n.text("선택 영역의 사진을 찾는 중…"))
          }
          .font(ViewerUIMetrics.font(.callout))
        } else if matchingAssetURLs.isEmpty {
          Text(L10n.text("이 영역에는 사진이 없습니다."))
            .font(ViewerUIMetrics.font(.callout))
          Text(L10n.text("영역을 넓히거나 다른 위치를 선택해 보세요."))
            .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
        } else {
          Text(L10n.format("선택 %lld장", Int64(matchingAssetURLs.count)))
            .font(ViewerUIMetrics.font(.callout).monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var selectionActions: some View {
    HStack(spacing: 10) {
      MapBatchActionsMenu(store: store, urls: matchingAssetURLs, title: BatchActionsL10n.text("map.area"))

      Button { onShowSelection(.viewer) } label: {
        Label(MapSelectionL10n.text("뷰어로 보기"), systemImage: "photo")
          .font(ViewerUIMetrics.font(.headline))
          .viewerFrame(minHeight: 34)
      }
      .buttonStyle(ViewerActionButtonStyle())
      .help(MapSelectionL10n.text("선택한 영역의 사진만 일반 뷰어에서 넘겨 봅니다."))

      Button { onShowSelection(.overview) } label: {
        Label(MapSelectionL10n.text("몽땅보기로 보기"), systemImage: "square.grid.2x2")
          .font(ViewerUIMetrics.font(.headline))
          .viewerFrame(minHeight: 34)
      }
      .buttonStyle(ViewerActionButtonStyle(prominent: true))
      .help(MapSelectionL10n.text("선택한 영역의 사진만 몽땅보기로 모아 봅니다."))
    }
    .controlSize(.large)
    .fixedSize()
    .disabled(isLoading || matchingAssetURLs.isEmpty)
  }

  private var drawingTools: some View {
    HStack(spacing: 3) {
      ForEach(PhotoMapDrawingMode.allCases) { mode in
        Button {
          switch mode {
          case .move, .polygon: drawingMode = mode
          case .radius, .rectangle:
            drawingMode = .move
            creationMode = mode
            creationRequest += 1
          }
        } label: {
          Label(mode.title, systemImage: mode.symbol)
        }
        .buttonStyle(ViewerToolButtonStyle(isSelected: drawingMode == mode))
        .help(mode != .move && !canAddArea ? areaLimitHelp : mode.instruction)
        .accessibilityAddTraits(drawingMode == mode ? .isSelected : [])
        .disabled(isLoading || (mode != .move && !canAddArea))
      }
    }
  }

  private var mapActions: some View {
    HStack(spacing: 8) {
      Button { fitRequest += 1 } label: {
        Label(L10n.text("모든 위치"), systemImage: "arrow.up.left.and.arrow.down.right")
      }
      .disabled(assets.isEmpty || isLoading)
      Button {
        drawingMode = .move
        viewportRequest += 1
      } label: {
        Label(L10n.text("현재 지도 영역"), systemImage: "viewfinder")
      }
      .help(canAddArea ? MapSelectionL10n.text("현재 지도 범위를 새 영역으로 추가합니다.") : areaLimitHelp)
      .disabled(assets.isEmpty || isLoading || !canAddArea)
    }
    .controlSize(.small)
    .buttonStyle(ViewerToolButtonStyle())
  }

  private var areas: [GeographicSelection] { selection?.areas ?? [] }
  private var activeArea: GeographicSelection? {
    guard let index = activeAreaIndex, areas.indices.contains(index) else { return nil }
    return areas[index]
  }
  private var canAddArea: Bool { areas.count < GeographicSelection.maximumAreaCount }
  private var areaLimitHelp: String {
    MapSelectionL10n.text("영역은 최대 3개까지 추가할 수 있습니다. 기존 영역을 지우면 더 추가할 수 있습니다.")
  }

  private var areaControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { areaChips; Spacer(minLength: 4); areaCountAndClear }
        VStack(alignment: .leading, spacing: 8) { areaChips; areaCountAndClear }
      }
      if case .radius = activeArea {
        HStack(spacing: 8) {
          Label(L10n.text("반경"), systemImage: "circle.dashed")
          TextField(L10n.text("반경"), value: $radiusKilometers,
            format: .number.precision(.fractionLength(0...3)))
            .textFieldStyle(.roundedBorder)
            .viewerFrame(width: 88)
            .onSubmit(applyRadius)
            .accessibilityLabel(L10n.text("반경 (km)"))
          Text("km").foregroundStyle(.secondary)
          Button(L10n.text("적용"), action: applyRadius)
          Spacer(minLength: 0)
        }
        .font(ViewerUIMetrics.font(.caption))
        .controlSize(.small)
        .disabled(isLoading)
      }
      Text(MapSelectionL10n.text("어느 한 영역에라도 포함된 사진을 모읍니다. 겹친 사진은 한 번만 표시됩니다."))
        .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
    }
    .viewerPadding(.horizontal, 14)
    .viewerPadding(.bottom, 10)
  }

  private var areaChips: some View {
    HStack(spacing: 8) {
      ForEach(areas.indices, id: \.self) { index in
        HStack(spacing: 2) {
          Button { activeAreaIndex = index } label: {
            Text(MapSelectionL10n.format("영역 %lld", Int64(index + 1)))
              .font(ViewerUIMetrics.font(.callout).weight(.medium))
          }
          .buttonStyle(ViewerToolButtonStyle(isSelected: activeAreaIndex == index))
          .accessibilityAddTraits(activeAreaIndex == index ? .isSelected : [])
          .help(MapSelectionL10n.text("번호 손잡이를 드래그해 영역을 옮기세요."))
          Button { removeArea(at: index) } label: {
            Image(systemName: "xmark").font(ViewerUIMetrics.font(.caption).weight(.semibold)).viewerFrame(width: 22, height: 28)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(MapSelectionL10n.format("영역 %lld 삭제", Int64(index + 1)))
          .help(MapSelectionL10n.format("영역 %lld 삭제", Int64(index + 1)))
        }
      }
    }
  }

  private var areaCountAndClear: some View {
    HStack(spacing: 10) {
      Text(MapSelectionL10n.format("영역 %lld개 / 최대 3개", Int64(areas.count)))
        .font(ViewerUIMetrics.font(.caption).monospacedDigit()).foregroundStyle(.secondary)
        .help(areaLimitHelp)
      Button(MapSelectionL10n.text("모두 해제")) {
        drawingMode = .move
        activeAreaIndex = nil
        onSelectionChange(nil)
      }
      .controlSize(.small)
    }
  }

  private func appendArea(_ value: GeographicSelection?) {
    guard !isLoading, canAddArea, let value else { return }
    drawingMode = .move
    activeAreaIndex = areas.count
    onSelectionChange(.combining(areas + [value]))
  }

  private func replaceArea(_ index: Int, with value: GeographicSelection) {
    guard !isLoading, areas.indices.contains(index) else { return }
    var updated = areas
    updated[index] = value
    onSelectionChange(.combining(updated))
  }

  private func removeArea(at index: Int) {
    guard areas.indices.contains(index) else { return }
    var updated = areas
    updated.remove(at: index)
    drawingMode = .move
    if let active = activeAreaIndex {
      activeAreaIndex = updated.isEmpty ? nil : min(active > index ? active - 1 : active, updated.count - 1)
    }
    onSelectionChange(.combining(updated))
  }

  private func syncRadius() {
    if case .radius(_, let meters) = activeArea { radiusKilometers = meters / 1_000 }
  }

  private var pickedAsset: ImageAsset? {
    guard pickedAssets.indices.contains(pickedIndex) else { return nil }
    return pickedAssets[pickedIndex]
  }

  private var radiusLabel: String? {
    guard case .radius(_, let meters) = activeArea else { return nil }
    let formatter = MeasurementFormatter()
    formatter.unitOptions = .naturalScale
    formatter.unitStyle = .short
    formatter.numberFormatter.maximumFractionDigits = 1
    return L10n.text("반경") + " "
      + formatter.string(from: Measurement(value: meters, unit: UnitLength.meters))
  }

  private func applyRadius() {
    guard let index = activeAreaIndex, case .radius(let center, let currentMeters) = activeArea, !isLoading else { return }
    guard radiusKilometers.isFinite else {
      radiusKilometers = currentMeters / 1_000
      return
    }
    radiusKilometers = min(20_000, max(0.01, radiusKilometers))
    replaceArea(index, with: .radius(center: center, meters: radiusKilometers * 1_000))
  }

  private func previewCard(_ asset: ImageAsset, availableWidth: CGFloat, availableHeight: CGFloat) -> some View {
    ScrollView(.vertical) {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "mappin.circle.fill").foregroundStyle(ViewerTheme.accent)
        Text(L10n.format("이 위치의 사진 %lld장", Int64(pickedAssets.count)))
          .font(ViewerUIMetrics.font(.caption).weight(.semibold))
        Spacer()
        Button {
          pickedAssets = []
          store.photoMapPreview.clearSelection()
        } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain)
          .accessibilityLabel(L10n.text("닫기"))
      }
      PhotoMapImagePreview(asset: asset, preview: store.photoMapPreview,
        thumbnailPipeline: thumbnailPipeline, pipeline: pipeline,
        adjustments: store.adjustments(for: asset), prefersHDR: store.prefersHDR,
        interpolationMode: store.imageInterpolationMode,
        onOpen: { onOpenAsset(asset) })
        .frame(height: min(180, max(100, availableHeight * 0.45)))
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .disabled(isLoading)
      PhotoMapPreviewControls(preview: store.photoMapPreview)
        .disabled(isLoading)
      Text(asset.filename).font(ViewerUIMetrics.font(.caption)).lineLimit(1).help(asset.filename)
      MapBatchActionsMenu(store: store, urls: [asset.url], title: BatchActionsL10n.text("map.photo"))
        .controlSize(.small)
      if pickedAssets.count > 1 {
        MapBatchActionsMenu(store: store, urls: Set(pickedAssets.map(\.url)), title: BatchActionsL10n.text("map.location"))
          .controlSize(.small)
        locationThumbnails
      }
      HStack {
        if pickedAssets.count > 1 {
          Button { pickedIndex = max(0, pickedIndex - 1) } label: {
            Image(systemName: "chevron.left")
          }
          .disabled(pickedIndex == 0)
          .accessibilityLabel(L10n.text("이전 이미지"))
          Text("\(pickedIndex + 1) / \(pickedAssets.count)")
            .font(ViewerUIMetrics.font(.caption).monospacedDigit())
          Button { pickedIndex = min(pickedAssets.count - 1, pickedIndex + 1) } label: {
            Image(systemName: "chevron.right")
          }
          .disabled(pickedIndex == pickedAssets.count - 1)
          .accessibilityLabel(L10n.text("다음 이미지"))
        }
        Spacer()
        Button(L10n.text("사진 보기")) { onOpenAsset(asset) }
          .disabled(isLoading)
      }
      .controlSize(.small)
    }
    .viewerPadding(12)
    }
    .frame(width: min(276, availableWidth), height: min(pickedAssets.count > 1 ? 465 : 365, availableHeight))
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
  }

  private var locationThumbnails: some View {
    ScrollViewReader { reader in
      ScrollView(.horizontal) {
        LazyHStack(spacing: 6) {
          ForEach(Array(pickedAssets.enumerated()), id: \.element.id) { index, asset in
            Button { pickedIndex = index } label: {
              ThumbnailImageView(asset: asset, thumbnailPipeline: thumbnailPipeline,
                pipeline: pipeline, maxPixelSize: 128)
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                  RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(index == pickedIndex ? ViewerTheme.accent : .clear, lineWidth: 3)
                }
            }
            .buttonStyle(.plain)
            .help(asset.filename)
            .accessibilityLabel(asset.filename)
            .accessibilityAddTraits(index == pickedIndex ? .isSelected : [])
            .id(asset.id)
          }
        }
        .padding(.vertical, 2)
      }
      .frame(height: 62)
      .onChange(of: pickedAsset?.id) { _, id in
        if let id { reader.scrollTo(id, anchor: .center) }
      }
    }
  }
}

/// Uses the same image geometry as the main viewer, with an independent transform.
/// Kept separate from the map so photo layout can be verified without map tiles.
struct PhotoMapImagePreview: View {
  let asset: ImageAsset
  @ObservedObject var preview: PhotoMapPreviewState
  let thumbnailPipeline: ThumbnailPipeline
  let pipeline: ImagePipeline
  let adjustments: ImageAdjustments
  let prefersHDR: Bool
  let interpolationMode: ImageInterpolationMode
  let onOpen: () -> Void

  @State private var panStart: CGSize?
  @State private var zoomStart: CGFloat?

  var body: some View {
    ViewerImageTile(asset: asset, itemCount: 1,
      thumbnailPipeline: thumbnailPipeline, pipeline: pipeline,
      adjustments: adjustments, prefersHDR: prefersHDR,
      interpolationMode: interpolationMode, comparisonLayout: .off,
      filenameDisplaySize: .hidden, baseScaleMode: preview.baseScaleMode,
      committedZoom: preview.zoom, effectiveZoom: preview.zoom,
      effectivePan: preview.panOffset, showsTileBoundary: false,
      highlightsSelection: false,
      onPanGeometryChange: { shown, geometry in
        preview.setGeometry(geometry, for: shown.id)
      })
      .environment(\.colorScheme, .dark)
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 2)
        .onChanged { value in
          guard preview.canPan else { return }
          if panStart == nil { panStart = preview.panOffset }
          let start = panStart ?? .zero
          preview.setPanOffset(CGSize(width: start.width + value.translation.width,
            height: start.height + value.translation.height))
        }
        .onEnded { _ in panStart = nil })
      .simultaneousGesture(MagnificationGesture()
        .onChanged { value in
          if zoomStart == nil { zoomStart = preview.zoom }
          preview.setZoom((zoomStart ?? 1) * value)
        }
        .onEnded { _ in zoomStart = nil })
      .onTapGesture(count: 2, perform: onOpen)
      .accessibilityLabel(asset.filename)
      .accessibilityIdentifier("map.preview.image")
      .accessibilityAction(named: Text(L10n.text("사진 보기")), onOpen)
      .onChange(of: asset.id, initial: true) { _, id in
        panStart = nil
        zoomStart = nil
        preview.focus(on: id)
      }
  }
}

struct PhotoMapPreviewControls: View {
  @ObservedObject var preview: PhotoMapPreviewState

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 4) {
        zoomControls
        Spacer(minLength: 0)
        fitMenu
      }
      VStack(alignment: .leading, spacing: 4) {
        zoomControls
        fitMenu
      }
    }
    .buttonStyle(ViewerToolButtonStyle())
    .controlSize(.small)
    .disabled(!preview.hasSelection)
  }

  private var zoomControls: some View {
    HStack(spacing: 2) {
      Button(action: preview.zoomOut) {
        Image(systemName: "minus").viewerFrame(width: 24, height: 28)
      }
      .disabled(preview.zoom <= PhotoMapPreviewState.zoomRange.lowerBound)
      .help(L10n.text("축소"))
      .accessibilityLabel(L10n.text("축소"))
      .accessibilityIdentifier("map.preview.zoomOut")
      Text(Double(preview.zoom).formatted(.percent.precision(.fractionLength(0))))
        .font(ViewerUIMetrics.font(.caption).monospacedDigit())
        .viewerFrame(minWidth: 42)
        .accessibilityIdentifier("map.preview.zoom")
      Button(action: preview.zoomIn) {
        Image(systemName: "plus").viewerFrame(width: 24, height: 28)
      }
      .disabled(preview.zoom >= PhotoMapPreviewState.zoomRange.upperBound)
      .help(L10n.text("확대"))
      .accessibilityLabel(L10n.text("확대"))
      .accessibilityIdentifier("map.preview.zoomIn")
    }
    .font(ViewerUIMetrics.font(.caption))
    .fixedSize(horizontal: true, vertical: false)
  }

  private var fitMenu: some View {
    ImageFitMenu(mode: preview.baseScaleMode, zoom: preview.zoom,
      identifier: "map.preview.fit", setMode: preview.setScaleMode,
      center: preview.centerImage)
  }
}
