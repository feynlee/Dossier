import XCTest

/// Taps through the Vault with the sample vault: folders, documents, the person switcher and back again.
final class VaultNavigationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-SampleVault"]
        app.launch()
        // Personal is the first tab, so Dossier opens on it.
        XCTAssertTrue(app.navigationBars["Personal"].waitForExistence(timeout: 15), "Personal didn't open first")
        app.tabBars.buttons["Vault"].tap()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 5), "The Vault didn't open")
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
        // The passport is a Key document: tapping its card brings it forward, and Open document opens its page.
        tap(app.buttons["document Li · Passport · 2019-03-14 to 2029-03-14"])
        let open = app.buttons["open document"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "The passport's card didn't come forward")
        open.tap()
        XCTAssertTrue(open.waitForNonExistence(timeout: 5), "The card didn't close")
        XCTAssertTrue(app.navigationBars["Passport"].waitForExistence(timeout: 5), "The passport didn't open")
        keepScreenshot("Document opened from the Vault")
        goBack()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 5), "Back didn't return to the Vault")

        tap(app.buttons["document Li · Medical exam I-693 · 2024-02-10"])
        XCTAssertTrue(app.navigationBars["Report of medical examination"].waitForExistence(timeout: 5), "The exam didn't open")
        // What the exam records shows under its own sections; each row is a button that shows where it was read.
        XCTAssertTrue(reveal(app.buttons["IGRA result"]), "The exam's results are missing")
        XCTAssertTrue(reveal(app.buttons["MMR · dose 2"]), "The exam's vaccinations are missing")
        keepScreenshot("Medical exam contents")
        goBack()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 5))
    }

    func testVaultShowsEveryonesDocumentsTogether() {
        keepScreenshot("Vault, everyone")
        // No person switcher: Li's, Mei's and the household's documents all show.
        XCTAssertFalse(app.segmentedControls.firstMatch.exists, "The person switcher is back")
        XCTAssertTrue(reveal(app.buttons["document Li · Passport · 2019-03-14 to 2029-03-14"]), "Li's passport is missing")
        XCTAssertTrue(reveal(app.buttons["folder EAD cards"]), "Mei's EAD cards are missing")
        XCTAssertTrue(reveal(app.buttons["document Household · Lease 88 Pine Ave · 2023-06-01 to 2024-05-31"]), "The shared lease is missing")

        tap(app.buttons["folder EAD cards"])
        XCTAssertTrue(app.navigationBars["EAD cards"].waitForExistence(timeout: 5))
        tap(app.buttons["document Mei · EAD card C09 · 2024-05-01 to 2026-04-30"])
        XCTAssertTrue(app.navigationBars["EAD card"].waitForExistence(timeout: 5))
        goBack()
        goBack()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 5))
    }

    func testShelfSeeAllListsTheCategory() {
        tap(app.buttons["category Immigration"])
        XCTAssertTrue(app.navigationBars["Immigration"].waitForExistence(timeout: 5), "See all didn't open the category")
        keepScreenshot("Immigration, see all")
        tap(app.buttons["document Mei · EAD card C09 · 2024-05-01 to 2026-04-30"])
        XCTAssertTrue(app.navigationBars["EAD card"].waitForExistence(timeout: 5), "A document didn't open from See all")
        goBack()
        goBack()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 5), "Back didn't return to the Vault")
    }

    func testTappingAKeyDocumentBringsItForward() {
        tap(app.buttons["document Li · Passport · 2019-03-14 to 2029-03-14"])
        let done = app.buttons["Done"]
        XCTAssertTrue(app.buttons["open document"].waitForExistence(timeout: 5), "The card didn't come forward")
        XCTAssertTrue(app.navigationBars["Passport"].exists, "The card's title isn't its type")
        keepScreenshot("Key document brought forward")

        // Tapping a field copies it: the row reads "Copied" for a moment.
        let surname = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Surname'")).firstMatch
        XCTAssertTrue(reveal(surname), "No surname field")
        surname.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Surname copied'")).firstMatch.waitForExistence(timeout: 3), "No sign the surname was copied")

        done.tap()
        XCTAssertTrue(app.buttons["open document"].waitForNonExistence(timeout: 5), "Done didn't close the card")
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 5))
    }

    func testSearchButtonOpensSearch() {
        let button = app.buttons["search documents"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "No search button")
        button.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), "The search button didn't show search")
    }

    func testPullingDownOpensSearch() {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), "Pulling down didn't show search")
        keepScreenshot("Pulled down to search")
    }

    func testPersonalInformationOpensAndGoesBack() {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Personal information'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // Li's vault: Mei's EAD cards are hers, so they don't make Li's given names disagree.
        XCTAssertFalse(row.label.contains("disagree"), "Family members' documents count as yours: \(row.label)")
        tap(row)
        XCTAssertTrue(app.navigationBars["Personal information"].waitForExistence(timeout: 5))
        goBack()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 5))
    }

    /// The first source button on screen ("Open Passport" or "Sources: 3 documents"). The other tab's
    /// Personal rows stay loaded off screen and match too, so only one you can tap counts.
    private func visibleSource(timeout: TimeInterval = 5) -> XCUIElement? {
        let query = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open ' OR label BEGINSWITH 'Sources:'"))
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if let match = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) { return match }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < end
        return nil
    }

    func testPersonalInformationCopiesAndOpensTheSource() {
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Personal information'")).firstMatch)
        XCTAssertTrue(app.navigationBars["Personal information"].waitForExistence(timeout: 5))

        // Tapping a value copies it: the row reads "Copied" for a moment.
        let surname = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Surname'")).firstMatch
        XCTAssertTrue(surname.waitForExistence(timeout: 5), "No surname row")
        surname.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Surname copied'")).firstMatch.waitForExistence(timeout: 3), "No sign the surname was copied")
        keepScreenshot("Surname copied")

        // The document button opens the document the value comes from, or a menu of them.
        // The other tab keeps its own rows, off screen: use the one on this screen.
        guard let source = visibleSource() else { return XCTFail("No document button") }
        let isMenu = source.label.hasPrefix("Sources:")
        source.tap()
        if isMenu {
            keepScreenshot("Source menu")
            let item = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Passport'")).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3), "The menu doesn't list the passport")
            item.tap()
        }
        XCTAssertTrue(app.navigationBars["Personal information"].waitForNonExistence(timeout: 5), "The document didn't open")
        keepScreenshot("Source document on the field")
        goBack()
        XCTAssertTrue(app.navigationBars["Personal information"].waitForExistence(timeout: 5), "Back didn't return to Personal information")
    }

    func testPersonalTabIsFirstAndCopies() {
        let tabs = app.tabBars.buttons.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(tabs.first, "Personal", "Personal isn't the first tab: \(tabs)")
        app.tabBars.buttons["Personal"].tap()
        XCTAssertTrue(app.navigationBars["Personal"].waitForExistence(timeout: 5))

        // Tapping a value copies it: "Copied" shows on the row for a moment.
        let surname = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Surname'")).firstMatch
        XCTAssertTrue(surname.waitForExistence(timeout: 5), "No surname row")
        surname.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Copied'")).firstMatch.waitForExistence(timeout: 3), "The row doesn't say Copied")
        keepScreenshot("Personal tab, surname copied")

        // The source on the right opens the document the value comes from.
        guard let source = visibleSource() else { return XCTFail("No source") }
        let isMenu = source.label.hasPrefix("Sources:")
        source.tap()
        if isMenu {
            let item = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Passport'")).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3), "The menu doesn't list the passport")
            item.tap()
        }
        XCTAssertTrue(app.navigationBars["Personal"].waitForNonExistence(timeout: 5), "The document didn't open")
        goBack()
        XCTAssertTrue(app.navigationBars["Personal"].waitForExistence(timeout: 5), "Back didn't return to Personal")
    }

    func testSearchResultsAndExpiredDocumentsOpen() {
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 3) { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "No search field")
        search.tap()
        search.typeText("EAD")
        // The 2024 card is current; the 2022 one has expired and is listed under Expired.
        tap(app.buttons["document Mei · EAD card C09 · 2024-05-01 to 2026-04-30"])
        XCTAssertTrue(app.navigationBars["EAD card"].waitForExistence(timeout: 5), "A search result didn't open")
        goBack()
        tap(app.buttons["document Mei · EAD card C09 · 2022-05-01 to 2024-04-30"])
        XCTAssertTrue(app.navigationBars["EAD card"].waitForExistence(timeout: 5), "An expired document didn't open")
        goBack()
        XCTAssertTrue(app.buttons["document Mei · EAD card C09 · 2022-05-01 to 2024-04-30"].waitForExistence(timeout: 5), "Back didn't return to the results")
    }

    func testSelectModeSelectsInsteadOfOpening() {
        app.buttons["More"].tap()
        app.buttons["Select"].tap()
        XCTAssertTrue(app.navigationBars["Select documents"].waitForExistence(timeout: 5), "Select mode didn't start")
        app.buttons["document Li · Passport · 2019-03-14 to 2029-03-14"].tap()
        XCTAssertTrue(app.navigationBars["1 selected"].waitForExistence(timeout: 5), "Tapping a row in Select mode didn't select it")
        XCTAssertFalse(app.navigationBars["Passport"].exists, "Tapping a row in Select mode opened it")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Vault"].waitForExistence(timeout: 5))
        // Out of Select mode, the passport is a card again: a tap brings it forward, and Open document opens it.
        tap(app.buttons["document Li · Passport · 2019-03-14 to 2029-03-14"])
        let open = app.buttons["open document"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "After Select mode, the card didn't come forward")
        open.tap()
        XCTAssertTrue(open.waitForNonExistence(timeout: 5), "The card didn't close")
        XCTAssertTrue(app.navigationBars["Passport"].waitForExistence(timeout: 5), "After Select mode, the passport didn't open")
    }

    func testTimelineShowsOnlyYourDocuments() {
        app.tabBars.buttons["Timeline"].tap()
        XCTAssertTrue(app.buttons["List"].waitForExistence(timeout: 5), "The timeline didn't open")
        // Mei's EAD cards are hers: her status isn't on Li's timeline.
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'EAD'")).firstMatch.waitForExistence(timeout: 3),
                       "A family member's status shows on your timeline")
    }

    // MARK: Helpers

    /// Scrolls until the element is on screen. Rows further down aren't made until they're near, and the
    /// document page's list scrolls on its own below the page preview, so each list gets a turn.
    @discardableResult
    private func reveal(_ element: XCUIElement) -> Bool {
        if element.waitForExistence(timeout: 3), element.isHittable { return true }
        for _ in 0..<6 {
            app.swipeUp()
            if element.exists, element.isHittable { return true }
        }
        // A swipe flings past lazy rows, so the lists are dragged a little at a time.
        // Down first, then back up, since the swipes above can fling a list past it to the end.
        for list in app.collectionViews.allElementsBoundByIndex where list.isHittable {
            for (from, to) in [(0.8, 0.45), (0.45, 0.8)] {
                for _ in 0..<12 {
                    if element.exists, element.isHittable { return true }
                    list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                        .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
                }
            }
        }
        return element.exists && element.isHittable
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
