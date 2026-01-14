package com.example.sensor_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import java.io.File
import java.io.FileWriter
import java.util.Timer
import java.util.TimerTask

class SensorForegroundService : Service(), SensorEventListener {

    companion object {
        const val CHANNEL_ID = "sensor_recording_channel"
        const val NOTIF_ID = 101

        const val ACTION_START = "ACTION_START"
        const val ACTION_STOP = "ACTION_STOP"

        const val EXTRA_ACTIVITY = "EXTRA_ACTIVITY"
        const val EXTRA_SESSION_ID = "EXTRA_SESSION_ID"

        const val SAMPLE_HZ = 20
    }

    private lateinit var sensorManager: SensorManager
    private var accel: Sensor? = null
    private var gyro: Sensor? = null

    @Volatile private var accX = 0.0
    @Volatile private var accY = 0.0
    @Volatile private var accZ = 0.0

    @Volatile private var gyroX = 0.0
    @Volatile private var gyroY = 0.0
    @Volatile private var gyroZ = 0.0

    private val ioLock = Any()
    private var timer: Timer? = null
    private var writer: FileWriter? = null

    private var activityLabel: String = "SITTING"
    private var sessionId: String = "session_unknown"

    private var wakeLock: PowerManager.WakeLock? = null
    private var isRunning = false
    private var linesSinceFlush = 0

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()

        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        accel = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        gyro = sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                if (isRunning) return START_STICKY

                activityLabel = intent.getStringExtra(EXTRA_ACTIVITY) ?: "SITTING"
                sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: "session_unknown"

                startForeground(NOTIF_ID, buildNotification())
                startRecording()
                return START_STICKY
            }

            ACTION_STOP -> {
                stopRecording()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
        }

        return START_NOT_STICKY
    }

    private fun startRecording() {
        isRunning = true

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "sensor_app:wakelock")
        wakeLock?.acquire()

        val outDir = File(filesDir, "sessions")
        outDir.mkdirs()

        val outFile = File(outDir, "$sessionId.csv")

        synchronized(ioLock) {
            writer = FileWriter(outFile, false).apply {
                write("timestamp,acc_x,acc_y,acc_z,gyro_x,gyro_y,gyro_z,activity,session_id\n")
                flush()
            }
            linesSinceFlush = 0
        }

        accel?.let { sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
        gyro?.let { sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }

        timer = Timer()
        val periodMs = (1000.0 / SAMPLE_HZ).toLong()

        timer?.scheduleAtFixedRate(object : TimerTask() {
            override fun run() {
                val ts = System.currentTimeMillis()
                val line = "$ts,$accX,$accY,$accZ,$gyroX,$gyroY,$gyroZ,$activityLabel,$sessionId\n"

                synchronized(ioLock) {
                    val w = writer ?: return
                    w.write(line)
                    linesSinceFlush++
                    if (linesSinceFlush >= 200) {
                        w.flush()
                        linesSinceFlush = 0
                    }
                }
            }
        }, 0, periodMs)
    }

    private fun stopRecording() {
        if (!isRunning) return
        isRunning = false

        timer?.cancel()
        timer = null

        sensorManager.unregisterListener(this)

        synchronized(ioLock) {
            try {
                writer?.flush()
            } catch (_: Exception) {
            }
            try {
                writer?.close()
            } catch (_: Exception) {
            }
            writer = null
        }

        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
    }

    override fun onDestroy() {
        stopRecording()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_ACCELEROMETER -> {
                accX = event.values[0].toDouble()
                accY = event.values[1].toDouble()
                accZ = event.values[2].toDouble()
            }
            Sensor.TYPE_GYROSCOPE -> {
                gyroX = event.values[0].toDouble()
                gyroY = event.values[1].toDouble()
                gyroZ = event.values[2].toDouble()
            }
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Sensor recording active")
            .setContentText("Recording accelerometer and gyroscope in background")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setOngoing(true)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Sensor Recording",
                NotificationManager.IMPORTANCE_LOW
            )
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }
}
