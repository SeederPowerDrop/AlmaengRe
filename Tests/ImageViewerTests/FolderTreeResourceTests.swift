import Combine
import Foundation
import Testing

@testable import ImageViewer

@Suite("폴더 트리 갱신의 자원 사용")
@MainActor
struct FolderTreeResourceTests {
  @Test("이미 표시 중인 경로를 다시 보여줄 때 동일한 행을 재발행하지 않는다")
  func repeatedRevealDoesNotRepublishRows() async {
    let root = URL(fileURLWithPath: "/folder-tree-resource-tests", isDirectory: true)
    let child = root.appendingPathComponent("child", isDirectory: true)
    let tree = FolderTreeStore { $0 == root ? [child] : [] }
    await tree.setRoot(root)
    await tree.reveal(child)
    var notifications = 0
    let observer = tree.objectWillChange.sink { notifications += 1 }
    for _ in 0..<100 { await tree.reveal(child) }
    #expect(notifications == 0)
    #expect(tree.rows.map(\.url) == [root, child])
    withExtendedLifetime(observer) {}
  }

  @Test("많은 삭제된 형제 폴더의 하위 캐시를 제거하고 새 분기만 다시 읽는다")
  func removesWideCachedSubtrees() async {
    let root = URL(fileURLWithPath: "/folder-tree-wide-resource-tests", isDirectory: true)
    let fixture = TreeResourceFixture(root: root, count: 120)
    let tree = FolderTreeStore { fixture.read($0) }
    await tree.setRoot(root)
    for child in fixture.children { await tree.toggleExpansion(child) }
    #expect(tree.rows.count == 241)
    fixture.replaceChildrenWithEmptyFolders()
    await tree.refresh()
    #expect(tree.rows.map(\.url) == [root])
    fixture.restoreChildren()
    await tree.refresh()
    #expect(tree.rows.count == 121)
    #expect(tree.rows.dropFirst().allSatisfy { !$0.isExpanded })
    // A removed branch must not resurrect its old cached grandchild on reopening.
    for child in fixture.children { await tree.toggleExpansion(child) }
    #expect(tree.rows.count == 121)
    #expect(tree.rows.dropFirst().allSatisfy { !$0.canExpand })
  }
}

private final class TreeResourceFixture: @unchecked Sendable {
  let root: URL
  let children: [URL]
  private let lock = NSLock()
  private var showsChildren = true
  private var showsGrandchildren = true

  init(root: URL, count: Int) {
    self.root = root
    children = (0..<count).map { root.appendingPathComponent("child\($0)", isDirectory: true) }
  }

  func read(_ url: URL) -> [URL] {
    lock.withLock {
      if url == root { return showsChildren ? children : [] }
      return showsGrandchildren ? [url.appendingPathComponent("nested", isDirectory: true)] : []
    }
  }

  func replaceChildrenWithEmptyFolders() {
    lock.withLock { showsChildren = false; showsGrandchildren = false }
  }

  func restoreChildren() { lock.withLock { showsChildren = true } }
}
