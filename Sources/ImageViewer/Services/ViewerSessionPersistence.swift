import Foundation

@MainActor
final class ViewerSessionPersistence {
  private let defaults: UserDefaults
  static let sessionKey = "ImageViewer.LastSession.v1"
  static let favoritesKey = "ImageViewer.FavoriteFolders.v1"

  init(defaults: UserDefaults) { self.defaults = defaults }

  func loadSession() -> ViewerSession? {
    guard let data = defaults.data(forKey: Self.sessionKey),
      let session = try? JSONDecoder().decode(ViewerSession.self, from: data),
      session.version == 1 else { return nil }
    return session
  }

  func save(_ session: ViewerSession) {
    guard let data = try? JSONEncoder().encode(session) else { return }
    defaults.set(data, forKey: Self.sessionKey)
  }

  func loadFavorites() -> [FavoriteFolder] {
    guard let data = defaults.data(forKey: Self.favoritesKey) else { return [] }
    return (try? JSONDecoder().decode([FavoriteFolder].self, from: data)) ?? []
  }

  func saveFavorites(_ favorites: [FavoriteFolder]) {
    guard let data = try? JSONEncoder().encode(favorites) else { return }
    defaults.set(data, forKey: Self.favoritesKey)
  }
}
