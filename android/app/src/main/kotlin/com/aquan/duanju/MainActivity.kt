package com.aquan.duanju

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import com.aquan.duanju.mirror.MirrorService
import com.aquan.duanju.receiver.ReceiverService
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// 继承 AudioServiceActivity（它本身继承 FlutterActivity）才能让 audio_service 的
// 前台服务拿到 Activity 上下文；同时保住下面 aquan/cast 的自定义通道。
class MainActivity : AudioServiceActivity() {

    private var multicastLock: WifiManager.MulticastLock? = null

    /// 通知权限申请只能有一个在飞：保存挂起的 result，系统回调时再回填。
    private var pendingNotificationResult: MethodChannel.Result? = null

    /// 屏幕镜像授权：系统投屏确认框的挂起结果。
    private var pendingMirrorResult: MethodChannel.Result? = null

    /// 「安装未知应用」授权页的挂起结果。
    private var pendingInstallPermissionResult: MethodChannel.Result? = null

    /// 安装轮次：回传给 Dart，用来丢弃上一轮迟到的安装结果。
    private var pendingInstallToken = 0

    private companion object {
        const val TAG = "MainActivity"
        const val REQ_POST_NOTIFICATIONS = 4001
        const val REQ_MIRROR_PERMISSION = 4002
        const val REQ_INSTALL_PERMISSION = 4003
        const val REQ_INSTALL_APK = 4004
        const val CRASH_LOG_MAX_BYTES = 256 * 1024

        /// `PackageInstaller.STATUS_FAILURE_INCOMPATIBLE`（API 29 才有常量，
        /// 这里写字面量避免低版本类加载问题）。
        const val STATUS_FAILURE_INCOMPATIBLE = 7
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        installCrashLogger()
        // DLNA 投屏设备发现：不持 MulticastLock 时多数机型收不到 SSDP 组播响应。
        // 所有 aquan/cast 方法统一 runCatching + 结构化返回：任何原生异常都不会
        // 冒出通道（R4），原始堆栈只写 logcat，不回传 Dart 作用户可见文案。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aquan/cast")
            .setMethodCallHandler { call, result ->
                runCatching {
                    when (call.method) {
                        "acquireMulticastLock" -> {
                            val ok = runCatching {
                                if (multicastLock == null) {
                                    // 无 Wi-Fi 硬件的盒子拿不到 WifiManager：
                                    // as? 空安全，不再因强转 null 抛未捕获异常。
                                    val wifi = applicationContext
                                        .getSystemService(Context.WIFI_SERVICE) as? WifiManager
                                        ?: return@runCatching false
                                    multicastLock = wifi.createMulticastLock("aquan-cast").apply {
                                        setReferenceCounted(false)
                                        acquire()
                                    }
                                }
                                true
                            }.getOrElse { e ->
                                Log.w(TAG, "multicast lock unavailable", e)
                                false
                            }
                            result.success(ok)
                        }
                        "releaseMulticastLock" -> {
                            runCatching { multicastLock?.release() }
                                .onFailure { Log.w(TAG, "release multicast lock", it) }
                            multicastLock = null
                            result.success(true)
                        }
                        "requestMirrorPermission" -> {
                            // 系统投屏确认框：onActivityResult 回填 {granted, ...}。
                            if (pendingMirrorResult != null) {
                                result.success(mapOf("granted" to false, "reason" to "busy"))
                            } else {
                                pendingMirrorResult = result
                                val launched = runCatching {
                                    val pm = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                                        as? MediaProjectionManager
                                        ?: error("MediaProjectionManager unavailable")
                                    startActivityForResult(
                                        pm.createScreenCaptureIntent(),
                                        REQ_MIRROR_PERMISSION,
                                    )
                                    true
                                }.getOrElse { e ->
                                    Log.w(TAG, "mirror permission launch failed", e)
                                    false
                                }
                                if (!launched) {
                                    pendingMirrorResult = null
                                    result.success(
                                        mapOf("granted" to false, "reason" to "unavailable")
                                    )
                                }
                            }
                        }
                        "startMirror" -> {
                            val started = runCatching {
                                if (MirrorService.isRunning()) {
                                    false
                                } else {
                                    MirrorService.dartChannel = MethodChannel(
                                        flutterEngine.dartExecutor.binaryMessenger, "aquan/cast"
                                    )
                                    // 授权 Intent 已由 onActivityResult 存进 MirrorService
                                    // 进程内，不再经 startForegroundService 的 extra 二次传递
                                    // （Android 14 起 token 只能消费一次）。
                                    MirrorService.start(
                                        applicationContext,
                                        call.argument<Boolean>("withAudio") ?: true,
                                    )
                                    true
                                }
                            }.getOrElse { e ->
                                Log.w(TAG, "start mirror failed", e)
                                false
                            }
                            // Dart 侧 invokeMethod<bool> 只 await、不读值：结构化返回。
                            result.success(started)
                        }
                        "stopMirror" -> {
                            runCatching { MirrorService.stop(applicationContext) }
                                .onFailure { Log.w(TAG, "stop mirror failed", it) }
                            result.success(true)
                        }
                        "receiverStart" -> {
                            // 接收端开关（R1.1/R1.2）：前台服务 + MulticastLock。
                            // Android 13+ 通知权限顺手请求（拒绝仍可投，仅无通知）。
                            requestReceiverNotificationPermission()
                            val port = runCatching {
                                // receiverPause 事件走独立 aquan/castd 通道：
                                // aquan/cast 的 Dart 侧 handler 被 MirrorController
                                // 独占，共用会互相顶掉（见 receiver_android_bridge.dart）。
                                if (ReceiverService.dartChannel == null) {
                                    ReceiverService.dartChannel = MethodChannel(
                                        flutterEngine.dartExecutor.binaryMessenger,
                                        "aquan/castd",
                                    )
                                }
                                ReceiverService.start(applicationContext, call.argument<Int>("port"))
                                call.argument<Int>("port")
                            }.getOrElse { e ->
                                Log.w(TAG, "start receiver failed", e)
                                null
                            }
                            result.success(port)
                        }
                        "receiverStop" -> {
                            runCatching { ReceiverService.stop(applicationContext) }
                                .onFailure { Log.w(TAG, "stop receiver failed", it) }
                            result.success(true)
                        }
                        "setSessionMeta" -> {
                            // 通知栏「正在接收：<标题>」+ 首个会话申请音频焦点。
                            runCatching { ReceiverService.setSessionMeta(call.argument<String>("title")) }
                                .onFailure { Log.w(TAG, "set session meta failed", it) }
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                }.onFailure { e ->
                    // 兜底：即便分支有遗漏也不把异常抛回 Flutter 线程；
                    // 回复可能已提交，这里再包一层避免二次回复异常外泄。
                    Log.e(TAG, "aquan/cast ${call.method} crashed", e)
                    runCatching {
                        if (call.method == "requestMirrorPermission") {
                            result.success(mapOf("granted" to false, "reason" to "internal-error"))
                        } else {
                            result.success(null)
                        }
                    }
                }
            }

        // TV 判定：电视盒子 / Android TV 与手机共用同一个包，启动时读系统特性。
        // 只读、不产生副作用；任何异常都回空 map，Dart 侧会按「有触摸屏」处理。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aquan/tv")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "probe" -> {
                        try {
                            val pm = packageManager
                            result.success(mapOf(
                                "leanback" to pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK),
                                "television" to pm.hasSystemFeature(PackageManager.FEATURE_TELEVISION),
                                "touchscreen" to pm.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN),
                            ))
                        } catch (e: Exception) {
                            result.success(emptyMap<String, Boolean>())
                        }
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

        // 应用内更新：Dart 负责下载 + SHA-256 校验；这里负责安装前的预检
        // （包名/签名）、未知来源授权引导、以及把系统安装器的结果回传。
        // 安装确认始终交给系统（不允许静默安装）。
        //
        // 为什么要在调起安装器之前预检签名：覆盖安装要求签名一致，不一致时
        // 系统只会给一个含义模糊的失败。提前读出 APK 的签名证书与当前应用比对，
        // 就能直接告诉用户"卸载旧版重装"，不用白走一遍安装器。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aquan/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstallPackages" -> result.success(canInstallPackages())
                    "requestInstallPermission" -> {
                        if (canInstallPackages()) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        if (pendingInstallPermissionResult != null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        pendingInstallPermissionResult = result
                        val opened = runCatching {
                            startActivityForResult(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName"),
                                ),
                                REQ_INSTALL_PERMISSION,
                            )
                            true
                        }.getOrElse { e ->
                            Log.w(TAG, "open unknown-sources settings failed", e)
                            false
                        }
                        if (!opened) {
                            pendingInstallPermissionResult = null
                            result.success(false)
                        }
                    }
                    "inspectApk" -> result.success(inspectApk(call.argument("path")))
                    "currentSignature" -> result.success(
                        runCatching { currentSigners() }.getOrElse { e ->
                            Log.w(TAG, "read current signature failed", e)
                            emptyList<String>()
                        },
                    )
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("BAD_ARGS", "安装包路径为空", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val file = File(path)
                            if (!file.exists()) {
                                result.error("NOT_FOUND", "安装包不存在", null)
                                return@setMethodCallHandler
                            }
                            // API 24+ 不允许 file:// 跨应用暴露：必须走 FileProvider。
                            val uri = FileProvider.getUriForFile(
                                this,
                                "$packageName.fileprovider",
                                file,
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(
                                    uri,
                                    "application/vnd.android.package-archive",
                                )
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            pendingInstallToken += 1
                            startActivityForResult(intent, REQ_INSTALL_APK)
                            result.success(
                                mapOf(
                                    "launched" to true,
                                    "token" to pendingInstallToken,
                                ),
                            )
                        } catch (e: Exception) {
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Android 8.0 起安装未知来源应用需要用户逐个应用授权。
    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()

    /// API 28+ 用签名证书信息（支持密钥轮换），更早版本只有 signatures。
    private fun signingFlags(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }

    /// 读取安装包的包名 / versionCode / 签名摘要；失败时不抛，返回 error 字段。
    ///
    /// 预检是**尽力而为**：读不出来就让安装流程继续（不能因为预检本身把正常的
    /// 升级路径卡死），只有明确读到"包名不同 / 签名不交集"才拦。
    private fun inspectApk(path: Any?): Map<String, Any?> {
        val apkPath = path as? String
        if (apkPath.isNullOrEmpty()) return mapOf("error" to "安装包路径为空")
        return runCatching {
            if (!File(apkPath).exists()) return@runCatching mapOf("error" to "安装包不存在")
            @Suppress("DEPRECATION")
            val info = packageManager.getPackageArchiveInfo(apkPath, signingFlags())
                ?: return@runCatching mapOf("error" to "无法解析安装包")
            mapOf(
                "packageName" to info.packageName,
                "versionCode" to versionCodeOf(info),
                "versionName" to (info.versionName ?: ""),
                "signers" to signersOf(info),
            )
        }.getOrElse { e ->
            Log.w(TAG, "inspect apk failed", e)
            mapOf("error" to (e.message ?: "解析安装包失败"))
        }
    }

    private fun currentSigners(): List<String> {
        @Suppress("DEPRECATION")
        val info = packageManager.getPackageInfo(packageName, signingFlags())
        return signersOf(info)
    }

    private fun versionCodeOf(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }

    /// 签名证书的 SHA-256（小写十六进制、无分隔符）。多签名与密钥轮换都覆盖，
    /// 与当前应用取交集即视为同一签名。
    private fun signersOf(info: PackageInfo): List<String> {
        val certificates: List<ByteArray> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val signing = info.signingInfo ?: return emptyList()
                if (signing.hasMultipleSigners()) {
                    signing.apkContentsSigners.map { it.toByteArray() }
                } else {
                    signing.signingCertificateHistory.map { it.toByteArray() }
                }
            } else {
                @Suppress("DEPRECATION")
                (info.signatures ?: emptyArray()).map { it.toByteArray() }
            }
        val digest = MessageDigest.getInstance("SHA-256")
        return certificates.map { certificate ->
            digest.reset()
            digest.digest(certificate).joinToString("") { "%02x".format(it) }
        }.distinct()
    }

    /// 把系统安装器的结果归一成稳定字符串交回 Dart；拿不到就报 unknown，
    /// Dart 侧把 unknown 当作"已交给系统处理"，不当作失败。
    private fun reportInstallResult(resultCode: Int, data: Intent?) {
        val status = data?.getIntExtra(PackageInstaller.EXTRA_STATUS, Int.MIN_VALUE)
            ?: Int.MIN_VALUE
        val message = data?.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        val code = installStatusCode(status, message, resultCode)
        Log.i(TAG, "install result: resultCode=$resultCode status=$status code=$code msg=$message")
        runCatching {
            MethodChannel(
                flutterEngine!!.dartExecutor.binaryMessenger,
                "aquan/update",
            ).invokeMethod(
                "installResult",
                mapOf(
                    "code" to code,
                    "status" to status,
                    "message" to message,
                    "token" to pendingInstallToken,
                ),
            )
        }.onFailure { Log.w(TAG, "report install result failed", it) }
    }

    private fun installStatusCode(
        status: Int,
        message: String?,
        resultCode: Int,
    ): String {
        when (status) {
            PackageInstaller.STATUS_SUCCESS -> return "success"
            PackageInstaller.STATUS_PENDING_USER_ACTION -> return "pendingUserAction"
            PackageInstaller.STATUS_FAILURE_ABORTED -> return "aborted"
            PackageInstaller.STATUS_FAILURE_BLOCKED -> return "blocked"
            PackageInstaller.STATUS_FAILURE_CONFLICT -> return "conflict"
            PackageInstaller.STATUS_FAILURE_INVALID -> return "invalid"
            PackageInstaller.STATUS_FAILURE_STORAGE -> return "storage"
            STATUS_FAILURE_INCOMPATIBLE -> return "incompatible"
            PackageInstaller.STATUS_FAILURE -> return "failure"
        }
        // 部分机型（尤其非 GMS 的盒子）不返回 EXTRA_STATUS，只有消息串。
        val text = message ?: ""
        return when {
            text.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") -> "conflict"
            text.contains("INSTALL_FAILED_ALREADY_EXISTS") -> "conflict"
            text.contains("INSTALL_FAILED_VERSION_DOWNGRADE") -> "incompatible"
            text.contains("INSTALL_FAILED_USER_RESTRICTED") -> "blocked"
            text.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") -> "storage"
            text.contains("INSTALL_FAILED_INVALID_APK") -> "invalid"
            text.isNotEmpty() -> "failure"
            // 用户在系统安装器里点了取消：没有 STATUS，只有 RESULT_CANCELED。
            resultCode == Activity.RESULT_CANCELED -> "aborted"
            else -> "unknown"
        }
    }

    /// 11-08 真机修复：默认未捕获异常处理器装饰器——任何线程的未捕获
    /// Throwable 先落 `<filesDir>/native_crash.log`（256KB 滚动）+ logcat，
    /// 再交还原 handler（**崩溃行为不变**，只增可观测）：真机闪退后可经
    /// 「导出运行日志」或 adb 拿到原生堆栈，不再黑盒排查。
    private fun installCrashLogger() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        if (previous == null) return
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            runCatching { writeNativeCrashLog(thread, throwable) }
                .onFailure { Log.e(TAG, "write native crash log failed", it) }
            previous.uncaughtException(thread, throwable)
        }
    }

    private fun writeNativeCrashLog(thread: Thread, throwable: Throwable) {
        val dir = filesDir ?: return
        val file = File(dir, "native_crash.log")
        val stamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US).format(Date())
        val text = "$stamp thread=${thread.name}\n${throwable.stackTraceToString()}\n\n"
        if (file.length() > CRASH_LOG_MAX_BYTES) {
            // 只留最近一次：滚动即重写，日志永不超限。
            file.writeText(text)
        } else {
            file.appendText(text)
        }
        Log.e(TAG, "uncaught exception on ${thread.name}", throwable)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_INSTALL_PERMISSION) {
            // 从「安装未知应用」授权页返回：把最新状态回填给 Dart。
            val pending = pendingInstallPermissionResult
            pendingInstallPermissionResult = null
            runCatching { pending?.success(canInstallPackages()) }
            return
        }
        if (requestCode == REQ_INSTALL_APK) {
            reportInstallResult(resultCode, data)
            return
        }
        if (requestCode != REQ_MIRROR_PERMISSION) return
        val result = pendingMirrorResult
        pendingMirrorResult = null
        val granted = runCatching {
            if (data != null && resultCode == android.app.Activity.RESULT_OK) {
                // token 只在服务进程内保存一次，由 MirrorService 启动时一次性消费；
                // 绝不塞进 startForegroundService 的 extra（Android 14 起禁止二次传递）。
                MirrorService.saveProjection(resultCode, data)
                true
            } else {
                false
            }
        }.getOrElse { e ->
            Log.e(TAG, "save projection failed", e)
            false
        }
        // 回复本身也可能抛（result 已失效）：包住，绝不向系统回调外抛异常。
        runCatching {
            if (granted) {
                result?.success(mapOf("granted" to true))
            } else {
                result?.success(mapOf("granted" to false, "reason" to "denied"))
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

    /// 接收端开启时的通知权限请求（复用 REQ_POST_NOTIFICATIONS 先例与挂起
    /// 结果机制）：已有申请在飞时不重复弹；拒绝只影响通知显示，前台服务照跑。
    /// 这里不挂起 receiverStart 的回复——权限与起服务互不阻塞。
    private fun requestReceiverNotificationPermission() {
        if (hasNotificationPermission()) return
        if (pendingNotificationResult != null) return
        try {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQ_POST_NOTIFICATIONS,
            )
        } catch (e: Exception) {
            Log.w(TAG, "receiver notification permission request failed", e)
        }
    }
}
