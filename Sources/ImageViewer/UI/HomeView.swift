import SwiftUI

struct HomeView: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var store: AppStore
  @ObservedObject private var recentPhotos: RecentPhotoStore

  init(store: AppStore) {
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
                RecentFolderCard(folder: folder, isBusy: !store.canShowHome,
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
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
      }
      .background(ViewerTheme.chromeGradient)
    }
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
              .resizable().scaledToFit().foregroundStyle(ViewerTheme.accent).padding(16)
          }
        }
        .frame(width: 86, height: 86)
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "알맹Re")
              .font(.system(size: 34, weight: .bold, design: .rounded))
              .tracking(-0.8)
              .accessibilityAddTraits(.isHeader)
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
              Text(verbatim: version)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(ViewerTheme.accent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(ViewerTheme.selection, in: Capsule())
            }
          }
          Text(verbatim: L10n.text("home.subtitle"))
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button { openWindow(id: AboutView.windowID) } label: {
            Label("앱 소개", systemImage: "info.circle")
              .frame(minWidth: 90)
          }
          .buttonStyle(ViewerActionButtonStyle())
          .accessibilityIdentifier("home.about")
          .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .trailing, spacing: 8) {
          Button { store.chooseItems() } label: {
            Label("열기…", systemImage: "folder.badge.plus")
              .frame(minWidth: 130)
          }
          .buttonStyle(ViewerActionButtonStyle(prominent: true))
          .accessibilityIdentifier("home.open")
          .disabled(!store.canShowHome)
          if store.canResumeWorkspace {
            Button { Task { await store.resumeWorkspace() } } label: {
              Text(verbatim: L10n.text("home.resume"))
                .frame(minWidth: 130)
            }
            .buttonStyle(ViewerActionButtonStyle())
            .accessibilityIdentifier("home.resume")
            .disabled(!store.canShowHome)
          }
        }
      }
      Label(L10n.text("이미지·영상·폴더를 여기에 놓으세요."), systemImage: "square.and.arrow.down")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("home.dropHint")
      inspiration
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ViewerTheme.panelGradient, in: RoundedRectangle(cornerRadius: 18))
    .overlay {
      RoundedRectangle(cornerRadius: 18).strokeBorder(ViewerTheme.separator, lineWidth: 0.75)
    }
  }

  @ViewBuilder
  private var inspiration: some View {
    if let quote = HomeInspiration.launchQuote,
      let localized = quote.localized(for: L10n.languageIdentifier) {
      VStack(alignment: .leading, spacing: 7) {
        Text(verbatim: localized.text)
          .font(.system(size: 16, weight: .medium))
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("home.quote.text")
        Text(verbatim: "\(localized.author) · \(localized.work)")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("home.quote.attribution")
        HStack(spacing: 10) {
          Link(destination: quote.sourceURL) {
            Label(L10n.text("home.quote.source"), systemImage: "arrow.up.right.square")
          }
          .accessibilityIdentifier("home.quote.source")
          if localized.isTranslation {
            Text(verbatim: L10n.text("home.quote.translation"))
              .foregroundStyle(.secondary)
          }
        }
        .font(.system(size: 11))
      }
      .padding(.vertical, 5)
      .padding(.leading, 13)
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
        Text(verbatim: L10n.text("home.recent"))
          .font(.system(size: 19, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Text(verbatim: L10n.text("home.recent.detail"))
          .font(.system(size: 12)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if !recentPhotos.folders.isEmpty {
        Button(L10n.text("home.clear")) { store.clearRecentPhotos() }
          .buttonStyle(ViewerToolButtonStyle())
          .help(L10n.text("home.clear.help"))
          .accessibilityIdentifier("home.clear")
      }
    }
  }

  private var emptyHistory: some View {
    VStack(spacing: 10) {
      Image(systemName: "folder.badge.plus")
        .font(.system(size: 27, weight: .light))
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
      Text(verbatim: L10n.text("home.empty"))
        .font(.system(size: 14, weight: .medium))
      Text(verbatim: L10n.text("home.empty.detail"))
        .font(.system(size: 12)).foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, minHeight: 180)
    .padding(.horizontal, 20)
    .background(ViewerTheme.panel.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14).strokeBorder(ViewerTheme.separator, lineWidth: 0.75)
    }
    .accessibilityIdentifier("home.empty")
  }
}

private struct RecentFolderCard: View {
  let folder: RecentFolder
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
          .font(.system(size: 23, weight: .medium))
          .foregroundStyle(ViewerTheme.accent)
          .frame(width: 46, height: 46)
          .background(ViewerTheme.selection, in: RoundedRectangle(cornerRadius: 12))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 5) {
          Text(verbatim: folder.name)
            .font(.system(size: 17, weight: .semibold))
            .lineLimit(1).truncationMode(.middle)
            .accessibilityAddTraits(.isHeader)
          Text(verbatim: folder.location.url.path)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .help(folder.location.url.path)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .trailing, spacing: 5) {
          Text(verbatim: L10n.format("home.folder.count", folder.photos.count))
            .font(.system(size: 11, weight: .medium))
          Text(folder.lastOpened, format: .dateTime.month(.abbreviated).day())
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        Button(action: open) {
          Label(L10n.text(folder.isArchive ? "home.archive.open" : "home.folder.open"),
            systemImage: "arrow.up.forward")
        }
        .buttonStyle(ViewerToolButtonStyle())
        .disabled(isBusy)
        .accessibilityLabel(L10n.format("home.folder.open.label", folder.name))
        .accessibilityIdentifier("home.folder.open.\(folder.id)")
        Menu {
          Button(L10n.text("home.folder.remove"), action: remove)
        } label: {
          Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
            .frame(width: 22, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.format("home.folder.remove.label", folder.name))
        .accessibilityIdentifier("home.folder.menu.\(folder.id)")
      }
      if folder.photos.isEmpty {
        Label(L10n.text("home.folder.empty"), systemImage: "photo.on.rectangle")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 90)
          .background(ViewerTheme.sidebar.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
      } else {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
          ForEach(folder.photos) { photo in
            RecentPhotoCard(photo: photo, isBusy: isBusy,
              open: { openPhoto(photo) }, remove: { removePhoto(photo) })
          }
        }
      }
    }
    .padding(20)
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
  let isBusy: Bool
  let open: () -> Void
  let remove: () -> Void
  private let preview: NSImage?
  @State private var hovered = false

  init(photo: RecentPhoto, isBusy: Bool, open: @escaping () -> Void, remove: @escaping () -> Void) {
    self.photo = photo
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
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 10)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
      }
      .buttonStyle(.plain)
      .disabled(isBusy)
      .accessibilityLabel(L10n.format("home.open.label", photo.filename))
      .accessibilityIdentifier("home.recent.open.\(photo.id)")

      // This is a sibling of the open button, so removing never opens the photo.
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.primary)
          .frame(width: 26, height: 26)
          .background(.regularMaterial, in: Circle())
          .overlay { Circle().strokeBorder(ViewerTheme.separator, lineWidth: 0.75) }
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .padding(6)
      .help(L10n.format("home.remove.label", photo.filename))
      .accessibilityLabel(L10n.format("home.remove.label", photo.filename))
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
      Button(L10n.text("home.remove"), action: remove)
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
            .padding(10)
            .accessibilityHidden(true)
        } else {
          VStack(spacing: 8) {
            Image(systemName: "photo")
              .font(.system(size: 25, weight: .light))
            Text(verbatim: L10n.text("home.preview.unavailable"))
              .font(.system(size: 11))
              .lineLimit(2)
              .multilineTextAlignment(.center)
          }
          .foregroundStyle(.secondary)
          .padding(12)
        }
      }
      .clipped()
  }
}
