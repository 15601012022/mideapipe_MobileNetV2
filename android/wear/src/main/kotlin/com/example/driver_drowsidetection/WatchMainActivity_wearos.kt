package com.example.driver_drowsidetection

import android.os.*
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material.*
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.*

class WatchMainActivity : ComponentActivity(), MessageClient.OnMessageReceivedListener {

    companion object {
        private const val PATH_ALERT  = "/drowsiness/alert"
        private const val PATH_STATUS = "/drowsiness/status"
        private const val PATH_HRV    = "/drowsiness/hrv"
        private const val PATH_CMD    = "/drowsiness/command"
    }

    private val isDrowsy     = mutableStateOf(false)
    private val isMonitoring = mutableStateOf(false)
    private val heartRate    = mutableStateOf(72)
    private val detections   = mutableStateOf(0)
    private val isConnected  = mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        setContent {
            WatchApp(
                isDrowsy     = isDrowsy.value,
                isMonitoring = isMonitoring.value,
                heartRate    = heartRate.value,
                detections   = detections.value,
                isConnected  = isConnected.value,
                onToggle     = {
                    sendCommandToPhone(if (!isMonitoring.value) "START" else "STOP")
                }
            )
        }

        checkConnection()
    }

    override fun onResume() {
        super.onResume()
        Wearable.getMessageClient(this).addListener(this)
        checkConnection()
    }

    override fun onPause() {
        super.onPause()
        Wearable.getMessageClient(this).removeListener(this)
    }

    override fun onMessageReceived(event: MessageEvent) {
        val data = String(event.data)
        when (event.path) {
            PATH_ALERT -> {
                val parts = data.split("|")
                if (parts.size >= 3) {
                    val drowsy = parts[0].toBoolean()
                    isDrowsy.value   = drowsy
                    detections.value = parts[2].toIntOrNull() ?: detections.value
                    if (drowsy) vibrateAlert()
                }
            }
            PATH_STATUS -> isMonitoring.value = data == "1"
            PATH_HRV    -> heartRate.value = data.toIntOrNull() ?: heartRate.value
        }
    }

    private fun sendCommandToPhone(command: String) {
        Thread {
            try {
                val nodes = Tasks.await(Wearable.getNodeClient(this).connectedNodes)
                nodes.forEach { node ->
                    Tasks.await(
                        Wearable.getMessageClient(this)
                            .sendMessage(node.id, PATH_CMD, command.toByteArray())
                    )
                }
                if (command == "START") isMonitoring.value = true
                if (command == "STOP")  isMonitoring.value = false
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }.start()
    }

    private fun checkConnection() {
        Thread {
            try {
                val nodes = Tasks.await(Wearable.getNodeClient(this).connectedNodes)
                isConnected.value = nodes.isNotEmpty()
            } catch (e: Exception) {
                isConnected.value = false
            }
        }.start()
    }

    private fun vibrateAlert() {
        val vibrator = getSystemService(VIBRATOR_SERVICE) as? Vibrator
        val pattern = longArrayOf(0, 200, 100, 200)
        vibrator?.vibrate(
            VibrationEffect.createWaveform(pattern, -1)
        )
    }
}

// ── Wear OS Compose UI ────────────────────────────────────────────────────

@Composable
fun WatchApp(
    isDrowsy: Boolean,
    isMonitoring: Boolean,
    heartRate: Int,
    detections: Int,
    isConnected: Boolean,
    onToggle: () -> Unit
) {
    val kGreen  = Color(0xFF78C841)
    val kRed    = Color(0xFFE53935)
    val kOrange = Color(0xFFFFA726)

    val bgColor     = if (isDrowsy) Color(0xFF1A0000) else Color(0xFF0D0D0D)
    val accentColor = if (isDrowsy) kRed else if (isMonitoring) kGreen else Color(0xFF888888)
    val statusText  = if (isDrowsy) "DROWSY!" else if (isMonitoring) "Normal" else "Stopped"

    val infiniteTransition = rememberInfiniteTransition(label = "pulse")
    val scale by infiniteTransition.animateFloat(
        initialValue = 1f,
        targetValue  = if (isDrowsy) 1.1f else 1f,
        animationSpec = infiniteRepeatable(
            animation  = tween(600, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "scale"
    )

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(bgColor),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier.padding(12.dp)
        ) {
            // Status icon
            Box(
                modifier = Modifier
                    .size(52.dp)
                    .scale(scale)
                    .clip(CircleShape)
                    .background(accentColor.copy(alpha = 0.2f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = when {
                        isDrowsy     -> Icons.Default.Warning
                        isMonitoring -> Icons.Default.RemoveRedEye
                        else         -> Icons.Default.VisibilityOff
                    },
                    contentDescription = statusText,
                    tint = accentColor,
                    modifier = Modifier.size(28.dp)
                )
            }

            Spacer(Modifier.height(6.dp))

            Text(
                text = statusText,
                color = accentColor,
                fontWeight = FontWeight.Bold,
                fontSize = 18.sp,
                textAlign = TextAlign.Center
            )

            Spacer(Modifier.height(2.dp))

            Text(
                text = "❤ $heartRate bpm",
                color = Color.White.copy(alpha = 0.7f),
                fontSize = 11.sp
            )

            Spacer(Modifier.height(2.dp))

            Text(
                text = "$detections alerts",
                color = if (detections > 0) kOrange else Color.White.copy(alpha = 0.5f),
                fontSize = 10.sp
            )

            Spacer(Modifier.height(8.dp))

            // Start/Stop button
            Button(
                onClick = onToggle,
                modifier = Modifier
                    .fillMaxWidth(0.75f)
                    .height(36.dp),
                colors = ButtonDefaults.buttonColors(
                    backgroundColor = if (isMonitoring) kRed else kGreen
                )
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center
                ) {
                    Icon(
                        imageVector = if (isMonitoring) Icons.Default.StopCircle
                        else Icons.Default.PlayCircle,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(14.dp)
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = if (isMonitoring) "Stop" else "Start",
                        color = Color.White,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold
                    )
                }
            }

            Spacer(Modifier.height(6.dp))

            // Connection dot
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(6.dp)
                        .clip(CircleShape)
                        .background(if (isConnected) kGreen else Color.Gray)
                )
                Spacer(Modifier.width(4.dp))
                Text(
                    text = if (isConnected) "Phone connected" else "No phone",
                    color = Color.White.copy(alpha = 0.4f),
                    fontSize = 9.sp
                )
            }
        }
    }
}
