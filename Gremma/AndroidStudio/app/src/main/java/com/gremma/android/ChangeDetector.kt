package com.gremma.android

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Rect
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Kotlin port of hub/delta.py for clips: compares a reference frame with a later frame on a 16-column
 * cell grid, with lighting gain = median of per-cell brightness ratios, person cells masked out,
 * and whole-frame changes treated as a lighting/camera change rather than an object change.
 */
class ChangeDetector(
    private val width: Int = 480,
    private val cell: Int = 20,
    private val pixelThreshold: Int = 28,
    private val cellFraction: Float = 0.08f,
    private val maxFrameFraction: Float = 0.5f,
) {
    data class Region(val box: Rect, val cropBox: Rect, val boxInCrop: Rect, val cells: Int)

    private class Gray(val w: Int, val h: Int, val px: IntArray)

    private fun gray(bmp: Bitmap, h: Int): Gray {
        val small = Bitmap.createScaledBitmap(bmp, width, h, true)
        val raw = IntArray(width * h)
        small.getPixels(raw, 0, width, 0, 0, width, h)
        val g = IntArray(raw.size) { val c = raw[it]; (Color.red(c) * 299 + Color.green(c) * 587 + Color.blue(c) * 114) / 1000 }
        return Gray(width, h, blur(g, width, h))
    }

    private fun blur(src: IntArray, w: Int, h: Int, r: Int = 2): IntArray {
        val tmp = IntArray(src.size); val out = IntArray(src.size)
        for (y in 0 until h) for (x in 0 until w) {
            var s = 0; var n = 0
            for (dx in -r..r) { val xx = x + dx; if (xx in 0 until w) { s += src[y * w + xx]; n++ } }
            tmp[y * w + x] = s / n
        }
        for (y in 0 until h) for (x in 0 until w) {
            var s = 0; var n = 0
            for (dy in -r..r) { val yy = y + dy; if (yy in 0 until h) { s += tmp[yy * w + x]; n++ } }
            out[y * w + x] = s / n
        }
        return out
    }

    /** Camera shift of the last [compare]'s after-frame, in full-resolution pixels (after = before moved by this). */
    var lastShiftX = 0; private set
    var lastShiftY = 0; private set

    /** Global translation minimising mean abs difference; handles a nudged or handheld camera. */
    private fun shift(a: Gray, b: Gray, range: Int = 40): Pair<Int, Int> {
        fun cost(dx: Int, dy: Int, step: Int): Float {
            var s = 0L; var n = 0
            var y = range
            while (y < a.h - range) {
                var x = range
                while (x < a.w - range) { s += abs(a.px[y * a.w + x] - b.px[(y + dy) * a.w + x + dx]); n++; x += step }
                y += step
            }
            return s.toFloat() / max(1, n)
        }
        var best = 0 to 0; var bestCost = cost(0, 0, 4)
        for (dy in -range..range step 2) for (dx in -range..range step 2) {
            val c = cost(dx, dy, 4); if (c < bestCost) { bestCost = c; best = dx to dy }
        }
        val (cx, cy) = best
        for (dy in cy - 1..cy + 1) for (dx in cx - 1..cx + 1) {
            if (abs(dx) > range || abs(dy) > range) continue
            val c = cost(dx, dy, 2); if (c < bestCost) { bestCost = c; best = dx to dy }
        }
        return best
    }

    /** [people] are boxes in [after]'s full-resolution coordinates. */
    fun compare(before: Bitmap, after: Bitmap, people: List<Rect> = emptyList()): List<Region> {
        val rows = max(1, (before.height.toFloat() / before.width * width / cell).toInt())
        val h = rows * cell
        val cols = width / cell
        val a = gray(before, h)
        val bRaw = gray(after, h)
        val (dx, dy) = shift(a, bRaw)
        val b = if (dx == 0 && dy == 0) bRaw else Gray(width, h, IntArray(width * h) { i ->
            val x = i % width + dx; val y = i / width + dy
            if (x in 0 until width && y in 0 until h) bRaw.px[y * width + x] else a.px[i]
        })
        lastShiftX = (dx * before.width.toFloat() / width).toInt(); lastShiftY = (dy * before.height.toFloat() / h).toInt()

        val means = Array(2) { FloatArray(rows * cols) }
        for (cy in 0 until rows) for (cx in 0 until cols) {
            var sa = 0L; var sb = 0L
            for (y in cy * cell until (cy + 1) * cell) for (x in cx * cell until (cx + 1) * cell) { sa += a.px[y * width + x]; sb += b.px[y * width + x] }
            means[0][cy * cols + cx] = sa.toFloat() / (cell * cell); means[1][cy * cols + cx] = sb.toFloat() / (cell * cell)
        }
        val ratios = (0 until rows * cols).filter { means[1][it] > 20 && means[0][it] > 20 }.map { means[0][it] / means[1][it] }.sorted()
        val gain = if (ratios.isEmpty()) 1f else ratios[ratios.size / 2].coerceIn(0.5f, 2f)

        val sx = before.width.toFloat() / width; val sy = before.height.toFloat() / h
        val blocked = BooleanArray(rows * cols)
        for (p in people) {
            val x0 = ((p.left - lastShiftX) / sx / cell).toInt() - 1; val x1 = ((p.right - lastShiftX) / sx / cell).toInt() + 1
            val y0 = ((p.top - lastShiftY) / sy / cell).toInt() - 1; val y1 = ((p.bottom - lastShiftY) / sy / cell).toInt() + 1
            for (cy in max(0, y0)..min(rows - 1, y1)) for (cx in max(0, x0)..min(cols - 1, x1)) blocked[cy * cols + cx] = true
        }

        val differs = BooleanArray(rows * cols)
        var changedCells = 0
        for (cy in 0 until rows) for (cx in 0 until cols) {
            var n = 0
            for (y in cy * cell until (cy + 1) * cell) for (x in cx * cell until (cx + 1) * cell) {
                val i = y * width + x
                if (abs(a.px[i] - min(255f, b.px[i] * gain)) > pixelThreshold) n++
            }
            val d = n > cellFraction * cell * cell
            if (d) changedCells++
            // Windows/sky: auto-exposure makes them flicker, and nothing is ever placed on them.
            val overexposed = max(means[0][cy * cols + cx], means[1][cy * cols + cx]) > 200
            differs[cy * cols + cx] = d && !blocked[cy * cols + cx] && !overexposed
        }
        if (changedCells > maxFrameFraction * rows * cols) return emptyList()

        val label = IntArray(rows * cols) { -1 }
        val regions = mutableListOf<Region>()
        for (start in 0 until rows * cols) {
            if (!differs[start] || label[start] >= 0) continue
            val stack = ArrayDeque<Int>().apply { add(start) }
            label[start] = start
            var minX = cols; var minY = rows; var maxX = -1; var maxY = -1; var count = 0
            while (stack.isNotEmpty()) {
                val c = stack.removeLast(); val cx = c % cols; val cy = c / cols
                count++; minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy)
                for (dy in -1..1) for (dx in -1..1) {
                    val nx = cx + dx; val ny = cy + dy
                    if (nx in 0 until cols && ny in 0 until rows) {
                        val ni = ny * cols + nx
                        if (differs[ni] && label[ni] < 0) { label[ni] = start; stack.add(ni) }
                    }
                }
            }
            val box = Rect((minX * cell * sx).toInt(), (minY * cell * sy).toInt(),
                min(before.width, ((maxX + 1) * cell * sx).toInt()), min(before.height, ((maxY + 1) * cell * sy).toInt()))
            regions += Region(box, cropAround(box, before.width, before.height), Rect(), count).let {
                it.copy(boxInCrop = Rect(box.left - it.cropBox.left, box.top - it.cropBox.top, box.right - it.cropBox.left, box.bottom - it.cropBox.top))
            }
        }
        return regions.sortedByDescending { it.cells }
    }

    private fun cropAround(box: Rect, w: Int, h: Int): Rect {
        val side = min(min(w, h), max(320, (max(box.width(), box.height()) * 2)))
        val cx = box.centerX(); val cy = box.centerY()
        val left = (cx - side / 2).coerceIn(0, w - side); val top = (cy - side / 2).coerceIn(0, h - side)
        return Rect(left, top, left + side, top + side)
    }
}
