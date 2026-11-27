import Testing
@testable import Dossier

/// The text on a Key document's card.
struct WalletTextTests {
    @Test func titleShowsTypeAndPerson() {
        #expect(WalletText.title(kind: "Passport", person: "Li") == "Passport · Li")
        #expect(WalletText.title(kind: "EAD card", person: nil) == "EAD card", "No person: the type alone")
        #expect(WalletText.title(kind: "Visa", person: "  ") == "Visa", "A blank person is left out")
    }

    @Test func nameIsGivenNamesThenSurname() {
        #expect(WalletText.name(given: "Wei", surname: "Li") == "Wei Li")
        #expect(WalletText.name(given: nil, surname: "Li") == "Li")
        #expect(WalletText.name(given: " ", surname: nil) == nil)
    }
}
