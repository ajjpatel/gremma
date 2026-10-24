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
) {
    private val detector = ChangeDetector()

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

        val indexed = events.map { it.copy(embedding = embedder.embed(it.sentence(), isQuery = false)) }
        store.addAll(indexed)
        store.addActivity(Activity(time, maxPeople, room))
        val note = if (indexed.isEmpty()) "Clip ${clip.name}: no lasting change." else indexed.joinToString(" ") { it.spoken() }
        val hazards = indexed.filter { it.kind in setOf(MemoryKind.APPEARED, MemoryKind.MOVED) && Routines.isFloor(it.location) }
        return Outcome(indexed, note, hazards)
    }

    data class Naming(val name: String, val details: String, val on: String)

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

    private fun frames(clip: File, middle: Int = 6): List<Bitmap> {
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
