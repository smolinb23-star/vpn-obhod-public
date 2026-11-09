package dev.local.vpnservice

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import android.telephony.TelephonyManager
import android.util.Base64
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.concurrent.Executors

/**
 * Платформенный мост (не VPN-ядро): network_key, форсирование LTE,
 * foreground keep-alive и dump logcat для экспорта логов.
 */
class PlatformBridge(private val context: Context) {

    companion object {
        const val CHANNEL = "dev.local.vpnservice/platform"
        private const val TAG = "PlatformBridge"
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getNetworkInfo" -> result.success(networkInfo())
            "forceLte" -> result.success(forceLte())
            "startKeepAlive" -> {
                TunnelKeepAliveService.start(
                    context,
                    call.argument<String>("server") ?: "",
                )
                result.success(null)
            }
            "stopKeepAlive" -> {
                TunnelKeepAliveService.stop(context)
                result.success(null)
            }
            "dumpLogcat" -> dumpLogcat(call, result)
            "getInstalledApps" -> result.success(getInstalledApps())
            "isVpnActive" -> result.success(isVpnActive())
            else -> result.notImplemented()
        }
    }

    /** SSID Wi-Fi или operator|mccmnc — ключ памяти побед. */
    @SuppressLint("MissingPermission", "HardwareIds")
    private fun networkInfo(): Map<String, Any?> {
        var ssid: String? = null
        var operator: String? = null
        var mccMnc: String? = null
        var type: String? = null

        try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = cm.activeNetwork
            val caps = network?.let { cm.getNetworkCapabilities(it) }
            type = when {
                caps == null -> "none"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                else -> "other"
            }
        } catch (e: Throwable) {
            Log.w(TAG, "network type: ${e.message}")
        }

        try {
            val wifi = context.applicationContext
                .getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
            @Suppress("DEPRECATION")
            val raw = wifi.connectionInfo?.ssid
            if (raw != null && raw != "<unknown ssid>" && raw.isNotBlank()) {
                ssid = raw.trim('"')
            }
        } catch (e: Throwable) {
            Log.w(TAG, "ssid unavailable: ${e.message}")
        }

        try {
            val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            operator = tm.networkOperatorName?.takeIf { it.isNotBlank() }
            mccMnc = tm.networkOperator?.takeIf { it.isNotBlank() }
        } catch (e: Throwable) {
            Log.w(TAG, "operator unavailable: ${e.message}")
        }

        return mapOf(
            "ssid" to ssid,
            "operator" to operator,
            "mccMnc" to mccMnc,
            "type" to type,
        )
    }

    /**
     * preferred_network_mode = 11 (LTE only).
     * Требует WRITE_SECURE_SETTINGS; без него — понятная инструкция.
     */
    private fun forceLte(): Map<String, Any?> {
        return try {
            val before = Settings.Global.getInt(
                context.contentResolver,
                "preferred_network_mode",
                -1,
            )
            Settings.Global.putInt(
                context.contentResolver,
                "preferred_network_mode",
                11,
            )
            val after = Settings.Global.getInt(
                context.contentResolver,
                "preferred_network_mode",
                -1,
            )
            Log.i(TAG, "forceLte: $before -> $after")
            if (after == 11) {
                mapOf(
                    "ok" to true,
                    "message" to "preferred_network_mode = 11 (LTE only).",
                    "needsPermission" to false,
                )
            } else {
                mapOf(
                    "ok" to false,
                    "message" to "Система не применила режим (было $before, стало $after).",
                    "needsPermission" to false,
                )
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "forceLte denied", e)
            mapOf(
                "ok" to false,
                "message" to "Нет разрешения WRITE_SECURE_SETTINGS.",
                "needsPermission" to true,
            )
        } catch (e: Throwable) {
            Log.w(TAG, "forceLte error", e)
            mapOf(
                "ok" to false,
                "message" to "Ошибка: ${e.message}",
                "needsPermission" to false,
            )
        }
    }

    /** logcat только своего процесса: AwgBridge, AmneziaWG/GoBackend и краши. */
    private fun dumpLogcat(call: MethodCall, result: MethodChannel.Result) {
        val lines = (call.argument<Number>("lines")?.toInt() ?: 500).coerceIn(50, 2000)
        executor.execute {
            val text = try {
                val pid = Process.myPid()
                val output = runLogcat(
                    arrayOf("logcat", "-d", "-v", "time", "--pid=$pid", "-t", "$lines"),
                ) ?: runLogcat(arrayOf("logcat", "-d", "-v", "time", "-t", "$lines"))
                val all = output?.split('\n')?.filter { it.isNotBlank() } ?: emptyList()
                all.takeLast(lines).joinToString("\n")
            } catch (e: Throwable) {
                Log.w(TAG, "dumpLogcat failed", e)
                "logcat недоступен: ${e.message}"
            }
            mainHandler.post { result.success(text) }
        }
    }

    private fun runLogcat(cmd: Array<String>): String? {
        return try {
            val process = ProcessBuilder(*cmd).redirectErrorStream(true).start()
            val sb = StringBuilder()
            BufferedReader(InputStreamReader(process.inputStream)).use { reader ->
                reader.lineSequence().forEach { sb.append(it).append('\n') }
            }
            process.waitFor()
            if (sb.isEmpty()) null else sb.toString()
        } catch (e: Throwable) {
            null
        }
    }

    fun dispose() {
        executor.shutdownNow()
    }

    /** Активен ли сейчас любой VPN-интерфейс (свой или сторонний). */
    private fun isVpnActive(): Boolean {
        return try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(network) ?: return false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        } catch (e: Throwable) {
            Log.w(TAG, "isVpnActive failed: ${e.message}")
            false
        }
    }

    /** Возвращает JSON-массив установленных приложений: [{name, package, icon_base64}]. */
    private fun getInstalledApps(): List<Map<String, Any?>> {
        val pm = context.packageManager
        val apps = mutableListOf<Map<String, Any?>>()
        try {
            val installed = pm.getInstalledApplications(PackageManager.GET_META_DATA)
            for (info in installed) {
                // Пропускаем системные приложения (опционально — оставляем все, пользователь выберет)
                val name = info.loadLabel(pm)?.toString() ?: info.packageName
                val pkg = info.packageName
                val iconBase64 = loadIconBase64(pm, info)
                apps.add(mapOf(
                    "name" to name,
                    "package" to pkg,
                    "icon" to iconBase64,
                ))
            }
        } catch (e: Throwable) {
            Log.w(TAG, "getInstalledApps failed: ${e.message}")
        }
        return apps
    }

    /** Иконка приложения в base64 PNG. */
    private fun loadIconBase64(pm: PackageManager, info: ApplicationInfo): String? {
        return try {
            val drawable: Drawable = info.loadIcon(pm)
            if (drawable is BitmapDrawable) {
                val bitmap = drawable.bitmap
                val baos = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 90, baos)
                Base64.encodeToString(baos.toByteArray(), Base64.DEFAULT)
            } else {
                null
            }
        } catch (e: Throwable) {
            Log.w(TAG, "loadIconBase64 failed for ${info.packageName}: ${e.message}")
            null
        }
    }
}
