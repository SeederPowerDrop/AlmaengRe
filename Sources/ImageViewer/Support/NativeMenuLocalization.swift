import AppKit

/// AppKit's built-in menus retain their launch language after SwiftUI changes
/// locale. Update only their titles; keep the native actions and validation.
@MainActor
public enum NativeMenuLocalization {
  private static var observer: NativeMenuLocalizationObserver?

  /// SwiftUI can rebuild AppKit's standard menus when a window or appearance
  /// changes. Follow those public menu notifications, rather than a timer or
  /// replacing SwiftUI's menu delegates/actions.
  public static func startObserving() {
    guard observer == nil else { return }
    let newObserver = NativeMenuLocalizationObserver(
      menu: { NSApp.mainMenu }, language: { L10n.languageIdentifier },
      appName: { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "알맹Re" },
      servicesMenu: { NSApp.servicesMenu })
    observer = newObserver
    newObserver.start()
  }

  public static func apply(to menu: NSMenu? = NSApp.mainMenu) {
    apply(to: menu, language: L10n.languageIdentifier,
      appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "알맹Re",
      servicesMenu: NSApp.servicesMenu)
  }

  /// Explicit inputs let tests exercise round trips without changing NSApp's
  /// real menu, the app preference, or the user's system language.
  static func apply(to menu: NSMenu?, language: String, appName: String = "알맹Re",
    servicesMenu: NSMenu? = nil) {
    guard let menu else { return }
    for item in menu.items {
      guard let submenu = item.submenu else { continue }
      guard let kind = menuKind(for: item) else { continue }
      if kind != "app" {
        let title = text(kind, language: language)
        if item.title != title { item.title = title }
        if submenu.title != title { submenu.title = title }
        translateActions(in: submenu, kind: kind, language: language, appName: appName)
      } else {
        translateActions(in: submenu, kind: "app", language: language, appName: appName)
        for child in submenu.items {
          if let servicesMenu, child.submenu === servicesMenu {
            let title = text("services", language: language)
            if child.title != title { child.title = title }
            if servicesMenu.title != title { servicesMenu.title = title }
          } else if child.keyEquivalent == ",", child.keyEquivalentModifierMask == [.command],
            knownTitles(for: "settings").contains(child.title) {
            // SwiftUI owns this action and exposes no public AppKit selector.
            // Its exact standard title + Command-comma identify it in the app
            // menu without matching document names or private selector names.
            let title = text("settings", language: language)
            if child.title != title { child.title = title }
          }
        }
      }
    }
  }

  fileprivate static func manages(_ menu: NSMenu, in root: NSMenu) -> Bool {
    menu === root || root.items.contains {
      $0.submenu === menu && menuKind(for: $0) != nil
    }
  }

  private static func menuKind(for item: NSMenuItem) -> String? {
    guard let submenu = item.submenu else { return nil }
    if let key = standardMenuKeys.first(where: {
      knownTitles(for: $0).contains(item.title) || knownTitles(for: $0).contains(submenu.title)
    }) { return key }
    if submenu.items.contains(where: {
      $0.action == #selector(NSApplication.terminate(_:))
        || $0.action == #selector(NSApplication.hide(_:))
    }) { return "app" }
    return nil
  }

  private static let standardMenuKeys = ["file", "edit", "view", "window", "help"]
  private static let knownTitleSets: [String: Set<String>] = Dictionary(uniqueKeysWithValues:
    (standardMenuKeys + ["settings", "undo", "redo"]).map { key in
      var values = Set(L10n.supportedLocalizations.map { text(key, language: $0) })
      if key == "settings" {
        for title in Array(values) {
          values.insert(title.replacingOccurrences(of: "…", with: "..."))
          values.insert(title.replacingOccurrences(of: "…", with: " …"))
        }
      }
      return (key, values)
    })

  private static func translateActions(in menu: NSMenu, kind: String,
    language: String, appName: String) {
    let actions: [String: String]
    switch kind {
    case "app":
      actions = [
        NSStringFromSelector(#selector(NSApplication.hide(_:))): "hide",
        NSStringFromSelector(#selector(NSApplication.hideOtherApplications(_:))): "hideOthers",
        NSStringFromSelector(#selector(NSApplication.unhideAllApplications(_:))): "showAll",
        NSStringFromSelector(#selector(NSApplication.terminate(_:))): "quit",
      ]
    case "file":
      actions = [NSStringFromSelector(#selector(NSWindow.performClose(_:))): "close"]
    case "edit":
      actions = ["undo:": "undo", "redo:": "redo",
        "cut:": "cut", "copy:": "copy", "paste:": "paste", "selectAll:": "selectAll"]
    case "window":
      actions = [
        NSStringFromSelector(#selector(NSWindow.performMiniaturize(_:))): "minimize",
        NSStringFromSelector(#selector(NSWindow.performZoom(_:))): "zoom",
        NSStringFromSelector(#selector(NSApplication.arrangeInFront(_:))): "bringAllToFront",
      ]
    default: return
    }
    for item in menu.items {
      guard let action = item.action, let key = actions[NSStringFromSelector(action)] else { continue }
      var title = text(key, language: language)
      if key == "hide" || key == "quit" {
        title = String(format: title, locale: Locale(identifier: language), appName)
      } else if key == "undo" || key == "redo" {
        // Keep an undo action's document/operation description verbatim. It is
        // user data, not a localization key, and may contain arbitrary text.
        let original = item.title
        if let prefix = knownTitles(for: key).sorted(by: { $0.count > $1.count }).first(where: {
          original == $0 || original.hasPrefix($0 + " ")
        }) {
          title += String(original.dropFirst(prefix.count))
        } else { continue }
      }
      if item.title != title { item.title = title }
    }
  }

  private static func knownTitles(for key: String) -> Set<String> {
    knownTitleSets[key] ?? []
  }

  private static func text(_ key: String, language: String) -> String {
    LanguageSettings.text("native.\(key)", language: language)
  }
}

/// Batches a SwiftUI menu rebuild into one update on the next main-run-loop
/// turn. Common modes also run while a menu is tracking. The observer only
/// follows the current main menu and its standard direct children, never a
/// document/context menu or Services' nested contents.
@MainActor
final class NativeMenuLocalizationObserver: NSObject {
  typealias Schedule = (@escaping @MainActor @Sendable () -> Void) -> Void

  private let menu: @MainActor () -> NSMenu?
  private let language: @MainActor () -> String
  private let appName: @MainActor () -> String
  private let servicesMenu: @MainActor () -> NSMenu?
  private let schedule: Schedule
  private var started = false
  private var queued = false
  private var applying = false

  init(menu: @escaping @MainActor () -> NSMenu?, language: @escaping @MainActor () -> String,
    appName: @escaping @MainActor () -> String = { "알맹Re" },
    servicesMenu: @escaping @MainActor () -> NSMenu? = { nil },
    schedule: @escaping Schedule = { work in
      RunLoop.main.perform(inModes: [.common, .eventTracking, .modalPanel]) {
        MainActor.assumeIsolated { work() }
      }
    }) {
    self.menu = menu
    self.language = language
    self.appName = appName
    self.servicesMenu = servicesMenu
    self.schedule = schedule
    super.init()
  }

  func start() {
    guard !started else { return }
    started = true
    for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification,
      NSMenu.didBeginTrackingNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(menuChanged(_:)),
        name: name, object: nil)
    }
    NotificationCenter.default.addObserver(self, selector: #selector(applicationActivated(_:)),
      name: NSApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(applicationActivated(_:)),
      name: NSWindow.didBecomeKeyNotification, object: nil)
    enqueue()
  }

  func stop() {
    NotificationCenter.default.removeObserver(self)
    started = false
  }

  @objc private func menuChanged(_ notification: Notification) {
    guard !applying, let changed = notification.object as? NSMenu, let root = menu(),
      NativeMenuLocalization.manages(changed, in: root) else { return }
    if notification.name == NSMenu.didBeginTrackingNotification { applyNow() }
    enqueue()
  }

  @objc private func applicationActivated(_ notification: Notification) { enqueue() }

  private func enqueue() {
    guard started, !queued, !applying else { return }
    queued = true
    schedule { [weak self] in
      guard let self else { return }
      self.queued = false
      guard self.started else { return }
      self.applyNow()
    }
  }

  private func applyNow() {
    guard started, !applying else { return }
    applying = true
    defer { applying = false }
    NativeMenuLocalization.apply(to: menu(), language: language(),
      appName: appName(), servicesMenu: servicesMenu())
  }
}
