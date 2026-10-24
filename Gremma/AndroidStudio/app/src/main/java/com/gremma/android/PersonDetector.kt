package com.gremma.android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Rect
import android.util.Log
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.objectdetector.ObjectDetector

/** Same model and threshold as hub/people.py. Returns no boxes (never crashes) if the model is missing. */
class PersonDetector(context: Context) {
    private val detector: ObjectDetector? = runCatching {
        ObjectDetector.createFromOptions(context, ObjectDetector.ObjectDetectorOptions.builder()
            .setBaseOptions(BaseOptions.builder().setModelAssetPath("efficientdet_lite0_int8.tflite").build())
            .setScoreThreshold(0.25f)
            .setCategoryAllowlist(listOf("person"))
            .setMaxResults(5)
            .build())
    }.onFailure { Log.w("GremmaPeople", "person detector unavailable", it) }.getOrNull()

    fun detect(bmp: Bitmap): List<Rect> {
        val d = detector ?: return emptyList()
        val argb = if (bmp.config == Bitmap.Config.ARGB_8888) bmp else bmp.copy(Bitmap.Config.ARGB_8888, false)
        return runCatching {
            d.detect(BitmapImageBuilder(argb).build()).detections().map { det ->
                val b = det.boundingBox()
                Rect(b.left.toInt(), b.top.toInt(), b.right.toInt(), b.bottom.toInt())
            }
        }.onFailure { Log.w("GremmaPeople", "detect failed (${bmp.config})", it) }.getOrDefault(emptyList())
    }
}
