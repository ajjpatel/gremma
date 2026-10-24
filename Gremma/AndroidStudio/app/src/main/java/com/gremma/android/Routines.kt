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

    private val FLOOR = Regex("\\b(floor|ground|rug|carpet|doorway|stairs?|steps|hallway|walkway)\\b", RegexOption.IGNORE_CASE)

    fun isFloor(location: String) = FLOOR.containsMatchIn(location)

    fun hazardAlert(r: MemoryRecord): String = "Careful: a ${r.name} was left ${r.location}."

    /** Things that appeared on the floor today and haven't been taken away since. */
    fun floorItems(store: MemoryStore): List<MemoryRecord> {
        val all = store.all()
        return all.filter { it.timeMs >= startOfToday() && it.kind in setOf(MemoryKind.APPEARED, MemoryKind.MOVED) && isFloor(it.location) }
            .filter { item -> all.none { it.kind == MemoryKind.REMOVED && it.timeMs > item.timeMs && it.name.equals(item.name, true) } }
            .distinctBy { it.name.lowercase() }
    }

    /** Clips with a person, merged when less than 10 minutes apart. Doesn't try to identify who. */
    fun visits(store: MemoryStore, sinceMs: Long = startOfToday()): List<Long> {
        val times = store.activity().filter { it.people > 0 && it.timeMs >= sinceMs }.map { it.timeMs }.sorted()
        val out = mutableListOf<Long>()
        for (t in times) if (out.isEmpty() || t - out.last() > 10 * 60_000) out += t
        return out
    }

    fun visitors(store: MemoryStore): String {
        val v = visits(store)
        return when {
            v.isEmpty() -> "The home camera hasn't seen anyone today."
            v.size == 1 -> "Someone was seen at ${clock(v[0])}."
            else -> "People were seen ${v.size} times today, at ${v.takeLast(4).joinToString(", ") { clock(it) }}."
        }
    }

    fun lastMovement(store: MemoryStore): String {
        val last = store.activity().firstOrNull() ?: return "The home camera hasn't seen any movement yet."
        val mins = (System.currentTimeMillis() - last.timeMs) / 60_000
        val ago = when {
            mins < 2 -> "just now"
            mins < 60 -> "$mins minutes ago"
            mins < 120 -> "an hour ago"
            else -> "${mins / 60} hours ago"
        }
        return "The last movement was at ${clock(last.timeMs)}, $ago."
    }

    /** Non-null when no clip has arrived for [hours] during the day (alert for people living alone). */
    fun inactivityAlert(store: MemoryStore, hours: Double): String? {
        val last = store.activity().firstOrNull() ?: return null
        val quietMs = System.currentTimeMillis() - last.timeMs
        return if (quietMs >= hours * 3_600_000) "No movement seen since ${clock(last.timeMs)}." else null
    }

    fun dailySummary(store: MemoryStore): String {
        val parts = mutableListOf<String>()
        val doses = store.all().filter { it.timeMs >= startOfToday() && isMedicine(it.name) && it.kind in setOf(MemoryKind.PICKED_UP, MemoryKind.REMOVED, MemoryKind.MOVED) }
        parts += if (doses.isEmpty()) "I haven't seen your medicine taken today."
            else "Today you took your medicine at ${doses.sortedBy { it.timeMs }.joinToString(" and ") { clock(it.timeMs) }}."
        val clips = store.activity().count { it.timeMs >= startOfToday() }
        parts += if (clips == 0) "The home camera saw no activity." else "The home camera saw activity $clips time${if (clips == 1) "" else "s"}."
        val v = visits(store)
        if (v.isNotEmpty()) parts += "Someone was around at ${v.takeLast(3).joinToString(", ") { clock(it) }}."
        val events = store.all().filter { it.timeMs >= startOfToday() && it.kind != MemoryKind.SEEN && !isMedicine(it.name) }
        events.filter { it.kind == MemoryKind.MOVED }.take(2).forEach { parts += "Your ${it.name} moved to ${it.location}." }
        events.filter { it.kind == MemoryKind.REMOVED }.take(2).forEach { parts += "Your ${it.name} was taken from ${it.location}." }
        val floor = floorItems(store)
        parts += if (floor.isEmpty()) "Nothing was left on the floor." else floor.take(3).joinToString(" ") { "A ${it.name} is still ${it.location}." }
        return parts.joinToString(" ")
    }
}
