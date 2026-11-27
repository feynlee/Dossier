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
        // Personal is the first tab, so Dossier opens on it.
        XCTAssertTrue(app.navigationBars["Personal"].waitForExistence(timeout: 15), "Personal didn't open first")
        app.tabBars.buttons["Vault"].tap()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 5), "The Vault didn't open")
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

    func testRowsStayPutWhileReading() {
        let passport = app.buttons["document Li · Passport · 2019-03-14 to 2029-03-14"]
        XCTAssertTrue(passport.waitForExistence(timeout: 5))
        let start = passport.frame.minY
        // Documents finish reading one by one; rows above the passport mustn't appear or go away meanwhile.
        for _ in 0..<12 {
            sleep(1)
            XCTAssertEqual(passport.frame.minY, start, accuracy: 1, "The passport row moved while documents were being read")
        }
    }

    // MARK: Helpers

    private func tapOnce(_ element: XCUIElement, opens title: String, backTo: String = "Vault", goingBack: Bool = true,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Couldn't find \(element)", file: file, line: line)
        element.tap()
        // A Key document's card comes forward first; its Open document button opens the page.
        let open = app.buttons["open document"]
        if open.waitForExistence(timeout: 2) {
            open.tap()
            XCTAssertTrue(open.waitForNonExistence(timeout: 4), "The card didn't close", file: file, line: line)
        }
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 4), "One tap didn't open \(title)", file: file, line: line)
        if goingBack { goBack(to: backTo, file: file, line: line) }
    }

    private func goBack(to title: String, file: StaticString = #filePath, line: UInt = #line) {
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 4), "Back didn't return to \(title)", file: file, line: line)
    }
}
