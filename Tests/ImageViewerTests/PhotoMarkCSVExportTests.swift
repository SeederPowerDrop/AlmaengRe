import Foundation
import Testing

@testable import ImageViewer

@Suite("분류 내역 CSV 내보내기")
struct PhotoMarkCSVExportTests {
  @Test("한글·쉼표·따옴표·줄바꿈과 현재/이전 두 상태를 스프레드시트 필드로 보존한다")
  func csvRoundTripPreservesFieldsAndDates() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let current = PhotoMarkClassificationState(marks: [.w, .one],
      labels: [.one: "가족, 친구", .w: "공유 \"후보\"\n확인"], changedAt: date)
    let previous = PhotoMarkClassificationState(marks: [.q], labels: [.q: "이전 이름"],
      changedAt: date.addingTimeInterval(-3600))
    let earlier = PhotoMarkClassificationState(marks: [], labels: [:], changedAt: date.addingTimeInterval(-7200))
    let filename = "여행, \"가족\"\n사진.jpg"
    let record = PhotoMarkClassificationRecord(assetID: "fixture", sourceURL: URL(fileURLWithPath: "/합성 사진").appendingPathComponent(filename),
      archiveEntryPath: nil, isUnavailable: false, current: current, previous: [previous, earlier, current])
    let data = PhotoMarkCSVExporter.data(for: [record], strings: .init(localeIdentifier: "ko"),
      timeZone: try #require(TimeZone(secondsFromGMT: 9 * 3600)))
    #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
    let fields = try parse(data)
    #expect(fields.count == 2)
    #expect(fields.allSatisfy { $0.count == 10 })
    #expect(fields[0][0] == "폴더 위치")
    #expect(fields[1][0] == "/합성 사진")
    #expect(fields[1][1] == filename)
    #expect(fields[1][2] == "1 · 가족, 친구; W · 공유 \"후보\"\n확인")
    #expect(fields[1][3] == "2023-11-15T07:13:20.000+09:00")
    #expect(fields[1][4] == "Q · 이전 이름")
    #expect(fields[1][5] == "2023-11-15T06:13:20.000+09:00")
    #expect(fields[1][6] == "분류 없음")
    #expect(fields[1][7] == "2023-11-15T05:13:20.000+09:00")
    #expect(fields[1][8] == "")
    #expect(fields[1][9] == "최근 확인 시 접근 가능")
  }

  @Test("과거 날짜 미기록·압축 내부 경로·찾을 수 없는 파일도 구분한다")
  func missingHistoryAndArchiveLocation() throws {
    let state = PhotoMarkClassificationState(marks: [.one], labels: [.one: "선택"], changedAt: nil)
    let record = PhotoMarkClassificationRecord(assetID: "fixture", sourceURL: URL(fileURLWithPath: "/사진/여행.zip"),
      archiveEntryPath: "원본/서울.jpg", isUnavailable: true, current: state, previous: [])
    let rows = try parse(PhotoMarkCSVExporter.data(for: [record], strings: .init(localeIdentifier: "ko")))
    #expect(rows[1][0] == "/사진/여행.zip")
    #expect(rows[1][1] == "서울.jpg")
    #expect(rows[1][3...7].allSatisfy { $0 == "미기록" })
    #expect(rows[1][8] == "원본/서울.jpg")
    #expect(rows[1][9] == "확인 필요")
  }

  @Test("수식처럼 시작하는 파일 이름은 CSV를 열 때 텍스트로 취급한다", arguments: ["=1+1.jpg", "+SUM(1).png", "-1.mp4", "@name.jpg", " \t=1.jpg"])
  func formulaLikeNamesAreText(filename: String) throws {
    let state = PhotoMarkClassificationState(marks: [.q], labels: [.q: "보류"], changedAt: nil)
    let record = PhotoMarkClassificationRecord(assetID: "fixture", sourceURL: URL(fileURLWithPath: "/synthetic").appendingPathComponent(filename),
      archiveEntryPath: nil, isUnavailable: false, current: state, previous: [])
    let rows = try parse(PhotoMarkCSVExporter.data(for: [record]))
    #expect(rows[1][1] == "'" + filename)
  }

  @Test("리포트 CSV 문구와 숫자 인수가 모든 지원 언어에 존재한다")
  func localizationCoverage() {
    let keys = PhotoMarkReportL10n.keys(localeIdentifier: "ko")
    #expect(keys.contains("export.title"))
    for locale in L10n.supportedLocalizations {
      #expect(PhotoMarkReportL10n.keys(localeIdentifier: locale) == keys)
      for key in ["export.countFormat", "export.successFormat"] {
        #expect(PhotoMarkReportL10n.text(key, localeIdentifier: locale).components(separatedBy: "%d").count == 2)
      }
      for column in PhotoMarkCSVExporter.Strings.columns {
        #expect(PhotoMarkReportL10n.text("csv.\(column)", localeIdentifier: locale) != "csv.\(column)")
      }
    }
  }

  @Test("내보내기는 대기 중인 저장까지 포함하고 파일 변경 리포트가 없어도 모든 분류 파일을 내보낸다")
  @MainActor func exportWaitsForDurableWrites() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = PhotoMarkStore(databaseURL: fixture.root.appendingPathComponent("marks.sqlite"))
    await store.waitUntilReady()
    try #require(store.isReady)
    let first = try fixture.asset("photo.jpg")
    let second = try fixture.asset("movie.mp4")
    store.setLabels([.one: "처음", .q: "보류"])
    store.toggle(.one, for: first)
    store.toggle(.q, for: first)
    store.toggle(.one, for: first)
    store.toggle(.one, for: second)
    #expect(store.trackingReports.isEmpty)
    let destination = fixture.root.appendingPathComponent("export.csv")
    #expect(try await store.exportClassifications(to: destination) == 2)
    let rows = try parse(Data(contentsOf: destination))
    #expect(rows.count == 3)
    let photo = try #require(rows.dropFirst().first { $0[1] == "photo.jpg" })
    #expect(photo[2] == "Q · 보류")
    #expect(photo[4] == "1 · 처음; Q · 보류")
    #expect(photo[6] == "1 · 처음")
    #expect(photo[3].contains("T") && photo[5].contains("T") && photo[7].contains("T"))
    let reopened = PhotoMarkStore(databaseURL: fixture.root.appendingPathComponent("marks.sqlite"))
    await reopened.waitUntilReady()
    let restored = try await reopened.classificationRecords()
    let original = try await store.classificationRecords()
    #expect(restored.map(\.assetID) == original.map(\.assetID))
    for (saved, previous) in zip(restored, original) {
      #expect(saved.current == previous.current && saved.previous == previous.previous)
      #expect(saved.archiveEntryPath == previous.archiveEntryPath)
      #expect(saved.isUnavailable == previous.isUnavailable)
      #expect(saved.sourceURL?.resolvingSymlinksInPath().path == previous.sourceURL?.resolvingSymlinksInPath().path)
    }
  }

  @Test("분류 저장소를 읽지 못하거나 CSV 쓰기가 실패하면 성공하지 않는다")
  @MainActor func failuresDoNotCreateAnExport() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let badDB = fixture.root.appendingPathComponent("broken.sqlite")
    try Data("not a database".utf8).write(to: badDB)
    let broken = PhotoMarkStore(databaseURL: badDB)
    await broken.waitUntilReady()
    let destination = fixture.root.appendingPathComponent("keep.csv")
    let sentinel = Data("keep existing export".utf8)
    try sentinel.write(to: destination)
    await #expect(throws: (any Error).self) { try await broken.exportClassifications(to: destination) }
    #expect(try Data(contentsOf: destination) == sentinel)

    let healthy = PhotoMarkStore(inMemory: true)
    await healthy.waitUntilReady()
    healthy.toggle(.q, for: try fixture.asset("photo.jpg"))
    let missingParent = fixture.root.appendingPathComponent("missing/export.csv")
    await #expect(throws: (any Error).self) { try await healthy.exportClassifications(to: missingParent) }
    #expect(!FileManager.default.fileExists(atPath: missingParent.path))
    #expect(healthy.isReady)
  }

  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("ClassificationCSV-\(UUID())")
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func asset(_ name: String) throws -> ImageAsset {
      let url = root.appendingPathComponent(name)
      if !FileManager.default.fileExists(atPath: url.path) { try Data("synthetic media".utf8).write(to: url) }
      let identity = try #require(PhotoMarkFileIdentity.read(url))
      return ImageAsset(url: url, byteCount: nil, modificationDate: nil, photoMarkIdentity: identity.key)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }

  /// Small independent parser used to check field boundaries, including quoted
  /// newlines; splitting by lines would conceal malformed CSV.
  private func parse(_ data: Data) throws -> [[String]] {
    let text = try #require(String(data: data.dropFirst(3), encoding: .utf8))
    let chars = Array(text)
    var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, index = 0
    while index < chars.count {
      let char = chars[index]
      if char == "\"" {
        if quoted && index + 1 < chars.count && chars[index + 1] == "\"" { field.append("\""); index += 1 }
        else { quoted.toggle() }
      } else if char == "," && !quoted { row.append(field); field = "" }
      else if (char == "\r\n" || char == "\n") && !quoted {
        row.append(field); rows.append(row); row = []; field = ""
      } else { field.append(char) }
      index += 1
    }
    #expect(!quoted && row.isEmpty && field.isEmpty)
    return rows
  }
}
