package dev.local.vpnservice

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var awgBridge: AwgBridge? = null
    private var platformBridge: PlatformBridge? = null
    private var mihomoBridge: MihomoBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val binaryMessenger = flutterEngine.dartExecutor.binaryMessenger

        // AWG Bridge
        val awg = AwgBridge(applicationContext)
        awgBridge = awg
        val awgChannel = MethodChannel(
            binaryMessenger,
            AwgBridge.CHANNEL,
        )
        awgChannel.setMethodCallHandler { call, result ->
            awg.handle(call, result, this)
        }
        awg.statusSink = { status ->
            runOnUiThread {
                awgChannel.invokeMethod("onStatus", status)
            }
        }
        awg.logSink = { message ->
            runOnUiThread {
                awgChannel.invokeMethod("onLog", mapOf("message" to message))
            }
        }

        // Platform Bridge
        val platform = PlatformBridge(applicationContext)
        platformBridge = platform
        val platformChannel = MethodChannel(
            binaryMessenger,
            PlatformBridge.CHANNEL,
        )
        platformChannel.setMethodCallHandler { call, result ->
            platform.handle(call, result)
        }

        // Mihomo Bridge
        val mihomo = MihomoBridge(applicationContext)
        mihomoBridge = mihomo
        val mihomoChannel = MethodChannel(
            binaryMessenger,
            MihomoBridge.CHANNEL,
        )
        val mihomoEventChannel = EventChannel(
            binaryMessenger,
            MihomoBridge.STATUS_CHANNEL,
        )
        mihomo.setMethodCallHandler(mihomoChannel, mihomoEventChannel)

        // Vpn Control Channel (команды из уведомления foreground service → Flutter)
        val vpnControlChannel = MethodChannel(
            binaryMessenger,
            "dev.local.vpnservice/vpn_control",
        )
        vpnControlChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "show_notification" -> {
                    val serverArg = call.arguments as? Map<*, *>
                    val server = serverArg?.get("server")?.toString() ?: ""
                    val intent = Intent(this, VpnForegroundService::class.java)
                        .putExtra("server", server)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }
                "hide_notification" -> {
                    stopService(Intent(this, VpnForegroundService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        awgBridge?.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        awgBridge?.dispose()
        awgBridge = null
        platformBridge?.dispose()
        platformBridge = null
        mihomoBridge?.dispose()
        mihomoBridge = null
        super.onDestroy()
    }
}
