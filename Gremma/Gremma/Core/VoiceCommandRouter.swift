import Foundation

/// The controller owns conversational state; parsing never starts a camera or changes data.
public enum VoiceCommandContext: Equatable, Sendable {
    case normal, imagine, awaitingMemoryChoice, awaitingRoom
}

public enum VoiceIntent: Equatable, Sendable {
    case stop, `repeat`, help
    case rememberPhoto, recordVideo, describe, retryCapture, describeLastCapture
    case read(ReadingMode)
    case find(query: String)
    case imagine(question: String)
    case chat(message: String)
    case setRoom(name: String)
    case clarify(prompt: String, context: VoiceCommandContext)
}

/// Bounded, explainable command grammar. Whole words and anchored phrases avoid actions
/// caused by incidental substrings (for example, "bread", "stopwatch", or "remember to call").
public enum VoiceCommandRouter {
    public static func route(command: String, context: VoiceCommandContext = .normal) -> VoiceIntent {
        let value = normalizedCommand(command)
        let words = Set(value.split(separator: " ").map(String.init))

        if ["stop", "stop now", "stop talking", "stop speaking", "stop listening", "stop everything",
            "cancel", "cancel that", "cancel it", "never mind", "nevermind", "that is enough"].contains(value) {
            return .stop
        }
        if ["repeat", "repeat that", "repeat it", "repeat the last answer", "say that again",
            "say it again", "say that one more time", "again", "what did you say"].contains(value) {
            return .repeat
        }
        if ["retry", "retry that", "retry the photo", "retry that photo", "retry this photo",
            "try again", "try that again", "try the photo again", "try that photo again"].contains(value) {
            return .retryCapture
        }
        if ["describe it", "describe that", "describe that photo", "describe this photo",
            "describe the photo", "describe the last photo", "describe the last picture"].contains(value) {
            return .describeLastCapture
        }
        if ["help", "help me", "what can you do", "what can i say", "show commands",
            "show me the commands", "how do i use this", "how does this work"].contains(value) {
            return .help
        }

        // Negation and requests for reminders must not accidentally open the camera.
        if matches(value, #"\b(?:do not|don t|dont|not|never)\b"#) {
            return .chat(message: command)
        }
        if matches(value, #"^(?:remember to|remind me|set (?:a |an )?reminder)\b"#) {
            return .chat(message: command)
        }

        if let room = capture(value, #"^(?:room (?:name )?is|set (?:the |my )?room(?: name)? to|change (?:the |my )?room(?: name)? to|i am in|we are in) (.+)$"#) {
            return roomIntent(room)
        }
        if ["room", "room name", "set room", "set the room", "change room", "change the room",
            "set room name", "room is", "room name is"].contains(value) {
            return .clarify(prompt: "What room should I use? For example, say kitchen or living room.", context: .awaitingRoom)
        }

        if context == .awaitingMemoryChoice {
            if ["photo", "a photo", "picture", "a picture", "one photo", "one picture"].contains(value) { return .rememberPhoto }
            if ["video", "a video", "room video", "a room video", "the whole room"].contains(value) { return .recordVideo }
        }

        // Explicit camera actions outrank the word "picture" and named landmarks.
        if matches(value, #"^(?:take|capture|snap|save) (?:me )?(?:a |the |this |that )?(?:photo|photograph|picture)\b"#) {
            return .rememberPhoto
        }
        if matches(value, #"^(?:record|film|capture|take) (?:me )?(?:a |the |this |my )?(?:room(?: video)?|video)\b"#)
            || matches(value, #"^remember (?:the |this |my )?room (?:with|using|in) (?:a )?video$"#) {
            return .recordVideo
        }
        if ["remember", "remember room", "remember the room", "remember this room", "save this room"].contains(value) {
            return .clarify(prompt: "Would you like a photo of an item or a video of the room? Say photo or video.", context: .awaitingMemoryChoice)
        }
        if matches(value, #"^remember (?:where (?:i|we) (?:put|left|placed)|this|that|these|my|the|a|an)\b"#)
            || matches(value, #"^save (?:this|that) (?:location|item|object|memory)$"#) {
            return .rememberPhoto
        }

        // Taj Mahal has a bundled fact pack. Resolve it before generic location questions.
        if matches(value, #"\btaj (?:mahal|ma hall)\b"#) { return .imagine(question: command.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if context == .imagine && isLandmarkFollowUp(value) {
            return .imagine(question: command.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let query = capture(value, #"^(?:tell me )?(?:find|locate|look for|search for|search my memories for|where (?:did (?:i|we) (?:put|leave|place)|(?:i|we) (?:put|left|placed)|have i put|is|are|was|were|can i find)) (.+)$"#) {
            guard !["it", "that", "this", "them", "my", "the"].contains(query) else {
                return .clarify(prompt: "Which saved item should I look for? Say find, followed by its name, such as find my keys.", context: .normal)
            }
            return .find(query: query)
        }
        if ["find", "find my", "find an item", "where is", "where are"].contains(value) {
            return .clarify(prompt: "Which saved item should I look for? For example, say find my keys.", context: .normal)
        }

        let isReadRequest = matches(value, #"^(?:read|reed|scan|read out|read aloud)\b"#)
            || ["what does this say", "what does that say", "tell me what this says", "tell me what that says",
                "what is written here"].contains(value)
        let isExpiryRequest = matches(value, #"^(?:expiry|expiration|expiry date|expiration date|expired)$"#)
            || (hasAny(words, ["expired", "expiry", "expiration", "expire", "expires"])
                && matches(value, #"^(?:check|is this|is that|has this|has that|when does|what is|what s|tell me)\b"#))
        let isCurrencyRequest = ["money", "cash", "currency", "dollars"].contains(value)
            || (hasAny(words, ["money", "cash", "currency", "dollars", "dollar", "banknote", "bill"])
                && matches(value, #"^(?:identify|check|count|how much|what (?:is|s) (?:this|that)|what (?:money|cash|currency|bill|banknote)|tell me (?:what|how much))\b"#))
        let isMedicineRequest = ["medicine", "medicine label", "medication label"].contains(value)
            || matches(value, #"^(?:what (?:medicine|medication|pill) is (?:this|that)|identify (?:this|that|the) (?:medicine|medication)|what is (?:this|that) (?:medicine|medication))\b"#)
        if isReadRequest || isExpiryRequest || isCurrencyRequest || isMedicineRequest {
            if isExpiryRequest || hasAny(words, ["expired", "expiry", "expiration", "expire", "expires"]) { return .read(.expiry) }
            if isCurrencyRequest || hasAny(words, ["money", "cash", "currency", "dollars", "dollar", "banknote"]) { return .read(.currency) }
            if isMedicineRequest || hasAny(words, ["medicine", "medication", "prescription", "pill", "pills"]) { return .read(.medicine) }
            return .read(.text)
        }

        if ["describe", "describe this", "describe the scene", "describe this scene", "describe the room",
            "describe my surroundings", "look at this", "what is this", "what s this", "what is that",
            "what am i looking at", "see what this is", "what do you see", "what can you see", "what is in front of me",
            "what s in front of me", "what is around me", "what is here", "what is on the table"].contains(value) {
            return .describe
        }
        if context == .awaitingRoom,
           matches(value, #"\b(?:kitchen|bedroom|bathroom|office|garage|hallway|living room|dining room|study|lounge|guest room|basement|attic|balcony|patio|workshop|studio)\b"#),
           isPlausibleRoomName(value) { return roomIntent(value) }
        if context == .awaitingMemoryChoice, ["yes", "sure", "okay", "ok", "both", "which one"].contains(value) {
            return .clarify(prompt: "Say photo to save an item's location, or video to record the room. You can also say cancel.", context: .awaitingMemoryChoice)
        }
        return .chat(message: command)
    }

    private static func normalizedCommand(_ command: String) -> String {
        var value = command.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
        for (from, to) in [("i'm", "i am"), ("what's", "what is"), ("that's", "that is"), ("don't", "do not")] {
            value = value.replacingOccurrences(of: from, with: to)
        }
        value = value.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        // Remove only leading courtesies; never erase words from the requested object.
        let prefixes = ["can you please help me", "could you please help me", "would you please help me",
                        "can you help me", "could you help me", "would you help me", "i would like you to",
                        "i want you to", "can you please", "could you please", "would you please",
                        "can you", "could you", "would you", "will you", "help me", "please", "hey", "hello",
                        "hi", "okay", "ok", "gremma", "gemma", "aster", "astro"]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where (value == prefix && ["hey", "hello", "hi", "okay", "ok", "gremma", "gemma", "aster", "astro", "please"].contains(prefix)) || value.hasPrefix(prefix + " ") {
                value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        for suffix in [" please", " thanks", " thank you"] where value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        return value
    }

    private static func roomIntent(_ value: String) -> VoiceIntent {
        var room = value
        for prefix in ["in the ", "in ", "the ", "my "] where room.hasPrefix(prefix) { room.removeFirst(prefix.count) }
        guard isPlausibleRoomName(room) else {
            return .clarify(prompt: "Say a short room name, such as kitchen or living room.", context: .awaitingRoom)
        }
        return .setRoom(name: room)
    }

    private static func isPlausibleRoomName(_ value: String) -> Bool {
        let words = value.split(separator: " ")
        guard !words.isEmpty, words.count <= 6, value.count <= 64 else { return false }
        let forbidden: Set<String> = ["what", "where", "why", "how", "who", "when", "read", "reed", "find", "remember",
                                      "describe", "stop", "cancel", "delete", "erase", "call", "weather", "help", "yes", "no"]
        return words.allSatisfy { !forbidden.contains(String($0)) }
    }

    private static func isLandmarkFollowUp(_ value: String) -> Bool {
        if ["tell me more", "go on", "continue", "give me a walkthrough", "give me a mental walkthrough",
            "where is it", "where is it located", "what does it look like", "how tall is it", "who built it"].contains(value) { return true }
        return matches(value, #"^(?:what|where|how|why|who|tell me|describe)\b"#)
            && matches(value, #"\b(?:dome|towers|tower|minarets|minaret|garden|gardens|marble|mausoleum|tomb|building)\b"#)
    }

    private static func hasAny(_ words: Set<String>, _ candidates: Set<String>) -> Bool { !words.isDisjoint(with: candidates) }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func capture(_ value: String, _ pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}
