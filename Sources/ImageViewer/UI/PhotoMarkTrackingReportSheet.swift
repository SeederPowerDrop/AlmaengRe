import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PhotoMarkTrackingReportSheet: View {
  @ObservedObject var marks: PhotoMarkStore
  @Environment(\.dismiss) private var dismiss
  @State private var isExporting = false
  @State private var exportStatus: String?
  @State private var exportError = ""
  @State private var showsExportError = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label(PhotoMarkReportL10n.text("title"), systemImage: "doc.text.magnifyingglass")
          .font(ViewerUIMetrics.font(.title3).weight(.semibold))
        Spacer()
        if marks.isRefreshingTracking { ProgressView().controlSize(.small) }
        Button(PhotoMarkReportL10n.text("refresh")) {
          Task { await marks.refreshTracking() }
        }
        .disabled(!marks.isReady || marks.isRefreshingTracking)
      }
      Text(PhotoMarkReportL10n.text("explanation"))
        .font(ViewerUIMetrics.font(.callout)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      exportControls
      HStack {
        Text(PhotoMarkReportL10n.format("unavailableFormat", marks.unavailableCount))
          .font(ViewerUIMetrics.font(.callout).weight(.medium))
        Spacer()
        Text(PhotoMarkReportL10n.format("historyFormat", marks.trackingReports.count))
          .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
      }
      if let error = marks.errorMessage {
        Text(error).font(ViewerUIMetrics.font(.caption)).foregroundStyle(.red).textSelection(.enabled)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if marks.trackingReports.isEmpty {
            Text(PhotoMarkReportL10n.text("empty"))
              .foregroundStyle(.secondary)
              .viewerFrame(maxWidth: .infinity, minHeight: 170)
          }
          ForEach(marks.trackingReports) { report in
            reportRow(report)
            Divider()
          }
        }
      }
      .background(ViewerTheme.controlFill, in: RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 3) {
        Text(PhotoMarkReportL10n.text("storage"))
          .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
        Text((marks.storageURL.path as NSString).abbreviatingWithTildeInPath)
          .font(ViewerUIMetrics.font(.caption2)).foregroundStyle(.secondary).textSelection(.enabled)
          .lineLimit(2).truncationMode(.middle)
      }
      HStack {
        Spacer()
        Button(PhotoMarkReportL10n.text("close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(isExporting)
      }
    }
    .viewerPadding(20)
    .viewerFrame(minWidth: 650, idealWidth: 780, maxWidth: 960, minHeight: 580, idealHeight: 740)
    .task { await marks.refreshTracking() }
    .alert(PhotoMarkReportL10n.text("export.failure"), isPresented: $showsExportError) {
      Button(L10n.text("확인"), role: .cancel) {}
    } message: {
      Text(exportError)
    }
  }

  private var exportControls: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 12) {
        Label(PhotoMarkReportL10n.format("export.countFormat", marks.classifiedFileCount),
          systemImage: "tag")
          .font(ViewerUIMetrics.font(.callout).weight(.semibold))
        Spacer()
        if isExporting { ProgressView().controlSize(.small) }
        Button(action: exportCSV) {
          Label(PhotoMarkReportL10n.text("export.title"), systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!marks.isReady || marks.classifiedFileCount == 0 || isExporting || marks.isRefreshingTracking)
        .accessibilityIdentifier("classification.report.exportCSV")
      }
      Text(PhotoMarkReportL10n.text("export.detail"))
        .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(PhotoMarkReportL10n.text("export.historyHint"))
        .font(ViewerUIMetrics.font(.caption2)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if isExporting {
        Text(PhotoMarkReportL10n.text("export.progress")).font(ViewerUIMetrics.font(.caption))
      } else if let exportStatus {
        Label(exportStatus, systemImage: "checkmark.circle")
          .font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
          .accessibilityIdentifier("classification.report.exportSuccess")
      }
    }
    .viewerPadding(12)
    .background(ViewerTheme.controlFill, in: RoundedRectangle(cornerRadius: 8))
  }

  private func exportCSV() {
    guard !isExporting, marks.isReady, marks.classifiedFileCount > 0 else { return }
    let panel = NSSavePanel()
    panel.title = PhotoMarkReportL10n.text("export.title")
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.canCreateDirectories = true
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    panel.nameFieldStringValue = PhotoMarkReportL10n.text("export.filename")
      + "-" + formatter.string(from: Date()) + ".csv"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    isExporting = true
    exportStatus = nil
    Task {
      defer { isExporting = false }
      do {
        let count = try await marks.exportClassifications(to: destination)
        exportStatus = PhotoMarkReportL10n.format("export.successFormat", count)
      } catch {
        exportError = error.localizedDescription
        showsExportError = true
      }
    }
  }

  private func reportRow(_ report: PhotoMarkTrackingReport) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Label(PhotoMarkReportL10n.text("event.\(report.event.rawValue)"), systemImage: icon(for: report.event))
          .font(ViewerUIMetrics.font(.caption).weight(.semibold))
          .foregroundStyle(report.event == .unavailable ? Color.orange : Color.secondary)
        Text(report.filename).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
        Text(report.observedAt, format: .dateTime.year().month().day().hour().minute())
          .font(ViewerUIMetrics.font(.caption2)).foregroundStyle(.secondary)
      }
      Text(report.classificationDescription).font(ViewerUIMetrics.font(.caption)).foregroundStyle(.secondary)
      if let previous = report.previousURL,
        report.currentURL?.standardizedFileURL != previous.standardizedFileURL {
        Text(PhotoMarkReportL10n.format("previousFormat", previous.path))
          .font(ViewerUIMetrics.font(.caption2)).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if let current = report.currentURL {
        Text(PhotoMarkReportL10n.format("currentFormat", current.path))
          .font(ViewerUIMetrics.font(.caption2)).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if let entry = report.archiveEntryPath {
        Text(PhotoMarkReportL10n.format("archiveEntryFormat", entry))
          .font(ViewerUIMetrics.font(.caption2)).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if report.event == .unavailable {
        Text(PhotoMarkReportL10n.text("unavailableHint"))
          .font(ViewerUIMetrics.font(.caption2)).foregroundStyle(.secondary)
      }
    }
    .viewerPadding(12)
    .viewerFrame(maxWidth: .infinity, alignment: .leading)
  }

  private func icon(for event: PhotoMarkTrackingReport.Event) -> String {
    switch event {
    case .unavailable: "exclamationmark.triangle"
    case .relocated: "arrow.triangle.branch"
    case .recovered: "checkmark.circle"
    }
  }
}
