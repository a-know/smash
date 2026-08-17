import XCTest

@testable import MarkdownDriveCore

final class MarkdownDriveCoreTests: XCTestCase {
    func testMarkdownFileRuleAcceptsMDExtensionCaseInsensitively() {
        XCTAssertTrue(MarkdownFileRules.isMarkdownFile(name: "memo.md"))
        XCTAssertTrue(MarkdownFileRules.isMarkdownFile(name: "README.MD"))
    }

    func testMarkdownFileRuleRejectsUnsupportedOrMissingExtensions() {
        XCTAssertFalse(MarkdownFileRules.isMarkdownFile(name: "memo.markdown"))
        XCTAssertFalse(MarkdownFileRules.isMarkdownFile(name: "memo.txt"))
        XCTAssertFalse(MarkdownFileRules.isMarkdownFile(name: "memo"))
        XCTAssertFalse(MarkdownFileRules.isMarkdownFile(name: ".md"))
    }

    func testDriveItemKeepsFileAndFolderIdentitySeparateFromItsName() {
        let item = DriveItem(
            id: "drive-file-id",
            name: "memo.md",
            kind: .file,
            parentIDs: ["vault-root-id"]
        )

        XCTAssertEqual(item.id, "drive-file-id")
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.parentIDs, ["vault-root-id"])
        XCTAssertFalse(item.isTrashed)
    }

    func testVaultDecodesSettingsSavedBeforeSoftTrashFolderWasIntroduced() throws {
        let data = Data(#"{"rootFolderID":"vault","displayName":"Notes"}"#.utf8)

        let vault = try JSONDecoder().decode(Vault.self, from: data)

        XCTAssertEqual(vault.rootFolderID, "vault")
        XCTAssertEqual(vault.displayName, "Notes")
        XCTAssertNil(vault.softTrashFolderID)
    }
}
