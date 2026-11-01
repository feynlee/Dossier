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

    /// The word, its synonyms, and every group it belongs to: "expire" → expires, expiry, expiration, …
    static func related(_ word: String) -> Set<String> {
        var out: Set<String> = [word]
        for (root, list) in synonyms where root == word || list.contains(word) || word.hasPrefix(root) && root.count >= 4 {
            out.insert(root)
            out.formUnion(list)
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
    /// People who may be the owner under another name, for questions about "my" anything.
    var maybeOwner: [String]
    var isEveryone: Bool
    var words: [String]
    var year: Int?
    var sinceYear: Int?
    var wantsCount: Bool
    var wantsDays: Bool
    var wantsPast: Bool
    var wantsExpiries: Bool
    var asksYesNo: Bool
    var asksWhen: Bool
    var asksWhere: Bool

    static let stopWords: Set<String> = ["what", "what's", "whats", "is", "my", "me", "i", "the", "a", "an", "of", "for", "in", "on", "to", "do", "does", "did",
                                         "was", "were", "are", "am", "have", "has", "had", "and", "it", "its", "it's", "at", "be", "been", "from", "with",
                                         "tell", "please", "dossier", "our", "we", "us", "you", "your", "which", "that", "this", "by", "how", "much", "many",
                                         "still", "there", "any", "can", "could", "would", "will", "shall", "ever", "her", "his", "their", "they", "she", "he",
                                         "who's", "whose", "get", "got", "find", "look", "up", "search", "show", "know", "see", "check", "?"]

    /// Ways of saying the same thing that word matching can't see: "blood group" is the blood type.
    static let phrases: [(String, String)] = [("blood group", "blood type"), ("abo group", "blood type"), ("rh factor", "blood type")]

    init(_ text: String, knowledge: Knowledge) {
        self.text = text
        var lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
        for (phrase, meaning) in Self.phrases { lower = lower.replacingOccurrences(of: phrase, with: meaning) }
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
        if people.isEmpty, let owner = knowledge.owner {
            people = [owner]
            // Someone Dossier can't relate to you may be you under another name (a document filed under
            // "Ziyue" when the rest are under "Li"): searched too, after your own documents.
            maybeOwner = knowledge.people.filter { !$0.isOwner && $0.relation == .other }.map(\.name)
        } else {
            maybeOwner = []
        }
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
        asksWhen = raw.first == "when" || lower.contains("what date") || lower.contains("what day")
        asksWhere = raw.first == "where"
    }
}

nonisolated struct KnowledgeMatch: Sendable {
    var topic: KnowledgeTopic
    var score: Double
}

/// Finds the topics a question is about. Plain word matching with synonyms: fast, predictable, and enough to
/// put the right topic in the top few for the model to choose from.
nonisolated enum KnowledgeSearch {
    /// Common questions whose words fit several topics equally: "when was Emma born" also matches her birth
    /// certificate's issue date, "when did I get married" every date on the marriage certificate.
    static func hint(_ question: KnowledgeQuestion, _ topic: KnowledgeTopic, isDate: Bool) -> Double {
        let words = Set(question.words)
        let name = topic.name.lowercased()
        // A family member's detail filed on your record ("Anna|detail|spouse|DAVID|…") answers questions about
        // them, not you: only when the question says spouse, husband, mother… or their name.
        let parts = topic.id.components(separatedBy: "|")
        if parts.count >= 5, parts[1] == "detail", let relation = Relation(rawValue: parts[2]) {
            let raw = Set(KnowledgeText.words(question.text.lowercased()).map { $0.hasSuffix("'s") ? String($0.dropLast(2)) : $0 })
            let mentioned = !raw.isDisjoint(with: KnowledgeTerms.relationWords(relation)) || raw.contains(parts[3].lowercased())
                || KnowledgeText.words(parts[3]).contains { raw.contains($0) }
            if !mentioned { return 0.4 }
        }
        // "What time was Emma born", "which hospital": the time or the place, not the birth date.
        if words.contains("time") || words.contains("hour") {
            let value = topic.current?.value.text ?? ""
            return value.range(of: #"\d{1,2}:\d{2}"#, options: .regularExpression) != nil || name.contains("time") ? 1.8 : 0.5
        }
        if !words.isDisjoint(with: ["hospital", "facility", "clinic"]) {
            return ["hospital", "facility", "clinic", "place"].contains(where: name.contains) ? 1.8 : 0.5
        }
        if !words.isDisjoint(with: ["born", "birthday", "dob", "birth"]) {
            if question.asksWhere { return topic.id.hasSuffix("|placeOfBirth") ? 1.6 : 1 }
            if topic.id.hasSuffix("|dateOfBirth") { return 1.6 }
        }
        if !words.isDisjoint(with: ["married", "marriage", "wedding", "anniversary"]), question.asksWhen || words.contains("anniversary") {
            return isDate && (name.contains("marriage") || name.contains("married")) && !name.contains("issue") && !name.contains("filed") ? 1.6 : 1
        }
        if !words.isDisjoint(with: ["a-number", "anumber", "alien"]), topic.id.hasSuffix("|alienNumber") { return 1.6 }
        if words.contains("i-94") || words.contains("i94"), words.contains("number"), topic.id.hasSuffix("|i94Number") { return 1.6 }
        return 1
    }

    static func search(_ question: KnowledgeQuestion, in knowledge: Knowledge, limit: Int = 12) -> [KnowledgeMatch] {
        let words = KnowledgeTerms.expand(question.words)
        let asked = Set(question.words)
        // Household documents (leases, the marriage certificate) are everyone's.
        let pool = question.isEveryone ? knowledge.topics : knowledge.topics.filter {
            question.people.contains($0.person) || $0.person == KnowledgeBuilder.household || question.maybeOwner.contains($0.person)
        }
        var matches: [KnowledgeMatch] = []
        for topic in pool {
            let terms = Set(topic.terms)
            let ownName = Set(KnowledgeText.words(topic.name))
            let nameWords = Set(KnowledgeTerms.expand(Array(ownName)))
            var score = 0.0
            for word in Set(words) {
                let direct = asked.contains(word)
                if terms.contains(word) {
                    score += direct ? 3 : 1
                    // The topic's own name counts most; a synonym of its name a little.
                    if ownName.contains(word) { score += direct ? 2 : 0.5 } else if nameWords.contains(word) { score += 0.5 }
                } else if word.count >= 4, terms.contains(where: { $0.count >= 4 && ($0.hasPrefix(word) || word.hasPrefix($0)) }) {
                    score += direct ? 1.5 : 0.5
                }
            }
            guard score > 0 else { continue }
            // Prefer topics with an answer, and specific topics over long generic ones.
            if topic.current == nil { score *= 0.5 }
            // Settled across documents beats one document's copy of the same thing.
            if topic.behavior == .state || topic.behavior == .identity { score *= 1.1 }
            // "When" wants a date and "where" a place: "when was I born" is the birth date, not the birthplace.
            let isDate = topic.current?.value.text.flatMap(KnowledgeText.date) != nil || topic.behavior == .event
            if question.asksWhen { score *= isDate ? 1.3 : 0.8 }
            if question.asksWhere, isDate { score *= 0.7 }
            score *= KnowledgeSearch.hint(question, topic, isDate: isDate)
            if question.maybeOwner.contains(topic.person) { score *= 0.6 }
            score /= (1 + Double(KnowledgeText.words(topic.name).count) * 0.05)
            matches.append(KnowledgeMatch(topic: topic, score: score))
        }
        return Array(matches.sorted { $0.score > $1.score }.prefix(limit))
    }
}
