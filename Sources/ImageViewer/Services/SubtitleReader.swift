import CoreFoundation
import Foundation

enum SubtitleReaderError: LocalizedError, Sendable, Equatable {
  case nonLocalFile, unsupportedFormat, fileTooLarge, unreadableFile
  case unsupportedEncoding, tooManyCues, tooMuchText, noCues

  var errorDescription: String? {
    switch self {
    case .nonLocalFile:
      MotionMediaL10n.text("subtitle.error.nonLocalFile")
    case .unsupportedFormat:
      MotionMediaL10n.text("subtitle.error.unsupportedFormat")
    case .fileTooLarge:
      MotionMediaL10n.text("subtitle.error.fileTooLarge")
    case .unreadableFile:
      MotionMediaL10n.text("subtitle.error.unreadableFile")
    case .unsupportedEncoding:
      MotionMediaL10n.text("subtitle.error.unsupportedEncoding")
    case .tooManyCues, .tooMuchText:
      MotionMediaL10n.text("subtitle.error.contentLimit")
    case .noCues:
      MotionMediaL10n.text("subtitle.error.noCues")
    }
  }
}

/// Reads external text only. Markup is stripped locally; no HTML renderer, links,
/// external resources, or network requests are used to interpret a subtitle.
enum SubtitleReader {
  static let maximumFileBytes = 8 * 1_024 * 1_024
  static let maximumCueCount = 40_000
  static let maximumTextBytes = 2 * 1_024 * 1_024
  static let maximumCueTextBytes = 16 * 1_024
  private static let maximumLineCount = 250_000

  static func read(_ url: URL) throws -> SubtitleDocument {
    try validateURL(url)
    try Task.checkCancellation()
    let handle: FileHandle
    do {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true else { throw SubtitleReaderError.unreadableFile }
      guard (values.fileSize ?? 0) <= maximumFileBytes else {
        throw SubtitleReaderError.fileTooLarge
      }
      handle = try FileHandle(forReadingFrom: url)
    } catch let error as SubtitleReaderError { throw error }
    catch { throw SubtitleReaderError.unreadableFile }
    defer { try? handle.close() }

    var data = Data()
    while true {
      try Task.checkCancellation()
      let chunk: Data
      do { chunk = try handle.read(upToCount: min(65_536, maximumFileBytes + 1 - data.count)) ?? Data() }
      catch { throw SubtitleReaderError.unreadableFile }
      if chunk.isEmpty { break }
      data.append(chunk)
      guard data.count <= maximumFileBytes else { throw SubtitleReaderError.fileTooLarge }
    }
    return try parse(data: data, sourceURL: url)
  }

  static func parse(data: Data, sourceURL: URL) throws -> SubtitleDocument {
    try validateURL(sourceURL)
    guard data.count <= maximumFileBytes else { throw SubtitleReaderError.fileTooLarge }
    try Task.checkCancellation()
    let decoded = try decode(data)
    // NULs usually indicate binary input or a UTF-16 file without an identifiable BOM.
    guard !decoded.contains("\0") else { throw SubtitleReaderError.unsupportedEncoding }
    let source = decoded.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let tracks: [SubtitleTrack]
    switch sourceURL.pathExtension.lowercased() {
    case "smi", "sami": tracks = try parseSAMI(source)
    default: tracks = try parseTimedText(source, isWebVTT: sourceURL.pathExtension.lowercased() == "vtt")
    }
    try Task.checkCancellation()
    guard !tracks.isEmpty else { throw SubtitleReaderError.noCues }
    return SubtitleDocument(sourceURL: sourceURL, tracks: tracks)
  }

  private static func validateURL(_ url: URL) throws {
    guard url.isFileURL else { throw SubtitleReaderError.nonLocalFile }
    guard ["srt", "vtt", "smi", "sami"].contains(url.pathExtension.lowercased()) else {
      throw SubtitleReaderError.unsupportedFormat
    }
  }

  private static func decode(_ data: Data) throws -> String {
    let bytes = Array(data.prefix(4))
    let encoding: String.Encoding?
    let bomLength: Int
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { encoding = .utf8; bomLength = 3 }
    else if bytes.starts(with: [0xFF, 0xFE, 0, 0]) { encoding = .utf32LittleEndian; bomLength = 4 }
    else if bytes.starts(with: [0, 0, 0xFE, 0xFF]) { encoding = .utf32BigEndian; bomLength = 4 }
    else if bytes.starts(with: [0xFF, 0xFE]) { encoding = .utf16LittleEndian; bomLength = 2 }
    else if bytes.starts(with: [0xFE, 0xFF]) { encoding = .utf16BigEndian; bomLength = 2 }
    else { encoding = nil; bomLength = 0 }
    if let encoding {
      let payload = data.dropFirst(bomLength)
      let alignment = encoding == .utf32LittleEndian || encoding == .utf32BigEndian ? 4
        : (encoding == .utf16LittleEndian || encoding == .utf16BigEndian ? 2 : 1)
      // Foundation may silently discard an incomplete final UTF-16 code unit.
      guard payload.count.isMultiple(of: alignment),
        let text = String(data: payload, encoding: encoding) else {
        throw SubtitleReaderError.unsupportedEncoding
      }
      return text
    }
    if let text = String(data: data, encoding: .utf8) { return text }
    // Windows CP949 includes the EUC-KR repertoire used by older Korean SAMI files.
    for encoding in [CFStringEncodings.dosKorean, .EUC_KR] {
      let foundationEncoding = String.Encoding(rawValue:
        CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
      if let text = String(data: data, encoding: foundationEncoding) { return text }
    }
    throw SubtitleReaderError.unsupportedEncoding
  }

  private struct Budget {
    var cueCount = 0
    var textBytes = 0

    mutating func include(_ text: String) throws {
      guard text.utf8.count <= maximumCueTextBytes else { throw SubtitleReaderError.tooMuchText }
      cueCount += 1
      textBytes += text.utf8.count
      guard cueCount <= maximumCueCount else { throw SubtitleReaderError.tooManyCues }
      guard textBytes <= maximumTextBytes else { throw SubtitleReaderError.tooMuchText }
    }
  }

  private static func parseTimedText(_ source: String, isWebVTT: Bool) throws -> [SubtitleTrack] {
    var cues: [SubtitleCue] = []
    var budget = Budget()
    var block: [String] = []
    var blockBytes = 0
    var lineCount = 0
    var cursor = source.startIndex

    func consumeBlock() throws {
      defer { block.removeAll(keepingCapacity: true); blockBytes = 0 }
      guard !block.isEmpty else { return }
      try Task.checkCancellation()
      let first = block[0].trimmingCharacters(in: .whitespaces)
      if isWebVTT && (first == "WEBVTT" || first.hasPrefix("WEBVTT ")
        || first == "NOTE" || first.hasPrefix("NOTE ") || first.hasPrefix("NOTE\t")
        || first == "STYLE" || first == "REGION") { return }
      // An optional cue identifier may precede the timing line.
      let timingIndex = first.contains("-->") ? 0 : 1
      guard block.indices.contains(timingIndex),
        let (start, end) = parseTiming(block[timingIndex], isWebVTT: isWebVTT) else { return }
      let text = cleanText(block.dropFirst(timingIndex + 1).joined(separator: "\n"))
      guard !text.isEmpty else { return }
      try budget.include(text)
      cues.append(SubtitleCue(start: start, end: end, text: text))
    }

    // Iterate without building an unbounded array for files containing millions of empty lines.
    while cursor < source.endIndex {
      lineCount += 1
      guard lineCount <= maximumLineCount else { throw SubtitleReaderError.tooManyCues }
      let lineEnd = source[cursor...].firstIndex(of: "\n") ?? source.endIndex
      let line = String(source[cursor..<lineEnd])
      cursor = lineEnd < source.endIndex ? source.index(after: lineEnd) : source.endIndex
      if line.trimmingCharacters(in: .whitespaces).isEmpty { try consumeBlock() }
      else {
        blockBytes += line.utf8.count
        guard blockBytes <= maximumCueTextBytes * 4 else { throw SubtitleReaderError.tooMuchText }
        block.append(line)
      }
    }
    try consumeBlock()
    guard !cues.isEmpty else { return [] }
    return [SubtitleTrack(id: "default", name: "", cues: cues)]
  }

  private static func parseTiming(_ line: String, isWebVTT: Bool) -> (TimeInterval, TimeInterval)? {
    let sides = line.components(separatedBy: "-->")
    guard sides.count == 2,
      let start = timestamp(sides[0].trimmingCharacters(in: .whitespaces), allowShort: isWebVTT),
      let endToken = sides[1].split(whereSeparator: \.isWhitespace).first,
      let end = timestamp(String(endToken), allowShort: isWebVTT), end > start else { return nil }
    return (start, end)
  }

  private static func timestamp(_ value: String, allowShort: Bool) -> TimeInterval? {
    let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3 || (allowShort && parts.count == 2) else { return nil }
    let secondsParts = parts.last!.split(separator: ".", omittingEmptySubsequences: false)
    guard secondsParts.count == 2, secondsParts[0].count == 2,
      secondsParts[1].count == 3,
      parts.allSatisfy({ $0.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } }),
      let seconds = Double(parts.last!), seconds < 60 else { return nil }
    let minutePart = parts[parts.count - 2]
    guard minutePart.count == 2, let minutes = Int(minutePart), minutes < 60 else { return nil }
    let hours: Int
    if parts.count == 3 {
      guard parts[0].count >= 2, parts[0].count <= 6, let parsed = Int(parts[0]) else { return nil }
      hours = parsed
    } else { hours = 0 }
    let result = Double(hours) * 3_600 + Double(minutes) * 60 + seconds
    return result.isFinite && result >= 0 ? result : nil
  }

  private struct SAMIEvent {
    let time: TimeInterval
    let text: String
    let sequence: Int
  }

  private static func parseSAMI(_ source: String) throws -> [SubtitleTrack] {
    let names = try samiTrackNames(source)
    let bodyStart = bodyTag.firstMatch(in: source, range: fullRange(source)).map { NSMaxRange($0.range) } ?? 0
    var body = (source as NSString).substring(from: bodyStart)
    body = comments.stringByReplacingMatches(in: body, range: fullRange(body), withTemplate: "")
    body = removingHiddenBlocks(body)
    let syncs = try boundedMatches(syncTag, in: body, limit: maximumCueCount + 1)
    var events: [String: [SAMIEvent]] = [:]
    var trackOrder: [String] = []
    var budget = Budget()
    var sequence = 0

    for (index, sync) in syncs.enumerated() {
      try Task.checkCancellation()
      let tag = (body as NSString).substring(with: sync.range)
      guard let start = attribute("start", in: tag), start.count <= 15,
        start.allSatisfy({ $0.isASCII && $0.isNumber }),
        let milliseconds = Double(start), milliseconds.isFinite else { continue }
      let range = NSRange(location: NSMaxRange(sync.range),
        length: (index + 1 < syncs.count ? syncs[index + 1].range.location : (body as NSString).length) - NSMaxRange(sync.range))
      let segment = (body as NSString).substring(with: range)
      guard segment.utf8.count <= maximumCueTextBytes * 4 else { throw SubtitleReaderError.tooMuchText }
      let paragraphs = try boundedMatches(paragraphTag, in: segment, limit: 256)
      var texts: [String: [String]] = [:]
      var segmentOrder: [String] = []
      func addText(classID: String, text: String) {
        if texts[classID] == nil { segmentOrder.append(classID) }
        texts[classID, default: []].append(text)
      }
      if paragraphs.isEmpty {
        addText(classID: "default", text: cleanText(segment))
      } else {
        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
          let tag = (segment as NSString).substring(with: paragraph.range)
          let classID = String((attribute("class", in: tag) ?? "default").prefix(128)).lowercased()
          let start = NSMaxRange(paragraph.range)
          let end = paragraphIndex + 1 < paragraphs.count
            ? paragraphs[paragraphIndex + 1].range.location : (segment as NSString).length
          addText(classID: classID, text: cleanText((segment as NSString).substring(with: NSRange(location: start, length: end - start))))
        }
      }
      for classID in segmentOrder {
        let text = (texts[classID] ?? []).filter { !$0.isEmpty }.joined(separator: "\n")
        try budget.include(text) // Empty captions are clear events and must remain bounded too.
        if events[classID] == nil {
          guard trackOrder.count < 32 else { throw SubtitleReaderError.tooManyCues }
          trackOrder.append(classID)
        }
        events[classID, default: []].append(SAMIEvent(time: milliseconds / 1_000, text: text, sequence: sequence))
        sequence += 1
      }
    }
    return trackOrder.compactMap { classID in
      let ordered = (events[classID] ?? []).sorted {
        $0.time == $1.time ? $0.sequence < $1.sequence : $0.time < $1.time
      }
      var cues: [SubtitleCue] = []
      for (index, event) in ordered.enumerated() where !event.text.isEmpty {
        // SAMI has no explicit end field: the next event (including a blank one)
        // closes this caption. An unterminated final caption holds to movie end.
        let end = index + 1 < ordered.count ? ordered[index + 1].time : .greatestFiniteMagnitude
        if end > event.time { cues.append(SubtitleCue(start: event.time, end: end, text: event.text)) }
      }
      guard !cues.isEmpty else { return nil }
      return SubtitleTrack(id: classID, name: names[classID] ?? (classID == "default" ? "" : classID), cues: cues)
    }
  }

  private static func samiTrackNames(_ source: String) throws -> [String: String] {
    var names: [String: String] = [:]
    let original = source as NSString
    var cursor = 0
    var styles = 0
    while cursor < original.length,
      let opening = styleOpeningTag.firstMatch(in: source, range: NSRange(location: cursor, length: original.length - cursor)) {
      try Task.checkCancellation()
      styles += 1
      guard styles <= 32 else { throw SubtitleReaderError.tooManyCues }
      let contentStart = NSMaxRange(opening.range)
      guard let closing = styleClosingTag.firstMatch(in: source,
        range: NSRange(location: contentStart, length: original.length - contentStart)) else { break }
      let text = original.substring(with: NSRange(location: contentStart, length: closing.range.location - contentStart))
      cursor = NSMaxRange(closing.range)
      for match in try boundedMatches(cssClass, in: text, limit: 128) {
        let classID = (text as NSString).substring(with: match.range(at: 1)).lowercased()
        let fields = (text as NSString).substring(with: match.range(at: 2))
        var properties: [String: String] = [:]
        for field in fields.split(separator: ";") {
          let pair = field.split(separator: ":", maxSplits: 1)
          if pair.count == 2 {
            properties[pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
              pair[1].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
          }
        }
        let name = properties["name"] ?? properties["lang"] ?? classID
        names[classID] = String(cleanText(name).prefix(128))
      }
    }
    return names
  }

  private static func attribute(_ name: String, in tag: String) -> String? {
    for match in attributes.matches(in: tag, range: fullRange(tag)) {
      guard (tag as NSString).substring(with: match.range(at: 1)).lowercased() == name else { continue }
      for index in 2...4 where match.range(at: index).location != NSNotFound {
        return (tag as NSString).substring(with: match.range(at: index))
      }
    }
    return nil
  }

  private static func cleanText(_ source: String) -> String {
    var text = comments.stringByReplacingMatches(in: source, range: fullRange(source), withTemplate: "")
    text = removingHiddenBlocks(text)
    text = lineBreakTag.stringByReplacingMatches(in: text, range: fullRange(text), withTemplate: "\n")
    text = markupTag.stringByReplacingMatches(in: text, range: fullRange(text), withTemplate: "")
    // Decode only after stripping tags: escaped angle brackets remain visible text.
    let original = text as NSString
    let matches = entity.matches(in: text, range: fullRange(text))
    let output = NSMutableString()
    var end = 0
    for match in matches {
      output.append(original.substring(with: NSRange(location: end, length: match.range.location - end)))
      let token = original.substring(with: match.range(at: 1))
      output.append(decodeEntity(token) ?? original.substring(with: match.range))
      end = NSMaxRange(match.range)
    }
    output.append(original.substring(from: end))
    return (output as String).components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func removingHiddenBlocks(_ source: String) -> String {
    let original = source as NSString
    let output = NSMutableString()
    var cursor = 0
    while cursor < original.length,
      let opening = hiddenOpeningTag.firstMatch(in: source,
        range: NSRange(location: cursor, length: original.length - cursor)) {
      output.append(original.substring(with: NSRange(location: cursor, length: opening.range.location - cursor)))
      let closingPattern = original.substring(with: opening.range(at: 1)).lowercased() == "style"
        ? styleClosingTag : scriptClosingTag
      let contentStart = NSMaxRange(opening.range)
      guard let closing = closingPattern.firstMatch(in: source,
        range: NSRange(location: contentStart, length: original.length - contentStart)) else {
        // Unterminated script/style content is still hidden, without repeated
        // whole-document searches for each nested opening tag.
        return output as String
      }
      cursor = NSMaxRange(closing.range)
    }
    output.append(original.substring(from: cursor))
    return output as String
  }

  private static func decodeEntity(_ token: String) -> String? {
    if let value = namedEntities[token.lowercased()] { return value }
    guard token.hasPrefix("#") else { return nil }
    let hex = token.lowercased().hasPrefix("#x")
    let digits = token.dropFirst(hex ? 2 : 1)
    guard let value = UInt32(digits, radix: hex ? 16 : 10),
      let scalar = UnicodeScalar(value), value != 0,
      !(value < 0x20 && value != 9 && value != 10) else { return nil }
    return String(scalar)
  }

  private static func boundedMatches(_ expression: NSRegularExpression, in source: String,
    limit: Int) throws -> [NSTextCheckingResult] {
    var matches: [NSTextCheckingResult] = []
    var exceededLimit = false
    expression.enumerateMatches(in: source, range: fullRange(source)) { match, _, stop in
      if Task.isCancelled { stop.pointee = true; return }
      guard let match else { return }
      if matches.count == limit { exceededLimit = true; stop.pointee = true }
      else { matches.append(match) }
    }
    guard !exceededLimit else { throw SubtitleReaderError.tooManyCues }
    try Task.checkCancellation()
    return matches
  }

  private static func fullRange(_ value: String) -> NSRange { NSRange(value.startIndex..., in: value) }
  private static let namedEntities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    "lrm": "\u{200E}", "rlm": "\u{200F}", "ndash": "–", "mdash": "—", "hellip": "…",
    "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "copy": "©", "reg": "®"]
  private static let bodyTag = try! NSRegularExpression(pattern: "(?is)<body\\b[^<>]*>")
  private static let syncTag = try! NSRegularExpression(pattern: "(?is)<sync\\b[^<>]*>")
  private static let paragraphTag = try! NSRegularExpression(pattern: "(?is)<p\\b[^<>]*>")
  private static let attributes = try! NSRegularExpression(pattern: "(?i)\\s+([a-z][a-z0-9_-]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
  private static let styleOpeningTag = try! NSRegularExpression(pattern: "(?is)<style\\b[^<>]*>")
  private static let styleClosingTag = try! NSRegularExpression(pattern: "(?is)</style\\s*>")
  private static let scriptClosingTag = try! NSRegularExpression(pattern: "(?is)</script\\s*>")
  private static let cssClass = try! NSRegularExpression(pattern: "(?is)\\.([a-z0-9_-]{1,128})\\s*\\{([^}]{0,4096})\\}")
  private static let comments = try! NSRegularExpression(pattern: "(?s)<!--.*?(?:-->|$)")
  private static let hiddenOpeningTag = try! NSRegularExpression(pattern: "(?is)<(script|style)\\b[^<>]*>")
  private static let lineBreakTag = try! NSRegularExpression(pattern: "(?i)<br\\s*/?\\s*>")
  private static let markupTag = try! NSRegularExpression(pattern: "(?s)</?[a-zA-Z][^<>]*>|<[0-9][0-9:.]*>")
  private static let entity = try! NSRegularExpression(pattern: "&(#(?:[xX][0-9a-fA-F]{1,8}|[0-9]{1,10})|[a-zA-Z]{2,12});")
}
