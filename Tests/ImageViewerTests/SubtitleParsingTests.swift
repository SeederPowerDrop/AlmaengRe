import CoreFoundation
import Foundation
import Testing

@testable import ImageViewer

@Suite("External subtitle parsing")
struct SubtitleParsingTests {
  @Test("SRT keeps multiline text, decodes entities, and preserves overlapping intervals")
  func srtTextAndOverlap() throws {
    let document = try parse("""
      1
      00:00:01,250 --> 00:00:04,000
      <i>안녕하세요</i> &amp; hello
      second &#x1F31F; &lt;literal&gt;

      2
      00:00:02,000 --> 00:00:03,000
      <font color="yellow">overlap</font><br/>line

      3
      00:00:04,000 --> 00:00:05,000
      Next
      """)
    let track = try #require(document.tracks.first)
    #expect(document.sourceURL.pathExtension == "srt")
    #expect(track.cues.count == 3)
    #expect(track.text(at: 1.249) == nil)
    #expect(track.text(at: 1.25) == "안녕하세요 & hello\nsecond 🌟 <literal>")
    #expect(track.text(at: 2) == "안녕하세요 & hello\nsecond 🌟 <literal>\noverlap\nline")
    #expect(track.text(at: 3.5) == "안녕하세요 & hello\nsecond 🌟 <literal>")
    #expect(track.text(at: 4) == "Next")
    #expect(track.text(at: 5) == nil)
  }

  @Test("The index finds an earlier long cue behind many already-ended cues")
  func intervalIndexAndUnsortedInput() {
    var cues = (1...39_999).map { SubtitleCue(start: Double($0), end: Double($0) + 0.5, text: "short") }
    cues.insert(SubtitleCue(start: 0, end: 100_000, text: "long"), at: 250)
    cues.append(SubtitleCue(start: .nan, end: 3, text: "invalid"))
    cues.append(SubtitleCue(start: -1, end: 3, text: "invalid"))
    cues.append(SubtitleCue(start: 2, end: 1, text: "invalid"))
    let track = SubtitleTrack(id: "test", name: "Test", cues: cues.reversed())
    #expect(track.cues.count == 40_000)
    #expect(track.text(at: 70_000) == "long")
    #expect(track.text(at: 400) == "long\nshort")
    #expect(track.text(at: -1) == nil)
    #expect(track.text(at: .infinity) == nil)
    #expect(track.text(at: .nan) == nil)
    #expect(track.text(at: 100_000) == nil)
  }

  @Test("Pathological overlap and text volume stay bounded during playback")
  func pathologicalOverlapIsBounded() throws {
    let overlapping = (0..<40_000).map {
      SubtitleCue(start: 0, end: 10, text: "Caption \($0)")
    }
    let track = SubtitleTrack(id: "many", name: "Many", cues: overlapping)
    let text = try #require(track.text(at: 1))
    #expect(text.hasPrefix("Caption 0\nCaption 1\n"))
    #expect(text.contains("Caption 15"))
    #expect(!text.contains("Caption 16"))
    #expect(text.hasSuffix("\n…"))
    let large = SubtitleTrack(id: "large", name: "Large", cues: [
      SubtitleCue(start: 0, end: 10, text: String(repeating: "한🌟", count: 40_000))])
    let bounded = try #require(large.text(at: 1))
    #expect(bounded.utf8.count <= SubtitleTrack.maximumDisplayedTextBytes)
    #expect(!bounded.contains("�"))
    #expect(bounded.hasSuffix("\n…"))
  }

  @Test("WebVTT identifiers, short timestamps, cue settings, and metadata are handled")
  func webVTT() throws {
    let document = try parse("""
      WEBVTT sample
      Kind: captions
      Language: en

      STYLE
      ::cue { color: lime; }

      NOTE not a cue
      00:00:00.000 --> 00:00:20.000
      hidden comment

      REGION
      id:fred
      width:40%

      introductory-cue
      00:01.000 --> 00:03.500 align:start position:20%
      <v Speaker><c.green>Hello</c></v> <00:02.000>there

      00:00:03.500 --> 00:00:04.000
      &quot;Next&quot; &#39;line&#39;
      """, extension: "vtt")
    let track = try #require(document.tracks.first)
    #expect(track.cues.count == 2)
    #expect(track.text(at: 1) == "Hello there")
    #expect(track.text(at: 3.5) == "\"Next\" 'line'")
  }

  @Test("Malformed timing blocks are skipped without accepting reversed or overflowing times")
  func malformedTimes() throws {
    let invalid = ["00:00:01,000 --> 00:00:00,999", "00:60:00,000 --> 01:01:00,000",
      "00:00:60,000 --> 01:00:00,000", "-1:00:00,000 --> 01:00:00,000",
      "00:00:01,000 --> inf", "9999999999999999:00:00,000 --> 9999999999999999:00:01,000",
      "00:00:01,00 --> 00:00:02,000", "00:00:01,000 --> 00:00:01,000",
      "00:01.000 --> 00:02.000"]
    let source = invalid.enumerated().map { "\($0.offset + 1)\n\($0.element)\nInvalid" }
      .joined(separator: "\n\n") + "\n\n100\n00:00:02,000 --> 00:00:03,000\nValid"
    let document = try parse(source)
    #expect(document.tracks.first?.cues == [SubtitleCue(start: 2, end: 3, text: "Valid")])
    #expect(throws: SubtitleReaderError.noCues) { try parse("1\n00:00:01,000 --> 00:00:00,000\nInvalid") }
  }

  @Test("UTF-8 BOM and both UTF-16 byte orders decode Korean without replacement characters")
  func unicodeEncodings() throws {
    let source = "1\r\n00:00:00,000 --> 00:00:01,000\r\n한글 자막\r\n"
    let fixtures: [(String.Encoding, [UInt8])] = [(.utf8, [0xEF, 0xBB, 0xBF]),
      (.utf16LittleEndian, [0xFF, 0xFE]), (.utf16BigEndian, [0xFE, 0xFF])]
    for (encoding, bom) in fixtures {
      var data = Data(bom)
      data.append(try #require(source.data(using: encoding)))
      let document = try SubtitleReader.parse(data: data, sourceURL: url("srt"))
      #expect(document.tracks.first?.text(at: 0) == "한글 자막")
    }
  }

  @Test("Korean Windows CP949 and EUC-KR SAMI decode with language tracks")
  func legacyKoreanEncodings() throws {
    let source = "<SAMI><BODY><SYNC Start=100><P Class=KRCC>한국어 자막<SYNC Start=900><P Class=KRCC>&nbsp;</BODY></SAMI>"
    for cfEncoding in [CFStringEncodings.dosKorean, .EUC_KR] {
      let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEncoding.rawValue)))
      let data = try #require(source.data(using: encoding))
      let document = try SubtitleReader.parse(data: data, sourceURL: url("smi"))
      #expect(document.tracks.first?.text(at: 0.1) == "한국어 자막")
      #expect(document.tracks.first?.text(at: 0.9) == nil)
    }
  }

  @Test("SAMI keeps languages separate, supports asynchronous cues, and honors blank clear events")
  func samiLanguageTracks() throws {
    let document = try parse("""
      <SAMI><HEAD><STYLE TYPE="text/css">
      <!--
      .KRCC { Name: '한국어'; lang: ko-KR; SAMIType: CC; }
      .ENCC { Name: English; lang: en-US; SAMIType: CC; }
      -->
      </STYLE></HEAD><BODY>
      <!-- <SYNC Start=0><P Class=KRCC>hidden -->
      <SYNC Start=1000><P Class="KRCC"><b>안녕</b><BR>두 줄
      <P Class=ENCC>Hello &amp; welcome
      <SYNC Start='2000'><P Class='KRCC'>다음
      <SYNC Start=3000><P Class=KRCC>&nbsp;<P Class=ENCC>&nbsp;
      <SYNC Start=4000><P Class=ENCC>Final &lt;caption&gt;
      </BODY></SAMI>
      """, extension: "smi")
    #expect(document.tracks.map(\.id) == ["krcc", "encc"])
    #expect(document.tracks.map(\.name) == ["한국어", "English"])
    let korean = try #require(document.tracks.first)
    let english = try #require(document.tracks.last)
    #expect(korean.text(at: 0) == nil)
    #expect(korean.text(at: 1) == "안녕\n두 줄")
    #expect(korean.text(at: 2) == "다음")
    #expect(korean.text(at: 3) == nil)
    #expect(english.text(at: 2.5) == "Hello & welcome")
    #expect(english.text(at: 3) == nil)
    #expect(english.text(at: 4) == "Final <caption>")
    #expect(english.text(at: 8_000) == "Final <caption>")
  }

  @Test("SAMI sorts out-of-order syncs and does not render script or style contents")
  func samiOrderingAndMarkup() throws {
    let document = try parse("""
      <SAMI><BODY>
      <SYNC Start=3000><P Class=A>&nbsp;
      <SYNC Start=1000><P Class=A>one<script>hidden</script><style>hidden</style>
      <SYNC Start=invalid><P Class=A>invalid
      <SYNC Start=2000><P Class=A>two &unknown; &#xD800; &amp;lt;
      </BODY></SAMI>
      """, extension: "sami")
    let track = try #require(document.tracks.first)
    #expect(track.text(at: 1) == "one")
    #expect(track.text(at: 2) == "two &unknown; &#xD800; &lt;")
    #expect(track.text(at: 3) == nil)
  }

  @Test("Only bounded local subtitle documents are accepted")
  func inputAndTextLimits() throws {
    #expect(throws: SubtitleReaderError.nonLocalFile) {
      try SubtitleReader.parse(data: Data(), sourceURL: URL(string: "https://example.invalid/captions.srt")!)
    }
    #expect(throws: SubtitleReaderError.unsupportedFormat) {
      try SubtitleReader.parse(data: Data(), sourceURL: url("html"))
    }
    #expect(throws: SubtitleReaderError.fileTooLarge) {
      try SubtitleReader.parse(data: Data(repeating: 0x20, count: SubtitleReader.maximumFileBytes + 1), sourceURL: url("srt"))
    }
    #expect(throws: SubtitleReaderError.tooMuchText) {
      try parse("1\n00:00:00,000 --> 00:00:01,000\n" + String(repeating: "a", count: SubtitleReader.maximumCueTextBytes + 1))
    }
    #expect(throws: SubtitleReaderError.tooManyCues) {
      try parse(String(repeating: "<SYNC Start=0>", count: SubtitleReader.maximumCueCount + 2), extension: "smi")
    }
    #expect(throws: SubtitleReaderError.unsupportedEncoding) {
      try SubtitleReader.parse(data: Data([0xFF, 0xFE, 0x00]), sourceURL: url("srt"))
    }
  }

  @Test("Local reads remain read-only and return generic filesystem errors")
  func localFileRead() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("subtitle-reader-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("synthetic.srt")
    let data = Data("1\n00:00:00,000 --> 00:00:01,000\nSynthetic".utf8)
    try data.write(to: file)
    let before = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let document = try SubtitleReader.read(file)
    #expect(document.tracks.first?.text(at: 0) == "Synthetic")
    #expect(try Data(contentsOf: file) == data)
    let after = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    #expect(before.contentModificationDate == after.contentModificationDate)
    #expect(before.fileSize == after.fileSize)
    #expect(throws: SubtitleReaderError.unreadableFile) {
      try SubtitleReader.read(directory.appendingPathComponent("missing.srt"))
    }
    #expect(throws: SubtitleReaderError.unreadableFile) {
      try SubtitleReader.read(directory.appendingPathComponent("subdirectory.srt", isDirectory: true))
    }
  }

  @Test("Cancelled work stops before parsing or reading")
  func cancellation() async {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      #expect(throws: CancellationError.self) {
        try SubtitleReader.parse(data: Data(), sourceURL: url("srt"))
      }
      #expect(throws: CancellationError.self) { try SubtitleReader.read(url("srt")) }
    }
    await task.value
  }

  private func parse(_ source: String, extension fileExtension: String = "srt") throws -> SubtitleDocument {
    try SubtitleReader.parse(data: Data(source.utf8), sourceURL: url(fileExtension))
  }

  private func url(_ fileExtension: String) -> URL {
    URL(fileURLWithPath: "/synthetic-subtitle.\(fileExtension)")
  }
}
