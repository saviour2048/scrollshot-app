import XCTest
@testable import ScrollShot

final class ShelfOrphanSweepTests: XCTestCase {

    /// 目录内容过滤: index.json 和被引用的文件(含缩略图伴生文件)不删,
    /// 其余(终端拖出残留 + 其缩略图)是清理候选。
    func testOrphanCandidates() {
        let contents = [
            "index.json",
            "IMG_8350.PNG",            // 被引用
            "IMG_8350.thumb.png",      // 被引用条目的缩略图
            "IMG_8343.PNG",            // 孤儿(终端拖出残留)
            "IMG_8343.thumb.png",      // 孤儿的缩略图
            "notes.txt",               // 孤儿
        ]
        let referenced: Set<String> = ["IMG_8350.PNG", "IMG_8350.thumb.png"]
        XCTAssertEqual(Set(ShelfStore.orphanCandidates(contents: contents, referenced: referenced)),
                       ["IMG_8343.PNG", "IMG_8343.thumb.png", "notes.txt"])
    }
}
