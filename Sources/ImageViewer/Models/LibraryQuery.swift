import Foundation

enum LibrarySort: String, Codable, CaseIterable, Identifiable, Sendable {
  case nameAscending, nameDescending, modifiedNewest, modifiedOldest, createdNewest, createdOldest
  case sizeLargest, sizeSmallest, northToSouth, southToNorth, eastToWest, westToEast
  var id: Self { self }
  var requiresLocation: Bool { [.northToSouth, .southToNorth, .eastToWest, .westToEast].contains(self) }
  var title: String {
    switch self {
    case .nameAscending: L10n.text("이름 오름차순")
    case .nameDescending: L10n.text("이름 내림차순")
    case .modifiedNewest: L10n.text("수정일 최신순")
    case .modifiedOldest: L10n.text("수정일 오래된순")
    case .createdNewest: L10n.text("생성일 최신순")
    case .createdOldest: L10n.text("생성일 오래된순")
    case .sizeLargest: L10n.text("용량 큰순")
    case .sizeSmallest: L10n.text("용량 작은순")
    case .northToSouth: L10n.text("GPS 북 → 남")
    case .southToNorth: L10n.text("GPS 남 → 북")
    case .eastToWest: L10n.text("GPS 동 → 서")
    case .westToEast: L10n.text("GPS 서 → 동")
    }
  }
}

enum ImageFormatFilter: String, Codable, CaseIterable, Identifiable, Sendable {
  case jpeg, png, heic, raw, gif, webp, tiff, other
  var id: Self { self }
  var title: String { self == .other ? L10n.text("기타 형식") : rawValue.uppercased() }
}

struct LibraryQuery: Codable, Equatable, Sendable {
  var searchText: String = ""
  var sort: LibrarySort = .nameAscending
  /// An empty selection includes every supported format.
  var formats: Set<ImageFormatFilter> = []
}
