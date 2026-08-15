import ClipboardCore
import SwiftUI

struct ExtractView: View {
    @ObservedObject var model: ExtractViewModel

    var body: some View {
        NavigationStack {
            Group {
                if model.sourceText == nil {
                    ContentUnavailableView(
                        "Paste text to extract values",
                        systemImage: "text.viewfinder",
                        description: Text("Pasted text stays in memory and is discarded unless you explicitly pin one value.")
                    )
                } else {
                    List {
                        if let sourceText = model.sourceText {
                            Section("Pasted Text") {
                                Text(sourceText)
                                    .lineLimit(5)
                            }
                        }
                        Section("Candidates") {
                            if model.candidates.isEmpty {
                                Text("No supported values found.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(model.candidates.enumerated()), id: \.offset) { _, candidate in
                                    candidateRow(candidate)
                                }
                            }
                        }
                        if let errorMessage = model.errorMessage {
                            Section("Status") {
                                Text(errorMessage)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Extract")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.sourceText != nil {
                        Button("Cancel", role: .cancel) { model.cancel() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PasteButton(payloadType: String.self) { values in
                        if let text = values.first {
                            model.acceptPastedText(text)
                        }
                    }
                }
            }
        }
        .onDisappear { model.viewDidDisappear() }
    }

    private func candidateRow(_ candidate: ValueCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(candidate.original)
                .font(.body.monospaced())
            Text(candidate.context)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                variantMenu("Copy", systemImage: "doc.on.doc", candidate: candidate) { variant in
                    try? model.copyCandidate(candidate, variant: variant)
                }
                variantMenu("Pin", systemImage: "pin", candidate: candidate) { variant in
                    Task { try? await model.pinCandidate(candidate, variant: variant) }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func variantMenu(
        _ title: String,
        systemImage: String,
        candidate: ValueCandidate,
        action: @escaping (ExtractCandidateVariant) -> Void
    ) -> some View {
        Menu {
            ForEach(model.availableVariants(for: candidate), id: \.self) { variant in
                Button(variant.title) { action(variant) }
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

private extension ExtractCandidateVariant {
    var title: String {
        switch self {
        case .original: "Original"
        case .digitsOnly: "Digits Only"
        case .normalized: "Normalized"
        }
    }
}
