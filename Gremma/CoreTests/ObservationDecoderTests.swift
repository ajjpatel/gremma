import XCTest
@testable import GremmaCore

final class ObservationDecoderTests: XCTestCase {
    func testFencedAnswerWithPreambleAndTrailingText() throws {
        let raw = """
        Here are the visible items:
        ```json
        {"items": [{"name": " black keys ", "location": " on the wooden table "}]}
        ```
        These are the objects I can identify.
        """
        XCTAssertEqual(try ObservationDecoder.decode(raw), [ObservationCandidate(name: "black keys", location: "on the wooden table")])
    }

    func testNestedExtrasAndBracesInsideStrings() throws {
        let raw = #"{"items":[{"name":"red mug","location":"beside the box marked {A}","extra":{"tags":["visible", {"note":"[not a delimiter]"}]}}],"metadata":{"note":"finished"}}"#
        XCTAssertEqual(try ObservationDecoder.decode(raw), [ObservationCandidate(name: "red mug", location: "beside the box marked {A}")])
    }

    func testEscapedQuotesAndBackslashesRemainLiteral() throws {
        let raw = #"{"items":[{"name":"book labeled \"Home\"","location":"beside the sign C:\\room"}]}"#
        XCTAssertEqual(try ObservationDecoder.decode(raw), [ObservationCandidate(name: "book labeled \"Home\"", location: "beside the sign C:\\room")])
    }

    func testDeliberatelySupportedArrayAndSingleObject() throws {
        let expected = [ObservationCandidate(name: "keys", location: "on the desk")]
        XCTAssertEqual(try ObservationDecoder.decode(#"[{"name":"keys","location":"on the desk"}]"#), expected)
        XCTAssertEqual(try ObservationDecoder.decode(#"{"name":"keys","location":"on the desk"}"#), expected)
    }

    func testEmptyItemsAreAValidNoObservationResult() throws {
        XCTAssertEqual(try ObservationDecoder.decode(#"{"items":[]}"#), [])
        XCTAssertEqual(try ObservationDecoder.decode("[]"), [])
    }

    func testMultipleSeparateAnswersAreNotMergedOrChosen() {
        let raw = #"{"items":[]} Then {"items":[{"name":"keys","location":"on desk"}]}"#
        XCTAssertThrowsError(try ObservationDecoder.decode(raw)) { XCTAssertEqual($0 as? ObservationDecodeError, .multipleJSONValues) }
    }

    func testTruncatedEnvelopeDoesNotSalvageNestedCompleteItem() {
        let raw = #"{"items":[{"name":"keys","location":"on desk"}"#
        XCTAssertThrowsError(try ObservationDecoder.decode(raw)) { XCTAssertEqual($0 as? ObservationDecodeError, .incompleteJSON) }
        XCTAssertThrowsError(try ObservationDecoder.decode(#"{"items":[{"name":"keys","location":"on"#))
    }

    func testMalformedJSONIsNotRepaired() {
        XCTAssertThrowsError(try ObservationDecoder.decode(#"{"items":[{"name":"keys", "location":"on desk",}]}"#)) {
            XCTAssertEqual($0 as? ObservationDecodeError, .malformedJSON)
        }
        XCTAssertThrowsError(try ObservationDecoder.decode(#"{"items":[{"name":"keys","location":"on desk"}]}]"#))
    }

    func testProseAndWrongShapesDoNotBecomeSavedFacts() {
        XCTAssertThrowsError(try ObservationDecoder.decode("The keys are on the table.")) {
            XCTAssertEqual($0 as? ObservationDecodeError, .noJSON)
        }
        for raw in [#"{"description":"keys on a table"}"#, #"{"items":null}"#, #"{"items":"keys"}"#,
                    #"{"items":[{"object":"keys","position":"desk"}]}"#, #"{"items":[{"name":"keys","location":42}]}"#] {
            XCTAssertThrowsError(try ObservationDecoder.decode(raw))
        }
    }

    func testAnyInvalidItemRejectsWholeAnswer() {
        let raw = #"{"items":[{"name":"keys","location":"on desk"},{"name":"mug","location":"  "}]}"#
        XCTAssertThrowsError(try ObservationDecoder.decode(raw))
        XCTAssertThrowsError(try ObservationDecoder.decode(#"{"items":[{"name":"...","location":"on desk"}]}"#))
    }

    func testNameAndLocationLengthLimits() throws {
        for item in [["name": String(repeating: "a", count: 101), "location": "on desk"],
                     ["name": "keys", "location": String(repeating: "b", count: 401)]] {
            let data = try JSONSerialization.data(withJSONObject: ["items": [item]])
            XCTAssertThrowsError(try ObservationDecoder.decode(String(decoding: data, as: UTF8.self)))
        }
    }

    func testItemLimitAndNormalizedDeduplication() throws {
        let raw = #"{"items":[{"name":"Keys","location":"on desk"},{"name":"key","location":"ON  DESK"}]}"#
        XCTAssertEqual(try ObservationDecoder.decode(raw), [ObservationCandidate(name: "Keys", location: "on desk")])
        let many = (1...6).map { ["name": "item \($0)", "location": "on desk"] }
        let data = try JSONSerialization.data(withJSONObject: ["items": many])
        XCTAssertThrowsError(try ObservationDecoder.decode(String(decoding: data, as: UTF8.self))) {
            XCTAssertEqual($0 as? ObservationDecodeError, .tooManyItems)
        }
    }

    func testConflictingDuplicateNamesDoNotChooseOneLocation() {
        let raw = #"{"items":[{"name":"keys","location":"on desk"},{"name":"keys","location":"on chair"}]}"#
        XCTAssertThrowsError(try ObservationDecoder.decode(raw)) { XCTAssertEqual($0 as? ObservationDecodeError, .conflictingDuplicate) }
    }

    func testOptInPreservesAllReportedPositionsForLaterGrounding() throws {
        let raw = #"{"items":[{"name":"chair","location":"on left"},{"name":"chair","location":"on right"}]}"#
        XCTAssertEqual(try ObservationDecoder.decode(raw, preservingDistinctLocations: true), [
            ObservationCandidate(name: "chair", location: "on left"),
            ObservationCandidate(name: "chair", location: "on right")
        ])
        XCTAssertThrowsError(try ObservationDecoder.decode(raw)) { XCTAssertEqual($0 as? ObservationDecodeError, .conflictingDuplicate) }
    }

    func testOptInCannotHideUnsupportedNormalizedDuplicateBeforeGrounding() throws {
        let raw = #"{"items":[{"name":"chair","location":"on left"},{"name":"the chair","location":"on left"}]}"#
        let entries = try ObservationDecoder.decode(raw, preservingDistinctLocations: true)
        XCTAssertEqual(entries.count, 2, "Every raw entry must reach grounding before duplicates collapse")
        XCTAssertThrowsError(try ObservationDescriptionGrounding.validate(entries, description: "A chair is on left.")) {
            XCTAssertEqual($0 as? ObservationGroundingError, .nameNotInDescription(index: 1))
        }
    }

    func testOptInStillRequiresCompleteValidShape() throws {
        XCTAssertThrowsError(try ObservationDecoder.decode(#"{"items":[{"name":"chair","location":"on left"}"#, preservingDistinctLocations: true)) {
            XCTAssertEqual($0 as? ObservationDecodeError, .incompleteJSON)
        }
        let raw = #"{"items":[{"name":"chair","location":"on left"},{"name":"chair","location":""}]}"#
        XCTAssertThrowsError(try ObservationDecoder.decode(raw, preservingDistinctLocations: true))
    }

    func testActualDeviceBlankResponseIsExplicitlyExcluded() throws {
        let raw = #"{"items":[{"name":"White background","location":"entire image"}]}"#
        let decoded = try ObservationDecoder.decode(raw)
        XCTAssertEqual(decoded.count, 1, "Parsing remains faithful to the model's output")
        let selection = ObservationContentFilter.select(decoded)
        XCTAssertTrue(selection.items.isEmpty)
        XCTAssertEqual(selection.excludedBackgroundItems, decoded)
    }

    func testBackgroundExclusionPreservesValidObjectsAndExactText() throws {
        let raw = #"{"items":[{"name":"White background","location":"entire image"},{"name":"Red mug","location":"on the table"}]}"#
        let selection = ObservationContentFilter.select(try ObservationDecoder.decode(raw))
        XCTAssertEqual(selection.items, [ObservationCandidate(name: "Red mug", location: "on the table")])
        XCTAssertEqual(selection.excludedBackgroundItems.count, 1)
    }

    func testConcreteWhiteObjectsAndPhysicalSurfacesAreNotBackgroundAbstractions() {
        let names = ["white paper", "whiteboard", "white wall", "picture frame", "wallpaper roll",
                     "roll of wallpaper", "photograph of a dog", "background lamp", "blank canvas",
                     "photograph", "picture", "photo", "black photo"]
        let candidates = names.map { ObservationCandidate(name: $0, location: "center of the image") }
        let selection = ObservationContentFilter.select(candidates)
        XCTAssertEqual(selection.items, candidates)
        XCTAssertTrue(selection.excludedBackgroundItems.isEmpty)
    }

    func testOnlySimpleBackgroundNamesAreExcluded() {
        let names = ["background", "plain white background", "a solid black image", "featureless photo", "blank wallpaper"]
        let candidates = names.map { ObservationCandidate(name: $0, location: "entire image") }
        let selection = ObservationContentFilter.select(candidates)
        XCTAssertTrue(selection.items.isEmpty)
        XCTAssertEqual(selection.excludedBackgroundItems, candidates)
    }

    func testMalformedBackgroundItemStillFailsBeforeContentFiltering() {
        XCTAssertThrowsError(try ObservationDecoder.decode(#"{"items":[{"name":"White background"}]}"#))
    }

    func testDescriptionGroundingPreservesLiteralMugAndGoldKey() {
        let description = "A red mug is on the left side of the image. A gold key is on the right. Both are above a brown surface."
        let candidates = [ObservationCandidate(name: "red mug", location: "on the left side of the image"),
                          ObservationCandidate(name: "gold key", location: "on the right")]
        XCTAssertNoThrow(try ObservationDescriptionGrounding.validate(candidates, description: description))
        XCTAssertEqual(candidates[1].name, "gold key", "Grounding must not rewrite model evidence")
    }

    func testDescriptionGroundingRejectsInventedCenterForVisibleSurface() {
        let description = "A red mug is on the left. A gold key is on the right. Both are above a brown surface."
        let candidates = [ObservationCandidate(name: "red mug", location: "on the left"),
                          ObservationCandidate(name: "brown surface", location: "in the center")]
        XCTAssertThrowsError(try ObservationDescriptionGrounding.validate(candidates, description: description)) {
            XCTAssertEqual($0 as? ObservationGroundingError, .locationNotInDescription(index: 1))
        }
    }

    func testDescriptionGroundingNormalizesCaseWhitespaceAndOuterPunctuation() {
        let description = "A GOLD\n\tKEY is on\u{00a0}the right."
        let candidate = ObservationCandidate(name: "  ‘gold  key’  ", location: "`ON\nTHE   RIGHT.`")
        XCTAssertNoThrow(try ObservationDescriptionGrounding.validate([candidate], description: description))
    }

    func testDescriptionGroundingDoesNotMatchInsideOtherWords() {
        XCTAssertThrowsError(try ObservationDescriptionGrounding.validate([ObservationCandidate(name: "mug", location: "near London")], description: "A smuggler is near London.")) {
            XCTAssertEqual($0 as? ObservationGroundingError, .nameNotInDescription(index: 0))
        }
        XCTAssertThrowsError(try ObservationDescriptionGrounding.validate([ObservationCandidate(name: "mug", location: "on")], description: "A mug from London.")) {
            XCTAssertEqual($0 as? ObservationGroundingError, .locationNotInDescription(index: 0))
        }
        XCTAssertThrowsError(try ObservationDescriptionGrounding.validate([ObservationCandidate(name: "key", location: "on the desk")], description: "A keychain is on the desk."))
    }

    func testDescriptionGroundingDoesNotStemParaphraseOrJoinSeparateSpans() {
        let description = "A gold key is beside the lamp. There is a blue mug elsewhere."
        for candidate in [ObservationCandidate(name: "golden key", location: "beside the lamp"),
                          ObservationCandidate(name: "gold key", location: "next to the lamp"),
                          ObservationCandidate(name: "gold key", location: "beside the blue mug"),
                          ObservationCandidate(name: "gold keys", location: "beside the lamp")] {
            XCTAssertThrowsError(try ObservationDescriptionGrounding.validate([candidate], description: description))
        }
    }

    func testDescriptionGroundingPreservesInteriorPunctuationAndAccents() {
        let description = "The café cup (red) is on shelf A-1."
        XCTAssertNoThrow(try ObservationDescriptionGrounding.validate([ObservationCandidate(name: "café cup (red)", location: "on shelf A-1")], description: description))
        XCTAssertThrowsError(try ObservationDescriptionGrounding.validate([ObservationCandidate(name: "cafe cup", location: "on shelf A-1")], description: description))
        XCTAssertThrowsError(try ObservationDescriptionGrounding.validate([ObservationCandidate(name: "café cup", location: "on shelf A 1")], description: description))
    }

    func testDescriptionGroundingEscapesRegexAndAcceptsLaterWholeWordMatch() {
        let description = "A keychain is beside a key. The sign A+B is near the key."
        XCTAssertNoThrow(try ObservationDescriptionGrounding.validate([ObservationCandidate(name: "key", location: "beside a key")], description: description))
        XCTAssertNoThrow(try ObservationDescriptionGrounding.validate([ObservationCandidate(name: "A+B", location: "near the key")], description: description))
        XCTAssertThrowsError(try ObservationDescriptionGrounding.validate([ObservationCandidate(name: "A.B", location: "near the key")], description: description))
    }

    func testDescriptionGroundingEmptyCandidatesRemainValid() {
        XCTAssertNoThrow(try ObservationDescriptionGrounding.validate([], description: ""))
        XCTAssertNoThrow(try ObservationDescriptionGrounding.validate([], description: "A plain white background."))
        XCTAssertThrowsError(try ObservationDescriptionGrounding.validate([ObservationCandidate(name: "mug", location: "left")], description: " \n\t")) {
            XCTAssertEqual($0 as? ObservationGroundingError, .emptyDescription)
        }
    }

    func testDescriptionGroundingRejectsEmptyFields() {
        XCTAssertThrowsError(try ObservationDescriptionGrounding.validate([ObservationCandidate(name: "...", location: "left")], description: "A mug is on the left.")) {
            XCTAssertEqual($0 as? ObservationGroundingError, .emptyName(index: 0))
        }
        XCTAssertThrowsError(try ObservationDescriptionGrounding.validate([ObservationCandidate(name: "mug", location: " \t")], description: "A mug is on the left.")) {
            XCTAssertEqual($0 as? ObservationGroundingError, .emptyLocation(index: 0))
        }
    }
}
