import SwiftUI

struct HomeView: View {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.locale) private var appLocale
  @ObservedObject var store: AppStore
  @ObservedObject private var recentPhotos: RecentPhotoStore
  private let localeIdentifier: String?
  private var formattingLocale: Locale { localeIdentifier.map(Locale.init(identifier:)) ?? .current }
  private var strings: HomeStrings {
    // Observe the language environment without replacing the user's regional
    // date and number formats. The explicit locale is only for layout previews.
    _ = appLocale
    return HomeStrings(languageIdentifier: localeIdentifier ?? L10n.languageIdentifier, locale: formattingLocale)
  }

  init(store: AppStore, localeIdentifier: String? = nil) {
    self.localeIdentifier = localeIdentifier
    self.store = store
    _recentPhotos = ObservedObject(wrappedValue: store.recentPhotos)
  }

  private static let brandIcon: NSImage? = {
    if let url = Bundle.main.url(forResource: "AppBrandIcon", withExtension: "png") {
      return NSImage(contentsOf: url)
    }
    return Bundle.module.url(forResource: "AppBrandIcon", withExtension: "png")
      .flatMap(NSImage.init(contentsOf:))
  }()

  var body: some View {
    GeometryReader { geometry in
      let contentWidth = min(1_100, max(0, geometry.size.width - 64))
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          hero
          VStack(alignment: .leading, spacing: 18) {
            recentHeading
            if !recentPhotos.homeFolders.isEmpty {
              ForEach(recentPhotos.homeFolders) { folder in
                RecentFolderCard(folder: folder, strings: strings, isBusy: !store.canShowHome,
                  open: { Task { await store.openRecentFolder(folder) } },
                  remove: { store.removeRecentFolder(folder.id) },
                  openPhoto: { photo in Task { await store.openRecentPhoto(photo) } },
                  removePhoto: { store.removeRecentPhoto($0.id) })
              }
            } else {
              emptyHistory
            }
          }
        }
        .frame(width: contentWidth)
        .viewerPadding(.vertical, 30)
        .frame(maxWidth: .infinity)
      }
      .background(ViewerTheme.chromeGradient)
    }
    .environment(\.locale, formattingLocale)
    .environment(\.layoutDirection, strings.languageIdentifier == "ar" ? .rightToLeft : .leftToRight)
    .accessibilityIdentifier("home.screen")
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 20) {
        Group {
          if let icon = Self.brandIcon {
            Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
          } else {
            Image(systemName: "photo.on.rectangle.angled")
              .resizable().scaledToFit().foregroundStyle(ViewerTheme.accent).viewerPadding(16)
          }
        }
        .viewerFrame(width: 86, height: 86)
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "알맹Re")
              .font(ViewerUIMetrics.font(size: 34, weight: .bold, design: .rounded))
              .tracking(-0.8)
              .accessibilityAddTraits(.isHeader)
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
              Text(verbatim: version)
                .font(ViewerUIMetrics.font(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(ViewerTheme.accent)
                .viewerPadding(.horizontal, 8).viewerPadding(.vertical, 3)
                .background(ViewerTheme.selection, in: Capsule())
            }
          }
          Text(verbatim: strings.text("home.subtitle"))
            .font(ViewerUIMetrics.font(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button { openWindow(id: AboutView.windowID) } label: {
            Label(strings.text("앱 소개"), systemImage: "info.circle")
              .fixedSize(horizontal: true, vertical: false)
              .viewerFrame(minWidth: 90)
          }
          .buttonStyle(ViewerActionButtonStyle())
          .accessibilityIdentifier("home.about")
          .viewerPadding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .trailing, spacing: 8) {
          Button { store.chooseItems() } label: {
            Label(strings.text("열기…"), systemImage: "folder.badge.plus")
              .fixedSize(horizontal: true, vertical: false)
              .viewerFrame(minWidth: 130)
          }
          .buttonStyle(ViewerActionButtonStyle(prominent: true))
          .accessibilityIdentifier("home.open")
          .disabled(!store.canShowHome)
          if store.canResumeWorkspace {
            Button { Task { await store.resumeWorkspace() } } label: {
              Text(verbatim: strings.text("home.resume"))
                .fixedSize(horizontal: true, vertical: false)
                .viewerFrame(minWidth: 130)
            }
            .buttonStyle(ViewerActionButtonStyle())
            .accessibilityIdentifier("home.resume")
            .disabled(!store.canShowHome)
          }
        }
      }
      Label(strings.text("이미지·영상·폴더를 여기에 놓으세요."), systemImage: "square.and.arrow.down")
        .font(ViewerUIMetrics.font(size: 12))
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("home.dropHint")
      inspiration
    }
    .viewerPadding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ViewerTheme.panelGradient, in: RoundedRectangle(cornerRadius: 18))
    .overlay {
      RoundedRectangle(cornerRadius: 18).strokeBorder(ViewerTheme.separator, lineWidth: 0.75)
    }
  }

  @ViewBuilder
  private var inspiration: some View {
    if let quote = HomeInspiration.launchQuote,
      let localized = quote.localized(for: strings.languageIdentifier) {
      VStack(alignment: .leading, spacing: 7) {
        Text(verbatim: localized.text)
          .font(ViewerUIMetrics.font(size: 16, weight: .medium))
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("home.quote.text")
        Text(verbatim: "\(localized.author) · \(localized.work)")
          .font(ViewerUIMetrics.font(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("home.quote.attribution")
        HStack(spacing: 10) {
          Link(destination: quote.sourceURL) {
            Label(strings.text("home.quote.source"), systemImage: "arrow.up.right.square")
          }
          .accessibilityIdentifier("home.quote.source")
          if localized.isTranslation {
            Text(verbatim: strings.text("home.quote.translation"))
              .foregroundStyle(.secondary)
          }
        }
        .font(ViewerUIMetrics.font(size: 11))
      }
      .viewerPadding(.vertical, 5)
      .viewerPadding(.leading, 13)
      .overlay(alignment: .leading) {
        Capsule().fill(ViewerTheme.accent.opacity(0.5)).frame(width: 2)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("home.quote")
    }
  }

  private var recentHeading: some View {
    HStack(alignment: .center, spacing: 20) {
      VStack(alignment: .leading, spacing: 5) {
        Text(verbatim: strings.text("home.recent"))
          .font(ViewerUIMetrics.font(size: 19, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Text(verbatim: strings.text("home.recent.detail"))
          .font(ViewerUIMetrics.font(size: 12)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      if !recentPhotos.folders.isEmpty {
        Button(strings.text("home.clear")) { store.clearRecentPhotos() }
          .buttonStyle(ViewerToolButtonStyle())
          .fixedSize(horizontal: true, vertical: false)
          .help(strings.text("home.clear.help"))
          .accessibilityIdentifier("home.clear")
      }
    }
  }

  private var emptyHistory: some View {
    VStack(spacing: 10) {
      Image(systemName: "folder.badge.plus")
        .font(ViewerUIMetrics.font(size: 27, weight: .light))
        .foregroundStyle(.secondary)
        .viewerPadding(.bottom, 4)
        .accessibilityHidden(true)
      Text(verbatim: strings.text("home.empty"))
        .font(ViewerUIMetrics.font(size: 14, weight: .medium))
      Text(verbatim: strings.text("home.empty.detail"))
        .font(ViewerUIMetrics.font(size: 12)).foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, minHeight: 180)
    .viewerPadding(.horizontal, 20)
    .background(ViewerTheme.panel.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14).strokeBorder(ViewerTheme.separator, lineWidth: 0.75)
    }
    .accessibilityIdentifier("home.empty")
  }
}

private struct RecentFolderCard: View {
  let folder: RecentFolder
  let strings: HomeStrings
  let isBusy: Bool
  let open: () -> Void
  let remove: () -> Void
  let openPhoto: (RecentPhoto) -> Void
  let removePhoto: (RecentPhoto) -> Void

  private let columns = Array(repeating: GridItem(.flexible(minimum: 100), spacing: 12),
    count: RecentPhotoStore.homePhotoLimit)

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 14) {
        Image(systemName: folder.isArchive ? "doc.zipper" : "folder.fill")
          .font(ViewerUIMetrics.font(size: 23, weight: .medium))
          .foregroundStyle(ViewerTheme.accent)
          .viewerFrame(width: 46, height: 46)
          .background(ViewerTheme.selection, in: RoundedRectangle(cornerRadius: 12))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 5) {
          Text(verbatim: folder.name)
            .font(ViewerUIMetrics.font(size: 17, weight: .semibold))
            .lineLimit(1).truncationMode(.middle)
            .accessibilityAddTraits(.isHeader)
          Text(verbatim: folder.location.url.path)
            .font(ViewerUIMetrics.font(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .help(folder.location.url.path)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .trailing, spacing: 5) {
          Text(verbatim: strings.format("home.folder.count", folder.photos.count))
            .font(ViewerUIMetrics.font(size: 11, weight: .medium))
          Text(folder.lastOpened, format: .dateTime.month(.abbreviated).day())
            .font(ViewerUIMetrics.font(size: 11))
            .foregroundStyle(.secondary)
        }
        Button(action: open) {
          Label(strings.text(folder.isArchive ? "home.archive.open" : "home.folder.open"),
            systemImage: "arrow.up.forward")
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(ViewerToolButtonStyle())
        .disabled(isBusy)
        .accessibilityLabel(strings.format("home.folder.open.label", folder.name))
        .accessibilityIdentifier("home.folder.open.\(folder.id)")
        Menu {
          Button(strings.text("home.folder.remove"), action: remove)
        } label: {
          Image(systemName: "ellipsis").font(ViewerUIMetrics.font(size: 16, weight: .semibold))
            .viewerFrame(width: 22, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(strings.format("home.folder.remove.label", folder.name))
        .accessibilityIdentifier("home.folder.menu.\(folder.id)")
      }
      if folder.photos.isEmpty {
        Label(strings.text("home.folder.empty"), systemImage: "photo.on.rectangle")
          .font(ViewerUIMetrics.font(size: 12))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 90)
          .background(ViewerTheme.sidebar.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
      } else {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
          ForEach(folder.photos) { photo in
            RecentPhotoCard(photo: photo, strings: strings, isBusy: isBusy,
              open: { openPhoto(photo) }, remove: { removePhoto(photo) })
          }
        }
      }
    }
    .viewerPadding(20)
    .background(ViewerTheme.panelGradient, in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16).strokeBorder(ViewerTheme.separator, lineWidth: 0.75)
    }
    .shadow(color: .black.opacity(0.025), radius: 8, y: 3)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("home.folder.\(folder.id)")
  }
}

private struct RecentPhotoCard: View {
  let photo: RecentPhoto
  let strings: HomeStrings
  let isBusy: Bool
  let open: () -> Void
  let remove: () -> Void
  private let preview: NSImage?
  @State private var hovered = false

  init(photo: RecentPhoto, strings: HomeStrings, isBusy: Bool, open: @escaping () -> Void, remove: @escaping () -> Void) {
    self.photo = photo
    self.strings = strings
    self.isBusy = isBusy
    self.open = open
    self.remove = remove
    // Only the already bounded, persisted JPEG is decoded. Drawing Home never
    // touches the original file or resolves/extracts a stored ZIP location.
    preview = photo.thumbnailData.flatMap(NSImage.init(data:))
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button(action: open) {
        VStack(spacing: 0) {
          thumbnail
          Text(verbatim: photo.filename)
            .font(ViewerUIMetrics.font(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .viewerPadding(.horizontal, 10).viewerPadding(.vertical, 10)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
      }
      .buttonStyle(.plain)
      .disabled(isBusy)
      .accessibilityLabel(strings.format("home.open.label", photo.filename))
      .accessibilityIdentifier("home.recent.open.\(photo.id)")

      // This is a sibling of the open button, so removing never opens the photo.
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(ViewerUIMetrics.font(size: 10, weight: .semibold))
          .foregroundStyle(.primary)
          .viewerFrame(width: 26, height: 26)
          .background(.regularMaterial, in: Circle())
          .overlay { Circle().strokeBorder(ViewerTheme.separator, lineWidth: 0.75) }
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .viewerPadding(6)
      .help(strings.format("home.remove.label", photo.filename))
      .accessibilityLabel(strings.format("home.remove.label", photo.filename))
      .accessibilityIdentifier("home.recent.remove.\(photo.id)")
    }
    .background(ViewerTheme.panelGradient)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(hovered ? ViewerTheme.selectionBorder : ViewerTheme.separator,
          lineWidth: hovered ? 1.25 : 0.75)
        .allowsHitTesting(false)
    }
    .onHover { hovered = $0 }
    .contextMenu {
      Button(strings.text("home.remove"), action: remove)
    }
  }

  private var thumbnail: some View {
    // The background determines the height from the grid's finite column width.
    // Overlay content cannot make the card grow in the vertical ScrollView.
    ViewerTheme.sidebar
      .aspectRatio(1.42, contentMode: .fit)
      .overlay {
        if let preview {
          Image(nsImage: preview)
            .resizable().interpolation(.high).scaledToFit()
            .viewerPadding(10)
            .accessibilityHidden(true)
        } else {
          VStack(spacing: 8) {
            Image(systemName: "photo")
              .font(ViewerUIMetrics.font(size: 25, weight: .light))
            Text(verbatim: strings.text("home.preview.unavailable"))
              .font(ViewerUIMetrics.font(size: 11))
              .lineLimit(2)
              .multilineTextAlignment(.center)
          }
          .foregroundStyle(.secondary)
          .viewerPadding(12)
        }
      }
      .clipped()
  }
}

/// Pass the same resolved app language through recent cards and previews. This
/// also lets layout checks render real translations without changing macOS.
private struct HomeStrings {
  let languageIdentifier: String
  let locale: Locale

  func text(_ key: String) -> String {
    L10n.text(key, localeIdentifier: languageIdentifier)
  }

  func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), locale: locale, arguments: arguments)
  }
}
