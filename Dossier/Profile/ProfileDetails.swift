import Foundation

/// The details beyond the standard fields, compiled from every document: more about you (height, phone,
/// employer…) and your family (each person's name, date of birth…). The same detail on several documents
/// becomes one entry; confirmed readings win, then the newest document's.
struct ProfileDetails {
    struct Detail: Identifiable {
        var id: String
        var label: String
        /// Every document's reading, best first.
        var facts: [Fact]
        var fact: Fact { facts[0] }
        var isSensitive: Bool { fact.isSensitive }
        /// In the clear, for non-sensitive details.
        var value: String? { VaultReader.value(of: fact) }
        var sources: [String] { Array(Set(facts.compactMap { $0.document?.title })).sorted() }
        /// The documents don't all say the same thing.
        var differs: Bool { Set(facts.compactMap { VaultReader.value(of: $0).map(ProfileDetails.normalize) }).count > 1 }
        var needsReview: Bool { fact.status == .needsReview }
    }

    struct Person: Identifiable {
        var id: String
        var relation: Relation
        var name: String?
        var details: [Detail]

        var title: String { [relation.label, name].compactMap { $0 }.joined(separator: " · ") }
    }

    var you: [Detail]
    var family: [Person]

    var isEmpty: Bool { you.isEmpty && family.isEmpty }

    static func build(documents: [SourceDocument]) -> ProfileDetails {
        let facts = documents
            .filter { !$0.isGone && $0.isReady }
            .flatMap(\.facts)
            .filter { $0.key == .detail && $0.status != .superseded }

        let you = details(from: facts.filter { $0.relation == nil })
        let people = Dictionary(grouping: facts.filter { $0.relation != nil }) { fact in
            "\(fact.relationRaw ?? "")|\(normalize(fact.personName ?? ""))"
        }
        let family = people.map { id, facts in
            let name = facts.compactMap(\.personName).first { !$0.isEmpty }
            let details = details(from: facts).sorted { a, b in
                let an = a.label.lowercased() == "name", bn = b.label.lowercased() == "name"
                return an != bn ? an : a.label < b.label
            }
            return Person(id: id, relation: facts[0].relation ?? .other, name: name, details: details)
        }
        .sorted { ($0.relation.order, $0.name ?? "") < ($1.relation.order, $1.name ?? "") }
        return ProfileDetails(you: you, family: family)
    }

    private static func details(from facts: [Fact]) -> [Detail] {
        Dictionary(grouping: facts) { normalize($0.label ?? "") }
            .map { id, facts in
                let ranked = facts.sorted { a, b in
                    let ac = a.status != .needsReview, bc = b.status != .needsReview
                    if ac != bc { return ac }
                    return (a.document?.ingestedAt ?? .distantPast) > (b.document?.ingestedAt ?? .distantPast)
                }
                return Detail(id: id, label: ranked[0].label ?? "Detail", facts: ranked)
            }
            .sorted { $0.label < $1.label }
    }

    /// Letters and digits only, uppercased: "Eye colour" and "EYE COLOUR" are the same detail.
    static func normalize(_ value: String) -> String {
        String(value.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
