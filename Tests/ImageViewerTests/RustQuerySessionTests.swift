import Foundation
import Testing
@testable import ImageViewer

@Suite("반복 검색 정보의 수명·무효화·결과 동일성", .serialized)
struct RustQuerySessionTests {
  private func fixtures(_ count: Int = 320) -> [ImageAsset] {
    (0..<count).map { i in
      var asset = ImageAsset(url: URL(fileURLWithPath: "/fixture/여행/photo\(i % 101).\(["dng","mp4","m4a","png"][i % 4])"),
        byteCount: Int64(i * 1000), modificationDate: Date(timeIntervalSince1970: Double(i)))
      asset.location = ImageLocation(latitude: Double(i % 80), longitude: Double(i % 170))
      asset.sortMetadata = LibrarySortMetadata(pixelWidth: i % 19, pixelHeight: i % 17,
        cameraMake: "Apple", cameraModel: "iPhone\(i % 5)")
      return asset
    }
  }

  @Test("모든 정렬과 파일명·확장자·종류·EXIF·지도 조건은 재사용 전후 같다")
  func resultParity() throws {
    let source = fixtures(), session = RustQuerySession()
    _ = try RustImageEngine.query(source, options: .init(), session: session)
    let initial = try #require(session.begin(source).snapshot)
    let area = GeographicSelection.rectangle(southWest: .init(latitude: 5,longitude: 5),
      northEast: .init(latitude: 35,longitude: 35))
    for sort in LibrarySort.allCases {
      let queries = [LibraryQuery(sort: sort), LibraryQuery(searchText: "photo1*",sort: sort),
        LibraryQuery(sort: sort,formats: [.raw,.png], geographicSelection: area),
        LibraryQuery(sort: sort,mediaKind: .audio),
        LibraryQuery(sort: sort,fileExtensions: ["*.MP4",".dng"],
          searchFilters: .init(metadataText: "Apple",minimumBytes: 2000,maximumBytes: 210_000)),
        LibraryQuery(searchText: "no_match",sort: sort)]
      for query in queries {
        #expect(try RustImageEngine.query(source, options: query,session: session)
          == RustImageEngine.query(source,options: query))
        #if DEBUG
        #expect(try RustImageEngine.query(source, options: query,session: session)
          == RustImageEngine.queryUsingLegacyJSON(source,options: query))
        #endif
      }
    }
    #expect(session.begin(source).snapshot === initial)
    let rebuilt = source.map { $0.replacingURL(URL(fileURLWithPath: $0.url.path)) }
    #expect(session.begin(rebuilt).snapshot === initial)
    var archived = source
    archived[0].archiveOrigin = ArchiveImageOrigin(archiveURL: URL(fileURLWithPath: "/fixture/모음.zip"),
      entryPath: "폴더/사진\u{301}.dng")
    #if DEBUG
    #expect(try RustImageEngine.query(archived,options: .init(),session: session)
      == RustImageEngine.queryUsingLegacyJSON(archived,options: .init()))
    #endif
  }

  @Test("같은 경로의 EXIF·크기·날짜·GPS·이름과 목록 변경을 무효화한다")
  func invalidation() throws {
    let source = fixtures()
    let changes: [([ImageAsset]) -> [ImageAsset]] = [
      { var a = $0; a[0] = a[0].replacingURL(URL(fileURLWithPath: "/renamed/new.mp4")); return a },
      { var a = $0; a[0] = ImageAsset(url: a[0].url,byteCount: 900_000,modificationDate: .now); return a },
      { var a = $0; a[0].creationDate = .now; return a },
      { var a = $0; a[0].location = nil; return a },
      { var a = $0; a[0].sortMetadata?.cameraMake = "Canon"; return a },
      { var a = $0; a[0].sortMetadataVersion = LibrarySortFileVersion(url: a[0].url); return a },
      { var a = $0; a.removeLast(); return a },
      { var a = $0; a.append(a[0]); return a },
      { Array($0.reversed()) },
    ]
    for change in changes {
      let pool = RustQueryReusePool(), session = RustQuerySession(pool: pool)
      _ = try RustImageEngine.query(source,options: .init(),session: session)
      let old = try #require(session.begin(source).snapshot)
      let changed = change(source)
      #expect(session.begin(changed).snapshot == nil)
      #expect(pool.retainedBytes == 0)
      for sort in [LibrarySort.nameAscending,.sizeLargest,.makeAscending,.northToSouth] {
        let query = LibraryQuery(sort: sort)
        #expect(try RustImageEngine.query(changed,options: query,session: session)
          == RustImageEngine.query(changed,options: query))
      }
      #expect(session.begin(changed).snapshot !== old)
    }
  }

  @Test("좁은 첫 검색과 적은 파일은 전체 준비·보관 비용을 늘리지 않는다")
  func narrowAndSmall() throws {
    let source = fixtures(), pool = RustQueryReusePool(), session = RustQuerySession(pool: pool)
    _ = try RustImageEngine.query(source,options: .init(searchText: "photo1*"),session: session)
    #expect(pool.retainedBytes == 0)
    _ = try RustImageEngine.query(source,options: .init(),session: session)
    #expect(pool.retainedBytes > 0)
    for count in [0,1,20,255] {
      _ = try RustImageEngine.query(Array(source.prefix(count)),options: .init(),session: session)
      #expect(pool.retainedBytes == 0)
    }
  }

  @Test("공유 예산·메모리 압력·세션 종료와 오래된 검색 재등록을 검증한다")
  func budgetAndLifetime() throws {
    let source = fixtures(), input = try RustQueryInput(source)
    let cost = RustQuerySnapshot(source: source,input: input).retainedBytes
    let pool = RustQueryReusePool(byteLimit: cost * 2)
    let a = RustQuerySession(pool: pool), b = RustQuerySession(pool: pool), c = RustQuerySession(pool: pool)
    for session in [a,b] { _ = try RustImageEngine.query(source,options: .init(),session: session) }
    #expect(pool.retainedBytes == cost * 2)
    #expect(a.begin(source).snapshot != nil) // touch A, evict B next
    _ = try RustImageEngine.query(source,options: .init(),session: c)
    #expect(pool.retainedBytes == cost * 2)
    #expect(b.begin(source).snapshot == nil)
    #expect(a.begin(source).snapshot != nil)
    let obsolete = a.begin(source)
    a.reset(); a.remember(input,source: source,request: obsolete)
    #expect(a.begin(source).snapshot == nil)
    let older = a.begin(source), newer = a.begin(source)
    a.remember(input,source: source,request: older)
    #expect(pool.retainedBytes == cost)
    a.remember(input,source: source,request: newer)
    #expect(pool.retainedBytes == cost * 2)
    pool.setReuseAllowed(false)
    #expect(pool.retainedBytes == 0)
    _ = try RustImageEngine.query(source,options: .init(),session: c)
    #expect(pool.retainedBytes == 0)
    pool.setReuseAllowed(true)
    var temporary: RustQuerySession? = RustQuerySession(pool: pool)
    _ = try RustImageEngine.query(source,options: .init(),session: temporary)
    #expect(pool.retainedBytes == cost)
    temporary = nil
    #expect(pool.retainedBytes == 0)
    let tiny = RustQueryReusePool(byteLimit: cost - 1)
    _ = try RustImageEngine.query(source,options: .init(),session: RustQuerySession(pool: tiny))
    #expect(tiny.retainedBytes == 0)
  }

  @Test("취소한 검색은 준비한 정보를 보관하지 않는다")
  func cancellation() async throws {
    let source = fixtures(), pool = RustQueryReusePool(), session = RustQuerySession(pool: pool)
    let request = session.begin(source), input = try RustQueryInput(source)
    await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      session.remember(input,source: source,request: request)
      do { _ = try RustImageEngine.query(source,options: .init(),session: session); Issue.record("Expected cancellation") }
      catch { #expect(error is CancellationError) }
    }.value
    #expect(pool.retainedBytes == 0)
  }

  @Test("폴더를 닫으면 압축 해제 파일의 수명을 붙잡지 않는다")
  func archiveLease() throws {
    let pool = RustQueryReusePool(), session = RustQuerySession(pool: pool)
    weak var observed: ArchiveImageLease?
    do {
      let lease = ArchiveImageLease(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
      observed = lease
      var source = fixtures()
      source[0].archiveOrigin = ArchiveImageOrigin(archiveURL: URL(fileURLWithPath: "/fixture/archive.zip"),
        entryPath: "photo.dng",lease: lease)
      _ = try RustImageEngine.query(source,options: .init(),session: session)
    }
    #expect(observed != nil)
    session.reset()
    #expect(observed == nil)
    #expect(pool.retainedBytes == 0)
  }
}
