import Foundation
import UniformTypeIdentifiers

/// Which documents a site's upload field takes, and which of them it most likely wants, from the field's
/// label ("Upload a copy of your passport") and its accepted types ("image/*,.pdf"). Pure, so it's tested.
nonisolated enum UploadMatching {
    struct Candidate: Equatable, Sendable {
        var id: String
        var kind: DocumentKind
        /// The title, the library name and folder: what the label is compared with.
        var text: String
        var fileExtension: String
    }

    /// The accepted types from an `accept` attribute: ".pdf", "application/pdf", "image/*".
    static func acceptedTypes(_ accept: String) -> [String] {
        accept.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    /// Whether a file with this extension is one the field takes. A field that names no types takes any.
    static func accepts(_ accepted: [String], fileExtension: String) -> Bool {
        guard !accepted.isEmpty else { return true }
        guard let type = UTType(filenameExtension: fileExtension.lowercased()) else { return false }
        return accepted.contains { token in
            if token.hasPrefix(".") {
                return UTType(filenameExtension: String(token.dropFirst())).map { type.conforms(to: $0) } ?? false
            }
            if token.hasSuffix("/*") {
                let group = token.dropLast(2)
                switch group {
                case "image": return type.conforms(to: .image)
                case "video": return type.conforms(to: .movie)
                case "audio": return type.conforms(to: .audio)
                default: return type.preferredMIMEType?.hasPrefix(group + "/") ?? false
                }
            }
            return UTType(mimeType: token).map { type.conforms(to: $0) } ?? false
        }
    }

    /// The accepted types as content types, for the system's file and photo pickers. Any file when the field
    /// names none.
    static func contentTypes(_ accept: String) -> [UTType] {
        let types = acceptedTypes(accept).compactMap { token -> UTType? in
            if token.hasPrefix(".") { return UTType(filenameExtension: String(token.dropFirst())) }
            switch token {
            case "image/*": return .image
            case "video/*": return .movie
            case "audio/*": return .audio
            default: return UTType(mimeType: token)
            }
        }
        return types.isEmpty ? [.item] : types
    }

    /// Words that say what the field is for, without the words every upload field has.
    static func words(_ text: String) -> Set<String> {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "licence", with: "license")
            .replacingOccurrences(of: #"\bi-(\d)"#, with: "i$1", options: .regularExpression)
        let all = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(all.filter { $0.count >= 2 && !ignored.contains($0) })
    }

    private static let ignored: Set<String> = [
        "upload", "uploads", "file", "files", "choose", "select", "attach", "attachment", "browse", "your", "the", "an",
        "of", "or", "and", "copy", "scan", "scanned", "here", "click", "drop", "drag", "to", "please", "document",
        "documents", "pdf", "jpg", "jpeg", "png", "heic", "max", "mb", "kb", "size", "format", "formats", "only",
        "for", "front", "back", "side", "page", "pages", "image", "images", "no", "chosen", "required", "optional",
    ]

    /// Words a site may use for a kind Dossier recognises, beyond its name.
    static func keywords(for kind: DocumentKind) -> Set<String> {
        switch kind {
        case .passport: ["passport", "travel"]
        case .driversLicense: ["driver", "drivers", "driving", "license", "dl", "id", "identification", "photo"]
        case .stateID: ["state", "id", "identification", "photo"]
        case .greenCard: ["green", "card", "permanent", "resident", "residence", "pr", "i551", "551"]
        case .employmentAuthorization: ["ead", "employment", "authorization", "work", "permit", "i766", "766"]
        case .visa: ["visa"]
        case .uscisNotice: ["uscis", "notice", "receipt", "approval", "i797", "797"]
        case .i94: ["i94", "94", "arrival", "admission", "record"]
        case .lease: ["lease", "rental", "rent", "tenancy", "residence", "address", "proof"]
        case .other, .addedByYou: []
        }
    }

    /// How well a document fits the label: the label's words found in the document's text or its kind's
    /// words. Zero when nothing in common.
    static func score(label: String, candidate: Candidate) -> Int {
        let wanted = words(label)
        guard !wanted.isEmpty else { return 0 }
        let own = words(candidate.text)
        let kind = keywords(for: candidate.kind)
        return wanted.reduce(0) { total, word in total + (own.contains(word) ? 2 : kind.contains(word) ? 1 : 0) }
    }

    /// The documents a field takes, best fit first. Suggested ones are those that fit at all.
    static func rank(_ candidates: [Candidate], label: String, accept: String) -> (suggested: [Candidate], others: [Candidate]) {
        let accepted = acceptedTypes(accept)
        let usable = candidates.filter { accepts(accepted, fileExtension: $0.fileExtension) }
        let scored = usable.map { ($0, score(label: label, candidate: $0)) }
        let suggested = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
        let ids = Set(suggested.map(\.id))
        return (suggested, usable.filter { !ids.contains($0.id) })
    }
}
