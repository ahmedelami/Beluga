import Darwin
import Foundation
import XCTest
@testable import CaptureServer

final class WorldwideSecondaryTestViewerControlPathTests: XCTestCase {
    func testLexicalValidationIsIndependentOfExistenceAndRejectsTraversal() throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let leaf = directory.appendingPathComponent("receipt.json")
        let socket = directory.appendingPathComponent("control.sock").path
        let arguments = ["CaptureServer", "--stop-secondary-test-viewer-generation", leaf.path,
                         "--secondary-test-viewer-control-socket", socket]
        let before = try WorldwideSecondaryTestViewerControlClientMode.parseIfRequested(arguments)
        try Data("fixture".utf8).write(to: leaf)
        try Data().write(to: URL(fileURLWithPath: socket))
        let after = try WorldwideSecondaryTestViewerControlClientMode.parseIfRequested(arguments)
        XCTAssertEqual(before, after)
        XCTAssertEqual(after?.receiptURL.path, leaf.path)
        for invalid in ["", "/", "relative", "/a//b", "/a/./b", "/a/../b", "/a/", "/a\0b"] {
            XCTAssertFalse(WorldwideSecondaryTestViewerControlPath.isLexicallyAbsolute(invalid), invalid)
            XCTAssertThrowsError(try WorldwideSecondaryTestViewerControlClientMode.parseIfRequested(
                ["CaptureServer", "--probe-secondary-test-viewer-status", invalid]
            ))
        }
    }

    func testDirectoryIdentityAllowsSystemAliasesButRejectsArbitraryAncestors() throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(WorldwideSecondaryTestViewerControlPath.isCanonicalDirectory(directory.path))
        let systemAlias = String(directory.path.dropFirst("/private".count))
        XCTAssertTrue(WorldwideSecondaryTestViewerControlPath.isCanonicalDirectory(systemAlias))
        let real = directory.appendingPathComponent("real/child", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: real.deletingLastPathComponent()
        )
        XCTAssertFalse(WorldwideSecondaryTestViewerControlPath.isCanonicalDirectory(
            alias.appendingPathComponent("child").path
        ))
        XCTAssertFalse(WorldwideSecondaryTestViewerControlPath.hasCanonicalParent(
            alias.appendingPathComponent("child/control.sock").path
        ))
    }

    private func privateDirectory() throws -> URL {
        var template = Array("/private/tmp/v90-path-fixture.XXXXXX".utf8CString)
        let created = try XCTUnwrap(mkdtemp(&template))
        return URL(fileURLWithPath: String(cString: created), isDirectory: true)
    }
}
