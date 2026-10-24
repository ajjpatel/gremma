package com.gremma.android

/** Deterministic elder-care answers composed from stored events (no free-form model text). */
object Routines {
    private val MED = Regex("\\b(pill|pills|medic\\w*|meds|tablet\\w*|vitamin\\w*|capsule\\w*|inhaler|blister)\\b", RegexOption.IGNORE_CASE)

    fun isMedicine(name: String) = MED.containsMatchIn(name)

    private fun dosesToday(store: MemoryStore) = store.all().filter {
        it.timeMs >= startOfToday() && isMedicine(it.name) && it.kind in setOf(MemoryKind.PICKED_UP, MemoryKind.REMOVED, MemoryKind.MOVED)
    }

    fun medicineStatus(store: MemoryStore): String {
        val doses = dosesToday(store)
        if (doses.isEmpty()) {
            val known = store.all().any { isMedicine(it.name) }
            return if (known) "I haven't seen your medicine picked up today." else
                "I don't know where your medicine is kept yet. Put it where the home camera can see it, or ask me to remember it."
        }
        val first = doses.minBy { it.timeMs }
        val times = doses.sortedBy { it.timeMs }.joinToString(" and ") { clock(it.timeMs) }
        val more = if (doses.size > 1) " It was picked up ${doses.size} times today, at $times." else ""
        return "I saw your ${first.name} picked up at ${clock(first.timeMs)} today.$more That may have been today's dose, so please check before taking another."
    }

    fun medicineTakenToday(store: MemoryStore) = dosesToday(store).isNotEmpty()

    fun whatChanged(store: MemoryStore, sinceMs: Long): String {
        val events = store.all().filter { it.kind != MemoryKind.SEEN && it.timeMs >= sinceMs }
        if (events.isEmpty()) return "Nothing has changed since ${clock(sinceMs)}."
        val lines = events.take(5).joinToString(" ") { it.spoken() }
        val more = if (events.size > 5) " And ${events.size - 5} more changes." else ""
        return "${events.size} change${if (events.size == 1) "" else "s"} since ${clock(sinceMs)}. $lines$more"
    }

    fun dailySummary(store: MemoryStore): String {
        val today = store.all().filter { it.timeMs >= startOfToday() }
        val events = today.filter { it.kind != MemoryKind.SEEN }
        val parts = mutableListOf<String>()
        parts += if (events.isEmpty()) "The home camera saw no changes today." else "The home camera saw ${events.size} change${if (events.size == 1) "" else "s"} today."
        events.filter { it.kind == MemoryKind.MOVED }.take(3).forEach { parts += "Your ${it.name} moved to ${it.location}." }
        events.filter { it.kind == MemoryKind.REMOVED && !isMedicine(it.name) }.take(2).forEach { parts += "Your ${it.name} was taken from ${it.location}." }
        events.filter { it.kind == MemoryKind.APPEARED }.take(2).forEach { parts += "Something new: ${it.name}, ${it.location}." }
        parts += if (medicineTakenToday(store)) medicineStatus(store).substringBefore(" That may") else "I haven't seen your medicine picked up today."
        val scans = today.count { it.kind == MemoryKind.SEEN }
        if (scans > 0) parts += "You saved $scans things from photos."
        return parts.joinToString(" ")
    }
}
