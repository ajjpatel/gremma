import Foundation

@main struct ActivityFastRouterChecks {
    static func main() {
        var count = 0
        var failures = [String]()
        func check(_ message: String, _ expected: ActivityFastRequest?) {
            count += 1
            let actual = ActivityFastRouter.route(message)
            if actual != expected { failures.append("\(message): expected \(String(describing: expected)); got \(String(describing: actual))") }
        }
        for message in ["Record a video", "Record an activity", "Start recording", "Can you please record this room", "Hey Gremma, record a conversation"] { check(message, .record) }
        for message in ["Upload a video", "Import a recorded video", "Please upload an existing video"] { check(message, .upload) }
        for message in ["Show my videos", "Delete a video", "Manage videos"] { check(message, .videos) }
        for message in ["What did I do today?", "What happened today?", "Show my timeline", "Daily summary"] { check(message, .timeline) }
        for message in ["Where are my keys?", "Where’s my wallet?", "Where did I put the glasses?", "What did we talk about?", "What happened yesterday?", "What was discussed?", "When did I put my keys down?"] { check(message, .recall(message)) }
        for message in ["What happened in a demo video?", "What happened in demo clip one?", "What did they do in demo clip 2?", "Describe the saved videos", "What activity happened in the video?", "Show all history", "Show all activities"] { check(message, .recall(message)) }
        for message in ["Did I take my medicine this morning?", "Is there a medicine-taking video today?", "Show my medicine log", "Have I taken medication tonight?"] { check(message, .medicine) }
        for message in ["Show reminders", "Medicine reminders", "Turn on reminders"] { check(message, .reminders) }
        check("Connect Ventuno Q", .devices)
        for message in ["Hello", "What can you help me with?"] { check(message, .help) }
        for message in ["Don't record a video", "Do not upload a video", "Never delete a video", "Suppose I record a video", "If I record a video what happens?", "Say \"record a video\"", "Explain the example: record a video", "I recorded a video yesterday", "What does record a video mean?", "Please read this label", "Imagine the Taj Mahal", "What makes a rainbow?", "I think my keys are gone", "Stop", "Repeat that"] { check(message, nil) }
        for message in ["Have you seen my wallet?", "Help me find my glasses", "I can't find my wallet", "Did I eat?", "Have I eaten?", "Did I have breakfast?", "Where is the TV remote?"] { check(message, .recall(message)) }
        // Medical questions must remain conversation, not silently become log queries.
        for message in ["Is there medicine for headaches?", "What about medicine side effects?", "Did I say the word medicine?", "Check medicine interactions"] { check(message, nil) }
        for message in ["Stop", "Stop now", "Cancel", "Stop talking"] {
            count += 1
            if VoiceCommandRouter.route(command: message) != .stop { failures.append("Stop control lost: \(message)") }
        }
        for message in ["Repeat", "Say that again"] {
            count += 1
            if VoiceCommandRouter.route(command: message) != .repeat { failures.append("Repeat control lost: \(message)") }
        }
        if !failures.isEmpty {
            failures.forEach { print("FAIL: \($0)") }
            print("\(failures.count) failures across \(count) activity fast-routing checks")
            exit(1)
        }
        print("\(count) activity fast-routing and stop/repeat checks passed; no model was used.")
    }
}
