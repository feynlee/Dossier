import Foundation
import Testing
@testable import Dossier

/// Which documents are Key documents, and their order in the stack.
struct KeyDocumentsTests {
    struct Doc {
        var hash: String
        var kind: DocumentKind
        var person = "Li"
    }

    func sorted(_ keys: KeyDocuments, _ docs: [Doc]) -> [String] {
        keys.sorted(docs, hash: { $0.hash }, kind: { $0.kind }, person: { $0.person }).map(\.hash)
    }

    @Test func idsInUseAreAddedOnTheirOwn() {
        let keys = KeyDocuments()
        #expect(keys.contains(hash: "p", kind: .passport, isInUse: true))
        #expect(keys.contains(hash: "e", kind: .employmentAuthorization, isInUse: true))
        #expect(keys.contains(hash: "v", kind: .visa, isInUse: true))
        #expect(!keys.contains(hash: "p", kind: .passport, isInUse: false), "An expired passport is not a Key document")
        #expect(!keys.contains(hash: "l", kind: .lease, isInUse: true), "A lease is not added on its own")
        #expect(!keys.contains(hash: "o", kind: .other, isInUse: true))
    }

    @Test func pinningAndRemoving() {
        var keys = KeyDocuments()
        keys.add("ssn")
        #expect(keys.contains(hash: "ssn", kind: .other, isInUse: true))
        #expect(keys.contains(hash: "ssn", kind: .other, isInUse: false), "A pinned document stays after it ends")

        keys.remove("p", kind: .passport)
        #expect(!keys.contains(hash: "p", kind: .passport, isInUse: true), "A removed ID stays out")
        keys.add("p")
        #expect(keys.contains(hash: "p", kind: .passport, isInUse: true), "Adding it again brings it back")

        keys.remove("ssn", kind: .other)
        #expect(!keys.contains(hash: "ssn", kind: .other, isInUse: true))
        #expect(!keys.hidden.contains("ssn"), "Only IDs are remembered as taken out")
    }

    @Test func orderIsYoursThenByKind() {
        let docs = [Doc(hash: "p", kind: .passport), Doc(hash: "g", kind: .greenCard), Doc(hash: "d", kind: .driversLicense)]
        // Without an order, the passport is in front (last).
        #expect(sorted(KeyDocuments(), docs) == ["g", "d", "p"])

        var keys = KeyDocuments()
        keys.reorder(["p", "g"])
        // Ordered ones first, unordered ones after them, so they show in front.
        #expect(sorted(keys, docs) == ["p", "g", "d"])
    }

    @Test func savesAndLoadsAsJSON() {
        var keys = KeyDocuments()
        keys.add("a")
        keys.remove("b", kind: .passport)
        keys.reorder(["a"])
        #expect(KeyDocuments(json: keys.json) == keys)
        #expect(KeyDocuments(json: "not json") == KeyDocuments())
    }
}
