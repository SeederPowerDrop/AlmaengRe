import SwiftUI

/// A bounded chooser keeps large native format catalogs out of cascading menus.
struct LibraryFormatMenu: View {
  @Binding var query: LibraryQuery
  var availableExtensions: [String] = []
  @State private var showsPicker = false
  @State private var searchesAllFormats = false
  @State private var extensionSearch = ""
  @State private var showsFamilies = false

  private var selectedCount: Int { query.formats.count + query.fileExtensions.count }
  private var hasFormatFilter: Bool { selectedCount > 0 || query.mediaKind != .all }
  private var folderExtensions: [String] {
    LibraryFormatPicker.extensions(availableExtensions, kind: .all)
  }
  private var matchingExtensions: [String] {
    let source = searchesAllFormats
      ? Array(ImageFormatRegistry.knownExtensions.union(MediaFormatRegistry.videoExtensions).union(MediaFormatRegistry.audioExtensions))
      : folderExtensions
    return LibraryFormatPicker.extensions(source, kind: query.mediaKind, search: extensionSearch)
  }
  private var selectionSummary: String {
    if !query.fileExtensions.isEmpty {
      return query.fileExtensions.sorted().map { ".\($0)" }.joined(separator: " · ")
    }
    if !query.formats.isEmpty {
      return ImageFormatFilter.allCases.filter { query.formats.contains($0) }
        .map(\.title).joined(separator: " · ")
    }
    return query.mediaKind == .all ? L10n.text("모든 형식") : query.mediaKind.title
  }

  var body: some View {
    Button {
      extensionSearch = ""
      searchesAllFormats = folderExtensions.isEmpty
      showsPicker.toggle()
    } label: {
      HStack(spacing: 5) {
        Label(selectedCount > 0 ? L10n.format("형식 %d", selectedCount)
          : query.mediaKind == .all ? L10n.text("형식") : query.mediaKind.title,
          systemImage: "line.3.horizontal.decrease.circle")
        Image(systemName: "chevron.down").font(ViewerUIMetrics.font(size: 9, weight: .semibold))
      }
    }
    .fixedSize()
    .help(MediaFormatsL10n.text("help"))
    .accessibilityIdentifier("library.formats")
    .popover(isPresented: $showsPicker, arrowEdge: .bottom) { picker }
  }

  var picker: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(MediaFormatsL10n.text("picker.title")).font(ViewerUIMetrics.font(.headline))
        Spacer()
        Button(MediaFormatsL10n.text("picker.reset")) {
          query.formats = []
          query.fileExtensions = []
          query.mediaKind = .all
        }
        .disabled(!hasFormatFilter)
        .accessibilityIdentifier("library.formats.reset")
      }

      Picker(MediaFormatsL10n.text("kind.title"), selection: Binding(
        get: { query.mediaKind }, set: { kind in
          query.mediaKind = kind
          query.formats = []
          query.fileExtensions = []
        })) {
          ForEach(LibraryMediaKind.allCases) { kind in
            Text(MediaFormatsL10n.text("picker.kind.\(kind.rawValue)")).tag(kind)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("library.formats.kind")

      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(MediaFormatsL10n.text("picker.search"), text: $extensionSearch)
          .textFieldStyle(.plain)
          .accessibilityIdentifier("library.formats.search")
        if !extensionSearch.isEmpty {
          Button { extensionSearch = "" } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(MediaFormatsL10n.text("picker.clearSearch"))
        }
      }
      .viewerPadding(9)
      .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

      Picker(MediaFormatsL10n.text("picker.source"), selection: $searchesAllFormats) {
        Text(MediaFormatsL10n.text("picker.folder")).tag(false)
        Text(MediaFormatsL10n.text("picker.supported")).tag(true)
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("library.formats.source")

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if (query.mediaKind == .all || query.mediaKind == .images) && extensionSearch.isEmpty {
            DisclosureGroup(isExpanded: $showsFamilies) {
              LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                ForEach(ImageFormatFilter.allCases) { format in
                  FormatChoice(title: format.title, isSelected: query.formats.contains(format)) {
                    query.mediaKind = .images
                    query.fileExtensions = []
                    if query.formats.contains(format) { query.formats.remove(format) }
                    else { query.formats.insert(format) }
                  }
                }
              }
              .viewerPadding(.top, 8)
            } label: {
              Text(MediaFormatsL10n.text("families")).font(ViewerUIMetrics.font(.callout))
            }
          }
          if matchingExtensions.isEmpty {
            VStack(spacing: 10) {
              Image(systemName: "line.3.horizontal.decrease.circle")
                .font(ViewerUIMetrics.font(.title2)).foregroundStyle(.secondary)
              Text(MediaFormatsL10n.text("picker.empty"))
                .font(ViewerUIMetrics.font(.callout)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
              if !searchesAllFormats {
                Button(MediaFormatsL10n.text("picker.supported")) { searchesAllFormats = true }
              }
            }
            .viewerFrame(maxWidth: .infinity, minHeight: 150)
          } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
              ForEach(matchingExtensions, id: \.self) { fileExtension in
                FormatChoice(title: ".\(fileExtension)", isSelected: query.fileExtensions.contains(fileExtension)) {
                  query.formats = []
                  if query.fileExtensions.contains(fileExtension) { query.fileExtensions.remove(fileExtension) }
                  else { query.fileExtensions.insert(fileExtension) }
                }
                .accessibilityIdentifier("library.formats.extension.\(fileExtension)")
              }
            }
          }
        }
        .viewerPadding(2)
      }
      .viewerFrame(height: 230)

      Divider()
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(selectionSummary).font(ViewerUIMetrics.font(size: 12, weight: .medium))
            .lineLimit(2).help(selectionSummary)
          Text(MediaFormatsL10n.text("picker.hint"))
            .font(ViewerUIMetrics.font(size: 11)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Button(MediaFormatsL10n.text("picker.done")) { showsPicker = false }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("library.formats.done")
      }
    }
    .viewerPadding(16)
    .viewerFrame(width: 440)
    .controlSize(.regular)
  }
}

private struct FormatChoice: View {
  let title: String
  let isSelected: Bool
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(ViewerUIMetrics.font(size: 11))
        Text(title).font(ViewerUIMetrics.font(size: 12, weight: .medium)).lineLimit(1)
        Spacer(minLength: 0)
      }
      .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
      .viewerPadding(.horizontal, 8)
      .viewerFrame(maxWidth: .infinity, minHeight: 32)
      .background(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
        in: RoundedRectangle(cornerRadius: 7))
      .overlay(RoundedRectangle(cornerRadius: 7)
        .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.16)))
      .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

enum LibraryFormatPicker {
  /// Put familiar formats first; retain uncommon native formats behind search/scroll.
  private static let commonExtensions = ["jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "bmp",
    "avif", "jxl", "mp4", "mov", "m4v", "mpeg", "mpg", "qt", "m4a", "mp3", "wav", "aac", "aiff", "caf", "flac"]

  static func extensions(_ values: [String], kind: LibraryMediaKind, search: String = "") -> [String] {
    let terms = search.components(separatedBy: CharacterSet.whitespacesAndNewlines
      .union(CharacterSet(charactersIn: ",;/")))
      .map(LibraryMediaFilter.normalizedExtension).filter { !$0.isEmpty }
    return Set(values.map(LibraryMediaFilter.normalizedExtension).filter { !$0.isEmpty })
      .filter { value in
        let isVideo = MediaFormatRegistry.videoExtensions.contains(value)
        let isAudio = MediaFormatRegistry.audioExtensions.contains(value)
        let matchesKind = kind == .all || (kind == .videos && isVideo)
          || (kind == .audio && isAudio) || (kind == .images && !isVideo && !isAudio)
        return matchesKind
          && (terms.isEmpty || terms.contains { value.contains($0) })
      }
      .sorted { lhs, rhs in
        let left = commonExtensions.firstIndex(of: lhs) ?? commonExtensions.count
        let right = commonExtensions.firstIndex(of: rhs) ?? commonExtensions.count
        return left == right ? lhs < rhs : left < right
      }
  }
}
