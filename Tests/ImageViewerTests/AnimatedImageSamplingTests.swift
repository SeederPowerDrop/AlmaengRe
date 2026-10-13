import Foundation
import Testing

@testable import ImageViewer

@Suite("애니메이션 프레임 간격과 재생시간")
struct AnimatedImageSamplingTests {
  private var document: AnimatedImageDocument {
    AnimatedImageDocument(sourceURL: URL(fileURLWithPath: "/synthetic.gif"),
      sourceTypeIdentifier: "com.compuserve.gif", width: 400, height: 300,
      frames: (0..<6).map { AnimatedImageFrame(index: $0, duration: 0.1, startTime: Double($0) * 0.1) },
      loopCount: 0)
  }

  @Test("시작과 끝을 포함하고 건너뛴 시간은 직전 유지 프레임에 더한다")
  func strideKeepsSelectedDuration() throws {
    let frames = try AnimatedImageExportOptions(frameRange: 1...5, frameStride: 2)
      .selectedFrames(in: document)
    #expect(frames.map(\.index) == [1, 3, 5])
    #expect(abs(frames[0].duration - 0.2) < 1e-9)
    #expect(abs(frames[2].duration - 0.1) < 1e-9)
    #expect(abs(frames.reduce(0) { $0 + $1.duration } - 0.5) < 1e-9)
    #expect(frames[0].startTime == 0)
  }

  @Test("FPS 제한은 프레임을 복제하지 않고 기존 시간축에서 샘플링한다")
  func limitsFrameRate() throws {
    let frames = try AnimatedImageExportOptions(frameRange: 0...5, maximumFramesPerSecond: 4)
      .selectedFrames(in: document)
    #expect(frames.map(\.index) == [0, 3])
    #expect(abs(frames[0].duration - 0.3) < 1e-9)
    #expect(abs(frames[1].duration - 0.3) < 1e-9)
    let unchanged = try AnimatedImageExportOptions(frameRange: 0...5, maximumFramesPerSecond: 120)
      .selectedFrames(in: document)
    #expect(unchanged.count == 6)
  }

  @Test("한 프레임 구간 및 매우 큰 건너뛰기 간격을 지원한다")
  func singleFrameAndLargeStride() throws {
    let single = try AnimatedImageExportOptions(frameRange: 3...3).selectedFrames(in: document)
    #expect(single.map(\.index) == [3])
    let held = try AnimatedImageExportOptions(frameRange: 0...5, frameStride: Int.max)
      .selectedFrames(in: document)
    #expect(held.map(\.index) == [0])
    #expect(abs(held[0].duration - 0.6) < 1e-9)
  }

  @Test("유효하지 않은 범위·간격·FPS 설정을 거절한다")
  func invalidOptions() {
    for options in [
      AnimatedImageExportOptions(frameRange: -1...2),
      .init(frameRange: 0...6), .init(frameRange: 0...2, frameStride: 0),
      .init(frameRange: 0...2, maximumFramesPerSecond: 0),
      .init(frameRange: 0...2, maximumFramesPerSecond: .infinity),
      .init(frameRange: 0...2, maximumFramesPerSecond: .nan),
    ] {
      #expect(throws: AnimatedImageExportError.self) { try options.selectedFrames(in: document) }
    }
  }
}
