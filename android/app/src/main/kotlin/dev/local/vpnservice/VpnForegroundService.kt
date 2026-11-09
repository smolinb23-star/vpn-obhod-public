package dev.local.vpnservice

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log

import io.flutter.plugin.common.MethodChannel

/**
 * Foreground Service с уведомлением в шторке Android.
 *
 * Показывает постоянное уведомление с кнопками:
 *   - "Ускорить" — перезапускает url-test (поиск лучшего сервера)
 *   - "Остановить" — полностью отключает VPN
 *
 * Кнопки уведомления отправляют Intent в MainActivity с действиями:
 *   - dev.local.vpnservice.ACCELERATE
 *   - dev.local.vpnservice.STOP
 * MainActivity.onNewIntent() обрабатывает эти действия и вызывает методы Flutter.
 */
class VpnForegroundService : Service() {

    companion object {
        private const val TAG = "VpnForegroundService"
        private const val CHANNEL_ID = "vpn_foreground"
        private const val CHANNEL_NAME = "VPN-туннель"
        private const val NOTIFICATION_ID = 0x5651

        private const val ACTION_ACCELERATE = "dev.local.vpnservice.ACCELERATE"
        private const val ACTION_STOP = "dev.local.vpnservice.STOP"

        /** Текущий сервер для отображения в уведомлении. */
        @Volatile
        private var currentServer: String = ""

        fun setCurrentServer(server: String) {
            currentServer = server
        }

        fun start(context: Context, server: String) {
            currentServer = server
            val intent = Intent(context, VpnForegroundService::class.java)
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
            try {
                context.stopService(Intent(context, VpnForegroundService::class.java))
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
        // Читаем имя сервера из intent extras (передано из Flutter)
        val server = intent?.getStringExtra("server") ?: ""
        if (server.isNotEmpty()) {
            currentServer = server
        }

        startForegroundCompat()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        Log.i(TAG, "foreground service destroyed")
    }

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
        // Открытие приложения по нажатию на уведомление
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val pendingOpen = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        // Кнопка "Ускорить" → действие в MainActivity
        val intentAccelerate = Intent(this, MainActivity::class.java)
            .setAction(ACTION_ACCELERATE)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pendingAccelerate = PendingIntent.getActivity(
            this,
            1,
            intentAccelerate,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        // Кнопка "Остановить" → действие в MainActivity
        val intentStop = Intent(this, MainActivity::class.java)
            .setAction(ACTION_STOP)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pendingStop = PendingIntent.getActivity(
            this,
            2,
            intentStop,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("VPN Подключен")
            .setContentText("Сервер: $currentServer")
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(pendingOpen)
            .addAction(R.drawable.ic_launcher, "Ускорить", pendingAccelerate)
            .addAction(android.R.drawable.ic_delete, "Остановить", pendingStop)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setShowWhen(false)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = android.app.NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            android.app.NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Уведомление активного VPN-туннеля с кнопками управления"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    fun dispose() {
    }
}
