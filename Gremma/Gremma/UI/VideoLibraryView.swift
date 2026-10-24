import SwiftUI

/// The parent queues import/resume until this sheet has finished dismissing.
struct VideoLibraryView: View {
    @EnvironmentObject var app: AppController
    @EnvironmentObject var model: LocalModelService
    @Environment(\.dismiss) private var dismiss
    let onImport: () -> Void
    let onResume: (String) -> Void
    @State private var pendingDelete: VideoIndexJob?
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onImport()
                        dismiss()
                    } label: {
                        Label("Import a recorded video", systemImage: "square.and.arrow.down")
                            .font(.headline).frame(minHeight: 48)
                    }
                    .disabled(app.isWorking)
                    Text("Choose a video from Photos. Gremma keeps a local copy and asks you to confirm the room before saving observations.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if model.requiresRestart {
                    Section("Reopen Gremma to resume videos") {
                        Text("Swipe up from the bottom and pause, swipe Gremma up to close it, then open Gremma again. Your videos and saved progress will remain.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text("Reading printed text and searching saved memories are still available.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                if app.videoJobs.isEmpty {
                    ContentUnavailableView("No saved videos", systemImage: "video",
                        description: Text("Record a room or import an existing video to remember where things were seen."))
                } else {
                    Section("Saved on this iPhone") {
                        ForEach(app.videoJobs) { job in
                            videoRow(job)
                        }
                    }
                }

                if let actionError {
                    Section { Text(actionError).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Your videos")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Delete this video and its saved observations?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible) {
                    if let job = pendingDelete {
                        Button("Delete video and observations", role: .destructive) { remove(job) }
                    }
                    Button("Cancel", role: .cancel) { pendingDelete = nil }
                } message: {
                    Text("This removes Gremma's copy and its evidence images. Your original video in Photos is kept.")
                }
            .task { await app.refreshMemory() }
        }
    }

    private func videoRow(_ job: VideoIndexJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.isRoomConfirmed ? job.room : "Room needs confirmation").font(.headline)
            if !job.isRoomConfirmed, let suggestion = job.proposedRoom {
                Text("Suggested room: \(suggestion)").font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Added \(job.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(duration(job.duration))")
                .font(.caption).foregroundStyle(.secondary)
            if !job.isRoomConfirmed {
                Label("Waiting for your room name", systemImage: "questionmark.bubble")
                    .font(.subheadline)
            } else if job.isComplete {
                Label("Ready to search", systemImage: "checkmark.circle")
                    .font(.subheadline)
            } else {
                ProgressView(value: job.progress) {
                    Text("\(job.nextFrameIndex) of \(job.sampleTimes.count) frames saved").font(.caption)
                }
            }
            if let failure = job.failureMessage {
                Label("Needs attention", systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Text(failure).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !job.isComplete {
                Button {
                    onResume(job.id)
                    dismiss()
                } label: {
                    Label(job.isRoomConfirmed ? "Resume at frame \(job.nextFrameIndex + 1)" : "Confirm room",
                          systemImage: job.isRoomConfirmed ? "play.fill" : "bubble.left.and.bubble.right")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                }
                .buttonStyle(.borderless).disabled(app.isWorking || model.requiresRestart)
                .accessibilityHint(model.requiresRestart ? "Close and reopen Gremma first" : "Continues from saved progress without recording again")
            }
            Button(role: .destructive) { pendingDelete = job } label: {
                Label("Delete video", systemImage: "trash").frame(minHeight: 48)
            }
            .buttonStyle(.borderless).disabled(app.isWorking)
            .accessibilityLabel("Delete \(job.isRoomConfirmed ? job.room : "unconfirmed") video added \(job.createdAt.formatted(date: .abbreviated, time: .shortened))")
        }
        .padding(.vertical, 8)
    }

    private func duration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        return rounded < 60 ? "\(rounded) seconds" : "\(rounded / 60) min \(rounded % 60) sec"
    }

    private func remove(_ job: VideoIndexJob) {
        pendingDelete = nil
        actionError = nil
        Task {
            do { try await app.deleteVideo(job) }
            catch { actionError = error.localizedDescription }
        }
    }
}
