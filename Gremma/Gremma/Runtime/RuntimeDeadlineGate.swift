import Foundation

enum RuntimeDeadlineReason: String, Codable, Sendable {
    case absoluteLimit, noProgress, cancellation
}

/// `nativeStillRunning` means only that the worker has not returned. Its resources
/// must remain retained and must not be reused, even though the caller is unblocked.
struct RuntimeDeadlineError: LocalizedError, Sendable {
    let reason: RuntimeDeadlineReason
    let nativeStillRunning: Bool

    var errorDescription: String? {
        if nativeStillRunning {
            return "The operation did not finish after it was stopped."
        }
        return "The operation took too long and was stopped. Please try again."
    }
}

enum RuntimeRecoveryError: LocalizedError {
    case restartRequired

    var errorDescription: String? {
        "Gemma stopped responding and could not finish safely. Close and reopen Gremma before using Gemma again. Saved video progress is kept. Reading text and opening saved memories are still available."
    }
}

/// Races a caller's wait against an independent watchdog, without cancelling the
/// worker or joining it on timeout. Structured task groups would wait for a stuck
/// native child when leaving the group. The owner remains responsible for retaining
/// and quarantining native resources when `nativeStillRunning` is true.
final class RuntimeDeadlineGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumDuration: TimeInterval
    private let noProgressDuration: TimeInterval?
    private let cancellationGrace: TimeInterval
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var progressedAt = ProcessInfo.processInfo.systemUptime
    private var cancellationAt: TimeInterval?
    private var reason: RuntimeDeadlineReason?
    private var onCancellation: (@Sendable () -> Void)?
    private var cancellationDelivered = false
    private var nativeFinished = false
    private var resolved: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var timer: DispatchSourceTimer?
    private var hasWaiter = false

    init(maximumDuration: TimeInterval, noProgressDuration: TimeInterval? = nil,
         cancellationGrace: TimeInterval = 4) {
        precondition(maximumDuration > 0 && cancellationGrace >= 0)
        self.maximumDuration = maximumDuration
        self.noProgressDuration = noProgressDuration
        self.cancellationGrace = cancellationGrace
    }

    var workerHasFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return nativeFinished
    }

    func noteProgress() {
        lock.lock(); defer { lock.unlock() }
        guard resolved == nil, reason == nil else { return }
        progressedAt = ProcessInfo.processInfo.systemUptime
    }

    func requestCancellation() {
        lock.lock()
        guard resolved == nil else { lock.unlock(); return }
        if reason == nil {
            reason = .cancellation
            cancellationAt = ProcessInfo.processInfo.systemUptime
        }
        let callback = takeCancellationCallbackLocked()
        lock.unlock()
        dispatchCancellation(callback)
        tick()
    }

    func wait(for worker: Task<Value, Error>, onCancellation: @escaping @Sendable () -> Void = {}) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation, onCancellation: onCancellation)
                // This observer intentionally outlives the caller after a deadline.
                Task.detached { [self] in complete(await worker.result) }
            }
        } onCancel: { self.requestCancellation() }
    }

    private func install(_ continuation: CheckedContinuation<Value, Error>,
                         onCancellation: @escaping @Sendable () -> Void) {
        lock.lock()
        precondition(!hasWaiter, "A deadline gate can only be awaited once")
        hasWaiter = true
        self.onCancellation = onCancellation
        if let resolved {
            let callback = takeCancellationCallbackLocked()
            lock.unlock()
            dispatchCancellation(callback)
            continuation.resume(with: resolved)
            return
        }
        self.continuation = continuation
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.tick() }
        source.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer = source
        let callback = takeCancellationCallbackLocked()
        // Start before unlocking so no completion can cancel an unresumed source.
        source.resume()
        lock.unlock()
        dispatchCancellation(callback)
    }

    private func tick() {
        lock.lock()
        guard resolved == nil else { lock.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if reason == nil {
            if now - startedAt >= maximumDuration {
                reason = .absoluteLimit
                cancellationAt = now
            } else if let noProgressDuration, now - progressedAt >= noProgressDuration {
                reason = .noProgress
                cancellationAt = now
            }
        }
        let callback = takeCancellationCallbackLocked()
        var outcome: Result<Value, Error>?
        if let reason, let cancellationAt, now - cancellationAt >= cancellationGrace {
            outcome = .failure(RuntimeDeadlineError(reason: reason, nativeStillRunning: !nativeFinished))
        }
        let waiter = outcome.flatMap { resolveLocked($0) }
        lock.unlock()
        dispatchCancellation(callback)
        if let outcome { waiter?.resume(with: outcome) }
    }

    private func complete(_ result: Result<Value, Error>) {
        lock.lock()
        nativeFinished = true
        let outcome: Result<Value, Error>
        if let reason {
            outcome = reason == .cancellation
                ? .failure(CancellationError())
                : .failure(RuntimeDeadlineError(reason: reason, nativeStillRunning: false))
        } else { outcome = result }
        let waiter = resolveLocked(outcome)
        lock.unlock()
        waiter?.resume(with: outcome)
    }

    private func takeCancellationCallbackLocked() -> (@Sendable () -> Void)? {
        guard reason != nil, !cancellationDelivered, let onCancellation else { return nil }
        cancellationDelivered = true
        return onCancellation
    }

    private func dispatchCancellation(_ callback: (@Sendable () -> Void)?) {
        // Native cancellation may itself block. Never run it on the caller,
        // continuation-registration path, or watchdog queue before resuming a waiter.
        if let callback { DispatchQueue.global(qos: .userInitiated).async(execute: callback) }
    }

    private func resolveLocked(_ result: Result<Value, Error>) -> CheckedContinuation<Value, Error>? {
        guard resolved == nil else { return nil }
        resolved = result
        timer?.cancel()
        timer = nil
        onCancellation = nil
        let waiter = continuation
        continuation = nil
        return waiter
    }
}

enum BoundedAsync {
    static func run<Value: Sendable>(maximumDuration: TimeInterval,
                                    cancellationGrace: TimeInterval = 0,
                                    onCancellation: @escaping @Sendable () -> Void = {},
                                    operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let gate = RuntimeDeadlineGate<Value>(maximumDuration: maximumDuration, cancellationGrace: cancellationGrace)
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        return try await gate.wait(for: worker, onCancellation: onCancellation)
    }
}
