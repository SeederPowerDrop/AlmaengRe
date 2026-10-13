import Testing

@testable import ImageViewer

@Suite("확장자 선택기의 검색과 종류 분류")
struct LibraryFormatPickerTests {
  @Test("폴더 목록을 정규화하고 중복을 제거하며 익숙한 형식을 먼저 표시한다")
  func normalizesFolderExtensions() {
    #expect(LibraryFormatPicker.extensions(["CR3", "jpg", ".PNG", "*.JPG", "mp4", "", "avif"], kind: .all)
      == ["jpg", "png", "avif", "mp4", "cr3"])
  }

  @Test("검색은 대소문자와 점을 무시하고 여러 확장자를 찾는다")
  func searchesSeveralExtensions() {
    let values = ["jpg", "jpeg", "png", "mp4", "mov", "cr3"]
    #expect(LibraryFormatPicker.extensions(values, kind: .all, search: "*.JPG, .MP4") == ["jpg", "mp4"])
    #expect(LibraryFormatPicker.extensions(values, kind: .all, search: "jp") == ["jpg", "jpeg"])
    #expect(LibraryFormatPicker.extensions(values, kind: .all, search: "unknown").isEmpty)
  }

  @Test("검색 결과에도 선택한 이미지 또는 영상 종류를 적용한다")
  func limitsSearchToMediaKind() {
    let values = ["jpg", "png", "mp4", "mov", "qt", "cr3"]
    #expect(LibraryFormatPicker.extensions(values, kind: .images) == ["jpg", "png", "cr3"])
    #expect(LibraryFormatPicker.extensions(values, kind: .videos) == ["mp4", "mov", "qt"])
    #expect(LibraryFormatPicker.extensions(values, kind: .images, search: "mp4").isEmpty)
  }
}
