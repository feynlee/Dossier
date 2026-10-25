import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Dossier

struct UploadMatchingTests {
    let passport = UploadMatching.Candidate(id: "p", kind: .passport, text: "Passport Li · Passport · 2019-03-14 to 2029-03-14 Passports Identity", fileExtension: "pdf")
    let ead = UploadMatching.Candidate(id: "e", kind: .employmentAuthorization, text: "EAD card Mei · EAD card C09 EAD cards Immigration", fileExtension: "jpg")
    let lease = UploadMatching.Candidate(id: "l", kind: .lease, text: "Lease Household · Lease 88 Pine Ave Leases Housing", fileExtension: "pdf")
    let i20 = UploadMatching.Candidate(id: "i", kind: .other, text: "Form I-20 Li · I-20 UW I-20s Education", fileExtension: "pdf")

    @Test func acceptedTypesFilterDocuments() {
        #expect(UploadMatching.accepts([], fileExtension: "pdf"))
        #expect(UploadMatching.accepts(["image/*"], fileExtension: "jpg"))
        #expect(UploadMatching.accepts(["image/*"], fileExtension: "heic"))
        #expect(!UploadMatching.accepts(["image/*"], fileExtension: "pdf"))
        #expect(UploadMatching.accepts([".pdf", ".png"], fileExtension: "pdf"))
        #expect(UploadMatching.accepts([".jpeg"], fileExtension: "jpg"))
        #expect(UploadMatching.accepts(["application/pdf"], fileExtension: "pdf"))
        #expect(!UploadMatching.accepts(["application/pdf"], fileExtension: "png"))
        #expect(UploadMatching.acceptedTypes(" image/*, .PDF ,") == ["image/*", ".pdf"])
    }

    @Test func contentTypesForTheSystemPickers() {
        #expect(UploadMatching.contentTypes("") == [.item])
        #expect(UploadMatching.contentTypes("image/*,.pdf") == [.image, .pdf])
    }

    @Test func labelsSuggestTheRightDocument() {
        let all = [lease, ead, passport, i20]
        #expect(UploadMatching.rank(all, label: "Upload a copy of your passport", accept: "").suggested.map(\.id) == ["p"])
        #expect(UploadMatching.rank(all, label: "Employment Authorization Document (front)", accept: "").suggested.first?.id == "e")
        #expect(UploadMatching.rank(all, label: "Proof of address", accept: "").suggested.map(\.id) == ["l"])
        #expect(UploadMatching.rank(all, label: "Form I-20", accept: "").suggested.first?.id == "i")
    }

    @Test func otherDocumentsFollowAndRespectTypes() {
        let ranked = UploadMatching.rank([lease, ead, passport], label: "Passport photo page", accept: "image/*")
        #expect(ranked.suggested.isEmpty)
        #expect(ranked.others.map(\.id) == ["e"])
    }

    @Test func genericLabelsSuggestNothing() {
        let ranked = UploadMatching.rank([lease, ead, passport], label: "Choose file (PDF or JPG, max 5 MB)", accept: "")
        #expect(ranked.suggested.isEmpty)
        #expect(ranked.others.count == 3)
    }
}
