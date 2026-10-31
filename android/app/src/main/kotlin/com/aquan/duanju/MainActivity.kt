package com.aquan.duanju

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 继承 AudioServiceActivity（它本身继承 FlutterActivity）才能让 audio_service 的
// 前台服务拿到 Activity 上下文；同时保住下面 aquan/cast 的自定义通道。
class MainActivity : AudioServiceActivity() {

    private var multicastLock: WifiManager.MulticastLock? = null

    /// 通知权限申请只能有一个在飞：保存挂起的 result，系统回调时再回填。
    private var pendingNotificationResult: MethodChannel.Result? = null

    private companion object {
        const val REQ_POST_NOTIFICATIONS = 4001
    }

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

        // Android 13+ 的通知权限：听书的后台通知/锁屏控制的前提。
        // 不引入 permission_handler：只有这一个权限，一个通道就够。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aquan/notifications")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(hasNotificationPermission())
                    "requestPermission" -> {
                        if (hasNotificationPermission()) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        // 上一次还没回：先把旧结果落成 false，避免 Dart 侧永远 await。
                        pendingNotificationResult?.success(false)
                        pendingNotificationResult = result
                        try {
                            requestPermissions(
                                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                REQ_POST_NOTIFICATIONS,
                            )
                        } catch (e: Exception) {
                            pendingNotificationResult = null
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_POST_NOTIFICATIONS) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingNotificationResult?.success(granted)
        pendingNotificationResult = null
    }

    /// Android 13 (API 33) 起才需要动态申请；更早版本安装时即授予。
    private fun hasNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
}
