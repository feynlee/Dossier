import Foundation
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
