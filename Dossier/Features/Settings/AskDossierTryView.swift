import SwiftData
import SwiftUI

/// Settings › Siri › Try a question: asks Dossier exactly as Siri's "Ask Dossier" does, and shows what it found,
/// so you can tell whether a question fails in Dossier or never reached it.
struct AskDossierTryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var question = "What's my blood type?"
    @State private var answer: KnowledgeAnswer?
    @State private var matches: [(name: String, person: String, value: String)] = []
    @State private var summary = ""
    @State private var isAsking = false

    var body: some View {
        List {
            Section {
                TextField("Question", text: $question, axis: .vertical)
                    .submitLabel(.go)
                    .onSubmit(ask)
                Button(isAsking ? "Asking…" : "Ask", systemImage: "questionmark.bubble", action: ask)
                    .disabled(isAsking || question.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                Text("The same answer Siri gets from “Ask Dossier”.")
            }
            if let answer {
                Section("Answer") {
                    Text(answer.text)
                    LabeledContent("Answered by", value: answer.method.rawValue)
                    if let note = answer.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            if !summary.isEmpty {
                Section {
                    ForEach(matches.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(matches[index].name)
                            Text("\(matches[index].person) · \(matches[index].value)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Facts it looked at")
                } footer: {
                    Text(summary)
                }
            }
        }
        .navigationTitle("Try a question")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func ask() {
        let text = question
        isAsking = true
        Task {
            defer { isAsking = false }
            guard let knowledge = try? KnowledgeSnapshot.knowledge(in: modelContext) else {
                summary = "Your documents couldn’t be opened."
                return
            }
            let parsed = KnowledgeQuestion(text, knowledge: knowledge)
            matches = KnowledgeSearch.search(parsed, in: knowledge, limit: 8).map { match in
                let value = match.topic.current.map { $0.value.text ?? "ends in \($0.value.hint ?? "····")" } ?? "unknown"
                return (match.topic.name, match.topic.person, value)
            }
            let people = knowledge.people.map { $0.isOwner ? "\($0.name) (you)" : $0.name }.joined(separator: ", ")
            summary = "\(knowledge.topics.count) facts from your documents. People: \(people.isEmpty ? "none" : people). Asked about: \(parsed.people.joined(separator: ", "))."
            answer = await KnowledgeService.answer(text, knowledge: knowledge)
        }
    }
}
