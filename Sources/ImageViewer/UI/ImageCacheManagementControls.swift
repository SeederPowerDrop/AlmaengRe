import SwiftUI

struct ImageCacheManagementControls: View {
  let usage: ImageCacheUsage?
  let isRefreshing: Bool
  let isClearing: Bool
  let clearFailed: Bool
  let refresh: () -> Void
  let clear: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let usage {
        Text(verbatim: L10n.format("cache.memoryUsage", usage.formattedMemorySize))
          .accessibilityIdentifier("settings.cache.memory")
        Text(verbatim: Self.diskUsageText(for: usage))
          .accessibilityIdentifier("settings.cache.disk")
        if !usage.isDiskUsageComplete {
          Text(verbatim: L10n.text("cache.diskUsageUnavailableHelp"))
            .font(ViewerUIMetrics.font(.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings.cache.disk.unavailable")
        }
      } else {
        Text(verbatim: L10n.text("cache.calculating"))
      }
      Text(verbatim: L10n.text("cache.usageHelp"))
        .font(ViewerUIMetrics.font(.caption))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(verbatim: L10n.text("cache.clearHelp"))
        .font(ViewerUIMetrics.font(.caption))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if clearFailed {
        Text(verbatim: L10n.text("cache.clearFailed"))
          .font(ViewerUIMetrics.font(.caption))
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) { refreshButton; clearButton }
          .fixedSize(horizontal: true, vertical: false)
        VStack(alignment: .leading, spacing: 8) { refreshButton; clearButton }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  static func diskUsageText(for usage: ImageCacheUsage) -> String {
    let size = usage.isDiskUsageComplete
      ? usage.formattedDiskSize : L10n.text("cache.usageUnknown")
    return L10n.format("cache.diskUsage", size)
  }

  private var refreshButton: some View {
    Button(L10n.text(isRefreshing ? "cache.calculating" : "cache.refresh"), action: refresh)
      .disabled(isRefreshing || isClearing)
      .accessibilityIdentifier("settings.cache.refresh")
  }

  private var clearButton: some View {
    Button(L10n.text(isClearing ? "cache.clearing" : "이미지 캐시 비우기"), action: clear)
      .disabled(isClearing)
      .accessibilityIdentifier("settings.cache.clear")
  }
}
