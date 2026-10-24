import Foundation

public struct ConversationTurn: Equatable, Sendable {
    public enum Role: Sendable { case user, assistant }
    public let role: Role
    public let text: String
    public init(role: Role, text: String) { self.role = role; self.text = text }
}

/// Session-only context. Keep whole recent exchanges within the mobile context budget.
public struct ConversationHistory {
    public private(set) var turns: [ConversationTurn] = []
    public init() {}
    public mutating func append(user: String, assistant: String) {
        turns += [ConversationTurn(role: .user, text: user), ConversationTurn(role: .assistant, text: assistant)]
        while turns.count > 6 || turns.map(\.text.count).reduce(0, +) > 2400 {
            guard turns.count > 2 else { turns.removeAll(); break }
            turns.removeFirst(2)
        }
    }
    public mutating func clear() { turns.removeAll() }
}
