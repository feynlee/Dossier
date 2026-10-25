import XCTest

/// Taps through the Vault with the sample vault: folders, documents, the person switcher and back again.
final class VaultNavigationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-SampleVault"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 15), "The Vault didn't open")
    }

    func testOpeningADocumentInAFolderAndGoingBack() {
        tap(app.buttons["folder EAD cards"])
        XCTAssertTrue(app.navigationBars["EAD cards"].waitForExistence(timeout: 5), "The folder didn't open")

        tap(app.buttons["document Mei · EAD card C09 · 2024-05-01 to 2026-04-30"])
        XCTAssertTrue(app.navigationBars["EAD card"].waitForExistence(timeout: 5), "The document didn't open")
        keepScreenshot("Document opened from a folder")

        goBack()
        XCTAssertTrue(app.navigationBars["EAD cards"].waitForExistence(timeout: 5), "Back didn't return to the folder")
        XCTAssertFalse(app.navigationBars["EAD card"].exists, "The document is still showing")

        // The other document in the same folder opens too.
        tap(app.buttons["document Mei · EAD card C09 · 2022-05-01 to 2024-04-30"])
        XCTAssertTrue(app.navigationBars["EAD card"].waitForExistence(timeout: 5), "The second document didn't open")
        goBack()
        goBack()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 5), "Back didn't return to the Vault")
        XCTAssertFalse(app.navigationBars["EAD cards"].exists, "The folder is still showing")
    }

    func testOpeningADocumentInTheVaultAndGoingBack() {
        tap(app.buttons["document Li · Passport · 2019-03-14 to 2029-03-14"])
        XCTAssertTrue(app.navigationBars["Passport"].waitForExistence(timeout: 5), "The passport didn't open")
        keepScreenshot("Document opened from the Vault")
        goBack()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 5), "Back didn't return to the Vault")

        tap(app.buttons["document Li · Medical exam I-693 · 2024-02-10"])
        XCTAssertTrue(app.navigationBars["Report of medical examination"].waitForExistence(timeout: 5), "The exam didn't open")
        goBack()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 5))
    }

    func testPersonSwitcherShowsEachPersonsDocuments() {
        keepScreenshot("Vault, everyone")
        app.buttons["Mei"].tap()
        XCTAssertTrue(app.buttons["folder EAD cards"].waitForExistence(timeout: 5), "Mei's EAD cards are missing")
        XCTAssertFalse(app.buttons["document Li · Passport · 2019-03-14 to 2029-03-14"].exists, "Li's passport shows for Mei")
        keepScreenshot("Vault, Mei")
        XCTAssertTrue(reveal(app.buttons["document Household · Lease 88 Pine Ave · 2023-06-01 to 2024-05-31"]), "The shared lease is missing")
        while !app.buttons["Mei"].isHittable { app.swipeDown() }

        tap(app.buttons["folder EAD cards"])
        XCTAssertTrue(app.navigationBars["EAD cards"].waitForExistence(timeout: 5))
        tap(app.buttons["document Mei · EAD card C09 · 2024-05-01 to 2026-04-30"])
        XCTAssertTrue(app.navigationBars["EAD card"].waitForExistence(timeout: 5))
        goBack()
        goBack()

        app.buttons["Li"].tap()
        XCTAssertTrue(app.buttons["document Li · Passport · 2019-03-14 to 2029-03-14"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["folder EAD cards"].exists, "Mei's EAD cards show for Li")
    }

    func testPersonalInformationOpensAndGoesBack() {
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Personal information'")).firstMatch)
        XCTAssertTrue(app.navigationBars["Personal information"].waitForExistence(timeout: 5))
        goBack()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 5))
    }

    // MARK: Helpers

    /// Scrolls the list until the element is on screen. Rows further down aren't made until they're near.
    @discardableResult
    private func reveal(_ element: XCUIElement) -> Bool {
        if element.waitForExistence(timeout: 3), element.isHittable { return true }
        for _ in 0..<6 {
            app.swipeUp()
            if element.exists, element.isHittable { return true }
        }
        return false
    }

    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(reveal(element), "Couldn't find \(element)", file: file, line: line)
        element.tap()
    }

    private func goBack() {
        app.navigationBars.firstMatch.buttons.firstMatch.tap()
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
