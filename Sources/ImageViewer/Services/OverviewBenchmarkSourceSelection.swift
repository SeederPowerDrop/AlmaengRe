import CryptoKit
import Foundation

struct OverviewBenchmarkSourceSelectionReport: Codable, Sendable {
  let scope: String
  let inventoryFileSHA256: String
  let originalInventorySHA256: String
  let originalRegularFileCount: Int
  let discoveredRegularFileCount: Int
  let excludedAddedRegularFileCount: Int
  let excludedAddedPathSHA256: [String]
  let originalPathMembershipVerified: Bool
  var selectedImageCount = 0
  let openRoute = "normal_AppStore_open_multiple_file_URLs_common_parent_folder_preserved"
}

/// Diagnostic-only selection data. Hashes identify allowed regular files; no
/// executable instructions, paths, pixel data or production behavior are loaded.
enum OverviewBenchmarkSourceSelection {
  enum Failure: String, Error {
    case invalidInventory, invalidHash, duplicateHash, invalidCount
    case invalidCurrentFile, duplicateCurrentFile, missingOriginalFile
  }

  private struct Record: Decodable {
    let pathSHA256: String
  }

  private struct Inventory: Decodable {
    let fileCount: Int
    let sha256: String
    let files: [Record]
  }

  struct Selection: Sendable {
    let sourceURLs: [URL]
    let originalPathHashes: Set<String>
    let report: OverviewBenchmarkSourceSelectionReport

    func includes(_ url: URL) -> Bool {
      originalPathHashes.contains(OverviewBenchmarkSourceSelection.pathHash(url))
    }
  }

  static func pathHash(_ url: URL) -> String {
    // Match Python sha256(str(absolute_Path).encode()) exactly: do not resolve
    // aliases or standardize the enumerated source path before hashing it.
    sha(Data(url.path.utf8))
  }

  static func select(sourceURLs: [URL], inventoryData: Data,
    expectedFileCount: Int = 734) throws -> Selection {
    guard inventoryData.count <= 1_048_576,
      let inventory = try? JSONDecoder().decode(Inventory.self, from: inventoryData) else {
      throw Failure.invalidInventory
    }
    guard expectedFileCount > 0, inventory.fileCount == expectedFileCount,
      inventory.files.count == expectedFileCount else { throw Failure.invalidCount }
    guard isHash(inventory.sha256), inventory.files.allSatisfy({ isHash($0.pathSHA256) })
      else { throw Failure.invalidHash }
    let hashes = inventory.files.map(\.pathSHA256)
    guard Set(hashes).count == hashes.count else { throw Failure.duplicateHash }
    var current: [String: URL] = [:]
    for url in sourceURLs {
      guard url.isFileURL, url.path.hasPrefix("/") else { throw Failure.invalidCurrentFile }
      guard current.updateValue(url, forKey: pathHash(url)) == nil else {
        throw Failure.duplicateCurrentFile
      }
    }
    var selected: [URL] = []
    for record in inventory.files {
      guard let url = current[record.pathSHA256] else { throw Failure.missingOriginalFile }
      selected.append(url)
    }
    let allowed = Set(hashes)
    let excluded = current.keys.filter { !allowed.contains($0) }.sorted()
    return Selection(sourceURLs: selected, originalPathHashes: allowed,
      report: OverviewBenchmarkSourceSelectionReport(
        scope: "fixed_original_regular_file_inventory_additions_excluded_without_moving_or_deleting_files",
        inventoryFileSHA256: sha(inventoryData), originalInventorySHA256: inventory.sha256,
        originalRegularFileCount: selected.count, discoveredRegularFileCount: sourceURLs.count,
        excludedAddedRegularFileCount: excluded.count, excludedAddedPathSHA256: excluded,
        originalPathMembershipVerified: true))
  }

  private static func isHash(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }

  private static func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
