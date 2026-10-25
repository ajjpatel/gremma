import Foundation

/// Conservative shortcuts for common requests. Everything else remains a conversation.
enum ActivityFastRequest: Equatable {
    case record, upload, videos, timeline, medicine, reminders, devices, help
    case recall(String)
}

enum ActivityFastRouter {
    static func route(_ message: String) -> ActivityFastRequest? {
        var text = message.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "where's", with: "where is")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        for prefix in ["hey gremma ", "hey gemma ", "gremma ", "gemma ", "can you ", "could you ", "please "] {
            if text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        }
        if message.contains("\"") || message.contains("“") { return nil }
        if text.range(of: #"\b(don t|do not|never|example|suppose|pretend|if)\b"#, options: .regularExpression) != nil { return nil }
        if ["hello", "hi", "help", "what can you do", "what can you help me with", "how does this work"].contains(text) { return .help }
        if ["record", "record a video", "record this", "record this room", "record a room", "record an activity", "record this activity", "record a conversation", "record this conversation", "start recording", "i want to record a video"].contains(text) { return .record }
        if ["upload a video", "upload video", "import a video", "import video", "upload an existing video", "import a recorded video"].contains(text) { return .upload }
        if ["videos", "my videos", "show videos", "show my videos", "delete a video", "manage videos", "open videos"].contains(text) { return .videos }
        if ["show today", "today s activities", "what did i do today", "what happened today", "show my activities", "show my timeline", "daily summary"].contains(text) { return .timeline }
        if ["reminders", "show reminders", "set up reminders", "enable reminders", "medicine reminders", "turn on reminders"].contains(text) { return .reminders }
        if ["home devices", "connect ventuno q", "connect the board", "connect raspberry pi", "connect a camera", "video api", "open the api", "upload api"].contains(text) { return .devices }
        let videoQuestion = text.range(of: #"^(?:what happened|what did|what activit(?:y|ies)|what is happening|describe|summarize|tell me about|show me)\b"#, options: .regularExpression) != nil
        let videoReference = text.range(of: #"\b(?:demo|demos|sample|saved|recorded|uploaded|this|that)\b.*\b(?:videos?|clips?|footage)\b|\b(?:videos?|clips?) (?:number )?(?:[0-9]+|one|two|three|four|five|six|seven|eight|nine|ten)\b|\bin the (?:video|clip)\b"#, options: .regularExpression) != nil
        if videoQuestion && videoReference { return .recall(message) }
        if ["show all history", "show all activities", "what happened in all history"].contains(text) { return .recall(message) }
        let hasMedicine = text.range(of: #"\b(?:medicine|medication|pills?)\b"#, options: .regularExpression) != nil
        let asksForLog = text.range(of: #"\b(?:log|logged|video|recorded|morning|evening)\b"#, options: .regularExpression) != nil
        let asksAboutTaking = text.range(of: #"^(?:did i|have i) (?:already )?(?:take|taken|record|recorded|log|logged)\b"#, options: .regularExpression) != nil
        if hasMedicine && (asksForLog || asksAboutTaking) { return .medicine }
        if text.range(of: #"^(?:where (?:is|are|did i (?:put|leave|place)) (?:my|the)|find my|when did i|what did (?:i|we|they|he|she)|what happened yesterday|what was (?:said|discussed)|what did we talk about|search (?:my )?(?:activities|conversations))\b"#, options: .regularExpression) != nil {
            return .recall(message)
        }
        if text.range(of: #"^(?:have you seen|help me find|i (?:can t|cannot) find|did i (?:eat|have breakfast|have lunch|have dinner)|have i (?:eaten|had breakfast|had lunch|had dinner)|was i eating|what was i eating)\b"#, options: .regularExpression) != nil {
            return .recall(message)
        }
        return nil
    }
}
