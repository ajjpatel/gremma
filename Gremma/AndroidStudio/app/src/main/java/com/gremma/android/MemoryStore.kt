package com.gremma.android

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** App-private JSON store of memory records + evidence JPEGs. No network, no backup. */
class MemoryStore(context: Context) {
    private val dir = File(context.filesDir, "GremmaMemory").apply { mkdirs() }
    val evidenceDir = File(dir, "evidence").apply { mkdirs() }
    private val file = File(dir, "memory.json")
    private var records: MutableList<MemoryRecord> = load()

    @Synchronized fun all(): List<MemoryRecord> = records.sortedByDescending { it.timeMs }

    @Synchronized fun nextId(): Long = (records.maxOfOrNull { it.id } ?: 0) + 1

    @Synchronized fun add(record: MemoryRecord) { records.add(record); persist() }

    @Synchronized fun addAll(batch: List<MemoryRecord>) { records.addAll(batch); persist() }

    @Synchronized fun delete(id: Long) { records.removeAll { it.id == id }; persist() }

    @Synchronized fun clear() { records.clear(); persist(); evidenceDir.listFiles()?.forEach { it.delete() } }

    fun saveImage(bytes: ByteArray, name: String): String {
        File(evidenceDir, name).writeBytes(bytes)
        return name
    }

    fun imageFile(name: String?): File? = name?.let { File(evidenceDir, it) }?.takeIf { it.exists() }

    private fun persist() {
        val rows = JSONArray()
        records.forEach { r ->
            rows.put(JSONObject().apply {
                put("id", r.id); put("kind", r.kind.name); put("name", r.name); put("details", r.details)
                put("location", r.location); put("fromLocation", r.fromLocation); put("room", r.room)
                put("timeMs", r.timeMs); put("source", r.source)
                r.beforeImage?.let { put("beforeImage", it) }; r.afterImage?.let { put("afterImage", it) }
                r.embedding?.let { e -> put("embedding", JSONArray().apply { e.forEach { put(it.toDouble()) } }) }
            })
        }
        val tmp = File(dir, "memory.tmp")
        tmp.writeText(JSONObject().put("version", 2).put("records", rows).toString())
        check(tmp.renameTo(file)) { "Could not save memory." }
    }

    private fun load(): MutableList<MemoryRecord> {
        if (!file.exists()) return mutableListOf()
        return runCatching {
            val rows = JSONObject(file.readText()).getJSONArray("records")
            MutableList(rows.length()) { i ->
                val o = rows.getJSONObject(i)
                MemoryRecord(
                    id = o.getLong("id"), kind = MemoryKind.valueOf(o.getString("kind")), name = o.getString("name"),
                    details = o.optString("details"), location = o.optString("location"),
                    fromLocation = o.optString("fromLocation"), room = o.optString("room"),
                    timeMs = o.getLong("timeMs"), source = o.optString("source"),
                    beforeImage = o.optString("beforeImage").ifBlank { null },
                    afterImage = o.optString("afterImage").ifBlank { null },
                    embedding = o.optJSONArray("embedding")?.let { a -> FloatArray(a.length()) { a.getDouble(it).toFloat() } },
                )
            }
        }.getOrElse { mutableListOf() }
    }
}
