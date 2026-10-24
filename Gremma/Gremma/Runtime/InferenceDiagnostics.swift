import Foundation
import os

enum RuntimeMemory {
    /// Current per-process headroom reported by iOS, not free system RAM or a guaranteed allocation.
    static var availableBytes: UInt64 { UInt64(os_proc_available_memory()) }
}

struct ModelLoadMemoryDiagnostics: Codable, Sendable {
    let startedAt: Date
    let availableBeforeBytes: UInt64
    var availableAfterBytes: UInt64?
    var elapsedSeconds: TimeInterval?
}

/// Bounded, in-memory debugging metadata. It contains no prompt, generated text,
/// image bytes, file paths, or schema contents and is never written by the runtime.
struct InferenceDiagnostics: Codable, Sendable {
    let requestID: UUID
    let startedAt: Date
    let constrainedJSON: Bool
    let promptCharacterCount: Int
    let systemCharacterCount: Int
    let includesImage: Bool
    let historyTurnCount: Int
    let historyCharacterCount: Int
    let schemaByteCount: Int
    let contextTokenLimit: Int?
    let maximumOutputTokens: Int
    var phase = "creating_conversation"
    var streamChunkCount = 0
    var textPartCount = 0
    var multipleTextPartChunks = 0
    var channelChunks = 0
    var responseCharacterCount = 0
    var returnedValidJSON: Bool?
    /// The entire native KV cache, including input and output; not an output-token count.
    var nativeKVTokenCount: Int?
    var elapsedSeconds: TimeInterval?
    var errorType: String?
    var engineInvalidated = false
    var availableProcessMemoryAtStartBytes = RuntimeMemory.availableBytes
    var availableProcessMemoryAtEndBytes: UInt64?

    // LiteRT-LM 0.18.1's Swift stream does not expose a finish reason or an exact
    // output-token count. Reaching a token limit cannot be inferred from chunk count.
}
