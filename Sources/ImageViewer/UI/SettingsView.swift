import AppKit
import SwiftUI

struct SettingsView: View {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore
  @ObservedObject var appearance: AppearanceStore
  @StateObject private var associations = DefaultAppAssociationStore()
  @State private var associationError: String?
  @State private var selectedTab = SettingsTab.general

  private enum SettingsTab { case general, shortcuts, photoMarks, associations }

  var body: some View {
    TabView(selection: $selectedTab) {
      generalSettings
        .tabItem { Label("일반", systemImage: "gearshape") }
        .tag(SettingsTab.general)

      shortcutSettings
        .tabItem { Label("단축키", systemImage: "keyboard") }
        .tag(SettingsTab.shortcuts)

      PhotoMarkSettingsView(marks: store.photoMarks, preferences: store.photoMarkPreferences)
        .tabItem { Label(PhotoMarkL10n.text("settings.title"), systemImage: "tag") }
        .tag(SettingsTab.photoMarks)

      fileAssociationSettings
        .tabItem { Label("파일 연결", systemImage: "doc.badge.gearshape") }
        .tag(SettingsTab.associations)
    }
    .frame(width: 700, height: 560)
    .padding(18)
    .background(ViewerTheme.chromeGradient)
    .tint(ViewerTheme.accent)
    .environment(\.layoutDirection,
      L10n.languageIdentifier == "ar" ? .rightToLeft : .leftToRight)
    .alert(
      "기본 앱을 변경할 수 없음",
      isPresented: Binding(
        get: { associationError != nil },
        set: { if !$0 { associationError = nil } }
      )
    ) {
      Button("확인", role: .cancel) { associationError = nil }
    } message: {
      Text(associationError ?? "")
    }
  }

  private var generalSettings: some View {
    Form {
      Section(LanguageSettings.text("title")) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            Text(LanguageSettings.text("current"))
              .foregroundStyle(.secondary)
            Text(LanguageSettings.languageName())
              .fontWeight(.medium)
          }
          .accessibilityIdentifier("settings.currentLanguage")

          Button(action: LanguageSettings.openSystemSettings) {
            Label(LanguageSettings.text("open"), systemImage: "globe")
              .fixedSize(horizontal: true, vertical: false)
          }
          .accessibilityIdentifier("settings.language")

          Text(LanguageSettings.text("instructions"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(LanguageSettings.text("restart"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Section("화면") {
        Picker(L10n.text("appearance.title"), selection: $appearance.mode) {
          ForEach(AppAppearance.allCases) { mode in
            Label(mode.title, systemImage: mode.systemImage).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("settings.appearance")
        Text(verbatim: L10n.text("appearance.help"))
          .font(.caption)
          .foregroundStyle(.secondary)

        Toggle("HDR/EDR 출력 사용", isOn: $store.prefersHDR)
        Text("HDR 디스플레이에서 확장 밝기 범위를 사용합니다. SDR 화면에서는 자동으로 안전하게 표시됩니다.")
          .font(.caption)
          .foregroundStyle(.secondary)

        Picker("썸네일 패널 위치", selection: $store.thumbnailPanelPlacement) {
          ForEach(ThumbnailPanelPlacement.quickSelectionOrder) { placement in
            Label(placement.title, systemImage: placement.systemImage)
              .tag(placement)
          }
        }

        Picker("뷰어 파일 이름", selection: $store.filenameDisplaySize) {
          ForEach(FilenameDisplaySize.allCases) { size in
            Text(size.title).tag(size)
          }
        }
        Text("이미지 왼쪽 위의 파일 이름을 숨기거나 크기를 조절합니다. 글자는 흰색, 배경은 검정으로 표시됩니다.")
          .font(.caption)
          .foregroundStyle(.secondary)

        Toggle("고화질 확대", isOn: $store.isAntialiasingEnabled)
        Text(store.imageInterpolationMode.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
        Picker(
          "확대 비교",
          selection: Binding(
            get: { store.comparisonLayout }, set: { store.setComparisonLayout($0) }
          )
        ) {
          ForEach(MagnificationComparisonLayout.allCases) { layout in
            Text(layout.title).tag(layout)
          }
        }
        Text("같은 이미지의 확대 배율과 이동 위치를 맞춰 비교합니다. 비교를 선택하면 고화질 확대가 켜집니다.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("탐색") {
        Toggle(MotionMediaL10n.text("showVideos"), isOn: $store.showsVideos)
        Text(MotionMediaL10n.text("showVideos.help"))
          .font(.caption).foregroundStyle(.secondary)
        Toggle("폴더 트리 표시", isOn: $store.showsFolderTree)
        Text("폴더를 펼쳐 다른 폴더로 이동합니다.")
          .font(.caption).foregroundStyle(.secondary)
        Toggle("마지막 이미지 다음에 첫 이미지로 이동", isOn: $store.wrapsNavigation)
      }

      Section("전자 앨범") {
        SlideshowOptionsView(store: store)
        Text("탐색 → 전자 앨범 또는 집중 보기 하단의 재생 버튼으로 시작합니다. 사진 두 장 이상 또는 영상이 있으면 재생할 수 있습니다.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("몽땅보기") {
        Toggle("몽땅보기 번호 표시", isOn: $store.showsOverviewNumbers)
        Text("번호가 이미지 면적의 ¼ 이상을 차지하면 사진 밖 카드의 왼쪽 위로 옮깁니다.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("드래그로 영역 선택 · Shift로 추가 · ⌘로 반전 · Esc로 취소")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("이미지 로딩") {
        Picker("자원 사용", selection: $store.imageLoadingMode) {
          ForEach(ImageLoadingMode.allCases) { mode in
            Text(mode == .comfortable ? L10n.format("%@ (권장)", mode.title) : mode.title)
              .tag(mode)
          }
        }
        Text(store.imageLoadingMode.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("모든 모드에서 메모리 여유와 발열을 살피고, 다른 앱을 사용하거나 저전력 모드일 때 처리량을 줄입니다.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("외장 SSD와 SD 카드에서는 미리 읽기를 줄여 현재 보이는 사진을 먼저 불러옵니다.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("확대 이미지 이동") {
        Picker("팬 조작", selection: $store.panInteractionMode) {
          ForEach(PanInteractionMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        Text(store.panInteractionMode.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("디코더") {
        Text(MotionMediaL10n.text("supported"))
          .font(.caption).foregroundStyle(.secondary)
        LabeledContent(
          "macOS 네이티브 입력 형식",
          value: L10n.format("%d개 UTI", ImageFormatRegistry.readableTypeIdentifiers.count)
        )
        Text(ImageFormatRegistry.nativeFormatNames.joined(separator: ", "))
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)

        HStack {
          Spacer()
          Button("이미지 캐시 비우기") { store.purgeCaches() }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var shortcutSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("키보드 단축키")
          .font(.title3.weight(.semibold))
        Spacer()
        Button("기본값 복원") { shortcuts.reset() }
          .help(ShortcutHelpL10n.text("reset.help"))
      }

      HStack(alignment: .top, spacing: 12) {
        Text(ShortcutHelpL10n.text("settings.hint"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Button {
          selectedTab = .photoMarks
        } label: {
          Label(PhotoMarkL10n.text("labels.settingsLink"), systemImage: "tag")
        }
        .help(PhotoMarkL10n.text("labels.editHelp"))
      }

      GeometryReader { geometry in
        let titleColumnWidth = shortcutTitleColumnWidth(availableWidth: geometry.size.width)
        ScrollView {
          Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
            ForEach(ShortcutAction.allCases) { action in
              ShortcutRow(
                action: action,
                shortcuts: shortcuts,
                hasConflict: shortcuts.conflictingActions.contains(action),
                titleColumnWidth: titleColumnWidth
              )
            }
          }
          .padding(.vertical, 4)
        }
      }
    }
  }

  private func shortcutTitleColumnWidth(availableWidth: CGFloat) -> CGFloat {
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let widestTitle = ShortcutAction.allCases.map {
      ($0.title as NSString).size(withAttributes: [.font: font]).width
    }.max() ?? 190
    // Reserve the key picker, four modifier buttons, status icon, six grid
    // gaps and the scroll bar. Every row shares one measured title column.
    let maximumWidth = min(340, max(0, availableWidth - 342))
    return min(maximumWidth, max(190, ceil(widestTitle) + 2))
  }

  private var fileAssociationSettings: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("기본 이미지 앱")
          .font(.title3.weight(.semibold))
        Text("선택한 파일 형식만 알맹Re로 열리도록 macOS 기본 앱을 변경합니다. 필요한 경우 macOS가 확인 창을 표시합니다.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("Finder에서 이미지를 열면 한 장 보기로 시작합니다. 이미지·영상·폴더를 창에 끌어 놓아도 열 수 있습니다.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Button("지원 이미지 모두 연결") {
            associations.selectAll()
            applySelectedAssociations()
          }
          .buttonStyle(.borderedProminent)
          .fixedSize(horizontal: true, vertical: false)
          Spacer(minLength: 8)
          Button {
            associations.refresh()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .accessibilityLabel("상태 새로고침")
          .help("상태 새로고침")
        }
        HStack {
          Button("모두 선택") { associations.selectAll() }
          Button("선택 해제") { associations.clearSelection() }
        }
        .fixedSize(horizontal: true, vertical: false)
      }
      .disabled(associations.isApplying)

      Divider()

      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(associations.formats) { format in
            associationRow(format)
              .disabled(associations.isApplying)
            Divider()
          }
        }
      }

      HStack {
        if let statusMessage = associations.statusMessage {
          Label(statusMessage, systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
        } else {
          Text("선택하지 않은 형식의 기본 앱은 변경하지 않습니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          applySelectedAssociations()
        } label: {
          if associations.isApplying {
            ProgressView()
              .controlSize(.small)
          } else {
            Text("선택한 형식에 적용")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(associations.selectedFormatIDs.isEmpty || associations.isApplying)
      }
    }
  }

  private func associationRow(_ format: DefaultImageFormat) -> some View {
    HStack(spacing: 12) {
      Toggle(
        isOn: Binding(
          get: { associations.isSelected(format) },
          set: { associations.setSelected($0, format: format) }
        )
      ) {
        VStack(alignment: .leading, spacing: 2) {
          Text(format.title)
          Text(format.extensionsDescription)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
      }

      Spacer()
      associationStatus(associations.coverage(for: format))
    }
    .padding(.vertical, 7)
    .padding(.horizontal, 2)
  }

  @ViewBuilder
  private func associationStatus(_ coverage: DefaultAppCoverage) -> some View {
    switch coverage {
    case .none:
      Label("다른 앱 사용 중", systemImage: "circle")
        .foregroundStyle(.secondary)
    case .partial:
      Label("일부만 연결됨", systemImage: "circle.lefthalf.filled")
        .foregroundStyle(.orange)
    case .all:
      Label("현재 기본 앱", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    }
  }

  private func applySelectedAssociations() {
    Task {
      do {
        try await associations.applySelected()
      } catch {
        associationError =
          (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
    }
  }
}

private struct ShortcutRow: View {
  let action: ShortcutAction
  @ObservedObject var shortcuts: ShortcutStore
  let hasConflict: Bool
  let titleColumnWidth: CGFloat

  var body: some View {
    GridRow {
      Text(action.title)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: titleColumnWidth, alignment: .leading)
        .help(actionHelp)
        .accessibilityLabel(action.title)
        .accessibilityHint(action.helpDescription)

      Picker("", selection: keyBinding) {
        ForEach(KeyBinding.selectableKeys, id: \.value) { option in
          Text(option.label).tag(option.value)
        }
      }
      .labelsHidden()
      .frame(width: 90)
      .accessibilityLabel(action.title)
      .help(ShortcutHelpL10n.format("key.helpFormat", action.title) + "\n\n" + actionHelp)

      modifierToggle("⌃", name: "Control", modifier: .control, helpKey: "modifiers.control")
      modifierToggle("⌥", name: "Option", modifier: .option, helpKey: "modifiers.option")
      modifierToggle("⇧", name: "Shift", modifier: .shift, helpKey: "modifiers.shift")
      modifierToggle("⌘", name: "Command", modifier: .command, helpKey: "modifiers.command")

      Image(systemName: hasConflict ? "exclamationmark.circle.fill" : "checkmark.circle")
        .foregroundStyle(hasConflict ? .red : .secondary)
        .help(
          ShortcutHelpL10n.format(hasConflict ? "conflict.helpFormat" : "available.helpFormat",
            shortcuts.binding(for: action).displayText)
        )
        .accessibilityLabel(ShortcutHelpL10n.format(
          hasConflict ? "conflict.helpFormat" : "available.helpFormat",
          shortcuts.binding(for: action).displayText))
    }
  }

  private var actionHelp: String {
    action.helpDescription + "\n\n" + shortcuts.binding(for: action).displayText
  }

  private var keyBinding: Binding<String> {
    Binding(
      get: { shortcuts.binding(for: action).key },
      set: { newKey in
        var binding = shortcuts.binding(for: action)
        binding.key = newKey
        shortcuts.setBinding(binding, for: action)
      }
    )
  }

  private func modifierToggle(_ label: String, name: String, modifier: ShortcutModifiers,
    helpKey: String) -> some View {
    Toggle(
      label,
      isOn: Binding(
        get: { shortcuts.binding(for: action).modifiers.contains(modifier) },
        set: { shortcuts.setModifier(modifier, enabled: $0, for: action) }
      )
    )
    .toggleStyle(.button)
    .controlSize(.small)
    .frame(width: 34)
    .accessibilityLabel("\(action.title) · \(name) (\(label))")
    .help(ShortcutHelpL10n.text(helpKey))
  }
}
