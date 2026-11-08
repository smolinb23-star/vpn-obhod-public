package dev.local.vpnservice

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Мост к ядру Mihomo (sing-box) через MethodChannel.
 *
 * Канал: dev.local.vpnservice/mihomo
 * Методы:
 *   - start(configJson) — запуск туннеля с JSON-конфигом Mihomo
 *   - stop — остановка туннеля
 *   - getStatus — текущий статус
 *
 * События (broadcast stream 'dev.local.vpnservice/mihomo/status'):
 *   - {connectionState, currentServer, downloadSpeed, uploadSpeed, latencyMs}
 */
class MihomoBridge(private val context: Context) {

    companion object {
        const val CHANNEL = "dev.local.vpnservice/mihomo"
        const val STATUS_CHANNEL = "dev.local.vpnservice/mihomo/status"
        private const val TAG = "MihomoBridge"
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var statusEventSink: EventChannel.EventSink? = null

    fun setMethodCallHandler(
        channel: MethodChannel,
        eventChannel: EventChannel,
    ) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val config = call.argument<String>("config") ?: ""
                    startMihomo(config, result)
                }
                "stop" -> {
                    stopMihomo(result)
                }
                "getStatus" -> {
                    result.success(getStatus())
                }
                else -> result.notImplemented()
            }
        }

        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                statusEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                statusEventSink = null
            }
        })
    }

    private fun startMihomo(configJson: String, result: MethodChannel.Result) {
        executor.execute {
            try {
                Log.i(TAG, "Mihomo start: config length=${configJson.length}")
                // Здесь будет запуск бинарника Mihomo / sing-box
                // Пока что эмулируем успешный запуск для 개발
                mainHandler.post {
                    statusEventSink?.success(mapOf(
                        "connectionState" to "connecting",
                        "currentServer" to "",
                        "downloadSpeed" to 0,
                        "uploadSpeed" to 0,
                        "latencyMs" to null,
                    ))
                    // Имитация подключения через 2 секунды
                    mainHandler.postDelayed({
                        statusEventSink?.success(mapOf(
                            "connectionState" to "connected",
                            "currentServer" to "Auto (url-test)",
                            "downloadSpeed" to 0,
                            "uploadSpeed" to 0,
                            "latencyMs" to 45,
                        ))
                    }, 2000)
                    result.success(null)
                }
            } catch (e: Throwable) {
                Log.e(TAG, "Mihomo start failed", e)
                mainHandler.post {
                    result.error("start", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun stopMihomo(result: MethodChannel.Result) {
        executor.execute {
            try {
                mainHandler.post {
                    statusEventSink?.success(mapOf(
                        "connectionState" to "disconnected",
                        "currentServer" to "",
                        "downloadSpeed" to 0,
                        "uploadSpeed" to 0,
                        "latencyMs" to null,
                    ))
                    result.success(null)
                }
            } catch (e: Throwable) {
                mainHandler.post {
                    result.error("stop", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun getStatus(): Map<String, Any?> {
        return mapOf(
            "connectionState" to "disconnected",
            "currentServer" to "",
        )
    }

    fun dispose() {
        executor.shutdownNow()
        statusEventSink = null
    }
}
