import Foundation

/// Words that find a topic: its person, its document kind, its label and their everyday synonyms. A question
/// says "when was I born", "my birthday", "DOB"; the topic is "Date of birth".
nonisolated enum KnowledgeTerms {
    static let synonyms: [String: [String]] = [
        "expires": ["expire", "expiry", "expiration", "expiring", "valid", "until", "renew", "renewal", "good"],
        "issued": ["issue", "issuance", "got", "received", "since"],
        "number": ["no", "num", "#", "id", "numbers"],
        "a-number": ["a-number", "anumber", "alien", "uscis", "a#", "registration"],
        "birth": ["born", "birthday", "dob", "age", "old", "birth"],
        "place": ["where", "born", "birthplace", "city", "country"],
        "address": ["address", "live", "lived", "living", "home", "house", "reside", "residence", "moved", "move", "apartment", "where"],
        "lease": ["lease", "rent", "rental", "renting", "apartment", "landlord", "tenancy", "tenant", "flat"],
        "rent": ["rent", "pay", "monthly", "cost"],
        "start": ["start", "begin", "began", "moved", "move", "in"],
        "end": ["end", "ends", "ending", "over", "out", "expire", "expires"],
        "licence": ["license", "licence", "driver's", "drivers", "driver", "driving", "dl"],
        "passport": ["passport"],
        "green": ["green", "card", "permanent", "resident", "residency", "pr", "lpr"],
        "authorization": ["ead", "work", "permit", "employment", "authorization", "authorisation"],
        "i-94": ["i-94", "i94", "admission", "entry"],
        "notice": ["notice", "uscis", "i-797", "approval", "approved", "receipt", "case"],
        "category": ["category", "class", "type", "status", "visa"],
        "wages": ["earn", "earned", "earning", "earnings", "income", "salary", "pay", "paid", "make", "made", "wages", "compensation"],
        "withheld": ["withheld", "withholding", "tax", "taxes"],
        "employer": ["employer", "work", "job", "company", "employed", "boss"],
        "ein": ["ein", "employer", "identification", "tax"],
        "member": ["member", "id", "insurance", "policy", "subscriber"],
        "group": ["group", "insurance"],
        "insurer": ["insurance", "insurer", "health", "plan", "carrier"],
        "copay": ["copay", "co-pay", "cost", "pay"],
        "landlord": ["landlord", "owner", "property", "manager", "management"],
        "deposit": ["deposit", "security"],
        "parking": ["parking", "park", "garage", "space", "spot", "car"],
        "phone": ["phone", "telephone", "cell", "mobile", "number", "call"],
        "email": ["email", "e-mail", "mail"],
        "height": ["height", "tall"],
        "eye": ["eye", "eyes", "colour", "color"],
        "weight": ["weight", "weigh", "heavy"],
        "marriage": ["married", "marriage", "wedding", "anniversary", "spouse"],
        "social": ["ssn", "social", "security", "ss"],
        "result": ["result", "test", "level", "levels", "negative", "positive"],
        "cholesterol": ["cholesterol", "lipid", "lipids", "ldl", "hdl"],
        "a1c": ["a1c", "hba1c", "hemoglobin", "sugar", "diabetes", "glucose"],
        "vitamin": ["vitamin", "vit"],
        "tuberculosis": ["tb", "tuberculosis", "igra", "quantiferon", "ppd"],
        "surgeon": ["surgeon", "doctor", "physician", "dr", "exam", "medical", "who"],
        "provider": ["doctor", "physician", "dr", "provider"],
        "pediatrician": ["pediatrician", "paediatrician", "doctor", "dr", "kid's", "children's"],
        "facility": ["hospital", "facility", "where", "clinic"],
        "time": ["time", "hour", "o'clock", "when"],
        "certificate": ["certificate", "cert"],
        "name": ["name", "called"],
        "maiden": ["maiden", "born", "née", "nee"],
        "sex": ["sex", "gender"],
        "nationality": ["nationality", "citizenship", "citizen"],
        "priority": ["priority"],
        "received": ["received", "filed", "applied"],
        "date": ["when", "date", "day"],
    ]

    static func expand(_ words: [String]) -> [String] {
        var out = words
        for word in words {
            for (root, list) in synonyms where word == root || word.hasPrefix(root) && root.count >= 4 {
                out += list
            }
        }
        return out
    }

    static func terms(person: String, group: String, label: String, key: FactKey?, value: KnowledgeValue) -> [String] {
        var words = KnowledgeText.words(person) + KnowledgeText.words(group) + KnowledgeText.words(label)
        if let key { words += KnowledgeText.words(key.label) + KnowledgeText.words(key.rawValue) }
        if key?.isDate == true || label.lowercased().contains("date") { words.append("when") }
        // Values help too ("Lovejoy", "Moderna", "Raman"), except numbers people wouldn't say.
        if let text = value.text, !value.isSensitive { words += KnowledgeText.words(text).filter { $0.count > 2 && !$0.allSatisfy(\.isNumber) } }
        return Array(Set(expand(words)))
    }

    static func relationWords(_ relation: Relation) -> [String] {
        switch relation {
        case .mother: ["mother", "mom", "mum", "mama"]
        case .father: ["father", "dad", "papa"]
        case .spouse: ["spouse", "husband", "wife", "partner"]
        case .child: ["child", "son", "daughter", "kid", "baby"]
        case .sibling: ["sibling", "brother", "sister"]
        case .other: ["family"]
        }
    }
}

/// What a question asks, as far as plain rules can tell.
nonisolated struct KnowledgeQuestion: Sendable {
    var text: String
    /// Whose information: one person, or everyone (for "our", "we", "whose").
    var people: [String]
    var isEveryone: Bool
    var words: [String]
    var year: Int?
    var sinceYear: Int?
    var wantsCount: Bool
    var wantsDays: Bool
    var wantsPast: Bool
    var wantsExpiries: Bool
    var asksYesNo: Bool

    static let stopWords: Set<String> = ["what", "what's", "whats", "is", "my", "me", "i", "the", "a", "an", "of", "for", "in", "on", "to", "do", "does", "did",
                                         "was", "were", "are", "am", "have", "has", "had", "and", "it", "its", "it's", "at", "be", "been", "from", "with",
                                         "tell", "please", "dossier", "our", "we", "us", "you", "your", "which", "that", "this", "by", "how", "much", "many",
                                         "still", "there", "any", "can", "could", "would", "will", "shall", "ever", "her", "his", "their", "they", "she", "he",
                                         "who's", "whose", "get", "got", "?"]

    init(_ text: String, knowledge: Knowledge) {
        self.text = text
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let raw = KnowledgeText.words(lower)
        var people: [String] = []
        for person in knowledge.people {
            let name = person.name.lowercased()
            if raw.contains(name) || raw.contains(name + "'s") || raw.contains(name + "s") { people.append(person.name) }
        }
        let relationMention: [Relation: [String]] = [.spouse: ["husband", "wife", "spouse", "partner", "husband's", "wife's", "spouse's", "partner's"],
                                                     .child: ["son", "daughter", "kid", "child", "baby", "son's", "daughter's", "kid's", "child's", "baby's"]]
        for (relation, mentions) in relationMention where mentions.contains(where: { raw.contains($0) }) {
            people += knowledge.people.filter { $0.relation == relation }.map(\.name)
        }
        let everyone = raw.contains("our") || raw.contains("we") || raw.contains("whose") || raw.contains("everyone") || raw.contains("family")
        if people.isEmpty, let owner = knowledge.owner { people = [owner] }
        self.people = Array(Set(people))
        self.isEveryone = everyone && people.count <= 1
        let names = Set(knowledge.people.flatMap { [$0.name.lowercased(), $0.name.lowercased() + "'s"] })
        let content = raw.map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : $0 }
            .filter { !Self.stopWords.contains($0) && !names.contains($0) }
        words = content
        let years = raw.compactMap { Int($0) }.filter { (1900...2100).contains($0) }
        if let index = raw.firstIndex(of: "since"), index + 1 < raw.count, let year = Int(raw[index + 1]) {
            sinceYear = year
            self.year = nil
        } else {
            sinceYear = nil
            year = years.first
        }
        wantsCount = lower.contains("how many")
        wantsDays = raw.contains("days")
        wantsPast = raw.contains("old") || raw.contains("previous") || raw.contains("former") || raw.contains("earlier") || raw.contains("first")
        wantsExpiries = (raw.contains("expire") || raw.contains("expires") || raw.contains("expiring")) && (everyone || raw.contains("documents") || raw.contains("next") || raw.contains("before"))
        asksYesNo = ["is", "was", "has", "have", "did", "does", "do", "are"].contains(raw.first ?? "")
    }
}

nonisolated struct KnowledgeMatch: Sendable {
    var topic: KnowledgeTopic
    var score: Double
}

/// Finds the topics a question is about. Plain word matching with synonyms: fast, predictable, and enough to
/// put the right topic in the top few for the model to choose from.
nonisolated enum KnowledgeSearch {
    static func search(_ question: KnowledgeQuestion, in knowledge: Knowledge, limit: Int = 12) -> [KnowledgeMatch] {
        let words = KnowledgeTerms.expand(question.words)
        let asked = Set(question.words)
        let pool = question.isEveryone ? knowledge.topics : knowledge.topics.filter { question.people.contains($0.person) }
        var matches: [KnowledgeMatch] = []
        for topic in pool {
            let terms = Set(topic.terms)
            let nameWords = Set(KnowledgeTerms.expand(KnowledgeText.words(topic.name)))
            var score = 0.0
            for word in Set(words) {
                let direct = asked.contains(word)
                if terms.contains(word) {
                    score += direct ? 3 : 1
                    if nameWords.contains(word) { score += direct ? 2 : 0.5 }
                } else if word.count >= 4, terms.contains(where: { $0.count >= 4 && ($0.hasPrefix(word) || word.hasPrefix($0)) }) {
                    score += direct ? 1.5 : 0.5
                }
            }
            guard score > 0 else { continue }
            // Prefer topics with an answer, and specific topics over long generic ones.
            if topic.current == nil { score *= 0.5 }
            // Settled across documents beats one document's copy of the same thing.
            if topic.behavior == .state || topic.behavior == .identity { score *= 1.1 }
            score /= (1 + Double(KnowledgeText.words(topic.name).count) * 0.05)
            matches.append(KnowledgeMatch(topic: topic, score: score))
        }
        return Array(matches.sorted { $0.score > $1.score }.prefix(limit))
    }
}
