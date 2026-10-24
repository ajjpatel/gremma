// Standalone executable checks for the real coordinator validation and room consensus logic.
// Inference is stubbed; these checks do not establish Gemma accuracy.
import Foundation
@main struct CoordinatorBoundaryChecks {
    @MainActor static func main() async throws {
        let model = LocalModelService()
        let normal = AssistantContext(room: "Kitchen", mode: "conversation", hasPhoto: false, savedItemNames: [], lastTaskResult: "")
        model.json = #"{"action":"confirm_room","argument":"Kitchen","reply":"saved","reading_mode":"text"}"#
        let unexpected = try await AgentCoordinator.decide(message: "Yes", history: [], context: normal, model: model)
        precondition(unexpected.action == .chat, "A model may not confirm without a pending video")
        var pending = normal; pending.hasPendingRoomConfirmation = true
        model.json = #"{"action":"confirm_room","argument":"","reply":"saved","reading_mode":"medicine"}"#
        let nameless = try await AgentCoordinator.decide(message: "Yes", history: [], context: pending, model: model)
        precondition(nameless.action == .chat && nameless.reply.contains("What room"), "Bare yes must not invent a room")
        pending.pendingRoomProposal = "Kitchen"
        let confirmed = try await AgentCoordinator.decide(message: "Yes", history: [], context: pending, model: model)
        precondition(confirmed.action == .confirmRoom && confirmed.reply.isEmpty && confirmed.readingMode == .text, "Handler owns actual outcome")
        model.json = #"{"action":"confirm_room","argument":"This is an overlong room description containing too many words","reply":"","reading_mode":"text"}"#
        let malformed = try await AgentCoordinator.decide(message: "No, wrong room", history: [], context: pending, model: model)
        precondition(malformed.action == .chat, "Malformed room names must not label a video")
        precondition(VideoRoomClassifier.normalizedRoom("  Kitchen.  ") == "Kitchen")
        precondition(VideoRoomClassifier.normalizedRoom("It might be a kitchen or bedroom") == nil)
        precondition(VideoRoomClassifier.normalizedRoom("unknown") == nil)
        precondition(VideoRoomClassifier.consensus(["Kitchen", "Bedroom", "Kitchen"]) == nil, "Mixed room clip cannot be majority labeled")
        precondition(VideoRoomClassifier.consensus([nil, "Kitchen", nil]) == nil, "Single recognized frame is insufficient")
        precondition(VideoRoomClassifier.consensus(["Kitchen", nil, "Kitchen"]) == "Kitchen")
        precondition(VideoRoomClassifier.consensus([]) == nil)
        model.json = #"{"action":"confirm_room","argument":"Bedroom","reply":"","reading_mode":"text"}"#
        let callsBeforeYes = model.jsonCalls
        let inventedFromYes = try await AgentCoordinator.decide(message: "Yes", history: [], context: pending, model: model)
        precondition(inventedFromYes.action == .confirmRoom && inventedFromYes.argument.isEmpty && model.jsonCalls == callsBeforeYes, "Bare yes must confirm only the actual proposal, without inference")
        let no = try await AgentCoordinator.decide(message: "No", history: [], context: pending, model: model)
        precondition(no.action == .rejectRoom && model.jsonCalls == callsBeforeYes, "Explicit no wins over a model confirmation")
        let inventedLongYes = try await AgentCoordinator.decide(message: "Yes, that is definitely right", history: [], context: pending, model: model)
        precondition(inventedLongYes.action == .chat, "A longer affirmative must not introduce a model-invented correction")
        let correct = try await AgentCoordinator.decide(message: "No, it's the bedroom", history: [], context: pending, model: model)
        precondition(correct.action == .confirmRoom && correct.argument == "Bedroom", "Explicit corrections remain natural")
        let denied = try await AgentCoordinator.decide(message: "That is not the bedroom", history: [], context: pending, model: model)
        precondition(denied.action == .chat, "A denied room cannot become the correction")
        let substring = try await AgentCoordinator.decide(message: "I have two bedrooms", history: [], context: pending, model: model)
        precondition(substring.action == .chat, "Room support must use whole phrases")
        model.json = #"{"action":"confirm_room","argument":"Kitchen","reply":"","reading_mode":"text"}"#
        let existing = try await AgentCoordinator.decide(message: "Yes, that is definitely right", history: [], context: pending, model: model)
        precondition(existing.action == .confirmRoom && existing.argument.isEmpty, "Natural affirmative may accept the existing proposal")
        model.json = #"{"action":"confirm_room","argument":"","reply":"","reading_mode":"text"}"#
        let unrelated = try await AgentCoordinator.decide(message: "What do you think?", history: [], context: pending, model: model)
        precondition(unrelated.action == .chat, "Unrelated words are not consent to an unlabeled confirmation")
        let uncertain = try await AgentCoordinator.decide(message: "Yes but I am not sure", history: [], context: pending, model: model)
        precondition(uncertain.action == .chat, "An uncertain affirmative needs clarification")
        model.json = #"{"action":"set_room","argument":"Living room","reply":"","reading_mode":"text"}"#
        pending.pendingRoomProposal = nil
        let namedPendingRoom = try await AgentCoordinator.decide(message: "Living room", history: [], context: pending, model: model)
        precondition(namedPendingRoom.action == .confirmRoom && namedPendingRoom.argument == "Living room", "A bare room name answers the pending video question")
        let namedFutureRoom = try await AgentCoordinator.decide(message: "Living room", history: [], context: normal, model: model)
        precondition(namedFutureRoom.action == .setRoom && namedFutureRoom.argument == "Living room", "Without a pending question the action remains set_room")
        let explicitFuture = try await AgentCoordinator.decide(message: "Use Living room for my next photos", history: [], context: pending, model: model)
        precondition(explicitFuture.action == .setRoom, "Explicit future capture instructions are not video confirmations")
        var failedVideo = normal
        failedVideo.hasPendingVideo = true
        failedVideo.lastVideoNeedsRetry = true
        failedVideo.hasPhoto = true
        model.json = #"{"action":"record_video","argument":"","reply":"","reading_mode":"text"}"#
        let beforeVideoRetry = model.jsonCalls
        let retryVideo = try await AgentCoordinator.decide(message: "Try again", history: [], context: failedVideo, model: model)
        precondition(retryVideo.action == .resumeVideo && model.jsonCalls == beforeVideoRetry, "Failed-video retry must resume saved progress without model inference or rerecording")
        var pausedVideo = failedVideo; pausedVideo.lastVideoNeedsRetry = false
        let explicitResume = try await AgentCoordinator.decide(message: "Resume processing the video", history: [], context: pausedVideo, model: model)
        precondition(explicitResume.action == .resumeVideo && model.jsonCalls == beforeVideoRetry, "Explicit video resume may target any unfinished job")
        model.json = #"{"action":"retry_capture","argument":"","reply":"","reading_mode":"text"}"#
        let explicitPhoto = try await AgentCoordinator.decide(message: "Try that photo again", history: [], context: failedVideo, model: model)
        precondition(explicitPhoto.action == .retryCapture && model.jsonCalls > beforeVideoRetry, "An explicit photo retry is not hijacked by a failed video")
        var photoOnly = normal; photoOnly.hasPhoto = true
        let photoRetry = try await AgentCoordinator.decide(message: "Try again", history: [], context: photoOnly, model: model)
        precondition(photoRetry.action == .retryCapture, "Photo-only retry remains photo processing")
        let beforeMissingVideo = model.jsonCalls
        let noVideo = try await AgentCoordinator.decide(message: "Resume the video", history: [], context: normal, model: model)
        precondition(noVideo.action == .chat && noVideo.reply.contains("unfinished video") && model.jsonCalls == beforeMissingVideo, "Missing saved video gets a local clarification")
        model.json = #"{"action":"resume_video","argument":"invented-job-id","reply":"Saved","reading_mode":"medicine"}"#
        let inventedVideo = try await AgentCoordinator.decide(message: "Could you finish processing that recording?", history: [], context: normal, model: model)
        precondition(inventedVideo.action == .chat, "The model cannot resume a nonexistent video")
        let validResume = try await AgentCoordinator.decide(message: "Could you finish processing that recording?", history: [], context: failedVideo, model: model)
        precondition(validResume.action == .resumeVideo && validResume.argument.isEmpty && validResume.reply.isEmpty && validResume.readingMode == .text, "Only the controller selects the actual saved job and speaks completion")
        model.json = #"{"action":"chat","argument":"","reply":"Your saved progress is still available.","reading_mode":"text"}"#
        let negatedResume = try await AgentCoordinator.decide(message: "Don't resume the video; tell me what happened", history: [], context: failedVideo, model: model)
        precondition(negatedResume.action == .chat && AgentCoordinator.immediateVideoRetryDecision(message: "Don't resume the video", context: failedVideo) == nil, "A negated resume does not trigger local recovery")
        model.json = #"{"action":"record_video","argument":"","reply":"","reading_mode":"text"}"#
        let newRecording = try await AgentCoordinator.decide(message: "Please record a new video", history: [], context: failedVideo, model: model)
        precondition(newRecording.action == .recordVideo, "An explicit new recording remains available after a failure")
        var staleFailure = failedVideo; staleFailure.hasPendingVideo = false
        let staleRetry = try await AgentCoordinator.decide(message: "Try again", history: [], context: staleFailure, model: model)
        precondition(staleRetry.action == .chat, "A stale failure flag cannot restart a deleted or completed video")
        print("33 coordinator and room-classifier boundary checks passed; model inference was stubbed.")
        print("Typical system prompt bytes: \(model.lastSystem.utf8.count)")
    }
}
