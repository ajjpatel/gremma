package com.gremma.android

import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** What a memory record says happened. SEEN = inventory from a photo; the rest come from board clips. */
enum class MemoryKind { SEEN, APPEARED, REMOVED, MOVED, PICKED_UP }

data class MemoryRecord(
    val id: Long,
    val kind: MemoryKind,
    val name: String,
    val details: String,
    val location: String,
    val fromLocation: String = "",
    val room: String = "",
    val timeMs: Long,
    val source: String,
    val beforeImage: String? = null,
    val afterImage: String? = null,
    val embedding: FloatArray? = null,
) {
    val evidenceImage: String? get() = if (kind == MemoryKind.REMOVED) beforeImage ?: afterImage else afterImage ?: beforeImage

    /** One line for the index and for Gemma's Find prompt. */
    fun sentence(): String {
        val d = if (details.isNotBlank()) ", $details" else ""
        val r = if (room.isNotBlank()) ", in the $room" else ""
        val what = when (kind) {
            MemoryKind.SEEN -> "$name$d, $location"
            MemoryKind.APPEARED -> "$name$d was put $location"
            MemoryKind.REMOVED -> "$name$d was taken away from $location"
            MemoryKind.MOVED -> "$name$d was moved from $fromLocation to $location"
            MemoryKind.PICKED_UP -> "$name$d was picked up from $location and put back"
        }
        return "$what$r, at ${clock(timeMs)}"
    }

    fun spoken(): String {
        val be = if (name.endsWith("s") && !name.endsWith("ss")) "were" else "was"
        val r = if (room.isNotBlank()) " in the $room" else ""
        return when (kind) {
            MemoryKind.SEEN -> "Your $name $be last seen at ${clock(timeMs)}$r, $location."
            MemoryKind.APPEARED -> "Your $name $be put $location at ${clock(timeMs)}$r."
            MemoryKind.REMOVED -> "Your $name $be taken away from $location at ${clock(timeMs)}$r. I haven't seen where it went."
            MemoryKind.MOVED -> "Your $name $be moved at ${clock(timeMs)} from $fromLocation to $location$r."
            MemoryKind.PICKED_UP -> "Your $name $be picked up at ${clock(timeMs)} and put back $location."
        }
    }
}

fun clock(ms: Long): String = SimpleDateFormat("h:mm a", Locale.US).format(Date(ms))

fun startOfToday(): Long = Calendar.getInstance().apply {
    set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
}.timeInMillis

/** A board clip happened at [timeMs]; [people] = most people seen in any sampled frame. */
data class Activity(val timeMs: Long, val people: Int, val room: String = "")

data class ChatLine(val fromUser: Boolean, val text: String, val image: String? = null)
