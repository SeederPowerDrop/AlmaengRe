import AppKit
import Foundation

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

  var id: Self { self }

  var title: String {
    switch self {
    case .previousPage: L10n.text("이전 이미지/페이지")
    case .nextPage: L10n.text("다음 이미지/페이지")
    case .zoomIn: L10n.text("확대")
    case .zoomOut: L10n.text("축소")
    case .fitToWindow: L10n.text("화면 맞춤")
    case .actualPixels: L10n.text("실제 크기")
    case .toggleOverview: L10n.text("전체 보기 전환")
    case .toggleFocus: L10n.text("집중 모드 전환")
    case .fewerImages: L10n.text("한 화면 이미지 수 줄이기")
    case .moreImages: L10n.text("한 화면 이미지 수 늘리기")
    case .openFolder: L10n.text("폴더 열기")
    case .exportImage: L10n.text("이미지 내보내기")
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

  static let selectableKeys: [(value: String, label: String)] = [
    ("left", "←"), ("right", "→"), ("up", "↑"), ("down", "↓"),
    ("space", "Space"), ("=", "+ / ="), ("-", "−"),
    ("0", "0"), ("1", "1"), ("[", "["), ("]", "]"),
    ("a", "A"), ("b", "B"), ("e", "E"), ("f", "F"),
    ("g", "G"), ("i", "I"), ("j", "J"), ("k", "K"),
    ("l", "L"), ("o", "O"), ("p", "P"), ("r", "R"),
    ("s", "S"), ("v", "V"), ("z", "Z"),
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

  init() {
    let fallback = Dictionary(
      uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultBinding) })
    guard let data = UserDefaults.standard.data(forKey: defaultsKey),
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
      UserDefaults.standard.set(data, forKey: defaultsKey)
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
      return event.charactersIgnoringModifiers?.lowercased()
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
