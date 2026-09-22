import XCTest

@testable import OpenZombrKit

/// The dropdown opens with the application's name, so it is clear which menu bar item it
/// belongs to. The version rides along when there is one to read.
final class MenuTitleTests: XCTestCase {
    func testTitleCarriesTheVersionWhenBundled() {
        XCTAssertEqual(MenuBarContentView.title(version: "0.4.0"), "OpenZombr 0.4.0")
    }

    /// `swift run` has no Info.plist, so there is no version to show.
    func testTitleIsJustTheNameWithoutAVersion() {
        XCTAssertEqual(MenuBarContentView.title(version: nil), "OpenZombr")
        XCTAssertEqual(MenuBarContentView.title(version: ""), "OpenZombr")
    }
}
