import Foundation
import Testing
@testable import Dossier

struct LibraryIndexTests {
    func entry(_ id: String, _ path: [String], _ name: String) -> LibraryIndex.Entry {
        LibraryIndex.Entry(id: id, path: path, name: name, size: 10, added: .distantPast, modified: .distantPast)
    }

    var index: LibraryIndex {
        LibraryIndex(entries: [
            entry("a", ["Mei", "Immigration", "EAD cards"], "Mei · EAD card C09.pdf"),
            entry("b", ["Mei", "Identity", "Passports"], "Mei · Passport.pdf"),
            entry("c", ["Li", "Identity", "Passports"], "Li · Passport.jpg"),
            entry("d", ["Household", "Housing", "Leases"], "Household · Lease.pdf"),
        ], updated: .now)
    }

    @Test func foldersIncludeEveryLevelAboveADocument() {
        let folders = index.folders
        #expect(folders.contains(["Mei"]))
        #expect(folders.contains(["Mei", "Identity"]))
        #expect(folders.contains(["Mei", "Identity", "Passports"]))
        #expect(!folders.contains([]))
        #expect(folders.count == 11)
    }

    @Test func contentsListSubfoldersAndDocuments() {
        let top = index.contents(of: [])
        #expect(top.folders == ["Household", "Li", "Mei"])
        #expect(top.entries.isEmpty)

        let mei = index.contents(of: ["Mei"])
        #expect(mei.folders == ["Identity", "Immigration"])

        let passports = index.contents(of: ["Mei", "Identity", "Passports"])
        #expect(passports.folders.isEmpty)
        #expect(passports.entries.map(\.id) == ["b"])
    }

    @Test func identifiersRoundTrip() {
        let path = ["Mei", "Immigration", "EAD cards"]
        #expect(LibraryIndex.item(for: LibraryIndex.identifier(forFolder: path)) == .folder(path))
        #expect(LibraryIndex.item(for: LibraryIndex.identifier(forFolder: [])) == .folder([]))
        #expect(LibraryIndex.item(for: LibraryIndex.identifier(forEntry: "abc123")) == .entry("abc123"))
        #expect(LibraryIndex.item(for: "something else") == nil)
    }

    @Test func copiesAreNamedByContentHash() {
        guard LibraryIndex.container != nil else { return }
        #expect(LibraryIndex.fileURL(for: entry("abc", [], "Li · Passport.JPG"))?.lastPathComponent == "abc.jpg")
    }

    @Test func indexEncodesAndDecodes() throws {
        let original = index
        let decoded = try JSONDecoder().decode(LibraryIndex.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
