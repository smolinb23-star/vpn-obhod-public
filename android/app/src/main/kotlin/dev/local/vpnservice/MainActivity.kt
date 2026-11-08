package dev.local.vpnservice

import android.content.Intent
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

        // AWG Bridge
        val awg = AwgBridge(applicationContext)
        awgBridge = awg
        val awgChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
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
            flutterEngine.dartExecutor.binaryMessenger,
            PlatformBridge.CHANNEL,
        )
        platformChannel.setMethodCallHandler { call, result ->
            platform.handle(call, result)
        }

        // Mihomo Bridge
        val mihomo = MihomoBridge(applicationContext)
        mihomoBridge = mihomo
        val mihomoChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MihomoBridge.CHANNEL,
        )
        val mihomoEventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MihomoBridge.STATUS_CHANNEL,
        )
        mihomo.setMethodCallHandler(mihomoChannel, mihomoEventChannel)
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
