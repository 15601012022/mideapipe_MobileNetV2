package com.example.driver_drowsidetection

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarker
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.sqrt
import kotlin.math.abs
import kotlin.math.atan2

class MediaPipePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var faceLandmarker: FaceLandmarker? = null

    private val LEFT_EYE  = intArrayOf(362, 385, 387, 263, 373, 380)
    private val RIGHT_EYE = intArrayOf(33,  160, 158, 133, 153, 144)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "mediapipe_channel")
        channel.setMethodCallHandler(this)
        android.util.Log.d("MEDIAPIPE_PLUGIN", "Plugin attached — starting init")
        Thread {
            android.util.Log.d("MEDIAPIPE_PLUGIN", "Background thread started")
            initFaceLandmarker()
        }.start()
    }

    private fun initFaceLandmarker() {
        try {
            val assetFiles = context.assets.list("") ?: emptyArray()
            android.util.Log.d("MEDIAPIPE_PLUGIN", "All assets: ${assetFiles.joinToString()}")
            android.util.Log.d("MEDIAPIPE_PLUGIN", "Looking for face_landmarker.task...")

            if (!assetFiles.contains("face_landmarker.task")) {
                android.util.Log.e("MEDIAPIPE_PLUGIN", "FILE NOT FOUND. Available: ${assetFiles.joinToString()}")
                return
            }
            android.util.Log.d("MEDIAPIPE_PLUGIN", "File found! Initializing...")

            val baseOptions = BaseOptions.builder()
                .setModelAssetPath("face_landmarker.task")
                .build()

            val options = FaceLandmarker.FaceLandmarkerOptions.builder()
                .setBaseOptions(baseOptions)
                .setRunningMode(RunningMode.IMAGE)
                .setNumFaces(1)
                .setMinFaceDetectionConfidence(0.5f)
                .setMinTrackingConfidence(0.5f)
                .build()

            faceLandmarker = FaceLandmarker.createFromOptions(context, options)
            android.util.Log.d("MEDIAPIPE_PLUGIN", "✅ FaceLandmarker initialized successfully")
        } catch (e: Exception) {
            android.util.Log.e("MEDIAPIPE_PLUGIN", "❌ Init error: ${e.message}")
            e.printStackTrace()
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "analyzeFrame" -> {
                val imageBytes = call.argument<ByteArray>("imageBytes")
                if (imageBytes == null) {
                    result.error("INVALID_INPUT", "No image bytes provided", null)
                    return
                }
                try {
                    val analysisResult = analyzeFrame(imageBytes)
                    result.success(analysisResult)
                } catch (e: Exception) {
                    android.util.Log.e("MEDIAPIPE_PLUGIN", "analyzeFrame error: ${e.message}")
                    result.error("ANALYSIS_ERROR", e.message, null)
                }
            }
            "isInitialized" -> result.success(faceLandmarker != null)
            else -> result.notImplemented()
        }
    }

    private fun analyzeFrame(imageBytes: ByteArray): Map<String, Any> {
        val rawBitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
            ?: return emptyResult()

        val bitmap = if (rawBitmap.config == Bitmap.Config.ARGB_8888) {
            rawBitmap
        } else {
            rawBitmap.copy(Bitmap.Config.ARGB_8888, false)
        }

        val mpImage  = BitmapImageBuilder(bitmap).build()
        val detection = faceLandmarker?.detect(mpImage) ?: return emptyResult()

        if (detection.faceLandmarks().isEmpty()) return emptyResult()

        val landmarks = detection.faceLandmarks()[0]
        val w = bitmap.width.toFloat()
        val h = bitmap.height.toFloat()

        // ── EAR ──
        val leftEAR  = computeEAR(landmarks, LEFT_EYE,  w, h)
        val rightEAR = computeEAR(landmarks, RIGHT_EYE, w, h)
        val avgEAR   = (leftEAR + rightEAR) / 2.0f

        // ── MAR ──
        val mar = computeMAR(landmarks, w, h)

        // ── Head Pose ──
        val (pitch, yaw, roll) = computeHeadPose(landmarks, w, h)

        // ── Flags ──
        val eyeClosed   = avgEAR < 0.25f
        val yawning     = mar > 0.60f
        val headNodding = pitch < -12.0f

        // WITH this — keep as normalized 0-1, painter will scale:
        val allX    = landmarks.map { it.x() }
        val allY    = landmarks.map { it.y() }
        val boxLeft   = (allX.minOrNull() ?: 0f).toDouble()
        val boxTop    = (allY.minOrNull() ?: 0f).toDouble()
        val boxRight  = (allX.maxOrNull() ?: 1f).toDouble()
        val boxBottom = (allY.maxOrNull() ?: 1f).toDouble()

        android.util.Log.d("MEDIAPIPE_PLUGIN",
            "EAR=$avgEAR MAR=$mar Pitch=$pitch Drowsy=${ eyeClosed || yawning || headNodding }")

        return mapOf(
            "faceDetected"    to true,
            "ear"             to avgEAR.toDouble(),
            "leftEar"         to leftEAR.toDouble(),
            "rightEar"        to rightEAR.toDouble(),
            "mar"             to mar.toDouble(),
            "pitch"           to pitch.toDouble(),
            "yaw"             to yaw.toDouble(),
            "roll"            to roll.toDouble(),
            "eyeClosed"       to eyeClosed,
            "yawning"         to yawning,
            "headNodding"     to headNodding,
            "drowsyGeometric" to (eyeClosed || yawning || headNodding),
            "boxLeft"         to boxLeft,
            "boxTop"          to boxTop,
            "boxRight"        to boxRight,
            "boxBottom"       to boxBottom
        )
    }

    private fun computeEAR(
        landmarks: List<com.google.mediapipe.tasks.components.containers.NormalizedLandmark>,
        indices: IntArray,
        w: Float,
        h: Float
    ): Float {
        fun pt(i: Int) = Pair(landmarks[i].x() * w, landmarks[i].y() * h)
        fun dist(a: Pair<Float, Float>, b: Pair<Float, Float>): Float {
            val dx = a.first - b.first
            val dy = a.second - b.second
            return sqrt(dx * dx + dy * dy)
        }
        val v1 = dist(pt(indices[1]), pt(indices[5]))
        val v2 = dist(pt(indices[2]), pt(indices[4]))
        val h1 = dist(pt(indices[0]), pt(indices[3]))
        return if (h1 > 0f) (v1 + v2) / (2.0f * h1) else 0f
    }

    private fun computeMAR(
        landmarks: List<com.google.mediapipe.tasks.components.containers.NormalizedLandmark>,
        w: Float,
        h: Float
    ): Float {
        fun pt(i: Int) = Pair(landmarks[i].x() * w, landmarks[i].y() * h)
        fun dist(a: Pair<Float, Float>, b: Pair<Float, Float>): Float {
            val dx = a.first - b.first
            val dy = a.second - b.second
            return sqrt(dx * dx + dy * dy)
        }
        val vertical   = dist(pt(13), pt(14))
        val horizontal = dist(pt(61), pt(291))
        return if (horizontal > 0f) vertical / horizontal else 0f
    }

    private fun computeHeadPose(
        landmarks: List<com.google.mediapipe.tasks.components.containers.NormalizedLandmark>,
        w: Float,
        h: Float
    ): Triple<Float, Float, Float> {
        val leftEyeX   = landmarks[226].x() * w
        val leftEyeY   = landmarks[226].y() * h
        val rightEyeX  = landmarks[446].x() * w
        val rightEyeY  = landmarks[446].y() * h

        val centerX = (leftEyeX + rightEyeX) / 2f
        val centerY = (leftEyeY + rightEyeY) / 2f

        val pitch = ((centerY - h / 2f) / h) * 45f
        val yaw   = ((centerX - w / 2f) / w) * 45f
        val dx    = rightEyeX - leftEyeX
        val dy    = rightEyeY - leftEyeY
        val roll  = Math.toDegrees(atan2(dy.toDouble(), dx.toDouble())).toFloat()

        return Triple(pitch, yaw, roll)
    }

    private fun emptyResult(): Map<String, Any> = mapOf(
        "faceDetected"    to false,
        "ear"             to 0.0,
        "mar"             to 0.0,
        "pitch"           to 0.0,
        "yaw"             to 0.0,
        "roll"            to 0.0,
        "eyeClosed"       to false,
        "yawning"         to false,
        "headNodding"     to false,
        "drowsyGeometric" to false,
        "boxLeft"         to 0.0,
        "boxTop"          to 0.0,
        "boxRight"        to 0.0,
        "boxBottom"       to 0.0
    )

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        faceLandmarker?.close()
    }
}