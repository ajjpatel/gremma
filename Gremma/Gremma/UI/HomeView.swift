import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case remember = "Remember", read = "Read", imagine = "Imagine"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .remember: return "sparkle.magnifyingglass"; case .read: return "text.viewfinder"; case .imagine: return "sparkles" }
    }
}

struct HomeView: View {
    @EnvironmentObject var app: AppController
    @EnvironmentObject var model: LocalModelService
    @EnvironmentObject var voice: VoiceService
    @ObservedObject private var cameraActivity = CameraActivityState.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingModels = false
    @State private var showingMemories = false
    @State private var showingTools = false
    @State private var showingDeveloperStatus = ProcessInfo.processInfo.arguments.contains("--gremma-voice-diagnostics")
    @State private var pendingToolAction: (() -> Void)?
    @State private var pendingVideoAction: (() -> Void)?
    @State private var correctedVideoRoom = ""
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
                        if let job = app.retryVideoJob, !app.isWorking { videoRecoveryCard(job) }
                        if showingDeveloperStatus { developerStatus }
                        if app.isWorking { progressCard }
                        if let error = app.error { errorCard(error) }
                        if let error = voice.error, error != app.error {
                            Label(error, systemImage: "mic.slash")
                                .font(.callout).foregroundStyle(Color(red: 1, green: 0.79, blue: 0.54))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        toolLinks
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
            .sheet(isPresented: $showingTools, onDismiss: finishToolDismissal) { toolsSheet }
            .sheet(isPresented: $app.showVideoLibrary, onDismiss: finishVideoDismissal) {
                VideoLibraryView(onImport: {
                    pendingVideoAction = { app.openVideo(record: false) }
                }, onResume: { id in
                    pendingVideoAction = { app.resumeVideo(id: id) }
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
            .task { await app.refreshMemory() }
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
                showingModels = true
            } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
                    .frame(minWidth: 48, minHeight: 48)
                    .background(.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Gremma settings and local models")
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Just ask Gremma.")
                .font(.largeTitle.weight(.semibold)).tracking(-0.7)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Read a label. Find your keys.\nOr start with hello.")
                .font(.title3).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                suggestion("What can you help me with?", symbol: "bubble.left")
                suggestion("Read this label", symbol: "text.viewfinder")
                suggestion("Remember where I put this", symbol: "camera")
            }.padding(.top, 6)
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
        if voice.isListening {
            VStack(alignment: .leading, spacing: 9) {
                Label("Listening · microphone on", systemImage: "waveform")
                    .font(.caption.weight(.semibold)).foregroundStyle(accent)
                if !liveTranscript.isEmpty {
                    Text(liveTranscript).font(.title3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
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
            if let image = app.evidenceImage { evidencePhoto(image) }
            Text(app.answer).font(.title3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !app.evidenceCaption.isEmpty {
                Text(app.evidenceCaption).font(.caption).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
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
                ProgressView(value: job.progress) {
                    Text("\(job.nextFrameIndex) of \(job.sampleTimes.count) frames saved")
                        .font(.callout)
                }
                .tint(accent)
                .accessibilityLabel("Saved video progress")
                .accessibilityValue("\(job.nextFrameIndex) of \(job.sampleTimes.count) frames")
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
            ProgressView(value: job.progress) {
                Text("\(job.nextFrameIndex) of \(job.sampleTimes.count) frames saved")
                    .font(.callout)
            }
            .tint(accent)
            .accessibilityLabel("Saved video progress")
            .accessibilityValue("\(job.nextFrameIndex) of \(job.sampleTimes.count) frames")
            if model.requiresRestart {
                Text("Reopen Gremma to resume")
                    .font(.headline).foregroundStyle(Color(red: 1, green: 0.79, blue: 0.54))
                Text("Swipe up from the bottom and pause, swipe Gremma up to close it, then open Gremma again. Your recording and saved progress will remain.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("You can still read printed text through Tools → Read, or search saved memories.")
                    .font(.callout).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Continue from the next frame. You don't need to record the room again.")
                    .font(.callout).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            primaryButton("Resume at frame \(job.nextFrameIndex + 1)", symbol: "play.fill") {
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
            HStack(spacing: 20) { toolsButton; videosButton; memoriesButton }
            VStack(alignment: .leading, spacing: 4) { toolsButton; videosButton; memoriesButton }
        }
        .font(.subheadline).foregroundStyle(muted)
        .disabled(app.isWorking)
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
        } label: { Label("Tools", systemImage: "square.grid.2x2").frame(minHeight: 48) }
        .accessibilityHint("Open capture, reading, and imagination controls")
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
            Text(voiceCaption)
                .font(.caption).foregroundStyle(muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)
        .background(canvas)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.09)).frame(height: 1) }
    }

    private var voiceCaption: String {
        if dynamicTypeSize.isAccessibilitySize {
            return app.voiceSessionEnabled ? "Voice session on" : "Tap Talk to begin."
        }
        return app.voiceSessionEnabled ? "Voice session on · listening pauses during replies" : "Tap Talk to begin. Allow microphone access the first time."
    }

    private var toolsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Everything is a conversation away. These controls are here when you want them.")
                        .font(.body).foregroundStyle(muted)
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 8) { modeButtons }
                    } else {
                        HStack(spacing: 8) { modeButtons }
                    }
                    activePanel
                    Toggle(isOn: $showingDeveloperStatus) {
                        Label("Show developer status", systemImage: "waveform.path.ecg")
                    }
                    .frame(minHeight: 48)
                    .accessibilityHint("Shows live microphone, speech, and camera details on the conversation screen")
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
                Label(voice.isListening ? "Microphone: listening" : "Microphone: off", systemImage: voice.isListening ? "mic.fill" : "mic.slash")
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
                panelHeading("Remember where things are", subtitle: "Save a photo or room video. Find an item later with its original evidence.")
                TextField("Room name", text: $app.roomName).textFieldStyle(.roundedBorder).accessibilityLabel("Room name")
                primaryButton("Remember a photo", symbol: "camera") { afterClosingTools { app.openCapture(purpose: .remember) } }
                primaryButton("Record a room video", symbol: "video") { afterClosingTools { app.openVideo(record: true) } }
                primaryButton("Import a recorded video", symbol: "square.and.arrow.down") { afterClosingTools { app.openVideo(record: false) } }
                primaryButton("Manage saved videos", symbol: "film.stack") { afterClosingTools { app.openSavedVideos() } }
                Menu {
                    Button("Import a photo") { afterClosingTools { app.openCapture(purpose: .remember, library: true) } }
                    Button("Describe a scene") { afterClosingTools { app.openCapture(purpose: .describe) } }
                } label: { Label("More capture options", systemImage: "plus.circle").frame(minHeight: 48) }
                HStack {
                    TextField("Find my keys…", text: $app.query).submitLabel(.search)
                        .onSubmit { afterClosingTools { app.findMemory() } }
                        .accessibilityLabel("Search saved memories")
                    Button { afterClosingTools { app.findMemory() } } label: {
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
            case .read:
                panelHeading("Read the details", subtitle: "Hear printed text, medicine labels, expiry dates, or US currency. Unclear details stay unknown.")
                Picker("What to read", selection: $app.readingMode) {
                    ForEach(ReadingMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.menu).frame(minHeight: 48)
                primaryButton("Read with camera", symbol: "text.viewfinder") { afterClosingTools { app.openCapture(purpose: .read) } }
                Button("Choose an existing photo") { afterClosingTools { app.openCapture(purpose: .read, library: true) } }
                    .frame(minHeight: 48)
            case .imagine:
                panelHeading("Picture the Taj Mahal", subtitle: "A guided description using verified facts saved on your iPhone.")
                LandmarkIllustration().frame(height: 140).accessibilityHidden(true)
                primaryButton("A short description", symbol: "sparkles") { afterClosingTools { app.imagine(short: true) } }
                primaryButton("A detailed walkthrough", symbol: "text.alignleft") { afterClosingTools { app.imagine(short: false) } }
                HStack {
                    TextField("Ask about the Taj Mahal…", text: $app.query).submitLabel(.send)
                        .onSubmit { afterClosingTools { app.imagine(question: app.query) } }
                        .accessibilityLabel("Ask about the Taj Mahal")
                    Button { afterClosingTools { app.imagine(question: app.query) } } label: {
                        Image(systemName: "arrow.up").frame(minWidth: 48, minHeight: 48)
                    }.accessibilityLabel("Send Taj Mahal question")
                }.padding(.leading, 14).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
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

struct LandmarkIllustration: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            Path { p in
                p.move(to: CGPoint(x: w * 0.1, y: 123)); p.addLine(to: CGPoint(x: w * 0.9, y: 123))
                p.addRect(CGRect(x: w * 0.32, y: 65, width: w * 0.36, height: 58))
                p.move(to: CGPoint(x: w * 0.35, y: 65))
                p.addCurve(to: CGPoint(x: w * 0.5, y: 20), control1: CGPoint(x: w * 0.3, y: 45), control2: CGPoint(x: w * 0.48, y: 34))
                p.addCurve(to: CGPoint(x: w * 0.65, y: 65), control1: CGPoint(x: w * 0.52, y: 34), control2: CGPoint(x: w * 0.7, y: 45))
                for x in [w * 0.2, w * 0.8] {
                    p.addRect(CGRect(x: x - 6, y: 53, width: 12, height: 70))
                    p.move(to: CGPoint(x: x - 10, y: 53)); p.addLine(to: CGPoint(x: x, y: 39)); p.addLine(to: CGPoint(x: x + 10, y: 53))
                }
                p.move(to: CGPoint(x: w * 0.44, y: 123)); p.addLine(to: CGPoint(x: w * 0.44, y: 93))
                p.addQuadCurve(to: CGPoint(x: w * 0.56, y: 93), control: CGPoint(x: w * 0.5, y: 70))
                p.addLine(to: CGPoint(x: w * 0.56, y: 123))
            }.stroke(Color(red: 0.56, green: 0.91, blue: 0.81).opacity(0.65), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
