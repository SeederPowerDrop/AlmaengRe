import Darwin
import Foundation

struct BatchRenameOptions: Hashable, Sendable {
  enum NameMode: String, CaseIterable, Identifiable, Sendable {
    case keep, replace, replaceText

    var id: Self { self }
    var title: String {
      switch self {
      case .keep: L10n.text("현재 이름 유지")
      case .replace: L10n.text("전체 이름 바꾸기")
      case .replaceText: L10n.text("이름의 일부 바꾸기")
      }
    }
  }

  enum ExtensionMode: String, CaseIterable, Identifiable, Sendable {
    case keep, lowercase, uppercase, custom

    var id: Self { self }
    var title: String {
      switch self {
      case .keep: L10n.text("확장자 유지")
      case .lowercase: L10n.text("확장자를 소문자로")
      case .uppercase: L10n.text("확장자를 대문자로")
      case .custom: L10n.text("확장자 직접 입력")
      }
    }
  }

  var nameMode: NameMode = .keep
  var newName = ""
  var searchText = ""
  var replacementText = ""
  var prefix = ""
  var suffix = ""
  var addsNumber = false
  var startNumber = 1
  var numberStep = 1
  var numberDigits = 3
  var numberSeparator = "_"
  var extensionMode: ExtensionMode = .keep
  var customExtension = ""
}

struct BatchRenameEntry: Identifiable, Sendable {
  var id: URL { sourceURL }
  let sourceURL: URL
  let destinationURL: URL
  var issue: String?
  let sourceSnapshot: BatchRenameSourceSnapshot?

  var isChanged: Bool {
    !sourceURL.path.utf8.elementsEqual(destinationURL.path.utf8)
  }
}

struct BatchRenamePlan: Sendable {
  var entries: [BatchRenameEntry]
  var changedCount: Int { entries.filter(\.isChanged).count }
  var canApply: Bool { changedCount > 0 && entries.allSatisfy { $0.issue == nil } }
}

/// File identity and nanosecond timestamps detect replacements and edits after preview.
struct BatchRenameSourceSnapshot: Equatable, Sendable {
  let device: Int32
  let inode: UInt64
  let size: Int64
  let modifiedSeconds: Int
  let modifiedNanoseconds: Int
  let changedSeconds: Int
  let changedNanoseconds: Int

  static func capture(_ url: URL) throws -> Self {
    guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
    var info = stat()
    guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      throw BatchRenameError.invalidPlan(L10n.text("일반 파일만 이름을 변경할 수 있습니다."))
    }
    return Self(
      device: info.st_dev, inode: info.st_ino, size: info.st_size,
      modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
      changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec
    )
  }

  /// A rename can update ctime without changing file contents.
  func matchesAfterMove(_ other: Self) -> Bool {
    device == other.device && inode == other.inode && size == other.size
      && modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
  }
}

enum BatchRenamePlanner {
  static func plan(urls: [URL], options: BatchRenameOptions) -> BatchRenamePlan {
    var entries = urls.enumerated().map { index, input in
      let source = input.standardizedFileURL
      var issue: String?
      var name = source.deletingPathExtension().lastPathComponent
      switch options.nameMode {
      case .keep: break
      case .replace: name = options.newName
      case .replaceText:
        if options.searchText.isEmpty {
          issue = L10n.text("바꿀 문자열을 입력해 주세요.")
        } else {
          name = name.replacingOccurrences(of: options.searchText, with: options.replacementText)
        }
      }
      name = options.prefix + name + options.suffix
      if options.addsNumber {
        if options.startNumber < 0 || options.numberStep < 1 || !(1...20).contains(options.numberDigits) {
          issue = L10n.text("시작 번호는 0 이상, 증가 값은 1 이상, 자릿수는 1~20으로 입력해 주세요.")
        } else {
          let (offset, multiplyOverflow) = index.multipliedReportingOverflow(by: options.numberStep)
          let (number, additionOverflow) = options.startNumber.addingReportingOverflow(offset)
          if multiplyOverflow || additionOverflow {
            issue = L10n.text("번호가 너무 큽니다. 시작 번호나 증가 값을 줄여 주세요.")
          } else {
            let digits = String(number)
            name += options.numberSeparator + String(repeating: "0", count: max(0, options.numberDigits - digits.count)) + digits
          }
        }
      }
      let sourceExtension = source.pathExtension
      let targetExtension: String
      switch options.extensionMode {
      case .keep: targetExtension = sourceExtension
      case .lowercase: targetExtension = sourceExtension.lowercased()
      case .uppercase: targetExtension = sourceExtension.uppercased()
      case .custom:
        var custom = options.customExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if custom.hasPrefix(".") { custom.removeFirst() }
        targetExtension = custom
        if custom.isEmpty || !custom.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) {
          issue = L10n.text("확장자는 영문자와 숫자로 입력해 주세요.")
        } else if !extensionsAreEquivalent(sourceExtension, custom) {
          issue = L10n.text("다른 이미지 형식으로 바꾸려면 일괄 변환을 사용해 주세요. 확장자만 바꾸면 형식은 변환되지 않습니다.")
        }
      }
      let filename = name + (targetExtension.isEmpty ? "" : "." + targetExtension)
      if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issue = issue ?? L10n.text("파일 이름은 비워 두거나 점으로 시작할 수 없습니다.")
      }
      issue = issue ?? filenameIssue(filename)
      // Invalid text is kept out of URL path parsing; the issue still blocks the entire plan.
      let destination = filenameIssue(filename) == nil
        ? source.deletingLastPathComponent().appendingPathComponent(filename)
        : source
      let snapshot: BatchRenameSourceSnapshot?
      do { snapshot = try BatchRenameSourceSnapshot.capture(source) }
      catch { snapshot = nil; issue = issue ?? error.localizedDescription }
      return BatchRenameEntry(sourceURL: source, destinationURL: destination, issue: issue, sourceSnapshot: snapshot)
    }
    validateDestinations(&entries)
    return BatchRenamePlan(entries: entries)
  }

  static func filenameIssue(_ filename: String) -> String? {
    if filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filename.hasPrefix(".") {
      return L10n.text("파일 이름은 비워 두거나 점으로 시작할 수 없습니다.")
    }
    if filename.contains("/") || filename.contains("\\") || filename.contains(":")
      || filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    {
      return L10n.text("파일 이름에 /, \\, :, 줄바꿈 또는 제어 문자를 사용할 수 없습니다.")
    }
    if filename.utf8.count > 255 {
      return L10n.text("파일 이름이 너무 깁니다. 확장자를 포함해 255바이트 이내로 줄여 주세요.")
    }
    return nil
  }

  static func extensionsAreEquivalent(_ first: String, _ second: String) -> Bool {
    let first = first.lowercased()
    let second = second.lowercased()
    if first == second { return true }
    let aliases: [Set<String>] = [["jpg", "jpeg", "jpe", "jfif"], ["tif", "tiff"], ["tga", "targa"]]
    return aliases.contains { $0.contains(first) && $0.contains(second) }
  }

  static func pathKey(_ url: URL) -> String {
    let directory = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
    return (directory + "/" + url.lastPathComponent)
      .precomposedStringWithCanonicalMapping
      .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
  }

  static func validateDestinations(_ entries: inout [BatchRenameEntry]) {
    // Large selections share a directory; avoid resolving its symlinks for every filename.
    var resolvedDirectories: [URL: URL] = [:]
    func resolved(_ directory: URL) -> URL {
      if let cached = resolvedDirectories[directory] { return cached }
      let result = directory.resolvingSymlinksInPath().standardizedFileURL
      resolvedDirectories[directory] = result
      return result
    }
    func key(_ url: URL) -> String {
      (resolved(url.deletingLastPathComponent()).path + "/" + url.lastPathComponent)
        .precomposedStringWithCanonicalMapping
        .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
    let sourceGroups = Dictionary(grouping: entries.indices, by: { key(entries[$0].sourceURL) })
    let targetGroups = Dictionary(grouping: entries.indices, by: { key(entries[$0].destinationURL) })
    for group in sourceGroups.values where group.count > 1 {
      for index in group { entries[index].issue = entries[index].issue ?? L10n.text("선택한 원본 파일 이름이 중복됩니다.") }
    }
    for group in targetGroups.values where group.count > 1 {
      for index in group { entries[index].issue = entries[index].issue ?? L10n.text("변경할 파일 이름이 서로 중복됩니다.") }
    }

    let movingSources = Set(entries.filter(\.isChanged).map { key($0.sourceURL) })
    let directoryGroups = Dictionary(grouping: entries.indices, by: { entries[$0].destinationURL.deletingLastPathComponent() })
    for (directory, indices) in directoryGroups {
      do {
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let occupied = Dictionary(grouping: children, by: key)
        for index in indices {
          let entry = entries[index]
          let sourceDirectory = resolved(entry.sourceURL.deletingLastPathComponent())
          if sourceDirectory != resolved(directory) {
            entries[index].issue = entries[index].issue ?? L10n.text("파일 이름은 원본과 같은 폴더 안에서만 변경할 수 있습니다.")
            continue
          }
          entries[index].issue = entries[index].issue ?? filenameIssue(entry.destinationURL.lastPathComponent)
          if !extensionsAreEquivalent(entry.sourceURL.pathExtension, entry.destinationURL.pathExtension) {
            entries[index].issue = entries[index].issue ?? L10n.text("다른 이미지 형식으로 바꾸려면 일괄 변환을 사용해 주세요. 확장자만 바꾸면 형식은 변환되지 않습니다.")
          }
          guard entry.isChanged else { continue }
          let destinationKey = key(entry.destinationURL)
          if let existing = occupied[destinationKey], !(existing.count == 1 && movingSources.contains(destinationKey)) {
            entries[index].issue = entries[index].issue ?? L10n.text("같은 이름의 파일 또는 폴더가 이미 있습니다.")
          }
        }
      } catch {
        for index in indices { entries[index].issue = entries[index].issue ?? error.localizedDescription }
      }
    }
  }
}

enum BatchRenameError: LocalizedError {
  case invalidPlan(String)
  case applyFailed(String)
  case rollbackIncomplete(reason: String, locations: String)

  var errorDescription: String? {
    switch self {
    case .invalidPlan(let reason): reason
    case .applyFailed(let reason):
      L10n.format("이름을 변경하지 못해 원래 이름으로 복원했습니다. %@", reason)
    case .rollbackIncomplete(let reason, let locations):
      L10n.format("이름 변경 중 문제가 발생해 일부 파일을 원래 위치로 복원하지 못했습니다. 파일은 아래 위치에 보관되어 있습니다.\n%@\n%@", reason, locations)
    }
  }
}
