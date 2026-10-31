import Testing
@testable import Dossier

/// US cards print 08/12/1990 for 12 August; the model sometimes reads it as 8 December.
struct DateOrderTests {
    @Test func putsSwappedUSDatesBack() {
        let pages = [["Date of Birth", "08/12/1990", "Resident Since 03/02/2021"]]
        let order = Verifier.numericDateOrder(in: pages, kind: .greenCard)
        #expect(order == .monthFirst)
        let fixed = Verifier.verify([.init(key: .dateOfBirth, value: "1990-12-08", page: 1)], pages: pages, mrz: nil, license: nil, kind: .greenCard)
        #expect(fixed.first?.value == "1990-08-12")
        #expect(Verifier.verifyEntry("2021-02-03 · Card", isConfident: true, page: 1, pages: pages, order: order)?.value.hasPrefix("2021-03-02") == true)
    }

    @Test func leavesRightDatesAlone() {
        let pages = [["DOB 08/12/1990"]]
        let kept = Verifier.verify([.init(key: .dateOfBirth, value: "1990-08-12", page: 1)], pages: pages, mrz: nil, license: nil, kind: .driversLicense)
        #expect(kept.first?.value == "1990-08-12")
    }

    @Test func readsTheOrderFromAnUnambiguousDate() {
        #expect(Verifier.numericDateOrder(in: [["Issued 25/03/2019", "Born 08/12/1990"]], kind: nil) == .dayFirst)
        #expect(Verifier.numericDateOrder(in: [["Born 12 AUG 1990"]], kind: .passport) == nil)
    }
}
