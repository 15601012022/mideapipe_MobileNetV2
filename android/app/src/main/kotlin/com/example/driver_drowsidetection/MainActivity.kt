package com.example.driver_drowsidetection

import android.os.VibrationEffect
import android.os.Vibrator
import android.content.Context
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Node
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.tasks.Tasks
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*

class MainActivity : FlutterActivity(), MessageClient.OnMessageReceivedListener {

    companion object {
        private const val CHANNEL     = "com.driver_drowsidetection/drowsiness"
        private const val PATH_ALERT  = "/drowsiness/alert"
        private const val PATH_STATUS = "/drowsiness/status"
        private const val PATH_HRV    = "/drowsiness/hrv"
        private const val PATH_CMD    = "/drowsiness/command"
    }

    private lateinit var methodChannel: MethodChannel
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        flutterEngine.plugins.add(MediaPipePlugin())

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, CHANNEL
        )

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {

                "checkConnection" -> {
                    scope.launch {
                        val connected = isWatchConnected()
                        withContext(Dispatchers.Main) { result.success(connected) }
                    }
                }

                // ── NEW: returns the display name of the paired watch node ──
                "getWatchName" -> {
                    scope.launch {
                        val nodes = getConnectedNodes()
                        val name  = nodes.firstOrNull()?.displayName ?: "Smart Watch"
                        withContext(Dispatchers.Main) { result.success(name) }
                    }
                }

                "sendAlert" -> {
                    val isDrowsy       = call.argument<Boolean>("isDrowsy") ?: false
                    val earScore       = call.argument<Double>("earScore") ?: 0.0
                    val detectionCount = call.argument<Int>("detectionCount") ?: 0
                    scope.launch {
                        sendMessageToWatch(PATH_ALERT, "$isDrowsy|$earScore|$detectionCount")
                        withContext(Dispatchers.Main) { result.success(true) }
                    }
                }

                "sendStatus" -> {
                    val isMonitoring = call.argument<Boolean>("isMonitoring") ?: false
                    scope.launch {
                        sendMessageToWatch(PATH_STATUS, if (isMonitoring) "1" else "0")
                        withContext(Dispatchers.Main) { result.success(true) }
                    }
                }

                "sendHeartRate" -> {
                    val bpm = call.argument<Int>("bpm") ?: 0
                    scope.launch {
                        sendMessageToWatch(PATH_HRV, "$bpm")
                        withContext(Dispatchers.Main) { result.success(true) }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        Wearable.getMessageClient(this).addListener(this)
    }

    override fun onPause() {
        super.onPause()
        Wearable.getMessageClient(this).removeListener(this)
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        if (messageEvent.path == PATH_CMD) {
            val command = String(messageEvent.data)
            runOnUiThread {
                methodChannel.invokeMethod("onWatchCommand", command)
            }
            vibratePhone(100)
        }
    }

    private suspend fun getConnectedNodes(): List<Node> {
        return try {
            Tasks.await(Wearable.getNodeClient(this).connectedNodes) ?: emptyList()
        } catch (e: Exception) {
            emptyList()
        }
    }

    private suspend fun isWatchConnected(): Boolean {
        return getConnectedNodes().isNotEmpty()
    }

    private suspend fun sendMessageToWatch(path: String, payload: String) {
        val nodes = getConnectedNodes()
        nodes.forEach { node ->
            try {
                Tasks.await(
                    Wearable.getMessageClient(this)
                        .sendMessage(node.id, path, payload.toByteArray())
                )
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    private fun vibratePhone(durationMs: Long) {
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        vibrator?.vibrate(
            VibrationEffect.createOneShot(durationMs, VibrationEffect.DEFAULT_AMPLITUDE)
        )
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}