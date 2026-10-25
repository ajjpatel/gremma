// Standalone executable checks for the real coordinator validation and room consensus logic.
// Inference is stubbed; these checks do not establish Gemma accuracy.
import Foundation
@main struct CoordinatorBoundaryChecks {
    @MainActor static func main() async throws {
        var checkCount = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String = "") {
            checkCount += 1
            precondition(condition(), message)
        }
        let model = LocalModelService()
        let normal = AssistantContext(room: "Kitchen", mode: "conversation", hasPhoto: false, savedItemNames: [], lastTaskResult: "")
        model.json = #"{"action":"confirm_room","argument":"Kitchen","reply":"saved","reading_mode":"text"}"#
        let unexpected = try await AgentCoordinator.decide(message: "Yes", history: [], context: normal, model: model)
        check(unexpected.action == .chat, "A model may not confirm without a pending video")
        var pending = normal; pending.hasPendingRoomConfirmation = true
        model.json = #"{"action":"confirm_room","argument":"","reply":"saved","reading_mode":"medicine"}"#
        let nameless = try await AgentCoordinator.decide(message: "Yes", history: [], context: pending, model: model)
        check(nameless.action == .chat && nameless.reply.contains("What room"), "Bare yes must not invent a room")
        pending.pendingRoomProposal = "Kitchen"
        let confirmed = try await AgentCoordinator.decide(message: "Yes", history: [], context: pending, model: model)
        check(confirmed.action == .confirmRoom && confirmed.reply.isEmpty && confirmed.readingMode == .text, "Handler owns actual outcome")
        model.json = #"{"action":"confirm_room","argument":"This is an overlong room description containing too many words","reply":"","reading_mode":"text"}"#
        let malformed = try await AgentCoordinator.decide(message: "No, wrong room", history: [], context: pending, model: model)
        check(malformed.action == .chat, "Malformed room names must not label a video")
        check(VideoRoomClassifier.normalizedRoom("  Kitchen.  ") == "Kitchen")
        check(VideoRoomClassifier.normalizedRoom("It might be a kitchen or bedroom") == nil)
        check(VideoRoomClassifier.normalizedRoom("unknown") == nil)
        check(VideoRoomClassifier.consensus(["Kitchen", "Bedroom", "Kitchen"]) == nil, "Mixed room clip cannot be majority labeled")
        check(VideoRoomClassifier.consensus([nil, "Kitchen", nil]) == nil, "Single recognized frame is insufficient")
        check(VideoRoomClassifier.consensus(["Kitchen", nil, "Kitchen"]) == "Kitchen")
        check(VideoRoomClassifier.consensus([]) == nil)
        model.json = #"{"action":"confirm_room","argument":"Bedroom","reply":"","reading_mode":"text"}"#
        let callsBeforeYes = model.jsonCalls
        let inventedFromYes = try await AgentCoordinator.decide(message: "Yes", history: [], context: pending, model: model)
        check(inventedFromYes.action == .confirmRoom && inventedFromYes.argument.isEmpty && model.jsonCalls == callsBeforeYes, "Bare yes must confirm only the actual proposal, without inference")
        let no = try await AgentCoordinator.decide(message: "No", history: [], context: pending, model: model)
        check(no.action == .rejectRoom && model.jsonCalls == callsBeforeYes, "Explicit no wins over a model confirmation")
        let inventedLongYes = try await AgentCoordinator.decide(message: "Yes, that is definitely right", history: [], context: pending, model: model)
        check(inventedLongYes.action == .chat, "A longer affirmative must not introduce a model-invented correction")
        let correct = try await AgentCoordinator.decide(message: "No, it's the bedroom", history: [], context: pending, model: model)
        check(correct.action == .confirmRoom && correct.argument == "Bedroom", "Explicit corrections remain natural")
        let denied = try await AgentCoordinator.decide(message: "That is not the bedroom", history: [], context: pending, model: model)
        check(denied.action == .chat, "A denied room cannot become the correction")
        let substring = try await AgentCoordinator.decide(message: "I have two bedrooms", history: [], context: pending, model: model)
        check(substring.action == .chat, "Room support must use whole phrases")
        model.json = #"{"action":"confirm_room","argument":"Kitchen","reply":"","reading_mode":"text"}"#
        let existing = try await AgentCoordinator.decide(message: "Yes, that is definitely right", history: [], context: pending, model: model)
        check(existing.action == .confirmRoom && existing.argument.isEmpty, "Natural affirmative may accept the existing proposal")
        model.json = #"{"action":"confirm_room","argument":"","reply":"","reading_mode":"text"}"#
        let unrelated = try await AgentCoordinator.decide(message: "What do you think?", history: [], context: pending, model: model)
        check(unrelated.action == .chat, "Unrelated words are not consent to an unlabeled confirmation")
        let uncertain = try await AgentCoordinator.decide(message: "Yes but I am not sure", history: [], context: pending, model: model)
        check(uncertain.action == .chat, "An uncertain affirmative needs clarification")
        model.json = #"{"action":"set_room","argument":"Living room","reply":"","reading_mode":"text"}"#
        pending.pendingRoomProposal = nil
        let namedPendingRoom = try await AgentCoordinator.decide(message: "Living room", history: [], context: pending, model: model)
        check(namedPendingRoom.action == .confirmRoom && namedPendingRoom.argument == "Living room", "A bare room name answers the pending video question")
        let namedFutureRoom = try await AgentCoordinator.decide(message: "Living room", history: [], context: normal, model: model)
        check(namedFutureRoom.action == .chat, "Room-setting outside a video confirmation is no longer an app action")
        let explicitFuture = try await AgentCoordinator.decide(message: "Use Living room for my next videos", history: [], context: pending, model: model)
        check(explicitFuture.action == .chat, "Removed set_room action must not become a pending video confirmation")
        var failedVideo = normal
        failedVideo.hasPendingVideo = true
        failedVideo.lastVideoNeedsRetry = true
        failedVideo.hasPhoto = true
        model.json = #"{"action":"record_video","argument":"","reply":"","reading_mode":"text"}"#
        let beforeVideoRetry = model.jsonCalls
        let retryVideo = try await AgentCoordinator.decide(message: "Try again", history: [], context: failedVideo, model: model)
        check(retryVideo.action == .resumeVideo && model.jsonCalls == beforeVideoRetry, "Failed-video retry must resume saved progress without model inference or rerecording")
        var pausedVideo = failedVideo; pausedVideo.lastVideoNeedsRetry = false
        let explicitResume = try await AgentCoordinator.decide(message: "Resume processing the video", history: [], context: pausedVideo, model: model)
        check(explicitResume.action == .resumeVideo && model.jsonCalls == beforeVideoRetry, "Explicit video resume may target any unfinished job")
        model.json = #"{"action":"retry_capture","argument":"","reply":"","reading_mode":"text"}"#
        let explicitPhoto = try await AgentCoordinator.decide(message: "Try that photo again", history: [], context: failedVideo, model: model)
        check(explicitPhoto.action == .chat && model.jsonCalls > beforeVideoRetry, "Removed photo retry is not hijacked by a failed video")
        var photoOnly = normal; photoOnly.hasPhoto = true
        let photoRetry = try await AgentCoordinator.decide(message: "Try again", history: [], context: photoOnly, model: model)
        check(photoRetry.action == .chat, "Removed photo processing does not reappear through retry")
        let beforeMissingVideo = model.jsonCalls
        let noVideo = try await AgentCoordinator.decide(message: "Resume the video", history: [], context: normal, model: model)
        check(noVideo.action == .chat && noVideo.reply.contains("unfinished video") && model.jsonCalls == beforeMissingVideo, "Missing saved video gets a local clarification")
        model.json = #"{"action":"resume_video","argument":"invented-job-id","reply":"Saved","reading_mode":"medicine"}"#
        let inventedVideo = try await AgentCoordinator.decide(message: "Could you finish processing that recording?", history: [], context: normal, model: model)
        check(inventedVideo.action == .chat, "The model cannot resume a nonexistent video")
        let validResume = try await AgentCoordinator.decide(message: "Could you finish processing that recording?", history: [], context: failedVideo, model: model)
        check(validResume.action == .resumeVideo && validResume.argument.isEmpty && validResume.reply.isEmpty && validResume.readingMode == .text, "Only the controller selects the actual saved job and speaks completion")
        model.json = #"{"action":"chat","argument":"","reply":"Your saved progress is still available.","reading_mode":"text"}"#
        let negatedResume = try await AgentCoordinator.decide(message: "Don't resume the video; tell me what happened", history: [], context: failedVideo, model: model)
        check(negatedResume.action == .chat && AgentCoordinator.immediateVideoRetryDecision(message: "Don't resume the video", context: failedVideo) == nil, "A negated resume does not trigger local recovery")
        model.json = #"{"action":"record_video","argument":"","reply":"","reading_mode":"text"}"#
        let newRecording = try await AgentCoordinator.decide(message: "Please record a new video", history: [], context: failedVideo, model: model)
        check(newRecording.action == .recordVideo, "An explicit new recording remains available after a failure")
        var staleFailure = failedVideo; staleFailure.hasPendingVideo = false
        let staleRetry = try await AgentCoordinator.decide(message: "Try again", history: [], context: staleFailure, model: model)
        check(staleRetry.action == .chat, "A stale failure flag cannot restart a deleted or completed video")
        for (action, question, expected) in [
            ("recall", "Where are my keys?", AssistantAction.recall),
            ("recall", "What did we discuss yesterday?", AssistantAction.recall),
            ("timeline", "What did I do today?", AssistantAction.timeline),
            ("medicine_log", "Is there a medicine-taking video this morning?", AssistantAction.medicineLog),
            ("reminders", "Show my 9 AM and 9 PM reminders", AssistantAction.reminders),
            ("home_devices", "Connect a home camera", AssistantAction.homeDevices),
            ("import_video", "Import a recorded video", AssistantAction.importVideo),
            ("show_videos", "Delete an older video", AssistantAction.showVideos)
        ] {
            model.json = "{\"action\":\"\(action)\",\"argument\":\"\(question)\",\"reply\":\"Already done\",\"reading_mode\":\"medicine\"}"
            let decision = try await AgentCoordinator.decide(message: question, history: [], context: normal, model: model)
            check(decision.action == expected && decision.reply.isEmpty && decision.readingMode == .text,
                  "New activity actions must leave actual completion and spoken outcome to handlers")
        }
        for removed in ["read", "imagine", "remember", "describe", "describe_last", "retry_capture", "set_room"] {
            model.json = "{\"action\":\"\(removed)\",\"argument\":\"\",\"reply\":\"\",\"reading_mode\":\"text\"}"
            let decision = try await AgentCoordinator.decide(message: "Help me with a feature", history: [], context: normal, model: model)
            check(decision.action == .chat, "Removed capture/reading/imagination actions must not dispatch")
        }
        let schema = try JSONSerialization.jsonObject(with: Data(AgentCoordinator.schema.utf8)) as! [String: Any]
        let properties = schema["properties"] as! [String: Any]
        let actionSchema = properties["action"] as! [String: Any]
        let actions = actionSchema["enum"] as! [String]
        check(!actions.contains("read") && !actions.contains("imagine"), "Removed features must not be offered to E4B")
        check(["recall", "timeline", "medicine_log", "reminders"].allSatisfy(actions.contains))
        model.json = #"{"action":"chat","argument":"","reply":"Hello. How can I help?","reading_mode":"text"}"#
        let greeting = try await AgentCoordinator.decide(message: "Hello", history: [], context: normal, model: model)
        check(greeting.action == .chat && !greeting.reply.isEmpty, "Free conversation remains available")
        print("\(checkCount) coordinator and room-classifier boundary checks passed; model inference was stubbed.")
        print("Typical system prompt bytes: \(model.lastSystem.utf8.count)")
    }
}
