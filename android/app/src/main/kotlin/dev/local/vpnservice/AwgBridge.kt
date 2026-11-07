package dev.local.vpnservice

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.amnezia.awg.backend.GoBackend
import org.amnezia.awg.backend.NoopTunnelActionHandler
import org.amnezia.awg.backend.Tunnel
import org.amnezia.awg.config.Config
import java.io.BufferedReader
import java.io.StringReader
import java.util.concurrent.Executors

/**
 * MethodChannel-мост к нативному движку AmneziaWG (com.zaneschepke:amneziawg-android).
 *
 * Поднимает туннель через GoBackend с полными параметрами обфускации
 * (Jc/Jmin/Jmax, S1/S2, H1..H4), которые plain-WireGuard/Xray не поддерживает.
 * Конфиг собирается из payload'а Dart ([AwgConfBuilder]) и парсится штатным
 * org.amnezia.awg.config.Config.parse — валидация атрибутов идёт нативным
 * кодом библиотеки.
 */
class AwgBridge(private val context: Context) {

    companion object {
        const val CHANNEL = "dev.local.vpnservice/awg"
        private const val TAG = "AwgBridge"
        private const val PREPARE_REQUEST = 0xA450
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var backend: GoBackend? = null
    private var tunnel: AwgTunnel? = null
    private var pendingPrepare: MethodChannel.Result? = null

    /** Отправка событий статуса в Dart (задаётся MainActivity). */
    var statusSink: ((Map<String, Any?>) -> Unit)? = null

    fun handle(call: MethodCall, result: MethodChannel.Result, activity: Activity) {
        when (call.method) {
            "prepare" -> prepare(result, activity)
            "connect" -> connect(call, result)
            "disconnect" -> disconnect(result)
            "getStatus" -> result.success(statusMap())
            else -> result.notImplemented()
        }
    }

    /** android.net.VpnService.prepare: запрос разрешения на VPN-туннель. */
    private fun prepare(result: MethodChannel.Result, activity: Activity) {
        val intent = VpnService.prepare(context)
        if (intent == null) {
            result.success(true)
        } else {
            pendingPrepare = result
            activity.startActivityForResult(intent, PREPARE_REQUEST)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PREPARE_REQUEST) return
        val pending = pendingPrepare
        pendingPrepare = null
        pending?.success(resultCode == Activity.RESULT_OK)
    }

    private fun connect(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val confText = AwgConfBuilder.build(args)
        if (confText == null) {
            result.error("conf", "не удалось собрать .conf из payload", null)
            return
        }
        executor.execute {
            try {
                val cfg = Config.parse(BufferedReader(StringReader(confText)))
                val name = sanitizeName(call.argument<String>("name") ?: "awg")
                val t = AwgTunnel(name) { emitStatus() }
                val b = backend ?: GoBackend(context.applicationContext, NoopTunnelActionHandler())
                    .also { backend = it }
                b.setState(t, Tunnel.State.UP, cfg)
                tunnel = t
                mainHandler.post { result.success(statusMap()) }
            } catch (e: Throwable) {
                Log.e(TAG, "AWG connect failed", e)
                mainHandler.post {
                    result.error("connect", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun disconnect(result: MethodChannel.Result) {
        val t = tunnel
        val b = backend
        if (t == null || b == null) {
            result.success(statusMap())
            return
        }
        executor.execute {
            try {
                b.setState(t, Tunnel.State.DOWN, null)
            } catch (e: Throwable) {
                Log.w(TAG, "AWG disconnect error", e)
            } finally {
                tunnel = null
                mainHandler.post { result.success(statusMap()) }
            }
        }
    }

    private fun statusMap(): Map<String, Any?> {
        val t = tunnel
        val b = backend
        val up = t != null && b != null && b.getState(t) == Tunnel.State.UP
        var rx = 0L
        var tx = 0L
        if (up) {
            try {
                val s = b!!.getStatistics(t!!)
                rx = s.totalRx()
                tx = s.totalTx()
            } catch (e: Throwable) {
                Log.w(TAG, "stats unavailable", e)
            }
        }
        return mapOf(
            "state" to if (up) "up" else "down",
            "rx" to rx,
            "tx" to tx,
            "version" to runCatching { backend?.version }.getOrNull(),
        )
    }

    private fun emitStatus() {
        mainHandler.post { statusSink?.invoke(statusMap()) }
    }

    private fun sanitizeName(raw: String): String {
        val cleaned = raw.replace(Regex("[^a-zA-Z0-9_=+.-]"), "-").take(15)
        return cleaned.ifEmpty { "awg" }
    }

    fun dispose() {
        executor.shutdownNow()
    }

    /** Туннель-обёртка: имя по ограничениям AWG + колбэк смены состояния. */
    private class AwgTunnel(
        private val name: String,
        private val onChanged: () -> Unit,
    ) : Tunnel {
        override fun getName(): String = name
        override fun onStateChange(newState: Tunnel.State) = onChanged()
        override fun isIpv4ResolutionPreferred(): Boolean = true
        override fun isMetered(): Boolean = false
    }
}
