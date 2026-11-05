import XCTest
@testable import ScrollShot

final class SmartPasteClipboardTests: XCTestCase {

    private func classify(_ types: [String], _ paths: [String] = []) -> SmartPasteController.ClipboardKind {
        SmartPasteController.classifyClipboard(types: Set(types), filePaths: paths)
    }

    /// 单个图片文件 → .singleImageFile(先转位图剪贴板再贴)——Kimi 对文件
    /// 剪贴板只贴路径引用, 直接放行贴不出图片附件。
    func testSingleImageFile() {
        XCTAssertEqual(classify(["public.file-url"], ["/tmp/a.png"]), .singleImageFile("/tmp/a.png"))
    }

    /// 单个非图片文件保持 .empty(放行), 终端原生 Cmd+V 贴路径。
    func testSingleNonImageFileStaysEmpty() {
        XCTAssertEqual(classify(["public.file-url"], ["/tmp/a.txt"]), .empty)
    }

    /// 回归(2026-10-22): Finder 复制单个图片文件会附带文件名 string + 位图,
    /// 必须仍判 .singleImageFile, 不能掉进 .text(Ctrl+V 被换成 Cmd+V 贴文件名)。
    func testSingleImageFileWithFilenameString() {
        XCTAssertEqual(classify(["public.file-url", "public.utf8-plain-text",
                                 "public.png", "public.tiff"], ["/tmp/a.png"]),
                       .singleImageFile("/tmp/a.png"))
    }

    /// 多文件 → 键入路径文本。
    func testMultipleFiles() {
        XCTAssertEqual(classify(["public.file-url"], ["/tmp/a.png", "/tmp/b.png"]),
                       .multipleFiles(["/tmp/a.png", "/tmp/b.png"]))
    }

    /// Finder 复制文件会附带图标位图: 有文件时不能判成图片附件。
    func testFileWithIconBitmapIsNotImage() {
        XCTAssertEqual(classify(["public.file-url", "public.tiff"], ["/tmp/a.png", "/tmp/b.png"]),
                       .multipleFiles(["/tmp/a.png", "/tmp/b.png"]))
    }

    func testPlainImage() {
        XCTAssertEqual(classify(["public.png"]), .image)
    }

    func testPlainText() {
        XCTAssertEqual(classify(["public.utf8-plain-text"]), .text)
    }

    func testEmpty() {
        XCTAssertEqual(classify([]), .empty)
    }

    func testQuotedPaths() {
        XCTAssertEqual(SmartPasteController.quotedPaths(["/tmp/a b.png", "/tmp/c.png"]),
                       "\"/tmp/a b.png\" \"/tmp/c.png\"")
        XCTAssertEqual(SmartPasteController.quotedPaths(["/tmp/we\"ird.png"]),
                       "\"/tmp/we\\\"ird.png\"")
        XCTAssertEqual(SmartPasteController.quotedPaths(["/tmp/back\\slash.png"]),
                       "\"/tmp/back\\\\slash.png\"")
    }
}
