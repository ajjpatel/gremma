import XCTest
@testable import GremmaCore

final class GremmaCoreTests: XCTestCase {
    private func item(_ name: String, at time: TimeInterval = 100, aliases: [String] = []) -> MemoryObservation {
        MemoryObservation(itemName: name, aliases: aliases, room: "Kitchen", locationDescription: "beside the sink", capturedAt: Date(timeIntervalSince1970: time))
    }

    private func reading(_ text: String, confidence: Float = 0.99) -> ReadingResult {
        ReadingResult(lines: text.components(separatedBy: "\n").map { RecognizedLine(text: $0, confidence: confidence) })
    }

    func testAbsentItemDoesNotReturnNearestObservation() {
        XCTAssertEqual(MemoryRetrieval.search("Where is my wallet?", in: [item("keys")]), .noMatch)
    }

    func testAliasAndPluralQuery() {
        let observation = item("blue ceramic mug", aliases: ["travel cup"])
        XCTAssertEqual(MemoryRetrieval.search("Where is my travel cup?", in: [observation]), .match(observation))
        let keys = item("set of keys")
        XCTAssertEqual(MemoryRetrieval.search("Find my key", in: [keys]), .match(keys))
    }

    func testGenericQueryIsAmbiguousForDistinctObjects() {
        let results = MemoryRetrieval.search("mug", in: [item("red mug"), item("blue mug")])
        guard case .ambiguous(let observations) = results else { return XCTFail("Should ask which mug") }
        XCTAssertEqual(observations.count, 2)
    }

    func testNewestSightingOfSameNamedItemWins() {
        let old = item("keys", at: 100)
        let recent = item("keys", at: 200)
        XCTAssertEqual(MemoryRetrieval.search("keys", in: [old, recent]), .match(recent))
    }

    func testLatestFrameWinsWithinSameImportedVideo() {
        var early = item("black keys", at: 100)
        early.videoID = "one-room-video"
        early.videoTimeSeconds = 3
        early.locationDescription = "on the table"
        var late = item("black keys", at: 100)
        late.videoID = early.videoID
        late.videoTimeSeconds = 57
        late.locationDescription = "beside the sink"
        XCTAssertEqual(MemoryRetrieval.search("keys", in: [early, late]), .match(late))
        XCTAssertEqual(MemoryRetrieval.search("keys", in: [late, early]), .match(late))
    }

    func testSameGenericNameInDifferentRoomsRemainsAmbiguous() {
        let kitchen = item("mug", at: 100)
        var bedroom = item("mug", at: 200)
        bedroom.room = "Bedroom"
        guard case .ambiguous(let candidates) = MemoryRetrieval.search("mug", in: [kitchen, bedroom]) else {
            return XCTFail("A generic name does not prove the same physical item moved between rooms")
        }
        XCTAssertEqual(Set(candidates.map(\.room)), Set(["Kitchen", "Bedroom"]))
    }

    func testRoomQualifierResolvesAmbiguityWithoutMatchingRoomAlone() {
        let kitchen = item("mug", at: 100)
        var bedroom = item("mug", at: 200, aliases: ["travel cup"])
        bedroom.room = "Bedroom"
        let observations = [kitchen, bedroom]
        XCTAssertEqual(MemoryRetrieval.search("find the mug in the bedroom", in: observations), .match(bedroom))
        XCTAssertEqual(MemoryRetrieval.search("bedroom travel cup", in: observations), .match(bedroom))
        XCTAssertEqual(MemoryRetrieval.search("bedroom", in: observations), .noMatch)
        XCTAssertEqual(MemoryRetrieval.search("find the mug in the garage", in: observations), .noMatch)
    }

    func testRepositoryPersistsEvidenceAndDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try MemoryRepository(directory: directory)
        let saved = try await repository.save(item("keys"), imageData: Data([1, 2, 3]))
        let reopened = try MemoryRepository(directory: directory)
        let observations = await reopened.all()
        XCTAssertEqual(observations, [saved])
        let url = await reopened.imageURL(for: saved)
        XCTAssertNotNil(url)
        try await reopened.deleteAll()
        let after = await reopened.all()
        XCTAssertTrue(after.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(url).path))
    }

    func testCorruptManifestIsNotSilentlyDiscarded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("observations.json")
        let corrupt = Data("broken json".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try MemoryRepository(directory: directory))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testLowConfidenceMedicineLabelRefuses() {
        let result = ReadingResult(lines: [RecognizedLine(text: "EXAMPLE", confidence: 0.99), RecognizedLine(text: "Take 2", confidence: 0.2)])
        let interpretation = ReadingInterpreter.describe(result, mode: .medicine)
        XCTAssertTrue(interpretation.needsRetake)
        XCTAssertTrue(interpretation.fields.isEmpty)
    }

    func testMedicineTextIsNotRephrasedAsAdvice() {
        let text = "EXAMPLE\n5 mg\nDirections: take as directed"
        let interpretation = ReadingInterpreter.describe(reading(text), mode: .medicine)
        XCTAssertEqual(interpretation.fields.first?.value, text)
        XCTAssertTrue(interpretation.spokenText.contains("visible label reads"))
        XCTAssertTrue(interpretation.spokenText.contains("pharmacist"))
    }

    func testAmbiguousExpiryIsPreservedLiterally() {
        let interpretation = ReadingInterpreter.describe(reading("EXP 03/04/27"), mode: .expiry)
        XCTAssertEqual(interpretation.fields.first?.value, "EXP 03/04/27")
        XCTAssertFalse(interpretation.spokenText.contains("March"))
    }

    func testExpiryDoesNotMislabelAdjacentDose() {
        XCTAssertTrue(ReadingInterpreter.describe(reading("EXP\n500 mg"), mode: .expiry).needsRetake)
    }

    func testCurrencyNeedsCurrencyAndUnambiguousDenomination() {
        XCTAssertTrue(ReadingInterpreter.describe(reading("FIVE DOLLARS"), mode: .currency).needsRetake)
        XCTAssertEqual(ReadingInterpreter.describe(reading("UNITED STATES OF AMERICA\nFIVE DOLLARS"), mode: .currency).fields.first?.value, "USD 5")
        XCTAssertTrue(ReadingInterpreter.describe(reading("UNITED STATES\nFIVE DOLLARS\nTEN DOLLARS"), mode: .currency).needsRetake)
        XCTAssertTrue(ReadingInterpreter.describe(reading("USD $1000"), mode: .currency).needsRetake)
    }

    func testSerialNumbersDoNotBecomeCurrencyAmounts() {
        XCTAssertTrue(ReadingInterpreter.describe(reading("UNITED STATES OF AMERICA\nAB000100CD\n100"), mode: .currency).needsRetake)
        XCTAssertTrue(ReadingInterpreter.describe(reading("USD 100Z"), mode: .currency).needsRetake)
    }

    func testUncertainConflictingCurrencyDoesNotGetDiscarded() {
        let result = ReadingResult(lines: [RecognizedLine(text: "UNITED STATES FIVE DOLLARS", confidence: 0.99), RecognizedLine(text: "TEN DOLLARS", confidence: 0.2)])
        XCTAssertTrue(ReadingInterpreter.describe(result, mode: .currency).needsRetake)
    }
}
