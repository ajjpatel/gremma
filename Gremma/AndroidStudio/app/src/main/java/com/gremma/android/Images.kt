package com.gremma.android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.Rect
import android.net.Uri
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.roundToInt

object Images {
    /** Decodes with EXIF rotation applied, longest side at most [maxSide]. */
    fun load(context: Context, uri: Uri, maxSide: Int = 1024): Bitmap {
        val src = ImageDecoder.createSource(context.contentResolver, uri)
        return ImageDecoder.decodeBitmap(src) { decoder, info, _ ->
            val s = maxSide.toFloat() / max(info.size.width, info.size.height)
            if (s < 1f) decoder.setTargetSize((info.size.width * s).roundToInt(), (info.size.height * s).roundToInt())
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
    }

    fun scale(bmp: Bitmap, maxSide: Int): Bitmap {
        val s = maxSide.toFloat() / max(bmp.width, bmp.height)
        return if (s >= 1f) bmp else Bitmap.createScaledBitmap(bmp, (bmp.width * s).roundToInt(), (bmp.height * s).roundToInt(), true)
    }

    fun png(bmp: Bitmap): ByteArray = ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()

    fun jpeg(bmp: Bitmap, quality: Int = 85): ByteArray = ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.JPEG, quality, it) }.toByteArray()

    fun crop(bmp: Bitmap, r: Rect): Bitmap = Bitmap.createBitmap(bmp, r.left, r.top, r.width(), r.height())

    /** Copy of [bmp] with a red rectangle, the cue Gemma is told to look inside. */
    fun markBox(bmp: Bitmap, r: Rect): Bitmap {
        val out = bmp.copy(Bitmap.Config.ARGB_8888, true)
        val paint = Paint().apply { color = 0xFFFF0000.toInt(); style = Paint.Style.STROKE; strokeWidth = max(3f, bmp.width / 120f) }
        Canvas(out).drawRect(r, paint)
        return out
    }
}
