package dev.local.vpnservice

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var awgBridge: AwgBridge? = null
    private var platformBridge: PlatformBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val bridge = AwgBridge(applicationContext)
        awgBridge = bridge
        val awgChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AwgBridge.CHANNEL,
        )
        awgChannel.setMethodCallHandler { call, result ->
            bridge.handle(call, result, this)
        }
        bridge.statusSink = { status ->
            runOnUiThread {
                awgChannel.invokeMethod("onStatus", status)
            }
        }
        bridge.logSink = { message ->
            runOnUiThread {
                awgChannel.invokeMethod("onLog", mapOf("message" to message))
            }
        }

        val platform = PlatformBridge(applicationContext)
        platformBridge = platform
        val platformChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PlatformBridge.CHANNEL,
        )
        platformChannel.setMethodCallHandler { call, result ->
            platform.handle(call, result)
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
        super.onDestroy()
    }
}
