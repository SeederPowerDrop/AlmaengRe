import Foundation
import Testing

@testable import ImageViewer

@Suite("실제 다중 뷰어 진단의 페이지·품질 판정")
@MainActor
struct MultipleViewerNativeValidationTests {
  private func assets() -> [ImageAsset] {
    (0..<12).map { index in
      ImageAsset(url: URL(fileURLWithPath: "/native-page-proof/\(index).dng"),
        byteCount: 10 + Int64(index), modificationDate: Date(timeIntervalSince1970: 10))
    }
  }

  @Test("페이지의 중복·누락·순서 및 같은 URL의 다른 원본 버전을 거부한다")
  func rejectsIncorrectPageMembershipAndVersion() {
    let all = assets()
    let page = Array(all[6..<12])
    #expect(MultipleViewerNativeValidation.isExactPage(actual: page, all: all, start: 6, count: 6))
    #expect(!MultipleViewerNativeValidation.isExactPage(actual: Array(page.dropLast()),
      all: all, start: 6, count: 6))
    #expect(!MultipleViewerNativeValidation.isExactPage(actual: Array(page.reversed()),
      all: all, start: 6, count: 6))
    var duplicate = page
    duplicate[5] = duplicate[4]
    #expect(!MultipleViewerNativeValidation.isExactPage(actual: duplicate, all: all, start: 6, count: 6))
    var replaced = page
    replaced[0] = ImageAsset(url: page[0].url, byteCount: 999, modificationDate: page[0].modificationDate)
    #expect(!MultipleViewerNativeValidation.isExactPage(actual: replaced, all: all, start: 6, count: 6))
  }

  @Test("작은 미리보기·잘못된 HDR·정책은 정밀 완료로 인정하지 않는다", arguments: [4, 6])
  func preciseValidationPreservesResolutionHDRAndVisibleCount(count: Int) {
    let request = ViewerFrameRequest(asset: assets()[0], maxPixelSize: 1_024,
      adjustments: .identity, prefersHDR: true, loadingPolicy: .forVisibleItemCount(count))
    func accepted(width: Int = 1_024, refinement: Bool = true, source: Double? = 6_000,
      visibleCount: Int? = nil, hdr: Bool = true) -> Bool {
      MultipleViewerNativeValidation.finalFrameIsValid(request: request, width: width, height: 256,
        isRefinement: refinement, sourceMaximumDimension: source,
        visibleCount: visibleCount ?? count, prefersHDR: hdr)
    }
    #expect(accepted())
    #expect(!accepted(width: 512))
    #expect(!accepted(refinement: false))
    #expect(!accepted(source: nil))
    #expect(!accepted(hdr: false))
    #expect(!accepted(visibleCount: count == 4 ? 6 : 4))
    // A genuinely smaller original is complete at its actual native dimensions.
    #expect(accepted(width: 800, source: 800))
  }
}
