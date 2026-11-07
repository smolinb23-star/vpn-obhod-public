package dev.local.vpnservice

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var awgBridge: AwgBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bridge = AwgBridge(applicationContext)
        awgBridge = bridge
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AwgBridge.CHANNEL,
        )
        channel.setMethodCallHandler { call, result ->
            bridge.handle(call, result, this)
        }
        bridge.statusSink = { status ->
            runOnUiThread {
                channel.invokeMethod("onStatus", status)
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
        super.onDestroy()
    }
}
