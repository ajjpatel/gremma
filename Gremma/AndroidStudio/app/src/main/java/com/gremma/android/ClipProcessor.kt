package com.gremma.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.graphics.Rect
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.time.OffsetDateTime

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
        private const val MAX_HAND_CALLS = 10
        /** Pose runs this often; a put-down takes about a second. */
        private const val SAMPLE_MS = 500L
        private const val MIDDLE_FRAMES = 10
        private const val ANALYSIS_SIDE = 1280
        private val NOT_A_SURFACE = Regex("\\b(wall|air|ceiling|window pane|nothing|person|body|pocket)\\b", RegexOption.IGNORE_CASE)
    }

    data class Outcome(val events: List<MemoryRecord>, val note: String, val hazards: List<MemoryRecord> = emptyList())

    /** [clip] is an .mp4, a board upload directory (video.mp4 + metadata.json), or a folder of frames. Throws if unreadable, so it is retried. */
    suspend fun process(clip: File, room: String = "", onSaved: () -> Unit = {}): Outcome {
        val video = File(clip, "video.mp4").takeIf { clip.isDirectory && it.isFile } ?: clip
        FrameSource(video).use { return process(clip, it, room, onSaved) }
    }

    private suspend fun process(clip: File, src: FrameSource, room: String, onSaved: () -> Unit): Outcome {
        val started = System.currentTimeMillis()
        val dur = src.durationMs
        val times = (0L..maxOf(0L, dur - 100) step SAMPLE_MS).toList().let { t -> if (dur - 100 - t.last() > 100) t + (dur - 100) else t }
        val midAt = (1..MIDDLE_FRAMES).map { times[it * (times.size - 1) / (MIDDLE_FRAMES + 1)] }.filter { it != times.first() && it != times.last() }.toSet()

        // One pass over the clip: keep the frames the change detector needs, note where hands are in every sample.
        val kept = mutableListOf<Pair<Long, Bitmap>>()
        val spots = mutableListOf<Spot>()
        src.scan(times, ANALYSIS_SIDE) { t, f ->
            if (t == times.first() || t == times.last() || t in midAt) kept += t to f
            for (h in pose.hands(f)) spots += Spot(t, h.side, h.crop, thumb(f, h.crop))
        }
        check(kept.size >= 2) { "Clip ${clip.name}: not enough readable frames." }
        val frames = kept.map { it.second }
        val first = frames.first(); val last = frames.last()
        val t0 = startTime(clip, dur)
        val time = t0 + dur
        Log.i(TAG, "${clip.name}: ${dur / 1000.0}s, ${times.size} samples, ${spots.size} hand spots, read in ${System.currentTimeMillis() - started} ms")

        // Each event is indexed the moment it is found, so it can be asked about while the rest of the clip is still running.
        val events = mutableListOf<MemoryRecord>()
        var id = store.nextId()
        suspend fun save(r: MemoryRecord) {
            if (events.any { sameThing(it.name, r.name) }) return
            val indexed = r.copy(embedding = embedder.embed(r.sentence(), isQuery = false))
            store.add(indexed); events += indexed
            Log.i(TAG, "${clip.name}: saved ${r.kind} ${r.name} after ${System.currentTimeMillis() - started} ms")
            onSaved()
        }

        // Hands first: the most reliable signal, and it sees small things the frame difference misses.
        for (h in watchHands(src, spots, first.width, t0, clip.nameWithoutExtension, room) { id++ }) save(h)

        // With people in view, only changes a hand came near are worth naming; the rest are light and camera noise.
        // A clip with nobody detected keeps every change (pose can miss a person entirely).
        fun reachable(box: Rect) = spots.isEmpty() || spots.any { Rect.intersects(expand(it.crop, 1.5f, first.width, first.height), box) }

        val firstPeople = people.detect(first)
        val lastPeople = people.detect(last)
        val allFinal = detector.compare(first, last, firstPeople + lastPeople).take(4)
        val final = allFinal.filter { reachable(it.box) }
        val sx = detector.lastShiftX; val sy = detector.lastShiftY
        Log.i(TAG, "${clip.name}: ${frames.size} frames, ${final.size} of ${allFinal.size} final regions within reach, people ${firstPeople.size}/${lastPeople.size}, shift $sx,$sy")
        fun moved(r: Rect) = Rect(r).apply {
            offset(sx.coerceIn(-left, last.width - right), sy.coerceIn(-top, last.height - bottom))
        }

        val removed = mutableListOf<MemoryRecord>(); val appeared = mutableListOf<MemoryRecord>()
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
            save(a.copy(kind = MemoryKind.MOVED, fromLocation = r.location, beforeImage = r.beforeImage))
        }
        for (r in removed + appeared) save(r)

        // Lifted and put back: visible in a middle frame, gone by the last frame (e.g. the pill bottle).
        val finalBoxes = allFinal.map { it.box }
        val lifted = mutableListOf<Pair<Long, ChangeDetector.Region>>()
        var maxPeople = maxOf(firstPeople.size, lastPeople.size)
        for ((t, mid) in kept.subList(1, kept.size - 1)) {
            val midPeople = people.detect(mid)
            maxPeople = maxOf(maxPeople, midPeople.size)
            for (r in detector.compare(first, mid, firstPeople + midPeople)) {
                if (!reachable(r.box)) continue
                if (finalBoxes.none { Rect.intersects(it, r.box) } && lifted.none { Rect.intersects(it.second.box, r.box) }) lifted += t to r
            }
        }
        for ((i, lift) in lifted.take(3).withIndex()) {
            val (t, region) = lift
            val n = name(first, region)
            if (n.name.isBlank()) continue
            val img = store.saveImage(Images.jpeg(Images.markBox(Images.crop(first, region.cropBox), region.boxInCrop)), "${clip.nameWithoutExtension}_lift$i.jpg")
            save(MemoryRecord(id++, MemoryKind.PICKED_UP, n.name, n.details, n.on, room = room, timeMs = t0 + t,
                source = "board", beforeImage = img, afterImage = img))
        }

        val indexed = events.toList()
        store.addActivity(Activity(time, maxPeople, room))
        Log.i(TAG, "${clip.name}: ${indexed.size} events in ${System.currentTimeMillis() - started} ms")
        val note = if (indexed.isEmpty()) "Clip ${clip.name}: no lasting change." else indexed.joinToString(" ") { it.spoken() }
        val hazards = indexed.filter { it.kind in setOf(MemoryKind.APPEARED, MemoryKind.MOVED) && Routines.isFloor(it.location) }
        return Outcome(indexed, note, hazards)
    }

    data class Naming(val name: String, val details: String, val on: String)

    /** A hand found by pose at [ms] into the clip; [crop] is in analysis-frame pixels. */
    private class Spot(val ms: Long, val side: String, val crop: Rect, val thumb: FloatArray)

    private data class Held(val ms: Long, val side: String, val crop: Rect, val name: String, val details: String)

    /**
     * What each hand holds over time. Works with a moving camera and catches pick-up-and-put-back,
     * which first-vs-last frame comparison cannot see. Held then empty = put down; still held = taken away;
     * medicine held at all = picked up. Gemma sees the hand crop cut from the full-resolution frame.
     */
    private suspend fun watchHands(src: FrameSource, spots: List<Spot>, analysisWidth: Int, t0: Long, tag: String, room: String,
                                   nextId: () -> Long): List<MemoryRecord> {
        val sightings = mutableListOf<Held>()
        val picked = pick(spots, MAX_HAND_CALLS)
        for ((ms, group) in picked.groupBy { it.ms }) {
            val full = src.at(ms, Int.MAX_VALUE) ?: continue
            for (spot in group) {
                val row = rows(Prompts.HOLD, "What is this hand holding?", fullCrop(full, spot.crop, analysisWidth)).firstOrNull().orEmpty()
                sightings += Held(ms, spot.side, spot.crop, objectName(row.getOrElse(0) { "" }), row.getOrElse(1) { "" })
            }
        }
        Log.i(TAG, "$tag hands (${picked.size} of ${spots.size} spots): " + sightings.joinToString { "${it.ms / 1000.0}s/${it.side}=${it.name.ifBlank { "-" }}" })

        val events = mutableListOf<MemoryRecord>()
        val firstFull by lazy { src.at(0, Int.MAX_VALUE) }
        for ((name, group) in sightings.filter { it.name.isNotBlank() }.groupBy { it.name }) {
            val lastSeen = group.maxBy { it.ms }
            // A thing already sitting at that spot before the person came (e.g. a charger on the sill) is scenery, not held.
            val before = firstFull?.let { f -> objectName(rows(Prompts.THERE_BEFORE, "What is here?", fullCrop(f, lastSeen.crop, analysisWidth)).firstOrNull()?.firstOrNull().orEmpty()) }.orEmpty()
            if (before.isNotBlank() && (sameThing(before, name) || group.size < 2)) {
                Log.i(TAG, "$tag drop held '$name': '$before' was already there"); continue
            }
            val full = src.at(lastSeen.ms, Int.MAX_VALUE) ?: continue
            val k = full.width.toFloat() / analysisWidth
            val wide = expand(scaled(lastSeen.crop, k), 2.2f, full.width, full.height)
            val wideImg = Images.scale(Images.crop(full, wide), 1024)
            val where = runCatching { gemma.generate(Prompts.SURFACE, "Where is the hand?", Images.png(wideImg), 30, visionTokens = 280) }
                .getOrDefault("").lines().firstOrNull().orEmpty().trim().trimEnd('.').ifBlank { "in view of the home camera" }
            if (NOT_A_SURFACE.containsMatchIn(where) && !Regex("\\b(on|in|under|next to|beside)\\b.*\\b(table|sill|shelf|counter|desk|floor|couch|bed|chair|cabinet|drawer|stand|tray|box|bowl|bag)\\b").containsMatchIn(where)) {
                Log.i(TAG, "$tag drop held '$name': '$where' is not a place to put things"); continue
            }
            val released = sightings.any { it.side == lastSeen.side && it.ms > lastSeen.ms && it.name.isBlank() }
            val kind = when {
                Routines.isMedicine(name) -> MemoryKind.PICKED_UP
                released -> MemoryKind.APPEARED
                else -> MemoryKind.REMOVED
            }
            val img = store.saveImage(Images.jpeg(wideImg), "${tag}_hand_${name.replace(' ', '_')}.jpg")
            Log.i(TAG, "$tag hand event: $kind $name $where at ${lastSeen.ms / 1000.0}s (seen ${group.size}x, released=$released)")
            events += MemoryRecord(nextId(), kind, name, group.first().details, where, room = room, timeMs = t0 + lastSeen.ms,
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

    /**
     * Which hand spots Gemma looks at. A hand that stays put holding the same thing is asked about once;
     * the rest are spread over the clip, always keeping each hand's last spot (shows whether it ended empty).
     */
    private fun pick(spots: List<Spot>, budget: Int): List<Spot> {
        val distinct = mutableListOf<Spot>()
        for (s in spots) {
            val prev = distinct.lastOrNull { it.side == s.side }
            if (prev != null && similar(prev, s)) continue
            distinct += s
        }
        if (distinct.size <= budget) return distinct
        val must = distinct.groupBy { it.side }.values.map { it.last() }.toSet()
        val rest = distinct.filter { it !in must }
        val n = (budget - must.size).coerceAtLeast(0)
        return ((0 until n).map { rest[it * rest.size / n] } + must).distinct().sortedBy { it.ms }
    }

    private fun similar(a: Spot, b: Spot): Boolean {
        val side = maxOf(a.crop.width(), a.crop.height()).toFloat()
        val moved = kotlin.math.hypot((a.crop.centerX() - b.crop.centerX()).toFloat(), (a.crop.centerY() - b.crop.centerY()).toFloat())
        val diff = a.thumb.indices.sumOf { kotlin.math.abs(a.thumb[it] - b.thumb[it]).toDouble() } / a.thumb.size
        return moved < 0.15f * side && diff < 12.0
    }

    /** 16x16 grey thumbnail of the hand crop. */
    private fun thumb(frame: Bitmap, r: Rect): FloatArray {
        val small = Bitmap.createScaledBitmap(Images.crop(frame, r), 16, 16, true)
        val px = IntArray(256).also { small.getPixels(it, 0, 16, 0, 0, 16, 16) }
        return FloatArray(256) { i -> val p = px[i]; (0.299f * (p shr 16 and 255) + 0.587f * (p shr 8 and 255) + 0.114f * (p and 255)) }
    }

    private fun scaled(r: Rect, k: Float) = Rect((r.left * k).toInt(), (r.top * k).toInt(), (r.right * k).toInt(), (r.bottom * k).toInt())

    /** [r] is in analysis-frame pixels; cut the same area from the full-resolution [full]. */
    private fun fullCrop(full: Bitmap, r: Rect, analysisWidth: Int): Bitmap {
        val s = scaled(r, full.width.toFloat() / analysisWidth)
        s.intersect(0, 0, full.width, full.height)
        return Images.crop(full, s)
    }

    /** Wall-clock time of the clip's first frame: the board's started_at if it sent one, else file time minus duration. */
    private fun startTime(clip: File, durMs: Long): Long {
        val now = System.currentTimeMillis()
        val board = runCatching {
            val metaFile = if (clip.isDirectory) File(clip, "metadata.json") else File(clip.parentFile, clip.nameWithoutExtension + ".json")
            val meta = JSONObject(metaFile.readText())
            OffsetDateTime.parse(meta.getString("started_at")).toInstant().toEpochMilli()
        }.getOrNull()
        // An unsynced board clock (e.g. 1970) would scatter events; trust it only if it's near today.
        if (board != null && kotlin.math.abs(now - board) < 2 * 86_400_000L) return board
        val file = clip.lastModified().takeIf { it > 0 } ?: now
        return file - durMs
    }

    /** Frames by time: an .mp4 via MediaMetadataRetriever, or a folder of images taken as one per [SAMPLE_MS]. */
    private class FrameSource(private val clip: File) : AutoCloseable {
        private val mmr: MediaMetadataRetriever?
        private val files: List<File>
        val durationMs: Long

        /**
         * Every frame at [times] (ascending), in order. For video this decodes the stream once front to back;
         * seeking per frame costs ~400 ms at 1080p because each seek re-decodes from the previous keyframe.
         */
        fun scan(times: List<Long>, maxSide: Int, onFrame: (Long, Bitmap) -> Unit) {
            val done = mutableSetOf<Long>()
            if (mmr != null) {
                val started = System.currentTimeMillis()
                runCatching { decodeInOrder(times, maxSide) { t, b -> done += t; onFrame(t, b) } }
                    .onFailure { Log.w(TAG, "sequential decode failed, seeking instead", it) }
                Log.i(TAG, "${clip.name}: decoded ${done.size}/${times.size} frames in order in ${System.currentTimeMillis() - started} ms")
            }
            for (t in times) if (t !in done) at(t, maxSide)?.let { onFrame(t, it) }
        }

        private fun decodeInOrder(times: List<Long>, maxSide: Int, onFrame: (Long, Bitmap) -> Unit) {
            val ex = MediaExtractor().apply { setDataSource(clip.absolutePath) }
            val track = (0 until ex.trackCount).first { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME).orEmpty().startsWith("video/") }
            ex.selectTrack(track)
            val fmt = ex.getTrackFormat(track)
            val rotation = if (fmt.containsKey(MediaFormat.KEY_ROTATION)) fmt.getInteger(MediaFormat.KEY_ROTATION) else 0
            val halfFrameMs = if (fmt.containsKey(MediaFormat.KEY_FRAME_RATE)) 500L / maxOf(1, fmt.getInteger(MediaFormat.KEY_FRAME_RATE)) else 16L
            fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            val codec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
            var convertMs = 0L; var callbackMs = 0L
            try {
                codec.configure(fmt, null, null, 0); codec.start()
                val info = MediaCodec.BufferInfo()
                var next = 0; var inputDone = false
                while (next < times.size) {
                    while (!inputDone) {
                        val i = codec.dequeueInputBuffer(0)
                        if (i < 0) break
                        val n = ex.readSampleData(codec.getInputBuffer(i)!!, 0)
                        if (n < 0) { codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true }
                        else { codec.queueInputBuffer(i, 0, n, ex.sampleTime, 0); ex.advance() }
                    }
                    val o = codec.dequeueOutputBuffer(info, 5_000)
                    if (o < 0) continue
                    val ms = info.presentationTimeUs / 1000
                    if (info.size > 0 && ms >= times[next] - halfFrameMs) {
                        val c0 = System.currentTimeMillis()
                        val bmp = codec.getOutputImage(o)?.use { img -> rotate(yuvToBitmap(img, maxSide), rotation) }
                        val c1 = System.currentTimeMillis(); convertMs += c1 - c0
                        bmp?.let { onFrame(times[next], it) }; callbackMs += System.currentTimeMillis() - c1
                        while (next < times.size && times[next] <= ms + halfFrameMs) next++
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            } finally {
                Log.i(TAG, "decoder ${codec.name}: convert $convertMs ms, pose $callbackMs ms")
                runCatching { codec.stop() }; codec.release(); ex.release()
            }
        }

        /** YUV_420_888 to ARGB, sampled straight down to [maxSide] (BT.601, video range). */
        private fun yuvToBitmap(img: Image, maxSide: Int): Bitmap {
            val crop = img.cropRect
            val s = minOf(1f, maxSide.toFloat() / maxOf(crop.width(), crop.height()))
            val ow = (crop.width() * s).toInt(); val oh = (crop.height() * s).toInt()
            val (yp, up, vp) = img.planes
            fun bytes(p: Image.Plane) = p.buffer.let { b -> ByteArray(b.remaining()).also { b.get(it) } }
            val yb = bytes(yp); val ub = bytes(up); val vb = bytes(vp)
            val yRow = yp.rowStride; val uvRow = up.rowStride; val uvPix = up.pixelStride
            val xs = IntArray(ow) { crop.left + (it / s).toInt() }
            val px = IntArray(ow * oh)
            for (oy in 0 until oh) {
                val sy = crop.top + (oy / s).toInt()
                val yBase = sy * yRow; val uvBase = (sy / 2) * uvRow
                for (ox in 0 until ow) {
                    val sx = xs[ox]
                    val y = 1.164f * ((yb[yBase + sx].toInt() and 255) - 16)
                    val uvAt = uvBase + (sx / 2) * uvPix
                    val u = (ub[uvAt].toInt() and 255) - 128f
                    val v = (vb[uvAt].toInt() and 255) - 128f
                    val r = (y + 1.596f * v).toInt().coerceIn(0, 255)
                    val g = (y - 0.392f * u - 0.813f * v).toInt().coerceIn(0, 255)
                    val b = (y + 2.017f * u).toInt().coerceIn(0, 255)
                    px[oy * ow + ox] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
                }
            }
            return Bitmap.createBitmap(px, ow, oh, Bitmap.Config.ARGB_8888)
        }

        private fun rotate(b: Bitmap, degrees: Int): Bitmap =
            if (degrees % 360 == 0) b else Bitmap.createBitmap(b, 0, 0, b.width, b.height, Matrix().apply { postRotate(degrees.toFloat()) }, true)

        init {
            if (clip.isDirectory) {
                mmr = null
                files = clip.listFiles { f -> f.extension.lowercase() in setOf("jpg", "jpeg", "png") }?.sortedBy { it.name }.orEmpty()
                durationMs = files.size * SAMPLE_MS
            } else {
                files = emptyList()
                mmr = MediaMetadataRetriever().apply { setDataSource(clip.absolutePath) }
                durationMs = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            }
        }

        fun at(ms: Long, maxSide: Int): Bitmap? = runCatching {
            val b = if (mmr != null) mmr.getFrameAtTime(ms * 1000, MediaMetadataRetriever.OPTION_CLOSEST)
                else files.getOrNull((ms / SAMPLE_MS).toInt().coerceAtMost(files.size - 1))?.let { BitmapFactory.decodeFile(it.absolutePath) }
            b?.let { Images.scale(it, maxSide) }
        }.onFailure { Log.w(TAG, "frame at $ms ms failed", it) }.getOrNull()

        override fun close() { mmr?.release() }
    }
}
