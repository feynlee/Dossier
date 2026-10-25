#if DEBUG
import SwiftData
import UIKit

/// A vault of made-up documents for UI tests: launched with `-SampleVault`, Dossier starts with these and
/// nothing else. Debug builds only.
enum SampleVault {
    static let launchArgument = "-SampleVault"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

    private struct Sample {
        var file: String
        var kind: DocumentKind
        var title: String
        var placement: LibraryPlacement
        var facts: [(FactKey, String)]
    }

    private static let samples: [Sample] = [
        Sample(
            file: "Passport scan.pdf", kind: .passport, title: "Passport",
            placement: LibraryPlacement(person: "Li", category: "Identity", folder: "Passports", name: "Li · Passport · 2019-03-14 to 2029-03-14"),
            facts: [(.givenNames, "LI"), (.surname, "SAMPLE"), (.issueDate, "2019-03-14"), (.expiryDate, "2029-03-14")]
        ),
        Sample(
            file: "EAD 2022.pdf", kind: .employmentAuthorization, title: "EAD card",
            placement: LibraryPlacement(person: "Mei", category: "Immigration", folder: "EAD cards", name: "Mei · EAD card C09 · 2022-05-01 to 2024-04-30"),
            facts: [(.givenNames, "MEI"), (.surname, "SAMPLE"), (.validFrom, "2022-05-01"), (.validUntil, "2024-04-30")]
        ),
        Sample(
            file: "EAD 2024.pdf", kind: .employmentAuthorization, title: "EAD card",
            placement: LibraryPlacement(person: "Mei", category: "Immigration", folder: "EAD cards", name: "Mei · EAD card C09 · 2024-05-01 to 2026-04-30"),
            facts: [(.givenNames, "MEI"), (.surname, "SAMPLE"), (.validFrom, "2024-05-01"), (.validUntil, "2026-04-30")]
        ),
        Sample(
            file: "Lease 2023.pdf", kind: .lease, title: "Lease for 88 Pine Ave",
            placement: LibraryPlacement(person: LibraryPlacement.household, category: "Housing", folder: "Leases", name: "Household · Lease 88 Pine Ave · 2023-06-01 to 2024-05-31"),
            facts: [(.leaseStartDate, "2023-06-01"), (.leaseEndDate, "2024-05-31")]
        ),
        Sample(
            file: "Medical exam.pdf", kind: .other, title: "Report of medical examination",
            placement: LibraryPlacement(person: "Li", category: "Health", folder: "Medical exams", name: "Li · Medical exam I-693 · 2024-02-10"),
            facts: [(.givenNames, "LI"), (.issueDate, "2024-02-10")]
        ),
    ]

    /// Replaces everything in the vault with the samples.
    static func load(into container: ModelContainer) {
        let context = ModelContext(container)
        ImportCoordinator.deleteAllRecords(context: context)
        let folder = URL.documentsDirectory.appending(path: "Samples", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for (index, sample) in samples.enumerated() {
            let url = folder.appending(path: sample.file)
            let pdf = page(sample.title, sample.placement.name)
            try? pdf.write(to: url)
            let document = SourceDocument(
                contentHash: FileAccess.contentHash(pdf), fileName: sample.file, kind: sample.kind, title: sample.title,
                engine: .privateCloudCompute, pageCount: 1
            )
            document.bookmark = try? FileAccess.bookmark(for: url)
            document.ingestedAt = .now.addingTimeInterval(Double(-index * 60))
            document.placement = sample.placement
            document.placementIsYours = true
            document.readVersion = DocumentExtractor.readingVersion
            context.insert(document)
            for (key, value) in sample.facts {
                guard let sealed = try? Sealer.shared.seal(value, sensitive: false) else { continue }
                let fact = Fact(key: key, sealedValue: sealed, sealedHint: nil, status: .verified, check: .pageText, page: 1)
                if key.isDate { fact.plainDate = SimpleDate(iso: value)?.date }
                fact.document = document
                context.insert(fact)
            }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: "hasOnboarded")
    }

    /// A one-page PDF that says what it is.
    private static func page(_ title: String, _ subtitle: String) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            (title as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 28)])
            (subtitle as NSString).draw(at: CGPoint(x: 72, y: 120), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            ("Sample document for testing. Not a real record." as NSString)
                .draw(at: CGPoint(x: 72, y: 150), withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.gray])
        }
    }
}
#endif
