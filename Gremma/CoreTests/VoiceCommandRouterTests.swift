import XCTest
@testable import GremmaCore

final class VoiceCommandRouterTests: XCTestCase {
    private func assertRoutes(_ phrases: [String], to expected: VoiceIntent,
                              context: VoiceCommandContext = .normal,
                              file: StaticString = #filePath, line: UInt = #line) {
        for phrase in phrases {
            XCTAssertEqual(VoiceCommandRouter.route(command: phrase, context: context), expected, phrase, file: file, line: line)
        }
    }

    private func assertChats(_ phrases: [String], context: VoiceCommandContext = .normal,
                             file: StaticString = #filePath, line: UInt = #line) {
        for phrase in phrases {
            XCTAssertEqual(VoiceCommandRouter.route(command: phrase, context: context), .chat(message: phrase), phrase, file: file, line: line)
        }
    }

    func testGreetingAndOrdinaryConversationGoToModel() {
        assertChats(["Hello", "Hi", "Hey Gremma", "Hello Astro!", "Good morning", "How are you?",
                     "What is the capital of India?", "What can we make with bread?", "Imagine a blue dragon"])
    }

    func testPoliteMedicineRequestIsNotGenericHelp() {
        assertRoutes(["Can you help me read this medicine label?", "Hey Gremma, could you please read my medication label?",
                      "Astro, please reed this prescription label", "Read medicine", "What medicine is this?"], to: .read(.medicine))
    }

    func testNaturalTextRequestsAndASRReadHomophone() {
        assertRoutes(["Read this", "Please reed this", "Could you read the sign for me?", "What does this say?",
                      "Tell me what that says", "Read this food label", "Can you scan this text?"], to: .read(.text))
    }

    func testExpiryTakesPrecedenceOverMedicine() {
        assertRoutes(["Is this expired?", "Check the expiration date", "Read the expiry on this medicine label",
                      "When does this expire?", "expiry"], to: .read(.expiry))
    }

    func testCurrencyVariants() {
        assertRoutes(["Read dollars", "Read this money", "How much cash is this?", "What currency is this?",
                      "Identify this banknote", "cash", "money"], to: .read(.currency))
        assertChats(["How can I earn money?", "What is money?", "The cash machine is broken"])
    }

    func testNaturalSceneRequests() {
        assertRoutes(["What is this?", "What am I looking at?", "What's in front of me?", "Describe my surroundings",
                      "Can you describe the scene?", "Look at this", "Can you see what this is?"], to: .describe)
    }

    func testCameraPictureIsNotLandmarkImagination() {
        assertRoutes(["Take a picture", "Can you take a photo?", "Take a picture of the Taj Mahal",
                      "Capture this photo", "Please snap a photograph"], to: .rememberPhoto)
    }

    func testRememberLocationDoesNotBecomeFind() {
        assertRoutes(["Remember this", "Remember where I put my keys", "Please remember where I left my wallet",
                      "Remember the red mug", "Can you remember my glasses?"], to: .rememberPhoto)
    }

    func testFindExtractsObjectWithoutPutVerb() {
        assertRoutes(["Where did I put my keys?", "Where are my keys?", "Hey Gremma, can you help me find my keys?",
                      "Tell me where I left my keys, please"], to: .find(query: "my keys"))
        assertRoutes(["Where did we leave the blue mug in the kitchen?"], to: .find(query: "the blue mug in the kitchen"))
    }

    func testNamedLandmarkLocationUsesFactPack() {
        let question = "Where is the Taj Mahal?"
        XCTAssertEqual(VoiceCommandRouter.route(command: question), .imagine(question: question))
        let picture = "Can you help me picture the Taj Mahal?"
        XCTAssertEqual(VoiceCommandRouter.route(command: picture), .imagine(question: picture))
    }

    func testLandmarkFollowUpsAreContextualAndDoNotStealPersonalItems() {
        for phrase in ["Where is it?", "How tall is it?", "Tell me about the towers", "Tell me more"] {
            XCTAssertEqual(VoiceCommandRouter.route(command: phrase, context: .imagine), .imagine(question: phrase))
        }
        assertRoutes(["Where are my keys?"], to: .find(query: "my keys"), context: .imagine)
        assertChats(["What time is it?", "How are you?"], context: .imagine)
    }

    func testWholeWordsPreventIncidentalOrDestructiveActions() {
        assertChats(["bread", "stopwatch", "I have a stopwatch", "I remember my childhood", "remember to call Mom",
                     "Please remind me to take medicine", "Do not take a picture", "Don't stop", "Delete all my memories",
                     "The room is cold", "Tell me about machine learning"])
    }

    func testStopRepeatAndHelpAreExplicit() {
        assertRoutes(["Stop", "Please stop", "Hey Astro, stop talking", "Cancel that", "Never mind", "That's enough"], to: .stop)
        assertRoutes(["Repeat", "Please say that again", "Can you repeat the last answer?", "What did you say?"], to: .repeat)
        assertRoutes(["Help", "Help me", "What can you do?", "What can I say?"], to: .help)
        assertChats(["I repeat this exercise daily", "I need help with algebra"])
    }

    func testRetryAndDescribeRetainedPhoto() {
        assertRoutes(["Try again", "Please retry", "Retry that photo", "Try the photo again"], to: .retryCapture)
        assertRoutes(["Describe it", "Describe that photo", "Describe the last picture"], to: .describeLastCapture)
    }

    func testVideoAndExplicitMemoryChoice() {
        assertRoutes(["Record a room", "Record this room", "Record a video", "Can you film my room?"], to: .recordVideo)
        guard case .clarify(_, .awaitingMemoryChoice) = VoiceCommandRouter.route(command: "Remember this room") else {
            return XCTFail("Ask which capture type instead of choosing silently")
        }
        assertRoutes(["photo", "a picture"], to: .rememberPhoto, context: .awaitingMemoryChoice)
        assertRoutes(["video", "room video"], to: .recordVideo, context: .awaitingMemoryChoice)
        assertRoutes(["cancel"], to: .stop, context: .awaitingMemoryChoice)
        assertChats(["How are you?"], context: .awaitingMemoryChoice)
    }

    func testRoomNamesAndRoomFollowUp() {
        assertRoutes(["Room is kitchen", "Please set the room to kitchen", "I'm in the kitchen"], to: .setRoom(name: "kitchen"))
        assertRoutes(["Room name is guest bedroom"], to: .setRoom(name: "guest bedroom"))
        guard case .clarify(_, .awaitingRoom) = VoiceCommandRouter.route(command: "Set room") else { return XCTFail("Ask for a room name") }
        assertRoutes(["kitchen", "in the kitchen"], to: .setRoom(name: "kitchen"), context: .awaitingRoom)
        assertRoutes(["Where are my keys?"], to: .find(query: "my keys"), context: .awaitingRoom)
        assertChats(["I love you", "What is the weather?"], context: .awaitingRoom)
    }

    func testMissingFindArgumentAsksForItem() {
        for phrase in ["find", "find my", "where is it"] {
            guard case .clarify(_, .normal) = VoiceCommandRouter.route(command: phrase) else {
                XCTFail("Missing item name should be clarified: \(phrase)"); continue
            }
        }
    }
}
