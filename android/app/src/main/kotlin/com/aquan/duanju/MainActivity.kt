package com.aquan.duanju

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // DLNA 投屏设备发现：不持 MulticastLock 时多数机型收不到 SSDP 组播响应。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aquan/cast")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticastLock" -> {
                        try {
                            if (multicastLock == null) {
                                val wifi = applicationContext
                                    .getSystemService(Context.WIFI_SERVICE) as WifiManager
                                multicastLock = wifi.createMulticastLock("aquan-cast").apply {
                                    setReferenceCounted(false)
                                    acquire()
                                }
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            // 个别系统无 Wi-Fi 服务：发现功能退化为仅 NOTIFY/单播。
                            result.success(false)
                        }
                    }
                    "releaseMulticastLock" -> {
                        try {
                            multicastLock?.release()
                        } catch (_: Exception) {
                        }
                        multicastLock = null
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
