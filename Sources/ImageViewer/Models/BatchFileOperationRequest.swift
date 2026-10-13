import Foundation

/// A sheet owns a frozen selection, including archive leases, until it closes.
struct BatchFileOperationRequest: Identifiable, Sendable {
  let id = UUID()
  let operation: BatchFileOperation
  let assets: [ImageAsset]
}
