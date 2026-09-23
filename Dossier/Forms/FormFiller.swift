import Foundation
import FoundationModels
import LocalAuthentication
import os
import PDFKit

/// Reads a PDF form's fillable text fields and fills them. Uses PDFKit's AcroForm support; XFA-only forms
/// have no widgets PDFKit can see and are reported as having no fillable fields.
nonisolated enum FormFiller {
    static func fields(in document: PDFDocument) -> [FormFieldInfo] {
        var seen = Set<String>()
        var fields: [FormFieldInfo] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.widgetFieldType == .text {
                guard let name = annotation.fieldName, seen.insert(name).inserted else { continue }
                let tooltip = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/TU")) as? String
                fields.append(FormFieldInfo(name: name, tooltip: tooltip, page: index + 1))
            }
        }
        return fields
    }

    /// Writes values into every widget with the given field names and returns the filled PDF's data.
    static func fill(_ document: PDFDocument, values: [String: String]) -> Data? {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.widgetFieldType == .text {
                if let name = annotation.fieldName, let value = values[name] {
                    annotation.widgetStringValue = value
                }
            }
        }
        return document.dataRepresentation()
    }
}

@Generable(description: "Which Dossier value, if any, belongs in each form field")
nonisolated struct GeneratedFieldMatches {
    var matches: [GeneratedFieldMatch]
}

@Generable(description: "The value for one form field")
nonisolated struct GeneratedFieldMatch {
    @Guide(description: "The field's number from the list.")
    var field: Int

    @Guide(description: "The value that belongs in the field, or none.", .anyOf(FormValue.allCases.map(\.rawValue) + ["none"]))
    var value: String
}

/// Asks the model to match the fields the rules couldn't. Only the form's field labels are sent: no values
/// from the vault are ever part of this prompt.
actor FormFieldAssistant {
    private let logger = Logger(subsystem: "liziyue.Dossier", category: "Forms")

    func suggest(for fields: [FormFieldInfo], preferPrivateCloud: Bool) async -> [String: FormValue] {
        guard !fields.isEmpty else { return [:] }
        let list = fields.enumerated().map { "\($0.offset). \($0.element.displayName) [\($0.element.searchText)]" }.joined(separator: "\n")
        let instructions = """
            You match the fields of a US government or rental form to personal values. Only match a field when \
            the field clearly asks for that value about the applicant. Fields about other people (spouse, parent, \
            preparer, interpreter), signatures, checkboxes and eligibility answers are "none".
            """
        let prompt = "Fields:\n\(list)"
        do {
            let session: LanguageModelSession
            let pcc = PrivateCloudComputeLanguageModel()
            if preferPrivateCloud, pcc.isAvailable, !pcc.quotaUsage.isLimitReached {
                session = LanguageModelSession(model: pcc, instructions: instructions)
            } else if SystemLanguageModel.default.isAvailable {
                session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            } else {
                return [:]
            }
            let response = try await session.respond(to: prompt, generating: GeneratedFieldMatches.self, options: GenerationOptions(samplingMode: .greedy))
            var result: [String: FormValue] = [:]
            for match in response.content.matches where fields.indices.contains(match.field) {
                if let value = FormValue(rawValue: match.value) { result[fields[match.field].name] = value }
            }
            return result
        } catch {
            logger.error("Field matching failed: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }
}
