import SwiftUI

struct SettingsView: View {
  @ObservedObject var store: AppStore
  @ObservedObject var shortcuts: ShortcutStore

  var body: some View {
    TabView {
      generalSettings
        .tabItem { Label("일반", systemImage: "gearshape") }

      shortcutSettings
        .tabItem { Label("단축키", systemImage: "keyboard") }
    }
    .frame(width: 650, height: 520)
    .padding(18)
  }

  private var generalSettings: some View {
    Form {
      Section("화면") {
        Toggle("HDR/EDR 출력 사용", isOn: $store.prefersHDR)
        Text("HDR 디스플레이에서 확장 밝기 범위를 사용합니다. SDR 화면에서는 자동으로 안전하게 표시됩니다.")
          .font(.caption)
          .foregroundStyle(.secondary)

        Picker("썸네일 패널 위치", selection: $store.thumbnailPanelPlacement) {
          ForEach(ThumbnailPanelPlacement.allCases) { placement in
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
      }

      Section("탐색") {
        Toggle("마지막 이미지 다음에 첫 이미지로 이동", isOn: $store.wrapsNavigation)
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
        LabeledContent(
          "macOS 네이티브 입력 형식", value: "\(ImageFormatRegistry.readableTypeIdentifiers.count)개 UTI")
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
        VStack(alignment: .leading) {
          Text("키보드 단축키")
            .font(.title3.weight(.semibold))
          Text("같은 조합이 겹치면 빨간색으로 표시됩니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("기본값 복원") { shortcuts.reset() }
      }

      ScrollView {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
          ForEach(ShortcutAction.allCases) { action in
            ShortcutRow(
              action: action,
              shortcuts: shortcuts,
              hasConflict: shortcuts.conflictingActions.contains(action)
            )
          }
        }
        .padding(.vertical, 4)
      }
    }
  }
}

private struct ShortcutRow: View {
  let action: ShortcutAction
  @ObservedObject var shortcuts: ShortcutStore
  let hasConflict: Bool

  var body: some View {
    GridRow {
      Text(action.title)
        .frame(width: 190, alignment: .leading)

      Picker("", selection: keyBinding) {
        ForEach(KeyBinding.selectableKeys, id: \.value) { option in
          Text(option.label).tag(option.value)
        }
      }
      .labelsHidden()
      .frame(width: 90)

      modifierToggle("⌃", modifier: .control)
      modifierToggle("⌥", modifier: .option)
      modifierToggle("⇧", modifier: .shift)
      modifierToggle("⌘", modifier: .command)

      Image(systemName: hasConflict ? "exclamationmark.circle.fill" : "checkmark.circle")
        .foregroundStyle(hasConflict ? .red : .secondary)
        .help(hasConflict ? "다른 동작과 단축키가 겹칩니다." : shortcuts.binding(for: action).displayText)
    }
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

  private func modifierToggle(_ label: String, modifier: ShortcutModifiers) -> some View {
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
  }
}
