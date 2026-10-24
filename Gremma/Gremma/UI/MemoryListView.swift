import SwiftUI

struct MemoryListView: View {
    @EnvironmentObject var app: AppController
    @Environment(\.dismiss) private var dismiss
    @State private var editing: MemoryObservation?
    @State private var deleteAll = false
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            List {
                if app.observations.isEmpty {
                    ContentUnavailableView("No observations yet", systemImage: "square.stack.3d.up", description: Text("Remember an item or record a room to save its location with a photograph."))
                }
                ForEach(app.observations) { observation in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(observation.itemName).font(.headline)
                        Text([observation.room, observation.locationDescription].filter { !$0.isEmpty }.joined(separator: " · "))
                        Text(observation.capturedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 24) {
                            Button("Show evidence") { app.showObservation(observation); dismiss() }.buttonStyle(.borderless)
                            Button("Correct") { editing = observation }.buttonStyle(.borderless)
                        }.font(.subheadline)
                    }.padding(.vertical, 6)
                        .swipeActions { Button("Delete", role: .destructive) { remove(observation) }.disabled(app.isWorking) }
                }
                if !app.observations.isEmpty || app.hasVideoCaptures {
                    Section { Button("Delete all observations and room videos", role: .destructive) { deleteAll = true }.disabled(app.isWorking) }
                }
                if let error = actionError { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("Your memories")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { ObservationEditor(observation: $0) }
            .confirmationDialog("Delete all saved observations, evidence images, and room videos?", isPresented: $deleteAll, titleVisibility: .visible) {
                Button("Delete all captures", role: .destructive) {
                    Task { do { try await app.deleteAllCaptures() } catch { actionError = error.localizedDescription } }
                }
            }
        }
    }
    private func remove(_ observation: MemoryObservation) {
        Task { do { try await app.deleteObservation(observation) } catch { actionError = error.localizedDescription } }
    }
}

private struct ObservationEditor: View {
    @EnvironmentObject var app: AppController
    @Environment(\.dismiss) private var dismiss
    @State var observation: MemoryObservation
    @State private var aliasText = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Item name", text: $observation.itemName)
                TextField("Room", text: $observation.room)
                TextField("Location", text: $observation.locationDescription, axis: .vertical)
                TextField("Other names, separated by commas", text: $aliasText, axis: .vertical)
                Text("Your correction updates the saved observation. Its original capture date and evidence image remain attached.").font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("Correct observation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        observation.aliases = aliasText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        observation.notes = "Name or location corrected by you. Original evidence retained."
                        Task { do { try await app.updateObservation(observation); dismiss() } catch { self.error = error.localizedDescription } }
                    }.disabled(app.isWorking)
                }
            }
        }.onAppear { aliasText = observation.aliases.joined(separator: ", ") }
    }
}
