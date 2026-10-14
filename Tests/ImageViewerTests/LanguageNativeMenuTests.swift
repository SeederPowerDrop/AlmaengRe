import AppKit
import Testing

@testable import ImageViewer

@Suite("기본 macOS 메뉴의 실시간 언어 변경")
@MainActor
struct LanguageNativeMenuTests {
  @Test("10개 언어를 왕복해도 메뉴의 동작·대상·단축키·상태는 유지된다")
  func languageRoundTripsPreserveBehavior() {
    let fixture = MenuFixture()
    let snapshots = fixture.allItems.map(ItemSnapshot.init)
    let sequence = L10n.supportedLocalizations
      + Array(L10n.supportedLocalizations.reversed()) + ["en"]

    for language in sequence {
      NativeMenuLocalization.apply(to: fixture.main, language: language,
        appName: "알맹Re QA", servicesMenu: fixture.services)
      for (key, item) in fixture.translated {
        var expected = native(key, language)
        if key == "hide" || key == "quit" {
          expected = String(format: expected, locale: Locale(identifier: language), "알맹Re QA")
        }
        #expect(item.title == expected, "\(language): \(key)")
      }
      for key in ["file", "edit", "view", "window", "help"] {
        #expect(fixture.menus[key]?.title == native(key, language))
      }
      #expect(fixture.services.title == native("services", language))
      for snapshot in snapshots { snapshot.checkUnchangedBehavior() }
    }
  }

  @Test("실행 취소·복귀의 작업명과 사용자 메뉴는 번역하지 않는다")
  func keepsUndoDescriptionsAndUserMenuEntries() throws {
    let fixture = MenuFixture()
    let undo = try #require(fixture.translated["undo"])
    let redo = try #require(fixture.translated["redo"])
    undo.title = "Undo Rename File.jpg"
    redo.title = "Redo Move 設定.png"

    for language in L10n.supportedLocalizations + ["en"] {
      NativeMenuLocalization.apply(to: fixture.main, language: language,
        servicesMenu: fixture.services)
      #expect(undo.title == native("undo", language) + " Rename File.jpg")
      #expect(redo.title == native("redo", language) + " Move 設定.png")
      for (item, title) in fixture.untouched {
        #expect(item.title == title, "A nonstandard or document menu was changed: \(title)")
      }
    }
  }

  @Test("설정 메뉴의 세 점과 공백 표기를 인식하되 다른 단축키는 변경하지 않는다",
    arguments: ["Settings...", "Einstellungen …", "Réglages…"])
  func identifiesOnlyStandardSettings(title: String) throws {
    let fixture = MenuFixture()
    let settings = try #require(fixture.translated["settings"])
    settings.title = title
    NativeMenuLocalization.apply(to: fixture.main, language: "ko", servicesMenu: fixture.services)
    #expect(settings.title == native("settings", "ko"))
    for (item, original) in fixture.untouched { #expect(item.title == original) }
    NativeMenuLocalization.apply(to: nil, language: "fr")
  }

  @Test("SwiftUI가 메뉴 제목을 복원하면 다음 한 번의 처리로 번역하고 자체 변경은 반복하지 않는다")
  func observesAndCoalescesNativeMenuRebuilds() throws {
    let fixture = MenuFixture()
    let work = PendingMenuWork()
    let observer = NativeMenuLocalizationObserver(menu: { fixture.main }, language: { "ja" },
      servicesMenu: { fixture.services }, schedule: { work.enqueue($0) })
    observer.start()
    defer { observer.stop() }
    #expect(work.count == 1)
    work.runNext()
    #expect(work.count == 0, "Localizer writes must not schedule another update")
    #expect(fixture.translated["file"]?.title == native("file", "ja"))
    let snapshots = fixture.allItems.map(ItemSnapshot.init)

    for key in ["file", "edit", "view", "window", "help", "close", "copy", "settings"] {
      fixture.translated[key]?.title = native(key, "fr")
    }
    // NSMenuItem setters post the actual public NSMenu notifications. One
    // complete framework rebuild must still produce just one deferred pass.
    #expect(work.count == 1)
    work.runNext()
    #expect(work.count == 0)
    for key in ["file", "edit", "view", "window", "help", "close", "copy", "settings"] {
      #expect(fixture.translated[key]?.title == native(key, "ja"))
    }
    for snapshot in snapshots { snapshot.checkUnchangedBehavior() }

    // No title assignment means no notification or unnecessary follow-up.
    NativeMenuLocalization.apply(to: fixture.main, language: "ja", servicesMenu: fixture.services)
    #expect(work.count == 0)
    let service = try #require(fixture.services.items.first)
    service.title = "Updated third-party service"
    #expect(work.count == 0, "Nested Services contents are outside this observer's scope")
    #expect(service.title == "Updated third-party service")
  }

  @Test("메뉴 교체·새 항목·활성화 알림은 현재 메뉴와 최신 언어를 다시 읽는다")
  func observesReplacementAndUsesLatestLanguage() throws {
    let first = MenuFixture()
    let replacement = MenuFixture()
    var current = first
    var language = "ja"
    let work = PendingMenuWork()
    let observer = NativeMenuLocalizationObserver(menu: { current.main }, language: { language },
      servicesMenu: { current.services }, schedule: { work.enqueue($0) })
    observer.start()
    defer { observer.stop() }
    work.runNext()
    current = replacement
    first.translated["file"]?.title = native("file", "fr")
    #expect(work.count == 0, "A detached old main menu must be ignored")

    let newCopy = NSMenuItem(title: "Copier", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
    let edit = try #require(replacement.menus["edit"])
    edit.addItem(newCopy)
    #expect(work.count == 1)
    language = "ar"
    work.runNext()
    #expect(work.count == 0)
    #expect(replacement.translated["file"]?.title == native("file", "ar"))
    #expect(newCopy.title == native("copy", "ar"))
    #expect(first.translated["file"]?.title == native("file", "fr"))

    language = "ko"
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(work.count == 1)
    work.runNext()
    #expect(replacement.translated["file"]?.title == native("file", "ko"))
    #expect(work.count == 0)

    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nil)
    #expect(work.count == 1)
    observer.stop()
    language = "en"
    work.runNext()
    #expect(replacement.translated["file"]?.title == native("file", "ko"))
    #expect(work.count == 0)
  }

  private func native(_ key: String, _ language: String) -> String {
    LanguageSettings.text("native.\(key)", language: language)
  }
}

@MainActor
private final class PendingMenuWork {
  private var operations: [@MainActor @Sendable () -> Void] = []
  var count: Int { operations.count }
  func enqueue(_ operation: @escaping @MainActor @Sendable () -> Void) { operations.append(operation) }
  func runNext() {
    guard !operations.isEmpty else { return }
    operations.removeFirst()()
  }
}

@MainActor
private final class MenuFixture {
  let main = NSMenu(title: "Main")
  let services = NSMenu(title: "Services")
  let target = NSObject()
  let representedObject = NSObject()
  var menus: [String: NSMenu] = [:]
  var translated: [String: NSMenuItem] = [:]
  var untouched: [(NSMenuItem, String)] = []

  var allItems: [NSMenuItem] {
    func descend(_ menu: NSMenu) -> [NSMenuItem] {
      menu.items.flatMap { item in [item] + (item.submenu.map(descend) ?? []) }
    }
    return descend(main)
  }

  init() {
    main.autoenablesItems = false
    services.autoenablesItems = false
    for key in ["app", "file", "edit", "view", "window", "help"] {
      let title = key == "app" ? "알맹Re" : text(key)
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let menu = NSMenu(title: title)
      menu.autoenablesItems = false
      item.submenu = menu
      main.addItem(item)
      menus[key] = menu
      if key != "app" { translated[key] = item }
    }

    for (key, action) in [
      ("hide", "hide:"), ("hideOthers", "hideOtherApplications:"),
      ("showAll", "unhideAllApplications:"), ("quit", "terminate:")
    ] { add(key, to: "app", action: action) }
    add("settings", to: "app", action: "openFixtureSettings:")
    translated["settings"]?.keyEquivalent = ","
    translated["settings"]?.keyEquivalentModifierMask = [.command]

    let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    servicesItem.submenu = services
    menus["app"]?.addItem(servicesItem)
    translated["services"] = servicesItem
    let service = NSMenuItem(title: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "")
    services.addItem(service)
    untouched.append((service, service.title))

    add("close", to: "file", action: "performClose:")
    for key in ["undo", "redo", "cut", "copy", "paste", "selectAll"] {
      add(key, to: "edit", action: key + ":")
    }
    for (key, action) in [
      ("minimize", "performMiniaturize:"), ("zoom", "performZoom:"),
      ("bringAllToFront", "arrangeInFront:")
    ] { add(key, to: "window", action: action) }

    // Document names can coincide with standard menu titles. Only the public
    // native action in the appropriate top-level menu may be translated.
    for title in ["File", "Settings…", "Copy", "Fenêtre"] {
      let document = NSMenuItem(title: title,
        action: NSSelectorFromString("makeKeyAndOrderFront:"), keyEquivalent: "")
      menus["window"]?.addItem(document)
      untouched.append((document, title))
    }
    let misleading = NSMenuItem(title: "Settings…",
      action: NSSelectorFromString("openFixtureSettings:"), keyEquivalent: "s")
    menus["app"]?.addItem(misleading)
    untouched.append((misleading, misleading.title))

    let custom = NSMenuItem(title: "My tools", action: nil, keyEquivalent: "")
    let customMenu = NSMenu(title: "My tools")
    customMenu.autoenablesItems = false
    custom.submenu = customMenu
    main.addItem(custom)
    let copy = NSMenuItem(title: "Copy my tool",
      action: NSSelectorFromString("copy:"), keyEquivalent: "")
    customMenu.addItem(copy)
    untouched.append((custom, custom.title))
    untouched.append((copy, copy.title))

    for (index, item) in allItems.enumerated() {
      item.target = target
      item.representedObject = representedObject
      item.tag = index + 100
      item.state = index.isMultiple(of: 2) ? .on : .mixed
      item.isEnabled = !index.isMultiple(of: 3)
      item.isHidden = index.isMultiple(of: 5)
    }
  }

  private func text(_ key: String) -> String {
    LanguageSettings.text("native.\(key)", language: "en")
  }

  private func add(_ key: String, to menu: String, action: String) {
    let item = NSMenuItem(title: text(key), action: NSSelectorFromString(action),
      keyEquivalent: String(key.prefix(1)))
    item.keyEquivalentModifierMask = [.command, .shift]
    menus[menu]?.addItem(item)
    translated[key] = item
  }
}

@MainActor
private struct ItemSnapshot {
  let item: NSMenuItem
  let action: Selector?
  let target: AnyObject?
  let key: String
  let modifiers: NSEvent.ModifierFlags
  let state: NSControl.StateValue
  let enabled: Bool
  let hidden: Bool
  let tag: Int
  let representedObject: AnyObject?
  let parent: NSMenu?
  let submenu: NSMenu?

  init(_ item: NSMenuItem) {
    self.item = item
    action = item.action
    target = item.target as AnyObject?
    key = item.keyEquivalent
    modifiers = item.keyEquivalentModifierMask
    state = item.state
    enabled = item.isEnabled
    hidden = item.isHidden
    tag = item.tag
    representedObject = item.representedObject as AnyObject?
    parent = item.menu
    submenu = item.submenu
  }

  func checkUnchangedBehavior() {
    #expect(item.action == action)
    #expect((item.target as AnyObject?) === target)
    #expect(item.keyEquivalent == key)
    #expect(item.keyEquivalentModifierMask == modifiers)
    #expect(item.state == state)
    #expect(item.isEnabled == enabled)
    #expect(item.isHidden == hidden)
    #expect(item.tag == tag)
    #expect((item.representedObject as AnyObject?) === representedObject)
    #expect(item.menu === parent)
    #expect(item.submenu === submenu)
  }
}
