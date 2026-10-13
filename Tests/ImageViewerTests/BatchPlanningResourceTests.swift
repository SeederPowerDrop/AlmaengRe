import Foundation
import Testing

@testable import ImageViewer

@Suite("일괄 변환 미리보기의 작업량과 취소")
struct BatchPlanningResourceTests {
  @Test("여러 앨범의 같은 이름을 연속 번호로 배정하고 실제 파일은 만들지 않는다")
  func repeatedBasenames() throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let sources = (0..<1_000).map {
      folder.appendingPathComponent("album\($0)/photo.qoi")
    }
    let start = ContinuousClock.now
    let items = try BatchImageExporter.plan(urls: sources, destinationFolder: folder, format: .png)
    print("BATCH_PLAN 1000 matching basenames: \(start.duration(to: .now))")
    #expect(items.count == 1_000)
    #expect(items.first?.destinationURL.lastPathComponent == "photo.png")
    #expect(items.last?.destinationURL.lastPathComponent == "photo-1000.png")
    #expect(Set(items.map(\.destinationURL)).count == items.count)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  }

  @Test("이미 번호가 붙은 이름과 섞여도 빈 번호와 대소문자 중복을 올바르게 처리한다")
  func interleavedStemsAndExistingSuffixes() throws {
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["PHOTO.png", "photo-3.png", "photo-5.png"] {
      try Data([1]).write(to: folder.appendingPathComponent(name))
    }
    let names = ["photo.qoi", "Photo-4.qoi", "PHOTO.jpeg", "photo.qoi", "photo-2.qoi"]
    let sources = names.enumerated().map {
      folder.appendingPathComponent("album\($0.offset)/\($0.element)")
    }
    let items = try BatchImageExporter.plan(urls: sources, destinationFolder: folder, format: .png)
    #expect(items.map(\.destinationURL.lastPathComponent) == [
      "photo-2.png", "Photo-4.png", "PHOTO-6.png", "photo-7.png", "photo-2-2.png",
    ])
  }

  @Test("취소된 계획은 파일 시스템을 검사하거나 미리보기를 반환하지 않는다")
  func cancelledPlanningDoesNotStart() async {
    let invalidFolder = URL(fileURLWithPath: "/not-a-real-export-folder-\(UUID())")
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        _ = try BatchImageExporter.plan(urls: [], destinationFolder: invalidFolder, format: .png)
        Issue.record("A cancelled synchronous plan returned a result")
      } catch is CancellationError {
      } catch {
        Issue.record("Cancelled planning reached folder validation: \(error)")
      }
      do {
        _ = try await BatchImageExporter.planInBackground(
          urls: [], destinationFolder: invalidFolder, format: .png)
        Issue.record("A cancelled background plan returned a result")
      } catch is CancellationError {
      } catch {
        Issue.record("Cancelled background planning reached folder validation: \(error)")
      }
    }
    await task.value
  }

  private func fixture() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("batch-planning-resources-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
  }
}
