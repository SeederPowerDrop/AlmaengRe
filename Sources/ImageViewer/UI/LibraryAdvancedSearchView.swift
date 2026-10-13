import SwiftUI

/// Draft controls commit together so typing an EXIF query never repeatedly scans a folder.
struct LibraryAdvancedSearchView: View {
  @Binding var filters: LibrarySearchFilters
  @Environment(\.dismiss) private var dismiss
  @State private var draft: LibrarySearchFilters
  @State private var dateFilter: LibraryDateFilter
  @State private var usesDate: Bool
  @State private var minimumSize: String
  @State private var maximumSize: String

  init(filters: Binding<LibrarySearchFilters>) {
    _filters = filters
    let initial = filters.wrappedValue
    _draft = State(initialValue: initial)
    _dateFilter = State(initialValue: initial.date ?? LibraryDateFilter())
    _usesDate = State(initialValue: initial.date != nil)
    _minimumSize = State(initialValue: LibrarySizeInput.text(initial.minimumBytes))
    _maximumSize = State(initialValue: LibrarySizeInput.text(initial.maximumBytes))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label(LibrarySearchL10n.text("advanced.title"), systemImage: "line.3.horizontal.decrease.circle")
          .font(.system(size: 16, weight: .semibold))
        Spacer()
        Button { dismiss() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain)
          .accessibilityLabel(LibrarySearchL10n.text("cancel"))
      }
      .padding(18)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 7) {
            heading("metadata.title")
            TextField(LibrarySearchL10n.text("metadata.placeholder"), text: $draft.metadataText)
              .accessibilityIdentifier("librarySearch.metadata")
            hint("metadata.hint")
          }
          VStack(alignment: .leading, spacing: 7) {
            heading("location.title")
            TextField(LibrarySearchL10n.text("location.placeholder"), text: $draft.locationText)
              .accessibilityIdentifier("librarySearch.location")
            Picker(LibrarySearchL10n.text("gps.title"), selection: $draft.gps) {
              ForEach(LibraryGPSFilter.allCases) { Text($0.title).tag($0) }
            }
            hint("location.hint")
          }
          Divider()
          VStack(alignment: .leading, spacing: 8) {
            heading("size.title")
            HStack(spacing: 12) {
              TextField(LibrarySearchL10n.text("size.minimum"), text: $minimumSize)
                .accessibilityIdentifier("librarySearch.minimumSize")
              Text("–").foregroundStyle(.secondary)
              TextField(LibrarySearchL10n.text("size.maximum"), text: $maximumSize)
                .accessibilityIdentifier("librarySearch.maximumSize")
            }
            hint("size.hint")
            if !validSize {
              Text(LibrarySearchL10n.text("size.invalid"))
                .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
          }
          Divider()
          VStack(alignment: .leading, spacing: 10) {
            Toggle(LibrarySearchL10n.text("date.title"), isOn: $usesDate)
              .font(.system(size: 12, weight: .semibold))
              .accessibilityIdentifier("librarySearch.dateEnabled")
            if usesDate {
              HStack {
                Picker(LibrarySearchL10n.text("date.source"), selection: $dateFilter.source) {
                  ForEach(LibraryDateSource.allCases) { Text($0.title).tag($0) }
                }
                Picker(LibrarySearchL10n.text("date.relation"), selection: $dateFilter.relation) {
                  ForEach(LibraryDateRelation.allCases) { Text($0.title).tag($0) }
                }
              }
              DatePicker(LibrarySearchL10n.text(dateFilter.relation == .between ? "date.start" : "date.day"),
                selection: Binding(get: { dateFilter.start.date },
                  set: { dateFilter.start = LibraryCalendarDay($0) }), displayedComponents: .date)
              if dateFilter.relation == .between {
                DatePicker(LibrarySearchL10n.text("date.end"),
                  selection: Binding(get: { dateFilter.end.date },
                    set: { dateFilter.end = LibraryCalendarDay($0) }), displayedComponents: .date)
              }
              hint("date.hint")
            }
          }
          hint("combine.hint")
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.regular)
        .padding(18)
      }
      .frame(maxHeight: 560)
      Divider()
      HStack {
        Button(LibrarySearchL10n.text("clear")) {
          filters = LibrarySearchFilters(); dismiss()
        }
        Spacer()
        Button(LibrarySearchL10n.text("cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(LibrarySearchL10n.text("apply")) {
          draft.minimumBytes = LibrarySizeInput.bytes(minimumSize)
          draft.maximumBytes = LibrarySizeInput.bytes(maximumSize)
          draft.date = usesDate ? dateFilter : nil
          filters = draft
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!validSize)
        .accessibilityIdentifier("librarySearch.apply")
      }
      .padding(16)
    }
    .frame(width: 460)
    .accessibilityIdentifier("librarySearch.editor")
  }

  private var validSize: Bool {
    let minimum = LibrarySizeInput.bytes(minimumSize), maximum = LibrarySizeInput.bytes(maximumSize)
    return (minimumSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || minimum != nil)
      && (maximumSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || maximum != nil)
      && (minimum == nil || maximum == nil || minimum! <= maximum!)
  }

  private func heading(_ key: String) -> some View {
    Text(LibrarySearchL10n.text(key)).font(.system(size: 12, weight: .semibold))
  }

  private func hint(_ key: String) -> some View {
    Text(LibrarySearchL10n.text(key)).font(.system(size: 11)).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
