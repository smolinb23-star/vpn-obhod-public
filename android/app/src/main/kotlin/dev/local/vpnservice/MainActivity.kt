package dev.local.vpnservice

import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var awgBridge: AwgBridge? = null
    private var platformBridge: PlatformBridge? = null
    private var mihomoBridge: MihomoBridge? = null
    private var vpnControlChannel: MethodChannel? = null

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
        this.vpnControlChannel = vpnControlChannel
        vpnControlChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "show_notification" -> {
                    val serverArg = call.arguments as? Map<*, *>
                    val server = serverArg?.get("server")?.toString() ?: ""
                    VpnForegroundService.start(this, server)
                    result.success(null)
                }
                "hide_notification" -> {
                    VpnForegroundService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Холодный старт по нажатию «Ускорить»/«Остановить» в уведомлении.
        dispatchVpnAction(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        dispatchVpnAction(intent)
    }

    /**
     * Кнопки уведомления открывают MainActivity с action; здесь действие
     * пробрасывается в Dart (vpn_control) — disconnect/accelerate.
     */
    private fun dispatchVpnAction(intent: Intent?) {
        val method = when (intent?.action) {
            VpnForegroundService.ACTION_ACCELERATE -> "accelerate"
            VpnForegroundService.ACTION_STOP -> "disconnect"
            else -> return
        }
        val channel = vpnControlChannel ?: return
        // Dart-обработчик регистрируется уже после первого кадра.
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                channel.invokeMethod(method, null, object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        Log.i("MainActivity", "vpn action $method → ok")
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        Log.w("MainActivity", "vpn action $method failed: $code $message")
                    }

                    override fun notImplemented() {
                        Log.w("MainActivity", "vpn action $method not implemented")
                    }
                })
            } catch (e: Throwable) {
                Log.w("MainActivity", "vpn action $method: ${e.message}")
            }
        }, 400)
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
        vpnControlChannel = null
        super.onDestroy()
    }
}
