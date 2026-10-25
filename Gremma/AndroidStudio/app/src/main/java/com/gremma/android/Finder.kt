package com.gremma.android

import android.util.Log

/**
 * Hybrid retrieval validated on the Mac: EmbeddingGemma top-20 ∪ name-word matches ∪ latest 5,
 * then Gemma copies the matching log lines and the answer is composed from stored rows (never free text).
 */
class Finder(private val store: MemoryStore, private val embedder: Embedder, private val gemma: GemmaService) {

    data class Result(val answer: String, val matches: List<MemoryRecord>)

    suspend fun find(question: String): Result {
        val all = store.all()
        if (all.isEmpty()) return Result("I don't have any memories yet. Ask me to remember a room, or let the home camera watch for a while.", emptyList())

        val candidates = candidates(question, all)
        val byId = candidates.associateBy { it.id }
        val ids: List<Long> = if (gemma.isReady) {
            val log = candidates.joinToString("\n") { "[${it.id}] ${it.sentence()}" }
            val out = runCatching { gemma.generate(Prompts.FIND + "\n\nObservation log:\n" + log, question, maxTokens = 200) }
                .onFailure { Log.w("GremmaFind", "find failed", it) }.getOrDefault("")
            Regex("^\\s*\\[(\\d+)]", RegexOption.MULTILINE).findAll(out).map { it.groupValues[1].toLong() }.filter { it in byId }.toList()
        } else {
            lexical(question, candidates).take(2).map { it.id }
        }
        val hits = ids.distinct().mapNotNull { byId[it] }.sortedByDescending { it.timeMs }
        return Result(compose(hits), hits)
    }

    private suspend fun candidates(question: String, all: List<MemoryRecord>): List<MemoryRecord> {
        val picked = LinkedHashMap<Long, MemoryRecord>()
        val qv = embedder.embed(question, isQuery = true)
        if (qv != null) {
            all.filter { it.embedding != null }.sortedByDescending { dot(qv, it.embedding!!) }.take(20).forEach { picked[it.id] = it }
        }
        lexical(question, all).forEach { picked[it.id] = it }
        all.take(5).forEach { picked[it.id] = it }
        return picked.values.toList()
    }

    private fun lexical(question: String, rows: List<MemoryRecord>): List<MemoryRecord> {
        val words = question.lowercase().split(Regex("[^a-z0-9]+")).filter { it.length > 2 && it !in STOP }
            .map { it.removeSuffix("es").removeSuffix("s") }
        return rows.filter { r -> val n = r.name.lowercase(); words.any { n.contains(it) } }
    }

    private fun compose(hits: List<MemoryRecord>): String {
        if (hits.isEmpty()) return "I haven't seen that yet. Try scanning the room where you think it is."
        val latest = hits.first()
        var s = latest.spoken()
        if (latest.kind == MemoryKind.REMOVED) {
            hits.drop(1).firstOrNull { it.kind != MemoryKind.REMOVED }?.let { s += " Before that: " + it.spoken() }
        } else {
            hits.drop(1).firstOrNull { !it.location.equals(latest.location, true) }?.let { prev ->
                s += " Earlier, at ${clock(prev.timeMs)}, ${prev.location}."
            }
        }
        return s
    }

    companion object {
        private val STOP = setOf("where", "did", "the", "my", "leave", "left", "put", "find", "have", "you", "seen", "what", "are", "was", "is", "can", "help", "me", "lost", "last", "time")
    }
}
