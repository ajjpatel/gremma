import Foundation
import LiteRTLM

/// Cancelling Swift's stream iterator can return before the native engine is done.
/// Keep the worker uncancelled, request native cancellation, and drain its final callback.
/// LiteRT-LM's StreamContext additionally retains Conversation, which retains Engine.
final class GenerationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false
    private var conversation: Conversation?
    private var activeCancellationCalls = 0

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    func attach(_ conversation: Conversation) {
        lock.lock()
        self.conversation = conversation
        let cancelled = cancellationRequested
        if cancelled { activeCancellationCalls += 1 }
        lock.unlock()
        if cancelled { cancelOffCaller(conversation) }
    }

    func requestCancellation() {
        lock.lock()
        cancellationRequested = true
        let active = conversation
        if active != nil { activeCancellationCalls += 1 }
        lock.unlock()
        if let active { cancelOffCaller(active) }
    }

    func detach() {
        lock.lock()
        conversation = nil
        lock.unlock()
    }

    private func cancelOffCaller(_ conversation: Conversation) {
        // The C cancellation call has no documented latency bound. Retain the
        // conversation in this block and keep it off the UI/watchdog thread.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            try? conversation.cancel()
            lock.lock()
            activeCancellationCalls -= 1
            lock.unlock()
        }
    }

    private var cancellationCallsFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return activeCancellationCalls == 0
    }

    /// The uncancelled worker also drains cancellation C calls before it returns.
    /// Its deadline gate can quarantine both if the native call never comes back.
    func waitForCancellationDrain() async {
        while !cancellationCallsFinished {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
