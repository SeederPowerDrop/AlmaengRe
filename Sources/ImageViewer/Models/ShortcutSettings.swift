import AppKit
import Foundation
import SwiftUI

enum ShortcutAction: String, CaseIterable, Identifiable, Codable, Sendable {
  case previousPage
  case nextPage
  case zoomIn
  case zoomOut
  case fitToWindow
  case actualPixels
  case toggleOverview
  case toggleFocus
  case fewerImages
  case moreImages
  case openFolder
  case exportImage
  case panPrimaryDrag
  case panSpaceDrag
  case panSecondaryDrag
  case panMiddleDrag
  case panTrackpadScroll
  case toggleAntialiasing
  case compareSideBySide
  case compareStacked
  case endMagnificationComparison
  case toggleSlideshow
  case setWallpaper
  case toggleFolderComparison
  case previousFirstFolder, nextFirstFolder
  case previousSecondFolder, nextSecondFolder

  var id: Self { self }

  var title: String {
    switch self {
    case .previousPage: L10n.text("이전 이미지/페이지")
    case .nextPage: L10n.text("다음 이미지/페이지")
    case .zoomIn: L10n.text("확대")
    case .zoomOut: L10n.text("축소")
    case .fitToWindow: L10n.text("화면 맞춤")
    case .actualPixels: L10n.text("실제 크기")
    case .toggleOverview: L10n.text("몽땅보기 전환")
    case .toggleFocus: L10n.text("집중 모드 전환")
    case .fewerImages: L10n.text("한 화면 이미지 수 줄이기")
    case .moreImages: L10n.text("한 화면 이미지 수 늘리기")
    case .openFolder: L10n.text("열기")
    case .exportImage: L10n.text("이미지 내보내기")
    case .panPrimaryDrag: PanInteractionMode.primaryDrag.title
    case .panSpaceDrag: PanInteractionMode.spacePrimaryDrag.title
    case .panSecondaryDrag: PanInteractionMode.secondaryDrag.title
    case .panMiddleDrag: PanInteractionMode.middleDrag.title
    case .panTrackpadScroll: PanInteractionMode.trackpadScroll.title
    case .toggleAntialiasing: L10n.text("고화질 확대 켜기/끄기")
    case .compareSideBySide: L10n.text("좌우 비교")
    case .compareStacked: L10n.text("상하 비교")
    case .endMagnificationComparison: L10n.text("비교 끄기")
    case .toggleSlideshow: L10n.text("전자 앨범 재생/일시정지")
    case .setWallpaper: L10n.text("현재 이미지를 바탕화면으로 설정")
    case .toggleFolderComparison: L10n.text("이미지 비교 전환")
    case .previousFirstFolder: L10n.text("A 폴더만 이전 이미지")
    case .nextFirstFolder: L10n.text("A 폴더만 다음 이미지")
    case .previousSecondFolder: L10n.text("B 폴더만 이전 이미지")
    case .nextSecondFolder: L10n.text("B 폴더만 다음 이미지")
    }
  }

  var defaultBinding: KeyBinding {
    switch self {
    case .previousPage: KeyBinding(key: "left")
    case .nextPage: KeyBinding(key: "right")
    case .zoomIn: KeyBinding(key: "=")
    case .zoomOut: KeyBinding(key: "-")
    case .fitToWindow: KeyBinding(key: "0")
    case .actualPixels: KeyBinding(key: "1")
    case .toggleOverview: KeyBinding(key: "g")
    case .toggleFocus: KeyBinding(key: "f")
    case .fewerImages: KeyBinding(key: "[")
    case .moreImages: KeyBinding(key: "]")
    case .openFolder: KeyBinding(key: "o", modifiers: [.command])
    case .exportImage: KeyBinding(key: "e", modifiers: [.command])
    case .panPrimaryDrag: KeyBinding(key: "1", modifiers: [.control, .option])
    case .panSpaceDrag: KeyBinding(key: "2", modifiers: [.control, .option])
    case .panSecondaryDrag: KeyBinding(key: "3", modifiers: [.control, .option])
    case .panMiddleDrag: KeyBinding(key: "4", modifiers: [.control, .option])
    case .panTrackpadScroll: KeyBinding(key: "5", modifiers: [.control, .option])
    case .toggleAntialiasing: KeyBinding(key: "a", modifiers: [.control, .option])
    case .compareSideBySide: KeyBinding(key: "6", modifiers: [.control, .option])
    case .compareStacked: KeyBinding(key: "7", modifiers: [.control, .option])
    case .endMagnificationComparison: KeyBinding(key: "0", modifiers: [.control, .option])
    case .toggleSlideshow: KeyBinding(key: "p", modifiers: [.control, .option])
    case .setWallpaper: KeyBinding(key: "w", modifiers: [.control, .option])
    case .toggleFolderComparison: KeyBinding(key: "c", modifiers: [.control, .option])
    case .previousFirstFolder: KeyBinding(key: "left", modifiers: [.option])
    case .nextFirstFolder: KeyBinding(key: "right", modifiers: [.option])
    case .previousSecondFolder: KeyBinding(key: "left", modifiers: [.option, .shift])
    case .nextSecondFolder: KeyBinding(key: "right", modifiers: [.option, .shift])
    }
  }
}

struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
  let rawValue: Int

  static let command = ShortcutModifiers(rawValue: 1 << 0)
  static let option = ShortcutModifiers(rawValue: 1 << 1)
  static let control = ShortcutModifiers(rawValue: 1 << 2)
  static let shift = ShortcutModifiers(rawValue: 1 << 3)

}

struct KeyBinding: Codable, Hashable, Sendable {
  var key: String
  var modifiers: ShortcutModifiers = []

  /// 메뉴에 실제 단축키를 등록해 사진을 아직 열지 않은 시작 화면에서도 동작합니다.
  var menuShortcut: KeyboardShortcut? {
    let equivalent: KeyEquivalent
    switch key {
    case "left": equivalent = .leftArrow
    case "right": equivalent = .rightArrow
    case "up": equivalent = .upArrow
    case "down": equivalent = .downArrow
    case "space": equivalent = .space
    default:
      guard key.count == 1, let character = key.first else { return nil }
      equivalent = KeyEquivalent(character)
    }
    var flags: EventModifiers = []
    if modifiers.contains(.command) { flags.insert(.command) }
    if modifiers.contains(.option) { flags.insert(.option) }
    if modifiers.contains(.shift) { flags.insert(.shift) }
    if modifiers.contains(.control) { flags.insert(.control) }
    return KeyboardShortcut(equivalent, modifiers: flags)
  }

  static let selectableKeys: [(value: String, label: String)] = [
    ("left", "←"), ("right", "→"), ("up", "↑"), ("down", "↓"),
    ("space", "Space"), ("=", "+ / ="), ("-", "−"),
    ("0", "0"), ("1", "1"), ("[", "["), ("]", "]"),
    ("2", "2"), ("3", "3"), ("4", "4"), ("5", "5"),
    ("6", "6"), ("7", "7"), ("8", "8"), ("9", "9"),
    ("a", "A"), ("b", "B"), ("c", "C"), ("e", "E"), ("f", "F"),
    ("g", "G"), ("i", "I"), ("j", "J"), ("k", "K"),
    ("l", "L"), ("o", "O"), ("p", "P"), ("r", "R"),
    ("s", "S"), ("v", "V"), ("w", "W"), ("z", "Z"),
  ]

  var displayText: String {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("⌃") }
    if modifiers.contains(.option) { parts.append("⌥") }
    if modifiers.contains(.shift) { parts.append("⇧") }
    if modifiers.contains(.command) { parts.append("⌘") }
    let label = Self.selectableKeys.first(where: { $0.value == key })?.label ?? key.uppercased()
    parts.append(label)
    return parts.joined()
  }
}

/// 단축키는 UserDefaults에 저장하고 앱의 모든 창에서 같은 설정을 사용합니다.
@MainActor
final class ShortcutStore: ObservableObject {
  @Published private(set) var bindings: [ShortcutAction: KeyBinding]

  private let defaultsKey = "ImageViewer.ShortcutBindings.v1"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let fallback = Dictionary(
      uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultBinding) })
    guard let data = defaults.data(forKey: defaultsKey),
      let saved = try? JSONDecoder().decode([String: KeyBinding].self, from: data)
    else {
      bindings = fallback
      return
    }

    bindings = fallback
    for (rawAction, binding) in saved {
      if let action = ShortcutAction(rawValue: rawAction) {
        bindings[action] = binding
      }
    }
  }

  func binding(for action: ShortcutAction) -> KeyBinding {
    bindings[action] ?? action.defaultBinding
  }

  func setBinding(_ binding: KeyBinding, for action: ShortcutAction) {
    bindings[action] = binding
    persist()
  }

  func setModifier(
    _ modifier: ShortcutModifiers,
    enabled: Bool,
    for action: ShortcutAction
  ) {
    var binding = binding(for: action)
    if enabled {
      binding.modifiers.insert(modifier)
    } else {
      binding.modifiers.remove(modifier)
    }
    setBinding(binding, for: action)
  }

  func reset() {
    bindings = Dictionary(
      uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultBinding) })
    persist()
  }

  func action(matching event: NSEvent) -> ShortcutAction? {
    guard let key = Self.normalizedKey(from: event) else { return nil }
    let modifiers = Self.modifiers(from: event)
    return ShortcutAction.allCases.first { action in
      let binding = binding(for: action)
      return binding.key == key && binding.modifiers == modifiers
    }
  }

  var conflictingActions: Set<ShortcutAction> {
    var grouped: [KeyBinding: [ShortcutAction]] = [:]
    for (action, binding) in bindings {
      grouped[binding, default: []].append(action)
    }
    return Set(grouped.values.filter { $0.count > 1 }.flatMap { $0 })
  }

  private func persist() {
    let value = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
    if let data = try? JSONEncoder().encode(value) {
      defaults.set(data, forKey: defaultsKey)
    }
  }

  private static func normalizedKey(from event: NSEvent) -> String? {
    switch event.keyCode {
    case 123: return "left"
    case 124: return "right"
    case 125: return "down"
    case 126: return "up"
    case 49: return "space"
    default:
      let character = event.charactersIgnoringModifiers?.lowercased()
      if KeyBinding.selectableKeys.contains(where: { $0.value == character }) {
        return character
      }
      // Option 조합이나 한글 입력 상태에서는 å/¡/한글 등이 전달될 수 있습니다.
      // 문자 키가 아닌 경우에만 macOS의 물리 키 위치로 폴백합니다.
      return [
        0: "a", 1: "s", 3: "f", 5: "g", 6: "z", 8: "c", 9: "v", 11: "b",
        13: "w", 14: "e", 15: "r", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        31: "o", 33: "[", 34: "i", 35: "p", 30: "]",
        37: "l", 38: "j", 40: "k",
      ][Int(event.keyCode)]
    }
  }

  private static func modifiers(from event: NSEvent) -> ShortcutModifiers {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    var result: ShortcutModifiers = []
    if flags.contains(.command) { result.insert(.command) }
    if flags.contains(.option) { result.insert(.option) }
    if flags.contains(.control) { result.insert(.control) }
    if flags.contains(.shift) { result.insert(.shift) }
    return result
  }
}
