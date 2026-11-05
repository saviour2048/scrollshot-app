import XCTest
@testable import ScrollShot

/// The launcher used to build its app index exactly once at launch, so anything
/// installed afterwards (user hit this with WeCom: installed 16:12, searched
/// "wecom" at 16:15, "无结果" until relaunch) never showed up.
@MainActor
final class AppIndexTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeApp(named name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("\(name).app", isDirectory: true),
            withIntermediateDirectories: true)
    }

    func testFindsAppInstalledAfterFirstBuild() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(named: "Alpha", in: root)

        let index = AppIndex(roots: [root.path])
        index.buildIfNeeded()
        XCTAssertEqual(index.search("alpha").map(\.name), ["Alpha"])
        XCTAssertTrue(index.search("beta").isEmpty)

        // Simulates installing WeCom while ScrollShot is running.
        try makeApp(named: "Beta", in: root)
        index.buildIfNeeded()

        XCTAssertEqual(index.search("beta").map(\.name), ["Beta"])
        XCTAssertEqual(index.search("alpha").count, 1, "existing entries must survive the refresh")
    }

    func testDropsAppRemovedAfterFirstBuild() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(named: "Gamma", in: root)

        let index = AppIndex(roots: [root.path])
        index.buildIfNeeded()
        XCTAssertEqual(index.search("gamma").count, 1)

        try FileManager.default.removeItem(at: root.appendingPathComponent("Gamma.app"))
        index.buildIfNeeded()

        XCTAssertTrue(index.search("gamma").isEmpty, "uninstalled apps must not stay as ghosts")
    }

    func testFindsAppInstalledInsideWrapperFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrapper = root.appendingPathComponent("Setapp", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        try makeApp(named: "Delta", in: wrapper)

        let index = AppIndex(roots: [root.path])
        index.buildIfNeeded()
        XCTAssertEqual(index.search("delta").count, 1)

        // Install inside the wrapper: /Applications' own mtime does not change,
        // the wrapper's does.
        try makeApp(named: "Epsilon", in: wrapper)
        index.buildIfNeeded()

        XCTAssertEqual(index.search("epsilon").count, 1)
    }

    /// ScrollShot runs in zh-Hans, so `displayName` returns 企业微信 while the
    /// English brand is WeCom. Searching "wecom" must still find it.
    func testFindsChineseNamedAppByEnglishLocalizedAlias() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("企业微信.app", isDirectory: true)
        let lproj = app.appendingPathComponent("Contents/Resources/en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        try "\"CFBundleDisplayName\" = \"WeCom\";\n"
            .write(to: lproj.appendingPathComponent("InfoPlist.strings"), atomically: true, encoding: .utf8)

        let index = AppIndex(roots: [root.path])
        index.buildIfNeeded()

        XCTAssertEqual(index.search("wecom").map(\.name), ["企业微信"])
        XCTAssertEqual(index.search("企业微信").count, 1, "the localized name must keep working")
    }
}
