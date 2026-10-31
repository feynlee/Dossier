import XCTest

/// Taps rows while Dossier is reading every document again, as it does after an update changes how
/// documents are read. Each row gets one tap, and the screen it opens has to appear.
final class RereadingTapTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-SampleVault", "-SampleVaultStale"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 15), "The Vault didn't open")
    }

    func testRowsOpenWithOneTapWhileReading() {
        for _ in 0..<3 {
            tapOnce(app.buttons["document Li · Passport · 2019-03-14 to 2029-03-14"], opens: "Passport")
            tapOnce(app.buttons["folder EAD cards"], opens: "EAD cards", goingBack: false)
            tapOnce(app.buttons["document Mei · EAD card C09 · 2024-05-01 to 2026-04-30"], opens: "EAD card", backTo: "EAD cards")
            goBack(to: "Vault")
        }
    }

    func testDocumentStaysOpenWhileItIsRead() {
        tapOnce(app.buttons["document Li · Passport · 2019-03-14 to 2029-03-14"], opens: "Passport", goingBack: false)
        // Reading all five takes a while; the page must stay put the whole time.
        for _ in 0..<15 {
            XCTAssertTrue(app.navigationBars["Passport"].exists, "The passport closed while it was being read")
            sleep(1)
        }
        goBack(to: "Vault")
    }

    // MARK: Helpers

    private func tapOnce(_ element: XCUIElement, opens title: String, backTo: String = "Vault", goingBack: Bool = true,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Couldn't find \(element)", file: file, line: line)
        element.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 4), "One tap didn't open \(title)", file: file, line: line)
        if goingBack { goBack(to: backTo, file: file, line: line) }
    }

    private func goBack(to title: String, file: StaticString = #filePath, line: UInt = #line) {
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 4), "Back didn't return to \(title)", file: file, line: line)
    }
}
