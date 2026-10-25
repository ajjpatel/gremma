import SwiftUI
import AVKit

/// The parent queues import/resume until this sheet has finished dismissing.
struct VideoLibraryView: View {
    @EnvironmentObject var app: AppController
    @EnvironmentObject var model: LocalModelService
    @Environment(\.dismiss) private var dismiss
    let onImport: () -> Void
    let onResume: (String) -> Void
    let onReanalyze: (VideoIndexJob) -> Void
    @State private var showAllRecordings = false
    private var displayedJobs: [VideoIndexJob] { showAllRecordings ? app.videoJobs : app.focusedVideoJobs }
    @State private var pendingDelete: VideoIndexJob?
    @State private var actionError: String?
    @State private var datingJob: VideoIndexJob?
    @State private var selectedDate = Date()
    @State private var playback: SavedVideoPlayback?

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
                    Text("Choose a video from Photos. Gremma analyzes the visible activity. Set the original recording date before processing if it is unknown.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if model.requiresRestart {
                    Section("Reopen Gremma to resume videos") {
                        Text("Swipe up from the bottom and pause, swipe Gremma up to close it, then open Gremma again. Your videos and saved progress will remain.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text("Searching saved activities is still available.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                if app.focusedCollection != nil {
                    Section {
                        Toggle("Show all recordings", isOn: $showAllRecordings)
                        Text("The focused collection uses five recordings. Other videos remain saved.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if displayedJobs.isEmpty {
                    ContentUnavailableView("No saved videos", systemImage: "video",
                        description: Text("Record an activity or upload a video to remember what happened."))
                } else {
                    Section("Saved on this iPhone") {
                        ForEach(displayedJobs) { job in
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
            .confirmationDialog("Delete this video and its saved activities?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible) {
                    if let job = pendingDelete {
                        Button("Delete video and activities", role: .destructive) { remove(job) }
                    }
                    Button("Cancel", role: .cancel) { pendingDelete = nil }
                } message: {
                    Text("This removes Gremma's copy and its evidence images. Your original video in Photos is kept.")
                }
            .sheet(item: $datingJob) { job in
                NavigationStack {
                    Form {
                        DatePicker("Original recording date", selection: $selectedDate, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        Text("Use when the video was recorded. This date determines daily activity logs.")
                        Button("Save recording date") {
                            Task {
                                do { try await app.setVideoDate(job, date: selectedDate); datingJob = nil }
                                catch { actionError = error.localizedDescription; datingJob = nil }
                            }
                        }.frame(minHeight: 48)
                    }.navigationTitle("Recording date")
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { datingJob = nil } } }
                }
            }
            .sheet(item: $playback) { item in
                VideoPlayer(player: AVPlayer(url: item.url)).ignoresSafeArea(edges: .bottom)
            }
            .task { await app.refreshMemory() }
        }
    }

    private func videoRow(_ job: VideoIndexJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.isRoomConfirmed ? app.videoTitle(job) : "Room needs confirmation").font(.headline)
            if job.isDemoVideo {
                Label("Demo footage · excluded from daily logs", systemImage: "film")
                    .font(.caption).foregroundStyle(.mint)
            }
            if !job.isRoomConfirmed, let suggestion = job.proposedRoom {
                Text("Suggested room: \(suggestion)").font(.subheadline).foregroundStyle(.secondary)
            }
            Text("Added \(job.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(duration(job.duration))")
                .font(.caption).foregroundStyle(.secondary)
            Text(job.recordedAt.map { "Recorded " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Recording date unknown · excluded from daily logs")
                .font(.callout).foregroundStyle(job.recordedAt == nil ? .orange : .secondary)
            if !job.isDemoVideo && !job.hasStartedActivityAnalysis && job.nextAudioChunkIndex == 0 {
                Button("Set recording date") { selectedDate = job.recordedAt ?? Date(); datingJob = job }
                    .frame(minHeight: 48).buttonStyle(.borderless).disabled(app.isWorking)
            }
            Button {
                Task {
                    if let url = await app.savedVideoURL(job) { playback = SavedVideoPlayback(url: url) }
                    else { actionError = "The saved source video is unavailable." }
                }
            } label: { Label("Play original video", systemImage: "play.rectangle").frame(minHeight: 48) }
                .buttonStyle(.borderless)
            if !job.isRoomConfirmed {
                Label("Waiting for your room name", systemImage: "questionmark.bubble")
                    .font(.subheadline)
            } else if job.isMemoryComplete {
                if app.activities.contains(where: { $0.videoID == job.id && !$0.isVisualNote }) {
                    Label("Ready to search", systemImage: "checkmark.circle")
                        .font(.subheadline)
                } else if app.activities.contains(where: { $0.videoID == job.id && $0.isVisualNote }) {
                    Label("Visual note saved · details unclassified", systemImage: "note.text")
                        .font(.subheadline)
                } else {
                    Label("Analyzed · no clear activity found", systemImage: "checkmark.circle")
                        .font(.subheadline)
                }
            } else {
                ProgressView(value: job.memoryProgress) {
                    Text("\(job.nextActivityWindowIndex) / \(job.activityWindowCount) activity segments saved").font(.caption)
                }
            }
            if !job.isMemoryComplete, job.memoryFailureStage != .audio, let failure = job.memoryFailureMessage {
                Label("Needs attention", systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Text(failure).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !job.isMemoryComplete {
                Button {
                    onResume(job.id)
                    dismiss()
                } label: {
                    Label(job.isRoomConfirmed ? "Resume processing" : "Confirm room",
                          systemImage: job.isRoomConfirmed ? "play.fill" : "bubble.left.and.bubble.right")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                }
                .buttonStyle(.borderless).disabled(app.isWorking || model.requiresRestart)
                .accessibilityHint(model.requiresRestart ? "Close and reopen Gremma first" : "Continues from saved progress without recording again")
            } else {
                Button {
                    onReanalyze(job)
                    dismiss()
                } label: {
                    Label("Analyze again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                }
                .buttonStyle(.borderless).disabled(app.isWorking || model.requiresRestart)
                .accessibilityHint("Analyzes the saved video again and replaces its previous analysis as each segment is saved")
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

private struct SavedVideoPlayback: Identifiable { let id = UUID(); let url: URL }
