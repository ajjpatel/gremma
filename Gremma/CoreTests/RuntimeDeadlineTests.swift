import XCTest
@testable import RuntimeValidation

private actor DeferredResult<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    func value() async throws -> Value {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: Result<Value, Error>) {
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

final class RuntimeDeadlineTests: XCTestCase {
    func testReturnsCompletedWorker() async throws {
        let worker = Task<Int, Error> { 42 }
        let gate = RuntimeDeadlineGate<Int>(maximumDuration: 2)
        let value = try await gate.wait(for: worker)
        XCTAssertEqual(value, 42)
        XCTAssertTrue(gate.workerHasFinished)
    }

    func testPreservesWorkerError() async {
        enum Failure: Error { case expected }
        let worker = Task<Int, Error> { throw Failure.expected }
        do {
            _ = try await RuntimeDeadlineGate<Int>(maximumDuration: 2).wait(for: worker)
            XCTFail("Expected worker error")
        } catch { XCTAssertTrue(error is Failure) }
    }

    func testStalledWorkerDoesNotHoldCallerAndLateSuccessIsIgnored() async throws {
        let deferred = DeferredResult<Int>()
        let worker = Task<Int, Error> { try await deferred.value() }
        let gate = RuntimeDeadlineGate<Int>(maximumDuration: 0.10, cancellationGrace: 0.05)
        let start = Date()
        do {
            _ = try await gate.wait(for: worker)
            XCTFail("Expected deadline")
        } catch let error as RuntimeDeadlineError {
            XCTAssertEqual(error.reason, .absoluteLimit)
            XCTAssertTrue(error.nativeStillRunning)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertFalse(gate.workerHasFinished)
        await deferred.finish(.success(7))
        _ = try await worker.value
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(gate.workerHasFinished)
    }

    func testExplicitCancellationReturnsWithinGraceIfWorkerIgnoresIt() async throws {
        let deferred = DeferredResult<Int>()
        let worker = Task<Int, Error> { try await deferred.value() }
        let gate = RuntimeDeadlineGate<Int>(maximumDuration: 10, cancellationGrace: 0.10)
        let caller = Task { try await gate.wait(for: worker) }
        caller.cancel()
        do { _ = try await caller.value; XCTFail("Expected cancellation deadline") }
        catch let error as RuntimeDeadlineError {
            XCTAssertEqual(error.reason, .cancellation)
            XCTAssertTrue(error.nativeStillRunning)
        }
        await deferred.finish(.success(1))
        _ = try await worker.value
    }

    func testCancellationDrainsWorkerAndReturnsCancellationRatherThanSuccess() async throws {
        let deferred = DeferredResult<Int>()
        let worker = Task<Int, Error> { try await deferred.value() }
        let gate = RuntimeDeadlineGate<Int>(maximumDuration: 10, cancellationGrace: 1)
        let caller = Task {
            try await gate.wait(for: worker, onCancellation: {
                Task { await deferred.finish(.success(99)) }
            })
        }
        caller.cancel()
        do { _ = try await caller.value; XCTFail("A canceled result must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(gate.workerHasFinished)
    }

    func testProgressExtendsStallWindow() async throws {
        let gate = RuntimeDeadlineGate<Int>(maximumDuration: 2, noProgressDuration: 0.15, cancellationGrace: 0)
        let worker = Task<Int, Error> {
            for _ in 0..<5 {
                try await Task.sleep(nanoseconds: 60_000_000)
                gate.noteProgress()
            }
            return 5
        }
        let value = try await gate.wait(for: worker)
        XCTAssertEqual(value, 5)
    }

    func testProgressCannotExtendAbsoluteLimit() async throws {
        let gate = RuntimeDeadlineGate<Int>(maximumDuration: 0.15, noProgressDuration: 0.1, cancellationGrace: 0)
        let worker = Task<Int, Error> {
            for _ in 0..<8 {
                try await Task.sleep(nanoseconds: 40_000_000)
                gate.noteProgress()
            }
            return 8
        }
        do { _ = try await gate.wait(for: worker); XCTFail("Expected absolute limit") }
        catch let error as RuntimeDeadlineError { XCTAssertEqual(error.reason, .absoluteLimit) }
        _ = try await worker.value
    }

    func testNoProgressDeadline() async throws {
        let deferred = DeferredResult<Int>()
        let worker = Task<Int, Error> { try await deferred.value() }
        let gate = RuntimeDeadlineGate<Int>(maximumDuration: 2, noProgressDuration: 0.1, cancellationGrace: 0)
        do { _ = try await gate.wait(for: worker); XCTFail("Expected no-progress deadline") }
        catch let error as RuntimeDeadlineError { XCTAssertEqual(error.reason, .noProgress) }
        await deferred.finish(.success(0))
        _ = try await worker.value
    }

    func testBlockingCancellationCallbackCannotHoldCaller() async throws {
        let deferred = DeferredResult<Int>()
        let worker = Task<Int, Error> { try await deferred.value() }
        let gate = RuntimeDeadlineGate<Int>(maximumDuration: 0.1, cancellationGrace: 0.05)
        let start = Date()
        do {
            _ = try await gate.wait(for: worker, onCancellation: {
                Thread.sleep(forTimeInterval: 0.6)
            })
            XCTFail("Expected deadline")
        } catch is RuntimeDeadlineError { }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        await deferred.finish(.success(0))
        _ = try await worker.value
    }

    func testConvenienceRunReturnsWithoutJoiningStalledOperation() async throws {
        let deferred = DeferredResult<Int>()
        do {
            _ = try await BoundedAsync.run(maximumDuration: 0.1) { try await deferred.value() }
            XCTFail("Expected deadline")
        } catch let error as RuntimeDeadlineError { XCTAssertTrue(error.nativeStillRunning) }
        await deferred.finish(.success(0))
    }
}
