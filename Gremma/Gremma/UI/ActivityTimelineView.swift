import SwiftUI

struct ActivityTimelineView: View {
    @EnvironmentObject var app: AppController
    @Environment(\.dismiss) private var dismiss
    @State private var todayOnly = true

    private var events: [ActivityEvent] {
        app.activities.filter { !todayOnly || $0.occurredAt.map { Calendar.current.isDateInToday($0) } == true }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Activity history", selection: $todayOnly) {
                        Text("Today").tag(true)
                        Text("All history").tag(false)
                    }.pickerStyle(.segmented)
                    Text("Events use the recording date, not the upload date. Every entry is an observation from your video.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if events.isEmpty {
                    ContentUnavailableView("No activities yet", systemImage: "clock",
                        description: Text("Record or upload a video to remember a visible activity."))
                }
                Section("Activities · \(events.count)") {
                    ForEach(events) { event in
                        Button {
                            dismiss()
                            app.showActivity(event)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(event.isVisualNote ? "Visual note · details unclassified" : (event.kind == .conversation ? "People interacting" : event.kind.title)).font(.headline)
                                    if !event.hasClearEvidence { Image(systemName: "questionmark.circle").accessibilityLabel("Uncertain observation") }
                                }
                                Text(event.summary).font(.body).foregroundStyle(.primary)
                                if event.isUserConfirmed {
                                    Label("User-confirmed label", systemImage: "person.crop.circle.badge.checkmark")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(event.timeDescription).font(.caption).foregroundStyle(.secondary)
                                Text("View video evidence · \(Int(event.startSeconds))–\(Int(event.endSeconds)) seconds")
                                    .font(.caption).foregroundStyle(.mint)
                            }.padding(.vertical, 6)
                        }.buttonStyle(.plain).disabled(app.isWorking)
                    }
                }
            }
            .navigationTitle("Your timeline")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await app.refreshMemory() }
        }
    }
}

struct MedicineReminderView: View {
    @EnvironmentObject var app: AppController
    @ObservedObject var reminders: MedicineLogReminders
    @Environment(\.dismiss) private var dismiss
    @State private var updating = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Medicine video logs") {
                    Text("Gremma checks whether you have logged a medicine-taking video. It does not decide whether you took a dose.")
                    LabeledContent("Morning check", value: "9:00 AM")
                    LabeledContent("Evening check", value: "9:00 PM")
                    Text("Morning covers midnight to noon; evening covers noon to midnight, in your iPhone's timezone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Today") {
                    Text(app.morningMedicineLog)
                    Text(app.eveningMedicineLog)
                }
                Section {
                    Toggle("Enable video-log reminders", isOn: Binding(get: { reminders.enabled }, set: { value in
                        updating = true
                        Task { await reminders.setEnabled(value, events: app.activities); updating = false }
                    })).disabled(updating)
                    Text(reminders.status).font(.callout)
                    if let through = reminders.scheduledThrough {
                        Text("Scheduled through \(through.formatted(date: .abbreviated, time: .shortened)). Opening Gremma renews the next seven days.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Video-log reminders")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await reminders.reconcile(events: app.activities) }
        }
    }
}

struct HomeDevicesView: View {
    @ObservedObject var server: LocalVideoUploadServer
    @Environment(\.dismiss) private var dismiss
    @State private var showToken = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Ventuno Q video uploads") {
                    Text("A paired device can send MP4 or MOV clips over your private Wi-Fi. Gremma saves each clip with its original recording time.")
                    Toggle("Receive videos while Gremma is open", isOn: Binding(get: { server.isRunning }, set: { $0 ? server.start() : server.stop() }))
                    Text(server.status).font(.callout)
                    if server.isRunning {
                        LabeledContent("Upload address") { Text(server.address + "/v1/videos").textSelection(.enabled) }
                    }
                }
                Section("Pair your device") {
                    Text("Use the repository's upload_video.py script on the Ventuno Q Linux system. Set GREMMA_UPLOAD_TOKEN on the sending device to the token below.")
                    Button(showToken ? "Hide pairing token" : "Show pairing token") { showToken.toggle() }
                        .frame(minHeight: 48)
                    if showToken {
                        Text(server.token).font(.callout.monospaced()).textSelection(.enabled)
                            .privacySensitive()
                    }
                    Text("The API uses HTTP on a trusted private network. Keep the token private and do not forward this port to the internet. Reception stops when Gremma enters the background.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Home devices")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
