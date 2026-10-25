import Foundation
import Testing
@testable import Dossier

struct FolderTreeTests {
    /// Paperwork/
    ///   Immigration/EAD 2024/EAD_front.jpg, EAD_back.jpg, notes.txt
    ///   Immigration/Passport scan.pdf
    ///   Housing/Leases/Lease 2021.pdf
    ///   Empty/readme.txt
    ///   .hidden.pdf
    func withPaperwork(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Paperwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "Immigration/EAD 2024/EAD_front.jpg", "Immigration/EAD 2024/EAD_back.jpg", "Immigration/EAD 2024/notes.txt",
            "Immigration/Passport scan.pdf", "Housing/Leases/Lease 2021.pdf", "Empty/readme.txt", ".hidden.pdf",
        ]
        for file in files {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("%PDF-1.4".utf8).write(to: url)
        }
        try body(root)
    }

    @Test func keepsOnlyPDFsPhotosAndTheFoldersThatHoldThem() throws {
        try withPaperwork { root in
            let tree = FolderTree.scan(root)
            #expect(tree.root.children.map(\.name) == ["Housing", "Immigration"])
            #expect(Set(tree.root.files.map(\.id)) == [
                "Immigration/EAD 2024/EAD_front.jpg", "Immigration/EAD 2024/EAD_back.jpg",
                "Immigration/Passport scan.pdf", "Housing/Leases/Lease 2021.pdf",
            ])
            let immigration = try #require(tree.root.children.last)
            #expect(immigration.children.map(\.name) == ["EAD 2024", "Passport scan.pdf"])
        }
    }

    @Test func showsICloudPlaceholdersUnderTheirRealNames() {
        #expect(FolderTree.visibleName(".Passport.pdf.icloud") == "Passport.pdf")
        #expect(FolderTree.visibleName(".DS_Store") == nil)
        #expect(FolderTree.visibleName("Lease.pdf") == "Lease.pdf")
    }

    @Test func tickingAFolderTicksEverythingInsideAndShowsPartlyTickedParents() throws {
        try withPaperwork { root in
            let tree = FolderTree.scan(root)
            let immigration = try #require(tree.root.children.first { $0.name == "Immigration" })
            let ead = try #require(immigration.children.first { $0.name == "EAD 2024" })
            var selection = FolderSelection()
            selection.toggle(ead)
            #expect(selection.selected == ["Immigration/EAD 2024/EAD_front.jpg", "Immigration/EAD 2024/EAD_back.jpg"])
            #expect(selection.state(of: ead) == .all)
            #expect(selection.state(of: immigration) == .some)
            #expect(selection.state(of: tree.root) == .some)
            #expect(selection.folderCount(in: tree) == 1)

            selection.toggle(immigration)
            #expect(selection.state(of: immigration) == .all)
            selection.toggle(immigration)
            #expect(selection.selected.isEmpty)
        }
    }

    @Test func filesAlreadyInDossierCantBeTickedAgain() throws {
        try withPaperwork { root in
            let tree = FolderTree.scan(root)
            let housing = try #require(tree.root.children.first { $0.name == "Housing" })
            var selection = FolderSelection(added: ["Housing/Leases/Lease 2021.pdf"])
            #expect(selection.state(of: housing) == .added)
            selection.toggle(housing)
            #expect(selection.selected.isEmpty)
            selection.toggle(tree.root)
            #expect(selection.selected.count == 3)
            #expect(selection.state(of: tree.root) == .all)
        }
    }

    @Test func filtersAndSearchesKeepTheFoldersAroundMatches() throws {
        try withPaperwork { root in
            let tree = FolderTree.scan(root)
            let pdfs = tree.filtered(.pdfs, search: "", added: [])
            #expect(Set(pdfs.files.map(\.name)) == ["Passport scan.pdf", "Lease 2021.pdf"])

            let notAdded = tree.filtered(.notAdded, search: "", added: ["Housing/Leases/Lease 2021.pdf"])
            #expect(notAdded.children.map(\.name) == ["Immigration"])

            let ead = tree.filtered(.all, search: "ead_", added: [])
            #expect(ead.files.map(\.name).sorted() == ["EAD_back.jpg", "EAD_front.jpg"])

            // A matching folder keeps everything in it.
            let leases = tree.filtered(.all, search: "leases", added: [])
            #expect(leases.files.map(\.name) == ["Lease 2021.pdf"])
        }
    }

    @Test func rowsShowOpenFoldersBelowTheirRow() throws {
        try withPaperwork { root in
            let tree = FolderTree.scan(root)
            let closed = FolderTree.rows(of: tree.root, expanded: [])
            #expect(closed.map(\.id) == ["Housing", "Immigration"])
            let open = FolderTree.rows(of: tree.root, expanded: ["Immigration", "Immigration/EAD 2024"])
            #expect(open.map(\.id) == [
                "Housing", "Immigration", "Immigration/EAD 2024",
                "Immigration/EAD 2024/EAD_back.jpg", "Immigration/EAD 2024/EAD_front.jpg", "Immigration/Passport scan.pdf",
            ])
            #expect(open.map(\.depth) == [0, 0, 1, 2, 2, 1])
        }
    }
}
