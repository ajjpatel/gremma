package com.gremma.android

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Rect
import android.util.Log
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * Finds where each hand is via body pose (elbow, wrist, index knuckle). More robust than a hand detector
 * when the hand is small or blurred. Same geometry as prompt-tests/wrist_test.py, which found "keys" on the real clip.
 */
class PoseDetector(context: Context) {
    data class Hand(val side: String, val crop: Rect)

    // CPU: the GPU delegate saved ~3 s per clip but cost ~60 s to initialise on every app start.
    private val landmarker: PoseLandmarker? = listOf(Delegate.CPU).firstNotNullOfOrNull { delegate ->
        runCatching {
            PoseLandmarker.createFromOptions(context, PoseLandmarker.PoseLandmarkerOptions.builder()
                .setBaseOptions(BaseOptions.builder().setModelAssetPath("pose_landmarker_full.task").setDelegate(delegate).build())
                .setRunningMode(RunningMode.IMAGE)
                .setNumPoses(2)
                .setMinPoseDetectionConfidence(0.3f)
                .setMinPosePresenceConfidence(0.3f)
                .build())
        }.onSuccess { Log.i("GremmaPose", "pose landmarker on $delegate") }
            .onFailure { Log.w("GremmaPose", "pose landmarker unavailable on $delegate", it) }.getOrNull()
    }

    fun hands(bmp: Bitmap): List<Hand> {
        val lm = landmarker ?: return emptyList()
        val argb = if (bmp.config == Bitmap.Config.ARGB_8888) bmp else bmp.copy(Bitmap.Config.ARGB_8888, false)
        val result = runCatching { lm.detect(BitmapImageBuilder(argb).build()) }
            .onFailure { Log.w("GremmaPose", "detect failed", it) }.getOrNull() ?: return emptyList()
        val w = bmp.width.toFloat(); val h = bmp.height.toFloat()
        val out = mutableListOf<Hand>()
        for (pose in result.landmarks()) {
            for ((side, e, wr, idx) in ARMS) {
                if (pose.size <= idx || pose[wr].visibility().orElse(1f) < 0.3f) continue
                val ex = pose[e].x() * w; val ey = pose[e].y() * h
                val wx = pose[wr].x() * w; val wy = pose[wr].y() * h
                val ix = pose[idx].x() * w; val iy = pose[idx].y() * h
                val forearm = max(20f, hypot(wx - ex, wy - ey))
                val cx = ix + 0.3f * (ix - wx); val cy = iy + 0.3f * (iy - wy) + 0.15f * forearm
                val half = max(120f, 1.3f * forearm) / 2
                val r = Rect(max(0f, cx - half).toInt(), max(0f, cy - half).toInt(), min(w, cx + half).toInt(), min(h, cy + half).toInt())
                if (r.width() > 24 && r.height() > 24) out += Hand(side, r)
            }
        }
        return out
    }

    private data class Arm(val side: String, val elbow: Int, val wrist: Int, val index: Int)

    companion object {
        private val ARMS = listOf(Arm("left", 13, 15, 19), Arm("right", 14, 16, 20))
    }
}
