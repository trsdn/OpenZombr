import ServiceManagement
import XCTest

@testable import OpenZombrKit

final class LoginItemTests: XCTestCase {
    func testStatusWordingDistinguishesEveryState() {
        XCTAssertEqual(LoginItem.describe(.enabled), "registriert")
        XCTAssertEqual(LoginItem.describe(.notRegistered), "nicht registriert")
        XCTAssertEqual(
            LoginItem.describe(.requiresApproval),
            "wartet auf Freigabe in den Systemeinstellungen")
        XCTAssertEqual(LoginItem.describe(.notFound), "nicht gefunden")
    }

    /// `requiresApproval` means the item exists but macOS will not start it. Reporting that
    /// as success would reproduce exactly the failure this command exists to detect: an
    /// app that looks registered and is nevertheless gone after the next reboot.
    func testOnlyEnabledCountsAsEffective() {
        XCTAssertTrue(LoginItem.isEffective(.enabled))
        XCTAssertFalse(LoginItem.isEffective(.requiresApproval))
        XCTAssertFalse(LoginItem.isEffective(.notRegistered))
        XCTAssertFalse(LoginItem.isEffective(.notFound))
    }

    /// Under `swift run` there is no `.app` bundle and `SMAppService` would fail obscurely.
    /// The command has to say so rather than register something that cannot work.
    func testRefusesToActOutsideAnAppBundle() {
        let outcome = LoginItem.run(
            arguments: ["register"], bundle: Bundle(for: LoginItemTests.self))
        guard case .failed(let text) = outcome else {
            return XCTFail("expected a refusal outside an .app bundle, got \(outcome)")
        }
        XCTAssertTrue(text.contains("installiertes App-Bundle"))
        XCTAssertEqual(outcome.exitCode, 1)
    }

    func testFailureExitsNonZeroAndStatusExitsZero() {
        XCTAssertEqual(LoginItem.Outcome.status("x").exitCode, 0)
        XCTAssertEqual(LoginItem.Outcome.failed("x").exitCode, 1)
    }
}
