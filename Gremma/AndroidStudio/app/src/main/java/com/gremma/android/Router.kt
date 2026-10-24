package com.gremma.android

/** Trimmed from the iOS AgentCoordinator: deterministic keyword routing, Gemma chat for everything else. */
enum class Action { FIND, REMEMBER, DESCRIBE, READ_TEXT, READ_MEDICINE, READ_EXPIRY, WHAT_CHANGED, MEDICINE_STATUS, SUMMARY, LIST, CHAT }

object Router {
    private fun has(q: String, vararg words: String) = words.any { Regex("\\b$it").containsMatchIn(q) }

    fun route(text: String): Action {
        val q = text.lowercase()
        val medWord = has(q, "medic", "pill", "meds", "tablet", "vitamin", "dose")
        return when {
            has(q, "expir", "best before", "use by", "use-by", "sell by") -> Action.READ_EXPIRY
            has(q, "read") && medWord -> Action.READ_MEDICINE
            has(q, "read", "what does (this|it) say", "label", "text") -> Action.READ_TEXT
            medWord && has(q, "take", "took", "taken", "had", "did i", "should i", "can i", "again") -> Action.MEDICINE_STATUS
            has(q, "what changed", "what has changed", "anything change", "anything new", "what's new", "while i was", "what happened", "any changes") -> Action.WHAT_CHANGED
            has(q, "summary", "summari", "my day", "recap") -> Action.SUMMARY
            has(q, "remember", "save this", "memorize", "memorise", "scan the room", "scan this") -> Action.REMEMBER
            has(q, "describe", "what do you see", "what's in front", "what is in front", "look around", "what is this", "what's this", "where am i") -> Action.DESCRIBE
            has(q, "what do you remember", "list my", "list everything", "what have you seen") -> Action.LIST
            has(q, "where", "find", "seen my", "lost", "locate", "misplaced", "left my", "put my") -> Action.FIND
            else -> Action.CHAT
        }
    }

    val NEEDS_PHOTO = setOf(Action.REMEMBER, Action.DESCRIBE, Action.READ_TEXT, Action.READ_MEDICINE, Action.READ_EXPIRY)
}
