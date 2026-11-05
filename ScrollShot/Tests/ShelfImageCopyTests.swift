import XCTest
@testable import ScrollShot

final class ShelfImageCopyTests: XCTestCase {

    private func fileItem(_ paths: [String]) -> ShelfItem {
        ShelfItem(id: UUID(), kind: .file, addedAt: Date(), filePaths: paths, text: nil, imageFileName: nil)
    }

    /// 用户真实场景：从 Finder 拖进暂存架的两个 HEIC，拖出时应全部识别为图片。
    func testFileItemFiltersImageExtensions() {
        let item = fileItem([
            "/tmp/Shelf/IMG_7957.HEIC",
            "/tmp/Shelf/IMG_7956.heic",
            "/tmp/Shelf/notes.txt",
            "/tmp/Shelf/archive.zip",
            "/tmp/Shelf/photo.PNG",
        ])
        XCTAssertEqual(ShelfImageCopy.imagePaths(for: item, imageURL: nil),
                       ["/tmp/Shelf/IMG_7957.HEIC", "/tmp/Shelf/IMG_7956.heic", "/tmp/Shelf/photo.PNG"])
    }

    func testImageItemUsesImageURL() {
        let item = ShelfItem(id: UUID(), kind: .image, addedAt: Date(),
                             filePaths: nil, text: nil, imageFileName: "shot.png")
        let url = URL(fileURLWithPath: "/tmp/Shelf/shot.png")
        XCTAssertEqual(ShelfImageCopy.imagePaths(for: item, imageURL: url), ["/tmp/Shelf/shot.png"])
    }

    func testTextItemHasNoImages() {
        let item = ShelfItem(id: UUID(), kind: .text, addedAt: Date(),
                             filePaths: nil, text: "hello", imageFileName: nil)
        XCTAssertTrue(ShelfImageCopy.imagePaths(for: item, imageURL: nil).isEmpty)
    }
}
