import Foundation

/// Classification is independent of the pane used for navigation or zooming.
enum ComparisonPhotoMarkTarget: String, CaseIterable, Identifiable {
  case first, second, both

  var id: Self { self }

  var title: String { PhotoMarkL10n.text("target.\(rawValue)") }

  var sides: [FolderComparisonSide] {
    switch self {
    case .first: [.first]
    case .second: [.second]
    case .both: [.first, .second]
    }
  }
}

enum PhotoMarkSelectionState: Equatable {
  case none, mixed, all
}
