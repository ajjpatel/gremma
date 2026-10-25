import SwiftUI
import UniformTypeIdentifiers

struct ModelSetupView: View {
    @EnvironmentObject var model: LocalModelService
    @EnvironmentObject var app: AppController
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("On this iPhone") {
                    Text(model.status)
                    if model.isBusy { ProgressView() }
                    Text("Import a downloaded .litertlm file, or copy it into Gremma/Models using USB file sharing. Models downloaded inside Google AI Edge Gallery stay in that app's storage.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Import model file", systemImage: "square.and.arrow.down") { importing = true }
                        .disabled(model.isBusy || app.isWorking)
                    Button("Refresh files copied over USB", systemImage: "arrow.clockwise") { Task { await model.refreshModels() } }
                        .disabled(model.isBusy || app.isWorking)
                }
                Section("Gemma · conversation and vision") {
                    if model.modelURLs.isEmpty { Text("No chat model imported yet.").foregroundStyle(.secondary) }
                    ForEach(model.modelURLs, id: \.self) { url in
                        Button { model.selectModel(url) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(url.deletingPathExtension().lastPathComponent).font(.callout)
                                    if let record = model.models.first(where: { $0.url == url }) {
                                        Text("\(ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file)) · \(record.supportsVision ? "text + vision" : "text")").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if model.selectedModelURL == url { Image(systemName: "checkmark.circle.fill") }
                            }
                        }.disabled(model.isBusy || app.isWorking)
                    }
                    Toggle("Use GPU acceleration", isOn: $model.useGPU).disabled(model.isBusy || app.isWorking || model.isReady)
                    Button(model.isReady ? "Unload model" : "Load selected model") {
                        Task {
                            actionError = nil
                            if model.isReady { await model.unloadModel() }
                            else { do { try await model.loadModel() } catch { actionError = error.localizedDescription } }
                        }
                    }.disabled(model.isBusy || app.isWorking || model.selectedModelURL == nil)
                    Text("Gremma uses E4B for activity understanding and grounded answers. Simple saved-fact questions use local records directly.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Embedding model · available for later retrieval") {
                    if model.embeddingModelURLs.isEmpty { Text("Optional. Name and alias search already works without an embedding model.").font(.footnote) }
                    ForEach(model.embeddingModelURLs, id: \.self) { url in
                        Button { model.selectEmbeddingModel(url) } label: {
                            HStack {
                                Text(url.deletingPathExtension().lastPathComponent).font(.callout)
                                Spacer()
                                if model.selectedEmbeddingModelURL == url { Image(systemName: "checkmark.circle.fill") }
                            }
                        }.disabled(model.isBusy || app.isWorking)
                    }
                }
                if let metrics = model.metrics {
                    Section("Last model operation · measured") {
                        LabeledContent("Elapsed", value: "\(metrics.elapsedSeconds.formatted(.number.precision(.fractionLength(1)))) s")
                        if let first = metrics.firstTextSeconds { LabeledContent("First text", value: "\(first.formatted(.number.precision(.fractionLength(1)))) s") }
                        LabeledContent("Characters", value: "\(metrics.characterCount)")
                        if metrics.cancelled { Text("Cancelled before completion.") }
                    }
                }
                if let error = actionError ?? model.lastError {
                    Section("Needs attention") { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                }
            }
            .navigationTitle("Local models")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                Task {
                    do {
                        guard let url = try result.get().first else { return }
                        actionError = nil
                        try await model.importModel(from: url)
                    } catch { actionError = error.localizedDescription }
                }
            }
        }.task { await model.refreshModels() }
    }
}
