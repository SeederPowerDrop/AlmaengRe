import SwiftUI

struct BasicUsageView: View {
  static let windowID = "basic-usage"

  @Environment(\.dismiss) private var dismiss
  @ObservedObject var shortcuts: ShortcutStore

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: "book.closed")
          .font(.system(size: 30, weight: .regular))
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 5) {
          Text("기본 사용법").font(.title2.bold())
          Text(verbatim: L10n.text("basicUsage.intro"))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(24)

      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          ForEach(BasicUsageTopic.allCases) { topic in
            HStack(alignment: .top, spacing: 14) {
              Image(systemName: topic.symbol)
                .font(.system(size: 19))
                .foregroundStyle(.tint)
                .frame(width: 26, height: 24)
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: L10n.text(topic.titleKey))
                  .font(.headline)
                Text(verbatim: topic.body(shortcuts: shortcuts))
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .lineSpacing(3)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
            }
          }
        }
        .padding(24)
      }
      Divider()

      HStack(spacing: 12) {
        Button { UserGuide.openDetailedGuide() } label: {
          Label("상세 사용설명서 (GitHub)", systemImage: "arrow.up.right.square")
        }
        Spacer(minLength: 8)
        SettingsLink { Text(verbatim: L10n.text("basicUsage.settingsButton")) }
        Button("닫기") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
    }
    .frame(minWidth: 620, minHeight: 540)
    .background(.background)
  }
}

enum BasicUsageTopic: String, CaseIterable, Identifiable {
  case open, browse, view, compare, tags, map, edit, settings

  var id: Self { self }
  var titleKey: String { "basicUsage.\(rawValue).title" }
  var bodyKey: String { "basicUsage.\(rawValue).body" }

  var symbol: String {
    switch self {
    case .open: "folder"
    case .browse: "arrow.left.arrow.right"
    case .view: "magnifyingglass"
    case .compare: "rectangle.split.2x1"
    case .tags: "tag"
    case .map: "map"
    case .edit: "slider.horizontal.3"
    case .settings: "gearshape"
    }
  }

  @MainActor
  func body(shortcuts: ShortcutStore) -> String {
    func key(_ action: ShortcutAction) -> String {
      shortcuts.binding(for: action).displayText
    }
    switch self {
    case .open:
      return L10n.format(bodyKey, key(.openFolder)) + " " + L10n.text("home.basicUsage")
    case .browse:
      let summary = L10n.format(bodyKey, key(.previousPage), key(.nextPage))
        + " " + WatermarkL10n.text("basicUsage.sort")
      let pageKeys = [-1, 1].compactMap { shortcuts.viewerPageBinding(direction: $0)?.displayText }
      return pageKeys.isEmpty ? summary
        : summary + " " + L10n.format("basicUsage.browse.pages", pageKeys.joined(separator: " / "))
    case .view:
      return L10n.format(bodyKey, key(.zoomIn), key(.zoomOut), key(.fitToWindow),
        key(.actualPixels), key(.toggleOverview), key(.toggleFocus))
        + " " + MotionMediaL10n.text("basicUsage.browse")
    case .compare:
      return L10n.format(bodyKey, key(.toggleFolderComparison))
        + " " + L10n.text("basicUsage.compare.names")
    case .edit:
      return L10n.format(bodyKey, key(.exportImage)) + "\n" + WatermarkL10n.text("basicUsage")
        + "\n" + MotionMediaL10n.text("basicUsage")
        + "\n" + L10n.text("aiPreview.basicUsage")
    case .tags, .map, .settings:
      return L10n.text(bodyKey)
    }
  }
}
