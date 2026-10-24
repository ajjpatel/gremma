package com.gremma.android

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.Locale

/** Versioned, app-private JSON storage; no account or network synchronization. */
class AndroidMemoryStore(context: Context) {
    private val file = File(context.filesDir, "AsterMemory/observations.json").apply { parentFile?.mkdirs() }

    @Synchronized fun all(): List<SavedMemory> {
        if (!file.exists()) return emptyList()
        return try {
            val root = JSONObject(file.readText())
            require(root.optInt("version") == 1) { "Unsupported memory format." }
            val rows = root.getJSONArray("observations")
            (0 until rows.length()).map { i ->
                val row = rows.getJSONObject(i)
                SavedMemory(row.getString("itemName"), row.optString("room"), row.optString("locationDescription"),
                    row.optJSONArray("aliases")?.toStringList() ?: emptyList())
            }
        } catch (_: Exception) { emptyList() }
    }

    @Synchronized fun save(memory: SavedMemory) {
        require(memory.name.isNotBlank() && (memory.room.isNotBlank() || memory.location.isNotBlank()))
        val rows = JSONArray()
        (all().filterNot { it.name.equals(memory.name, true) && it.room.equals(memory.room, true) } + memory).forEach { item ->
            rows.put(JSONObject().put("itemName", item.name).put("aliases", JSONArray(item.aliases))
                .put("room", item.room).put("locationDescription", item.location)
                .put("capturedAt", DateFormat.getDateTimeInstance().format(Date())))
        }
        val temp = File(file.parentFile, "observations.tmp")
        temp.writeText(JSONObject().put("version", 1).put("observations", rows).toString(2))
        check(temp.renameTo(file)) { "Could not safely save observations." }
    }

    fun search(query: String): String? {
        val q = tokens(query)
        if (q.isEmpty()) return null
        val matches = all().filter { m ->
            val names = (listOf(m.name) + m.aliases).map(::tokens)
            names.any { n -> n.isNotEmpty() && q.intersect(n.toSet()).isNotEmpty() && q.all { it in n || it in tokens(m.room) } }
        }.distinctBy { "${tokens(it.name)}|${tokens(it.room)}" }
        return when (matches.size) {
            0 -> null
            1 -> matches.single().let { "${it.name}, ${it.room}, ${it.location}. This is a saved observation; it may have moved." }
            else -> "I found multiple possible items: ${matches.take(3).joinToString { "${it.name} in ${it.room}" }}. Add the room to your search."
        }
    }

    private fun tokens(value: String): Set<String> = value.lowercase(Locale.ROOT)
        .split(Regex("[^a-z0-9]+"))
        .filter { it.isNotBlank() && it !in setOf("where", "was", "were", "is", "are", "my", "the", "a", "an", "of", "in", "from", "at", "please", "find", "locate", "i", "leave", "you", "me", "tell") }
        .map { if (it.endsWith("s") && it.length > 3 && !it.endsWith("ss")) it.dropLast(1) else it }.toSet()

    private fun JSONArray.toStringList() = (0 until length()).mapNotNull { optString(it).takeIf(String::isNotBlank) }
}
