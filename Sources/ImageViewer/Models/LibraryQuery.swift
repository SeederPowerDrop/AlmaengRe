import Foundation

enum LibrarySort: String, Codable, CaseIterable, Identifiable, Sendable {
  case nameAscending, nameDescending, modifiedNewest, modifiedOldest, createdNewest, createdOldest
  case sizeLargest, sizeSmallest, northToSouth, southToNorth, eastToWest, westToEast
  case widthAscending, widthDescending, heightAscending, heightDescending
  case capturedNewest, capturedOldest, typeAscending, typeDescending
  case shutterFastest, shutterSlowest, makeAscending, makeDescending, modelAscending, modelDescending
  case apertureAscending, apertureDescending, colorSpaceAscending, colorSpaceDescending
  var id: Self { self }
  static var groupedCases: [(title: String, sorts: [LibrarySort])] {
    [
      (SortL10n.text("category.file"), [.nameAscending, .nameDescending,
        .modifiedNewest, .modifiedOldest, .createdNewest, .createdOldest,
        .sizeLargest, .sizeSmallest, .typeAscending, .typeDescending]),
      (SortL10n.text("category.dimensions"), [.widthAscending, .widthDescending,
        .heightAscending, .heightDescending, .capturedNewest, .capturedOldest]),
      (SortL10n.text("category.camera"), [.shutterFastest, .shutterSlowest,
        .makeAscending, .makeDescending, .modelAscending, .modelDescending,
        .apertureAscending, .apertureDescending, .colorSpaceAscending, .colorSpaceDescending]),
      (SortL10n.text("category.location"), [.northToSouth, .southToNorth, .eastToWest, .westToEast]),
    ]
  }
  var requiresLocation: Bool { [.northToSouth, .southToNorth, .eastToWest, .westToEast].contains(self) }
  var requiresMetadata: Bool {
    switch self {
    case .widthAscending, .widthDescending, .heightAscending, .heightDescending,
      .capturedNewest, .capturedOldest, .shutterFastest, .shutterSlowest,
      .makeAscending, .makeDescending, .modelAscending, .modelDescending,
      .apertureAscending, .apertureDescending, .colorSpaceAscending, .colorSpaceDescending: true
    default: false
    }
  }
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
    default: SortL10n.text(rawValue)
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
  var geographicSelection: GeographicSelection? = nil
  var mediaKind: LibraryMediaKind = .all
  /// Empty means every extension within the selected media kind/format families.
  var fileExtensions: Set<String> = []
  var searchFilters = LibrarySearchFilters()

  var requiresMetadata: Bool { sort.requiresMetadata || searchFilters.requiresMetadata }
}

extension LibraryQuery {
  private enum CodingKeys: String, CodingKey {
    case searchText, sort, formats, geographicSelection, mediaKind, fileExtensions, searchFilters
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    searchText = try values.decodeIfPresent(String.self, forKey: .searchText) ?? ""
    sort = try values.decodeIfPresent(LibrarySort.self, forKey: .sort) ?? .nameAscending
    formats = try values.decodeIfPresent(Set<ImageFormatFilter>.self, forKey: .formats) ?? []
    geographicSelection = try values.decodeIfPresent(GeographicSelection.self, forKey: .geographicSelection)
    mediaKind = try values.decodeIfPresent(LibraryMediaKind.self, forKey: .mediaKind) ?? .all
    fileExtensions = try values.decodeIfPresent(Set<String>.self, forKey: .fileExtensions) ?? []
    searchFilters = try values.decodeIfPresent(LibrarySearchFilters.self, forKey: .searchFilters)
      ?? LibrarySearchFilters()
  }
}
