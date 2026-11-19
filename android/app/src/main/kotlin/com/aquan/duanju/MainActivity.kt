package com.aquan.duanju

import android.Manifest
import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.util.Rational
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

    /// Android 画中画（PiP）：aquan/pip 通道。控制指令（Dart→Kotlin）与事件
    /// 回推（Kotlin→Dart 的 onPipChanged / onPipClosed）共用同一条通道；引擎
    /// 重建时 [configureFlutterEngine] 重新赋值，旧引用自然作废。
    private var pipChannel: MethodChannel? = null

    /// Activity 是否已 onStop：用来区分「点小窗展开」与「划掉小窗」两条退出
    /// 路径（见 [onPictureInPictureModeChanged]）。本类继承 FlutterActivity
    /// （非 ComponentActivity），拿不到 androidx Lifecycle，自己跟踪 stopped 态。
    private var pipActivityStopped = false


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

        // 画中画（PiP）：与 aquan/cast 同套路，runCatching 包裹，任何原生异常
        // 都不冒出通道。**不支持时一律返回 false / supported=false**，由 Dart
        // 侧决定不渲染入口——绝不依赖系统 toast 告诉用户「不支持」。
        val pip = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aquan/pip")
        pipChannel = pip
        pip.setMethodCallHandler { call, result ->
            runCatching {
                when (call.method) {
                    // 三重判定：SDK 版本 / 系统特性 / Manifest 声明（合并结果）。
                    "probe" -> result.success(probePip())
                    "enter" -> result.success(
                        enterPipNow(
                            (call.argument<Number>("aspectRatio")?.toDouble())
                                ?: (9.0 / 16.0),
                        ),
                    )
                    "isInPip" -> result.success(isInPipMode())
                    else -> result.notImplemented()
                }
            }.onFailure { e ->
                Log.e(TAG, "aquan/pip ${call.method} crashed", e)
                // probe 的失败也要给出结构化结果，Dart 侧按「不支持」处理。
                runCatching {
                    if (call.method == "probe") {
                        result.success(
                            mapOf<String, Any>("supported" to false, "reason" to "error"),
                        )
                    } else {
                        result.success(false)
                    }
                }
            }
        }
    }

    /// 设备是否支持画中画。
    ///
    /// 只做两项**公开且稳定**的判定：`SDK_INT >= O(26)` 与
    /// `FEATURE_PICTURE_IN_PICTURE`（部分盒子 / 车机没有该特性）。
    ///
    /// **不读 `ActivityInfo` 的 PiP flags 位**：那个常量在公开 android.jar 里
    /// 是 @hide（`javap` 无输出），字面量取值无法在构建期校验；一旦写错就会
    /// fail-closed，把所有设备（包括真支持的平板）的入口判死，且只能靠真机
    /// logcat 才发现。Manifest 的 `supportsPictureInPicture` 声明由本仓库构建
    /// 保证（发版前用 aapt2 验证过 APK 清单），真正的权威失败点是 [enterPipNow]：
    /// ROM 拒绝时返回 false，播放页隐藏入口并记住版本号。
    private fun probePip(): Map<String, Any> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return mapOf<String, Any>("supported" to false, "reason" to "sdk_too_low")
        }
        val hasFeature = runCatching {
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
        }.getOrElse { false }
        if (!hasFeature) {
            return mapOf<String, Any>("supported" to false, "reason" to "feature_missing")
        }
        return mapOf<String, Any>("supported" to true, "reason" to "ok")
    }

    /// 构造 PiP 参数：宽高比 clamp 到系统允许的 [1/2.39, 2.39]；Android 12+
    /// 关掉 seamlessResize 避免小窗重排闪烁。**不设置 setAutoEnterEnabled**——
    /// 按 Home 不强入小窗，只在用户主动点入口时进入。
    private fun pipParams(ratio: Double): PictureInPictureParams {
        val clamped = ratio.coerceIn(1.0 / 2.39, 2.39)
        val builder = PictureInPictureParams.Builder()
            // Rational 要分数：1/1000 精度足够（系统内部会化简）。
            .setAspectRatio(Rational((clamped * 1000).toInt().coerceAtLeast(1), 1000))
        // setSeamlessResizeEnabled 是 API 31 才有的方法：API 26–30 调用会抛
        // NoSuchMethodError，被 runCatching 吞成 false →「明明支持却报不支持」，
        // 并把版本号记成失败，入口彻底消失（复评 C1）。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    /// 手动进入画中画。任何异常（含 ROM 拒绝）都返回 false，由 Dart 侧把入口
    /// 隐藏并记住版本号，不重试、不弹系统 toast。
    private fun enterPipNow(ratio: Double): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return runCatching {
            enterPictureInPictureMode(pipParams(ratio))
        }.getOrElse { e ->
            Log.w(TAG, "enter pip failed", e)
            false
        }
    }

    private fun isInPipMode(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isInPictureInPictureMode

    private fun notifyPipChanged(inPip: Boolean) {
        val channel = pipChannel ?: return
        runCatching { channel.invokeMethod("onPipChanged", mapOf("inPip" to inPip)) }
            .onFailure { Log.w(TAG, "notify pip changed failed", it) }
    }

    private fun notifyPipClosed() {
        val channel = pipChannel ?: return
        runCatching { channel.invokeMethod("onPipClosed", null) }
            .onFailure { Log.w(TAG, "notify pip closed failed", it) }
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

    // ---------- 画中画（PiP）：退出路径判定 ----------
    //
    // PiP 中的尺寸变化由 Manifest configChanges 吸收，Activity 不重建，
    // 这里的成员（pipChannel / pipActivityStopped）全程有效。

    override fun onStart() {
        super.onStart()
        pipActivityStopped = false
    }

    override fun onResume() {
        super.onResume()
        pipActivityStopped = false
    }

    override fun onStop() {
        super.onStop()
        pipActivityStopped = true
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        notifyPipChanged(isInPictureInPictureMode)
        if (isInPictureInPictureMode) return
        // 退出 PiP 有两条路径，必须区分（否则「展开」会被误判成「划走」）：
        // - 点小窗 ✕ / 划走：Activity 保持 onStop（stopped=true）→ 通知 Dart 暂停；
        // - 点小窗展开回全屏：Activity 回到 RESUMED（onStart/onResume 把
        //   stopped 清回 false）→ 什么也不做。
        // 回调与 onStart/onStop 的先后在不同 ROM 上不一致，因此**两个方向都
        // 延迟复查**（复评 W2）：400ms 后仍不在 PiP 且仍 stopped 才算划走。
        // 期间用户若从桌面重新打开应用（stopped 被清回 false）则不误报。
        Handler(Looper.getMainLooper()).postDelayed({
            if (!isInPipMode() && pipActivityStopped) {
                notifyPipClosed()
            }
        }, 400)
    }

    override fun onDestroy() {
        pipChannel = null
        super.onDestroy()
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
