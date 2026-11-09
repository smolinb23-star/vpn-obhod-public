package dev.local.vpnservice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Foreground Service вокруг нативного VPN-туннеля.
 *
 * VpnService сам по себе не обязан быть foreground, поэтому процесс может
 * быть убит в фоне (звонок, doze, swipe из recents). Этот сервис:
 *  - показывает постоянное уведомление (важно для Android 8+);
 *  - возвращает START_STICKY — система перезапустит его;
 *  - stopWithTask=false — swipe из recents не останавливает туннель.
 */
class TunnelKeepAliveService : Service() {

    companion object {
        private const val TAG = "TunnelKeepAlive"
        private const val CHANNEL_ID = "vpn_tunnel_keepalive"
        private const val NOTIFICATION_ID = 0x5650
        private const val ACTION_START = "dev.local.vpnservice.KEEPALIVE_START"
        private const val ACTION_STOP = "dev.local.vpnservice.KEEPALIVE_STOP"

        /**
         * Жив ли туннель в этом процессе. При перезапуске процесса после
         * START_STICKY статическое поле сбрасывается в false — сервис
         * останавливается сам, чтобы не показывать ложное уведомление.
         */
        @Volatile
        private var tunnelUp: Boolean = false

        /** Имя активного сервера для текста уведомления. */
        @Volatile
        private var currentServer: String = ""

        fun start(context: Context) {
            start(context, "")
        }

        fun start(context: Context, server: String) {
            tunnelUp = true
            if (server.isNotEmpty()) currentServer = server
            val intent = Intent(context, TunnelKeepAliveService::class.java)
                .setAction(ACTION_START)
                .putExtra("server", server)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Throwable) {
                Log.w(TAG, "start failed: ${e.message}")
            }
        }

        fun stop(context: Context) {
            tunnelUp = false
            try {
                // stopService, а не startService(ACTION_STOP): на Android 8+
                // startService из фона бросает IllegalStateException.
                context.stopService(
                    Intent(context, TunnelKeepAliveService::class.java),
                )
            } catch (e: Throwable) {
                Log.w(TAG, "stop failed: ${e.message}")
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val server = intent?.getStringExtra("server") ?: ""
                if (server.isNotEmpty()) currentServer = server
                startForegroundCompat()
                Log.i(TAG, "foreground started, sticky")
            }
        }
        // START_STICKY: после убийства процесса система перезапустит сервис.
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // stopWithTask=false в манифесте + явный no-op: туннель живёт дальше.
        Log.i(TAG, "task removed — keep-alive остаётся")
        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val accelerate = Intent(this, MainActivity::class.java)
            .setAction(VpnForegroundService.ACTION_ACCELERATE)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pendingAccelerate = PendingIntent.getActivity(
            this,
            1,
            accelerate,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val stop = Intent(this, MainActivity::class.java)
            .setAction(VpnForegroundService.ACTION_STOP)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pendingStop = PendingIntent.getActivity(
            this,
            2,
            stop,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val text = if (currentServer.isNotEmpty()) {
            "Сервер: $currentServer"
        } else {
            "AmneziaWG · защищённое соединение"
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("VPN активен")
            .setContentText(text)
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(pending)
            .addAction(R.drawable.ic_launcher, "Ускорить", pendingAccelerate)
            .addAction(android.R.drawable.ic_delete, "Остановить", pendingStop)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setShowWhen(false)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "VPN-туннель",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Постоянное уведомление активного VPN-туннеля"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }
}
