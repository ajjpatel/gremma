package com.gremma.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.media.MediaMetadataRetriever
import android.util.Log
import java.io.File

private const val TAG = "GremmaClip"

/**
 * Turns one activity clip from the board into change events:
 * first vs last frame -> appeared / removed / replaced / moved; first vs middle frames -> picked up and put back.
 * A clip can be an .mp4 or a folder of frames (sorted by name).
 */
class ClipProcessor(
    private val store: MemoryStore,
    private val gemma: GemmaService,
    private val embedder: Embedder,
    private val people: PersonDetector,
    private val pose: PoseDetector,
) {
    private val detector = ChangeDetector()

    companion object {
        /** ~2.5 s each on the Pixel; caps background time per clip. */
        private const val MAX_HAND_CALLS = 14
        private val NOT_A_SURFACE = Regex("\\b(wall|air|ceiling|window pane|nothing|person|body|pocket)\\b", RegexOption.IGNORE_CASE)
    }

    data class Outcome(val events: List<MemoryRecord>, val note: String, val hazards: List<MemoryRecord> = emptyList())

    suspend fun process(clip: File, room: String = ""): Outcome {
        val frames = frames(clip)
        if (frames.size < 2) return Outcome(emptyList(), "Clip ${clip.name}: not enough frames.")
        val first = frames.first(); val last = frames.last()
        val time = clip.lastModified().takeIf { it > 0 } ?: System.currentTimeMillis()
        val firstPeople = people.detect(first)
        val lastPeople = people.detect(last)
        val final = detector.compare(first, last, firstPeople + lastPeople).take(4)
        val sx = detector.lastShiftX; val sy = detector.lastShiftY
        Log.i(TAG, "${clip.name}: ${frames.size} frames, ${final.size} final regions, people ${firstPeople.size}/${lastPeople.size}, shift $sx,$sy")
        fun moved(r: Rect) = Rect(r).apply {
            offset(sx.coerceIn(-left, last.width - right), sy.coerceIn(-top, last.height - bottom))
        }

        val events = mutableListOf<MemoryRecord>()
        val removed = mutableListOf<MemoryRecord>(); val appeared = mutableListOf<MemoryRecord>()
        var id = store.nextId()
        for ((i, region) in final.withIndex()) {
            val lastRegion = region.copy(cropBox = moved(region.cropBox))
            val before = name(first, region); val after = name(last, lastRegion)
            val tag = "${clip.nameWithoutExtension}_$i"
            val beforeImg = store.saveImage(Images.jpeg(Images.markBox(Images.crop(first, region.cropBox), region.boxInCrop)), "${tag}_before.jpg")
            val afterImg = store.saveImage(Images.jpeg(Images.markBox(Images.crop(last, lastRegion.cropBox), region.boxInCrop)), "${tag}_after.jpg")
            fun rec(kind: MemoryKind, n: Naming, loc: String) = MemoryRecord(id++, kind, n.name, n.details, loc, room = room,
                timeMs = time, source = "board", beforeImage = beforeImg, afterImage = afterImg)
            val bName = before.name; val aName = after.name
            when {
                bName.isBlank() && aName.isNotBlank() -> appeared += rec(MemoryKind.APPEARED, after, after.on)
                bName.isNotBlank() && aName.isBlank() -> removed += rec(MemoryKind.REMOVED, before, before.on)
                bName.isNotBlank() && aName.isNotBlank() && !sameThing(bName, aName) -> {
                    removed += rec(MemoryKind.REMOVED, before, before.on); appeared += rec(MemoryKind.APPEARED, after, after.on)
                }
            }
        }
        // Same object removed in one place and appearing in another = moved.
        for (r in removed.toList()) {
            val a = appeared.firstOrNull { sameThing(it.name, r.name) } ?: continue
            removed.remove(r); appeared.remove(a)
            events += a.copy(kind = MemoryKind.MOVED, fromLocation = r.location, beforeImage = r.beforeImage)
        }
        events += removed; events += appeared

        // Lifted and put back: visible in a middle frame, gone by the last frame (e.g. the pill bottle).
        val finalBoxes = final.map { it.box }
        val lifted = mutableListOf<ChangeDetector.Region>()
        var maxPeople = maxOf(firstPeople.size, lastPeople.size)
        for (mid in frames.subList(1, frames.size - 1)) {
            val midPeople = people.detect(mid)
            Log.i(TAG, "mid frame ${mid.width}x${mid.height} ${mid.config}: ${midPeople.size} people")
            maxPeople = maxOf(maxPeople, midPeople.size)
            for (r in detector.compare(first, mid, firstPeople + midPeople)) {
                if (finalBoxes.none { Rect.intersects(it, r.box) } && lifted.none { Rect.intersects(it.box, r.box) }) lifted += r
            }
        }
        for ((i, region) in lifted.take(3).withIndex()) {
            val n = name(first, region)
            if (n.name.isBlank()) continue
            val img = store.saveImage(Images.jpeg(Images.markBox(Images.crop(first, region.cropBox), region.boxInCrop)), "${clip.nameWithoutExtension}_lift$i.jpg")
            events += MemoryRecord(id++, MemoryKind.PICKED_UP, n.name, n.details, n.on, room = room, timeMs = time,
                source = "board", beforeImage = img, afterImage = img)
        }

        for (h in watchHands(frames, clip.nameWithoutExtension, time, room) { id++ }) {
            if (events.none { sameThing(it.name, h.name) }) events += h
        }

        val indexed = events.map { it.copy(embedding = embedder.embed(it.sentence(), isQuery = false)) }
        store.addAll(indexed)
        store.addActivity(Activity(time, maxPeople, room))
        val note = if (indexed.isEmpty()) "Clip ${clip.name}: no lasting change." else indexed.joinToString(" ") { it.spoken() }
        val hazards = indexed.filter { it.kind in setOf(MemoryKind.APPEARED, MemoryKind.MOVED) && Routines.isFloor(it.location) }
        return Outcome(indexed, note, hazards)
    }

    data class Naming(val name: String, val details: String, val on: String)

    private data class Held(val frame: Int, val side: String, val crop: Rect, val name: String, val details: String)

    /**
     * What each hand holds over time. Works with a moving camera and catches pick-up-and-put-back,
     * which first-vs-last frame comparison cannot see. Held then empty = put down; still held = taken away;
     * medicine held at all = picked up.
     */
    private suspend fun watchHands(frames: List<Bitmap>, tag: String, time: Long, room: String, nextId: () -> Long): List<MemoryRecord> {
        val sightings = mutableListOf<Held>()
        var calls = 0
        for ((fi, frame) in frames.withIndex()) {
            for (hand in pose.hands(frame)) {
                if (calls++ >= MAX_HAND_CALLS) break
                val row = rows(Prompts.HOLD, "What is this hand holding?", Images.crop(frame, hand.crop)).firstOrNull().orEmpty()
                sightings += Held(fi, hand.side, hand.crop, objectName(row.getOrElse(0) { "" }), row.getOrElse(1) { "" })
            }
        }
        Log.i(TAG, "$tag hands: " + sightings.joinToString { "${it.frame}/${it.side}=${it.name.ifBlank { "-" }}" })

        val events = mutableListOf<MemoryRecord>()
        for ((name, group) in sightings.filter { it.name.isNotBlank() }.groupBy { it.name }) {
            val lastSeen = group.maxBy { it.frame }
            // A thing already sitting at that spot before the person came (e.g. a charger on the sill) is scenery, not held.
            val before = objectName(rows(Prompts.THERE_BEFORE, "What is here?", Images.crop(frames.first(), lastSeen.crop)).firstOrNull()?.firstOrNull().orEmpty())
            if (before.isNotBlank() && (sameThing(before, name) || group.size < 2)) {
                Log.i(TAG, "$tag drop held '$name': '$before' was already there"); continue
            }
            val frame = frames[lastSeen.frame]
            val wide = expand(lastSeen.crop, 2.2f, frame.width, frame.height)
            val where = runCatching { gemma.generate(Prompts.SURFACE, "Where is the hand?", Images.png(Images.crop(frame, wide)), 30, visionTokens = 280) }
                .getOrDefault("").lines().firstOrNull().orEmpty().trim().trimEnd('.').ifBlank { "in view of the home camera" }
            if (NOT_A_SURFACE.containsMatchIn(where) && !Regex("\\b(on|in|under|next to|beside)\\b.*\\b(table|sill|shelf|counter|desk|floor|couch|bed|chair|cabinet|drawer|stand|tray|box|bowl|bag)\\b").containsMatchIn(where)) {
                Log.i(TAG, "$tag drop held '$name': '$where' is not a place to put things"); continue
            }
            val released = sightings.any { it.side == lastSeen.side && it.frame > lastSeen.frame && it.name.isBlank() }
            val kind = when {
                Routines.isMedicine(name) -> MemoryKind.PICKED_UP
                released -> MemoryKind.APPEARED
                else -> MemoryKind.REMOVED
            }
            val img = store.saveImage(Images.jpeg(Images.crop(frame, wide)), "${tag}_hand_${name.replace(' ', '_')}.jpg")
            Log.i(TAG, "$tag hand event: $kind $name $where (seen ${group.size}x, released=$released)")
            events += MemoryRecord(nextId(), kind, name, group.first().details, where, room = room, timeMs = time,
                source = "board", beforeImage = img, afterImage = img)
        }
        return events
    }

    private suspend fun rows(system: String, prompt: String, crop: Bitmap): List<List<String>> = runCatching {
        gemma.generateRows(system, prompt, Images.png(Images.scale(crop, 768)), 30, visionTokens = 280)
    }.onFailure { Log.w(TAG, "hand call failed", it) }.getOrDefault(emptyList())

    private fun objectName(raw: String): String {
        val n = raw.trim().lowercase()
        return if (n.isBlank() || n in setOf("none", "nothing", "empty", "object", "hand", "unknown", "-")) "" else n
    }

    private fun expand(r: Rect, f: Float, w: Int, h: Int): Rect {
        val hw = (r.width() * f / 2).toInt(); val hh = (r.height() * f / 2).toInt()
        return Rect(maxOf(0, r.centerX() - hw), maxOf(0, r.centerY() - hh), minOf(w, r.centerX() + hw), minOf(h, r.centerY() + hh))
    }

    private suspend fun name(frame: Bitmap, region: ChangeDetector.Region): Naming {
        val crop = Images.markBox(Images.crop(frame, region.cropBox), region.boxInCrop)
        val row = runCatching {
            gemma.generateRows(Prompts.NAME_CROP, "What is inside the red box?", Images.png(Images.scale(crop, 768)), 60, visionTokens = 280).firstOrNull()
        }.onFailure { Log.w(TAG, "naming failed", it) }.getOrNull().orEmpty()
        val n = row.getOrElse(0) { "" }.lowercase()
        val empty = n.isBlank() || n in setOf("none", "nothing", "empty", "person", "hand", "shadow", "surface")
        return Naming(if (empty) "" else n, row.getOrElse(1) { "" }, row.getOrElse(2) { "" }.ifBlank { "in view of the home camera" })
    }

    private fun sameThing(a: String, b: String): Boolean {
        val wa = a.lowercase().split(" ").filter { it.length > 2 }.toSet()
        val wb = b.lowercase().split(" ").filter { it.length > 2 }.toSet()
        return a.equals(b, true) || wa.intersect(wb).isNotEmpty()
    }

    private fun frames(clip: File, middle: Int = 10): List<Bitmap> {
        if (clip.isDirectory) {
            val files = clip.listFiles { f -> f.extension.lowercase() in setOf("jpg", "jpeg", "png") }?.sortedBy { it.name } ?: return emptyList()
            if (files.size < 2) return emptyList()
            val pick = (listOf(0) + (1..middle).map { it * (files.size - 1) / (middle + 1) } + listOf(files.size - 1)).distinct()
            return pick.mapNotNull { BitmapFactory.decodeFile(files[it].absolutePath)?.let { b -> Images.scale(b, 1280) } }
        }
        val mmr = MediaMetadataRetriever()
        return try {
            mmr.setDataSource(clip.absolutePath)
            val durUs = (mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L) * 1000
            val times = listOf(0L) + (1..middle).map { durUs * it / (middle + 1) } + listOf(maxOf(0L, durUs - 100_000))
            times.mapNotNull { mmr.getFrameAtTime(it, MediaMetadataRetriever.OPTION_CLOSEST)?.let { b -> Images.scale(b, 1280) } }
        } catch (e: Exception) {
            Log.w(TAG, "could not read ${clip.name}", e); emptyList()
        } finally { mmr.release() }
    }
}
