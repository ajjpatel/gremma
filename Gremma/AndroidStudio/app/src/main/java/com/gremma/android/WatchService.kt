package com.gremma.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.PowerManager

/**
 * Keeps Gremma running with the screen off: the clip receiver listens, new clips are processed,
 * alerts are spoken. Holds CPU and Wi-Fi awake for as long as it runs (the hub phone is meant to stay plugged in).
 */
class WatchService : Service() {
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?) = null

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Home camera", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val note = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle("Gremma is watching")
            .setContentText("Receiving clips from the home camera")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        startForeground(1, note, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        wake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "gremma:watch").apply { acquire() }
        wifi = getSystemService(WifiManager::class.java).createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "gremma:watch").apply { acquire() }
        (application as GremmaApp).core
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_STICKY

    override fun onDestroy() {
        wake?.release(); wifi?.release()
        super.onDestroy()
    }

    companion object { private const val CHANNEL = "watch" }
}
