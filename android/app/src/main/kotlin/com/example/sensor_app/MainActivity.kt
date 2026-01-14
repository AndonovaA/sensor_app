package com.example.sensor_app

import android.content.Intent
import androidx.annotation.NonNull
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val channelName = "sensor_service_channel"
    private var lastSessionId: String? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        val activity = call.argument<String>("activity") ?: "SITTING"
                        val sessionId = call.argument<String>("sessionId") ?: "session_unknown"
                        lastSessionId = sessionId

                        val i = Intent(this, SensorForegroundService::class.java).apply {
                            action = SensorForegroundService.ACTION_START
                            putExtra(SensorForegroundService.EXTRA_ACTIVITY, activity)
                            putExtra(SensorForegroundService.EXTRA_SESSION_ID, sessionId)
                        }

                        ContextCompat.startForegroundService(this, i)
                        result.success(true)
                    }

                    "stopService" -> {
                        val sessionId = lastSessionId ?: "session_unknown"

                        val i = Intent(this, SensorForegroundService::class.java).apply {
                            action = SensorForegroundService.ACTION_STOP
                        }
                        startService(i)

                        val outFile = File(filesDir, "sessions/$sessionId.csv")
                        result.success(
                            mapOf(
                                "filePath" to outFile.absolutePath,
                                "sessionId" to sessionId
                            )
                        )
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
