import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case remember = "Activities"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .remember: return "clock.arrow.circlepath" }
    }
}

struct HomeView: View {
    @EnvironmentObject var app: AppController
    @EnvironmentObject var model: LocalModelService
    @EnvironmentObject var voice: VoiceService
    @ObservedObject private var cameraActivity = CameraActivityState.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingModels = false
    @State private var showingMemories = false
    @State private var showingTools = false
    @State private var showingDeveloperStatus = ProcessInfo.processInfo.arguments.contains("--gremma-voice-diagnostics")
    @State private var pendingToolAction: (() -> Void)?
    @State private var pendingVideoAction: (() -> Void)?
    @State private var correctedVideoRoom = ""
    @State private var videoRecordingDate = Date()
    @State private var message = ""
    @FocusState private var isTyping: Bool

    private let accent = Color(red: 0.56, green: 0.91, blue: 0.81)
    private let canvas = Color(red: 0.035, green: 0.065, blue: 0.085)
    private let muted = Color(red: 0.73, green: 0.79, blue: 0.81)

    private var liveTranscript: String {
        guard voice.isListening else { return "" }
        let text = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == app.lastUserMessage.trimmingCharacters(in: .whitespacesAndNewlines) ? "" : text
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        if app.answer.isEmpty && app.lastUserMessage.isEmpty && !app.isWorking {
                            welcome
                        }
                        conversation
                        if app.pendingVideoID != nil && !app.isWorking { videoRoomConfirmation }
                        if app.isWorking { progressCard }
                        if let error = app.error { errorCard(error) }
                        if let error = voice.error, error != app.error {
                            Label(error, systemImage: "mic.slash")
                                .font(.callout).foregroundStyle(Color(red: 1, green: 0.79, blue: 0.54))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Color.clear.frame(height: 1).id("conversation-end")
                    }
                    .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: app.answer) { _, _ in
                    if !isTyping { proxy.scrollTo("conversation-end", anchor: .bottom) }
                }
                .onChange(of: app.isWorking) { _, working in
                    if working && !isTyping { proxy.scrollTo("conversation-end", anchor: .bottom) }
                }
            }
            .background(canvas.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { voiceDock }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingModels) { ModelSetupView() }
            .sheet(isPresented: $showingMemories) { MemoryListView() }
            .sheet(isPresented: $app.showActivityTimeline) { ActivityTimelineView() }
            .sheet(isPresented: $app.showReminders) { MedicineReminderView(reminders: app.reminders) }
            .sheet(isPresented: $showingTools, onDismiss: finishToolDismissal) { toolsSheet }
            .sheet(isPresented: $app.showVideoLibrary, onDismiss: finishVideoDismissal) {
                VideoLibraryView(onImport: {
                    pendingVideoAction = { app.openVideo(record: false) }
                }, onResume: { id in
                    pendingVideoAction = { app.resumeVideo(id: id) }
                }, onReanalyze: { job in
                    pendingVideoAction = { app.reanalyzeVideo(job) }
                })
            }
            .fullScreenCover(item: $app.captureRequest) { request in
                if request.kind == .cameraPhoto || request.kind == .cameraVideo {
                    AccessibleCameraView(recordVideo: request.kind == .cameraVideo,
                        onImage: { app.receivePhoto($0, purpose: request.purpose) },
                        onVideo: { app.receiveVideo($0) }, onCancel: { app.cancelCapture() })
                } else {
                    MediaPicker(kind: request.kind,
                        onImage: { app.receivePhoto($0, purpose: request.purpose) },
                        onVideo: { app.receiveVideo($0) }, onCancel: { app.cancelCapture() })
                        .ignoresSafeArea()
                }
            }
            .task { await app.appBecameActive() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await app.appBecameActive() } }
                else if phase == .background { app.stop() }
            }
            .onChange(of: app.pendingVideoID) { _, _ in correctedVideoRoom = "" }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "asterisk")
                .font(.title.weight(.bold)).foregroundStyle(accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Gremma").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                HStack(spacing: 5) {
                    Circle().fill(model.modelURLs.isEmpty ? Color.orange : accent).frame(width: 6, height: 6)
                    Text(model.modelURLs.isEmpty ? "Model setup needed" : "On your iPhone")
                        .font(.caption).foregroundStyle(muted)
                }.accessibilityElement(children: .combine)
            }
            Spacer(minLength: 8)
            Button {
                pauseVoiceForSheet()
                showingTools = true
            } label: {
                Image(systemName: "ellipsis").font(.title3)
                    .frame(minWidth: 48, minHeight: 48)
                    .background(.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Gremma menu, videos and settings")
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Just ask Gremma.")
                .font(.largeTitle.weight(.semibold)).tracking(-0.7)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Remember your day.\nFind your keys.")
                .font(.title3).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
    }

    private func suggestion(_ title: String, symbol: String) -> some View {
        Button { send(title) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(accent)
                Text(title).multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(muted)
            }
            .font(.subheadline).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 13)
            .frame(minHeight: 48)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).disabled(app.isWorking)
    }

    @ViewBuilder private var conversation: some View {
        if !app.lastUserMessage.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Label("You", systemImage: "person.crop.circle")
                    .font(.caption.weight(.semibold)).foregroundStyle(accent)
                Text(app.lastUserMessage)
                    .font(.title3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .combine)
        }
        if !app.answer.isEmpty {
            answerCard
        } else if let image = app.evidenceImage {
            evidencePhoto(image)
        }
        if voice.isListening && !liveTranscript.isEmpty {
            Text(liveTranscript).font(.title3).foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("You are saying: \(liveTranscript)")
        }
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Gremma", systemImage: "asterisk").font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                Spacer()
                Button { voice.speak(app.answer) } label: {
                    Image(systemName: "speaker.wave.2").font(.title3).frame(minWidth: 48, minHeight: 48)
                }.buttonStyle(.plain).accessibilityLabel("Hear Gremma's answer again")
            }
            Text(app.answer).font(.title3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let image = app.evidenceImage {
                DisclosureGroup("View video evidence") {
                    evidencePhoto(image).padding(.top, 10)
                    if !app.evidenceCaption.isEmpty {
                        Text(app.evidenceCaption).font(.caption).foregroundStyle(muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.font(.subheadline)
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(accent.opacity(0.16)))
    }

    private func evidencePhoto(_ image: UIImage) -> some View {
        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel("Photograph for this conversation")
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProgressView().tint(accent)
                Text(app.status)
                    .font(.callout.weight(.medium)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let job = app.retryVideoJob, app.videoProgress != nil {
                ProgressView(value: job.memoryProgress) {
                    Text("\(job.nextActivityWindowIndex) of \(job.activityWindowCount) activity segments saved")
                        .font(.callout)
                }
                .tint(accent)
                .accessibilityLabel("Saved video progress")
                .accessibilityValue("\(Int(job.memoryProgress * 100)) percent")
            } else if let progress = app.videoProgress {
                ProgressView(value: progress).tint(accent)
                    .accessibilityLabel("Saved video progress")
                    .accessibilityValue("\(Int(progress * 100)) percent")
            }
        }.padding(.vertical, 8).accessibilityElement(children: .combine)
    }

    private func videoRecoveryCard(_ job: VideoIndexJob) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Video progress saved", systemImage: "video.badge.checkmark")
                .font(.headline).accessibilityAddTraits(.isHeader)
            Text(job.room).font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: job.memoryProgress) {
                Text("\(job.nextActivityWindowIndex) of \(job.activityWindowCount) activity segments saved")
                    .font(.callout)
            }
            .tint(accent)
            .accessibilityLabel("Saved video progress")
            .accessibilityValue("\(Int(job.memoryProgress * 100)) percent")
            if model.requiresRestart {
                Text("Reopen Gremma to resume")
                    .font(.headline).foregroundStyle(Color(red: 1, green: 0.79, blue: 0.54))
                Text("Swipe up from the bottom and pause, swipe Gremma up to close it, then open Gremma again. Your recording and saved progress will remain.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("You can still ask about saved activities.")
                    .font(.callout).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Continue from the next unfinished segment. Your original recording is saved.")
                    .font(.callout).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            primaryButton("Resume saved video", symbol: "play.fill") {
                isTyping = false
                app.resumeVideo(id: job.id)
            }
            .disabled(model.requiresRestart)
            .accessibilityHint(model.requiresRestart ? "Close and reopen Gremma first" : "Continues this video from its saved progress")
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(accent.opacity(0.25)))
    }

    private func errorCard(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Needs attention", systemImage: "exclamationmark.circle")
                .font(.headline).foregroundStyle(Color(red: 1, green: 0.79, blue: 0.54))
            Text(error).font(.callout).fixedSize(horizontal: false, vertical: true)
            if app.canRetryCapture {
                Button { app.retryLastCapture() } label: {
                    Label("Try this photo again", systemImage: "arrow.clockwise")
                        .font(.body.weight(.semibold)).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).disabled(app.isWorking)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private var toolLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { toolsButton; videosButton; activitiesButton }
            VStack(alignment: .leading, spacing: 4) { toolsButton; videosButton; activitiesButton }
        }
        .font(.subheadline).foregroundStyle(muted)
        .disabled(app.isWorking)
    }

    private var activitiesButton: some View {
        Button { pauseVoiceForSheet(); app.showActivityTimeline = true } label: {
            Label("Timeline", systemImage: "clock.arrow.circlepath").frame(minHeight: 48)
        }
        .accessibilityValue("\(app.activities.count) saved activities")
    }

    private var medicineOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Today's video logs", systemImage: "sun.max").font(.headline)
                Spacer()
                Button { pauseVoiceForSheet(); app.showReminders = true } label: {
                    Image(systemName: "bell").frame(minWidth: 48, minHeight: 48)
                }.accessibilityLabel("Medicine video-log reminders")
            }
            Text(app.morningMedicineLog).font(.callout).foregroundStyle(muted)
            Text(app.eveningMedicineLog).font(.callout).foregroundStyle(muted)
            Text("Reminder times: 9 AM and 9 PM · enable in reminders")
                .font(.caption).foregroundStyle(accent)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
    }

    private var videosButton: some View {
        Button {
            isTyping = false
            app.openSavedVideos()
        } label: { Label("Videos", systemImage: "video").frame(minHeight: 48) }
        .accessibilityHint("Import, resume, or delete saved room videos")
        .accessibilityValue("\(app.videoJobs.count) saved videos")
    }

    private var videoRoomConfirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Confirm the video's room", systemImage: "house")
                .font(.headline).accessibilityAddTraits(.isHeader)
            if let room = app.pendingVideoRoom {
                Text("Does this video show the \(room)?")
                    .font(.title3).fixedSize(horizontal: false, vertical: true)
                primaryButton("Yes, use \(room)", symbol: "checkmark.circle") {
                    isTyping = false
                    app.confirmVideoRoom()
                }
                Button("No, I'll tell you the room") { app.rejectVideoRoom() }
                    .frame(minHeight: 48)
            } else {
                Text("Say the room name, or enter a name below.")
                    .foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            if let job = app.videoJobs.first(where: { $0.id == app.pendingVideoID }), job.recordedAt == nil {
                Text("This video's recording date is unknown. Set it before processing to include it in daily logs.")
                    .font(.callout).foregroundStyle(.orange)
                DatePicker("Recorded on", selection: $videoRecordingDate, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                Button("Use this recording date") {
                    Task { do { try await app.setVideoDate(job, date: videoRecordingDate) }
                           catch { app.error = error.localizedDescription } }
                }.frame(minHeight: 48)
            }
            TextField("Room or area name", text: $correctedVideoRoom)
                .textFieldStyle(.roundedBorder).submitLabel(.done)
                .accessibilityLabel("Correct room for this video")
                .onSubmit(confirmTypedVideoRoom)
            Button("Use this room", action: confirmTypedVideoRoom)
                .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                .disabled(correctedVideoRoom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))
    }

    private func confirmTypedVideoRoom() {
        let room = correctedVideoRoom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !room.isEmpty else { return }
        isTyping = false
        app.confirmVideoRoom(room)
        correctedVideoRoom = ""
    }

    private var toolsButton: some View {
        Button {
            pauseVoiceForSheet()
            showingTools = true
        } label: { Label("More", systemImage: "ellipsis.circle").frame(minHeight: 48) }
        .accessibilityHint("Record activities and manage reminders")
    }

    private var memoriesButton: some View {
        Button {
            pauseVoiceForSheet()
            showingMemories = true
        } label: { Label("Saved memories", systemImage: "square.stack").frame(minHeight: 48) }
        .accessibilityValue("\(app.observations.count) saved observations")
    }

    private var voiceDock: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Gremma…", text: $message)
                    .font(.body).focused($isTyping)
                    .submitLabel(.send).onSubmit(sendTypedMessage)
                    .accessibilityLabel("Type a message to Gremma")
                    .padding(.leading, 15).padding(.vertical, 13)
                Button(action: sendTypedMessage) {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                        .frame(minWidth: 48, minHeight: 48)
                }
                .accessibilityLabel("Send message")
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.isWorking)
            }
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 17))
            HStack(spacing: 12) {
                Button {
                    isTyping = false
                    app.toggleVoice()
                } label: {
                    Label(voice.isListening ? "Finish listening" : "Talk to Gremma", systemImage: voice.isListening ? "waveform" : "mic.fill")
                        .font(.headline).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .padding(.horizontal, 16).padding(.vertical, 4)
                        .foregroundStyle(canvas).background(accent, in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain).disabled(app.isWorking)
                .accessibilityHint(voice.isListening ? "Finish your message and send it to Gremma" : "Start a voice conversation")
                if app.isWorking || voice.isSpeaking || app.voiceSessionEnabled {
                    Button { app.stop() } label: {
                        Image(systemName: "stop.fill").font(.title3)
                            .frame(minWidth: 58, minHeight: 58)
                            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                    }
                    .buttonStyle(.plain).accessibilityLabel("Stop Gremma and end voice session")
                }
            }
            queryStats
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
        .background(canvas)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.09)).frame(height: 1) }
    }

    private var queryStats: some View {
        let stats = app.queryPerformance
        return VStack(spacing: 7) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6),
                                    count: dynamicTypeSize.isAccessibilitySize ? 2 : 4), spacing: 10) {
                metric("TPUT", value: stats?.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "—",
                       hint: "Native model decode throughput in tokens per second")
                metric("TTFT", value: seconds(stats?.firstTokenSeconds), hint: "Time from question received to first answer text received")
                metric("TPOT", value: stats?.timePerOutputTokenSeconds.map { String(format: "%.1f ms", $0 * 1_000) } ?? "—",
                    hint: "Average time per output token after the first, using native token count and text arrival times")
                metric("Answer", value: seconds(stats?.answerSeconds), hint: "Time from question received until the answer is ready")
            }
            Text(stats.map { $0.source == "Saved answer" ? "Saved answer · no model generation" : "Gemma E4B · timings from question received" } ?? "Response statistics appear here")
                .font(.caption2).foregroundStyle(muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 5)
    }

    private func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.2f s", $0) } ?? "—"
    }

    private func metric(_ title: String, value: String, hint: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(muted)
            Text(value).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hint).accessibilityValue(value)
    }

    private var toolsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Everything is a conversation away. These controls are here when you want them.")
                        .font(.body).foregroundStyle(muted)
                    activePanel
                    primaryButton("Local model settings", symbol: "slider.horizontal.3") {
                        afterClosingTools { showingModels = true }
                    }
                    primaryButton("Activity timeline", symbol: "clock.arrow.circlepath") {
                        afterClosingTools { app.showActivityTimeline = true }
                    }
                    Toggle(isOn: $showingDeveloperStatus) {
                        Label("Show developer status", systemImage: "waveform.path.ecg")
                    }
                    .frame(minHeight: 48)
                    .accessibilityHint("Shows microphone, speech, and camera details here")
                    if showingDeveloperStatus { developerStatus }
                }.padding(24)
            }
            .background(canvas.ignoresSafeArea())
            .navigationTitle("Tools")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingTools = false } } }
        }.tint(accent).preferredColorScheme(.dark)
    }

    private var developerStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Developer status", systemImage: "waveform.path.ecg")
                .font(.caption.weight(.semibold)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 6) {
                Label(voice.isListening || cameraActivity.isMicrophoneRunning ? "Microphone: on" : "Microphone: off", systemImage: voice.isListening || cameraActivity.isMicrophoneRunning ? "mic.fill" : "mic.slash")
                if let elapsed = app.lastLookupSeconds { Text("Saved-fact lookup: \(Int(elapsed * 1000)) ms · no model call") }
                Label(voice.isSpeaking ? "Speech: speaking" : "Speech: idle", systemImage: "speaker.wave.2")
                Label(cameraActivity.isRunning ? "Camera: running with live preview" : "Camera: off", systemImage: cameraActivity.isRunning ? "camera.fill" : "camera")
                Text("Voice status: \(voice.status)")
                Text(voice.developerStatus)
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private var modeButtons: some View {
        ForEach(AppMode.allCases) { mode in
            Button { app.mode = mode } label: {
                Label(mode.rawValue, systemImage: mode.symbol)
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(app.mode == mode ? canvas : Color.white)
                    .background(app.mode == mode ? accent : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).accessibilityAddTraits(app.mode == mode ? .isSelected : [])
        }
    }

    @ViewBuilder private var activePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch app.mode {
            case .remember:
                panelHeading("Your day, remembered", subtitle: "Record an activity. Ask what happened or where an item was last seen.")
                TextField("Room name", text: $app.roomName).textFieldStyle(.roundedBorder).accessibilityLabel("Room name")
                primaryButton("Record an activity", symbol: "video") { afterClosingTools { app.openVideo(record: true) } }
                primaryButton("Import a recorded video", symbol: "square.and.arrow.down") { afterClosingTools { app.openVideo(record: false) } }
                primaryButton("Manage saved videos", symbol: "film.stack") { afterClosingTools { app.openSavedVideos() } }
                primaryButton("Medicine video-log reminders", symbol: "bell") { afterClosingTools { app.showReminders = true } }
                primaryButton("Earlier photo memories", symbol: "photo") { afterClosingTools { showingMemories = true } }
                HStack {
                    TextField("Find my keys…", text: $app.query).submitLabel(.search)
                        .onSubmit { afterClosingTools { app.recallActivity("Where are my " + app.query + "?") } }
                        .accessibilityLabel("Search saved memories")
                    Button { afterClosingTools { app.recallActivity("Where are my " + app.query + "?") } } label: {
                        Image(systemName: "magnifyingglass").frame(minWidth: 48, minHeight: 48)
                    }.accessibilityLabel("Search memories")
                }.padding(.leading, 14).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                if app.hasPendingVideo {
                    primaryButton("Resume room video", symbol: "play.circle") { afterClosingTools { app.resumeVideo() } }
                        .disabled(model.requiresRestart)
                    if model.requiresRestart {
                        Text("Close and reopen Gremma to resume the video. Its saved progress will remain.")
                            .font(.callout).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.disabled(app.isWorking)
    }

    private func panelHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.body).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primaryButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48).padding(12)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).disabled(app.isWorking)
    }

    private func sendTypedMessage() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !app.isWorking else { return }
        message = ""
        send(text)
    }

    private func send(_ text: String) {
        isTyping = false
        app.sendMessage(text)
    }

    private func pauseVoiceForSheet() {
        isTyping = false
        app.voiceSessionEnabled = false
        voice.cancelListening()
        voice.stopSpeaking()
    }

    private func afterClosingTools(_ action: @escaping () -> Void) {
        pendingToolAction = action
        showingTools = false
    }

    private func finishToolDismissal() {
        let action = pendingToolAction
        pendingToolAction = nil
        action?()
    }

    private func finishVideoDismissal() {
        let action = pendingVideoAction
        pendingVideoAction = nil
        action?()
    }
}
