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
import java.io.File
import java.io.StringReader
import java.net.InetAddress
import java.util.HashMap
import java.util.concurrent.Executors

/**
 * MethodChannel-мост к нативному движку AmneziaWG (com.zaneschepke:amneziawg-android).
 *
 * Поднимает туннель через GoBackend с полными параметрами обфускации
 * (Jc/Jmin/Jmax, S1/S2, H1..H4, I1..I5), которые plain-WireGuard/Xray не поддерживает.
 * Конфиг собирается из payload'а Dart ([AwgConfBuilder]) и парсится штатным
 * org.amnezia.awg.config.Config.parse — валидация атрибутов идёт нативным
 * кодом библиотеки.
 *
 * Перед сборкой .conf выполняется санитизация: отброс IPv6-адресов (VpnService
 * на части прошивок падает с "Cannot set address"), приведение к маске хоста
 * (/32), резолв домена Endpoint в IP, валидация DNS/MTU. Сырые значения
 * логируются для диагностики.
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

    /** Отправка логов в Dart (для logs.txt без adb). */
    var logSink: ((String) -> Unit)? = null

    fun handle(call: MethodCall, result: MethodChannel.Result, activity: Activity) {
        when (call.method) {
            "prepare" -> prepare(result, activity)
            "connect" -> connect(call, result)
            "disconnect" -> disconnect(result)
            "getStatus" -> result.success(statusMap())
            else -> result.notImplemented()
        }
    }

    private fun log(message: String) {
        Log.i(TAG, message)
        mainHandler.post { logSink?.invoke(message) }
    }

    /** android.net.VpnService.prepare: запрос разрешения на VPN-туннель. */
    private fun prepare(result: MethodChannel.Result, activity: Activity) {
        val intent = VpnService.prepare(context)
        if (intent == null) {
            log("prepare: разрешение уже выдано")
            result.success(true)
        } else {
            log("prepare: показываю системный диалог VPN")
            pendingPrepare = result
            activity.startActivityForResult(intent, PREPARE_REQUEST)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PREPARE_REQUEST) return
        val pending = pendingPrepare
        pendingPrepare = null
        val ok = resultCode == Activity.RESULT_OK
        log("prepare result: ${if (ok) "OK" else "DENIED"} ($resultCode)")
        pending?.success(ok)
    }

    private fun connect(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>

        val rawAddresses = (args?.get("addresses") as? List<*>)?.filterIsInstance<String>() ?: emptyList()
        val rawDns = (args?.get("dns") as? List<*>)?.filterIsInstance<String>() ?: emptyList()
        val rawEndpoint = args?.get("endpoint") as? String ?: ""
        val rawMtu = (args?.get("mtu") as? Number)?.toInt()

        log("connect: raw Address=$rawAddresses, DNS=$rawDns, " +
            "Endpoint=$rawEndpoint, MTU=${rawMtu ?: "default"}")

        // 1) Отбрасываем IPv6-адреса: VpnService.Builder на части прошивок
        //    не умеет их в addAddress() -> "Cannot set address".
        val ipv4Addresses = rawAddresses.filter { !isIpv6Cidr(it) }
        if (ipv4Addresses.size < rawAddresses.size) {
            log("IPv6 address dropped due to VpnService limitation")
        }

        // 2) Приводим к маске хоста (/32 для IPv4).
        val sanitizedAddresses = ipv4Addresses.map { toHostMask(it) }.distinct()
        if (sanitizedAddresses.isEmpty()) {
            log("connect: нет usable IPv4-адреса в Address после фильтрации")
            result.error("conf", "Address не содержит usable IPv4 (после отброса IPv6)", null)
            return
        }

        // 3) Резолвим домен Endpoint до нативного слоя (GoBackend ожидает IP).
        var endpoint = rawEndpoint
        val hostPart = rawEndpoint.substringBefore(':')
        val portPart = rawEndpoint.substringAfter(':', missingDelimiterValue = "")
        if (hostPart.isNotBlank() && !isIpLiteral(hostPart)) {
            try {
                val resolved = InetAddress.getByName(hostPart).hostAddress
                endpoint = if (portPart.isNotBlank()) "$resolved:$portPart" else resolved
                log("connect: Endpoint resolved $hostPart -> $resolved")
            } catch (e: Throwable) {
                log("connect: Endpoint resolve failed for $hostPart: ${e.message}")
            }
        }

        // 4) DNS: только валидные IP, иначе 1.1.1.1.
        val sanitizedDns = rawDns.filter { isIpLiteral(it) && it != "0.0.0.0" }
        val dns = if (sanitizedDns.isEmpty()) listOf("1.1.1.1") else sanitizedDns
        if (dns != sanitizedDns) {
            log("connect: DNS sanitized -> $dns")
        }

        // 5) MTU: целое в диапазоне 1180..1500.
        val mtu = (rawMtu ?: 1280).coerceIn(1180, 1500)

        val sanitizedArgs = HashMap<String, Any?>()
        if (args != null) {
            for ((k, v) in args) {
                sanitizedArgs[k.toString()] = v
            }
        }
        sanitizedArgs["addresses"] = sanitizedAddresses
        sanitizedArgs["dns"] = dns
        sanitizedArgs["endpoint"] = endpoint
        sanitizedArgs["mtu"] = mtu

        val confText = AwgConfBuilder.build(sanitizedArgs)
        if (confText == null) {
            log("connect: не удалось собрать .conf из payload")
            result.error("conf", "не удалось собрать .conf из payload", null)
            return
        }
        log("connect: sanitized Address=$sanitizedAddresses, DNS=$dns, " +
            "Endpoint=$endpoint, MTU=$mtu; " +
            "amnezia=${(sanitizedArgs["amnezia"] as? Map<*, *>)?.keys}")

        executor.execute {
            try {
                val cfg = Config.parse(BufferedReader(StringReader(confText)))
                log("connect: Config.parse OK, peers=${cfg.peers.size}")

                val b = backend ?: GoBackend(
                    context.applicationContext,
                    NoopTunnelActionHandler(),
                ).also { backend = it }

                // Повторный connect при живом туннеле: сначала DOWN, иначе
                // GoBackend молча оставит старую конфигурацию.
                tunnel?.let { old ->
                    runCatching { b.setState(old, Tunnel.State.DOWN, null) }
                        .onFailure { log("connect: старый туннель DOWN: ${it.message}") }
                }

                val name = sanitizeName(call.argument<String>("name") ?: "awg")
                val t = AwgTunnel(name) { emitStatus() }
                b.setState(t, Tunnel.State.UP, cfg)
                tunnel = t
                log("connect: UP ($name), state=${b.getState(t)}")
                mainHandler.post { result.success(statusMap()) }
            } catch (e: Throwable) {
                Log.e(TAG, "AWG connect failed", e)
                log("connect FAILED: ${e.javaClass.simpleName}: ${e.message}")
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
            log("disconnect: туннель уже опущен")
            result.success(statusMap())
            return
        }
        executor.execute {
            try {
                b.setState(t, Tunnel.State.DOWN, null)
                log("disconnect: DOWN")
            } catch (e: Throwable) {
                Log.w(TAG, "AWG disconnect error", e)
                log("disconnect error: ${e.message}")
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
        var lastHandshake = 0L
        var endpoint: String? = null
        if (up) {
            try {
                val s = b!!.getStatistics(t!!)
                rx = s.totalRx()
                tx = s.totalTx()
                for (key in s.peers()) {
                    val peer = s.peer(key) ?: continue
                    if (peer.latestHandshakeEpochMillis() > lastHandshake) {
                        lastHandshake = peer.latestHandshakeEpochMillis()
                    }
                    if (peer.resolvedEndpoint().isNotBlank()) {
                        endpoint = peer.resolvedEndpoint()
                    }
                }
            } catch (e: Throwable) {
                Log.w(TAG, "stats unavailable", e)
            }
        }
        val packets = if (up) tunPackets() else null
        return mapOf(
            "state" to if (up) "up" else "down",
            "rx" to rx,
            "tx" to tx,
            "rxPackets" to packets?.first,
            "txPackets" to packets?.second,
            "lastHandshake" to if (lastHandshake > 0) lastHandshake else null,
            "endpoint" to endpoint,
            "version" to runCatching { backend?.version }.getOrNull(),
        )
    }

    /**
     * Пакеты tun-интерфейса из /proc/net/dev. Байты берём из GoBackend,
     * а пакеты там не отдаются; при недоступности /proc — null (UI покажет н/д).
     */
    private fun tunPackets(): Pair<Long, Long>? {
        return try {
            val lines = File("/proc/net/dev").readLines()
            var rx = 0L
            var tx = 0L
            var found = false
            for (line in lines.drop(2)) {
                val parts = line.trim().split(Regex("\\s+"))
                if (parts.size < 11) continue
                val iface = parts[0].removeSuffix(":")
                if (!iface.startsWith("tun")) continue
                rx += parts[2].toLongOrNull() ?: 0L
                tx += parts[10].toLongOrNull() ?: 0L
                found = true
            }
            if (found) rx to tx else null
        } catch (e: Throwable) {
            null
        }
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

    // --- helpers ---

    private fun isIpv6Cidr(value: String): Boolean {
        val ip = value.substringBefore('/')
        return ip.contains(':')
    }

    private fun toHostMask(value: String): String {
        val ip = value.substringBefore('/')
        return if (ip.contains(':')) "$ip/128" else "$ip/32"
    }

    private fun isIpLiteral(value: String): Boolean {
        // Домены содержат буквы; IP-литералы — только цифры/точки/двоеточия.
        return !value.any { it.isLetter() } && value.isNotBlank()
    }
}
