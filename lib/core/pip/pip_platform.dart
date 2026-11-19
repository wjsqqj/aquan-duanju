/// Android 原生画中画（PiP）能力探测与进入的唯一 Dart 入口。
///
/// 设计原则：**探测不通过就完全不渲染入口**。旧版（1.12.20 及更早）把按钮
/// 常驻底栏且只查系统特性，结果在华为等 ROM 上点击只弹「应用暂不支持该
/// 功能」，还把横屏按钮挤出屏幕。本文件因此：
/// - 探测以原生三重判定为准（SDK / 系统特性 / Manifest 声明），见
///   `MainActivity.probePip`；
/// - 入口由播放页放进「更多」菜单，不占底栏槽位；
/// - 实际进入失败时由播放页隐藏入口并记住版本号，本文件只如实回报 `false`。
///
/// 非 Android 平台所有方法短路：探测恒「不支持」、进入恒 `false`，播放页
/// 的桌面迷你置顶小窗是另一条独立路径，不受影响。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _pipChannel = MethodChannel('aquan/pip');

/// 系统允许的 PiP 宽高比区间（Android `setAspectRatio` 的硬限制）。
const double kMinPipAspectRatio = 1 / 2.39;

/// 见 [kMinPipAspectRatio]。
const double kMaxPipAspectRatio = 2.39;

/// 竖屏短剧缺省比例（拿不到流真实尺寸时的兜底，与桌面迷你窗同口径）。
const double kDefaultPipAspectRatio = 9 / 16;

/// 设备画中画能力（探测结果）。
@immutable
class PipCapability {
  const PipCapability({required this.supported, this.reason = 'ok'});

  /// 是否支持画中画。
  final bool supported;

  /// 不支持的原因：`ok` / `sdk_too_low` / `feature_missing` / `not_declared` /
  /// `malformed` / `channel_error` / `not_android`。仅用于日志排查，不面向用户。
  final String reason;

  static const PipCapability unsupported =
      PipCapability(supported: false, reason: 'not_android');

  @override
  bool operator ==(Object other) =>
      other is PipCapability &&
      other.supported == supported &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(supported, reason);

  @override
  String toString() => 'PipCapability(supported: $supported, reason: $reason)';
}

/// 解析原生 `probe` 回包。
///
/// 格式不符一律判「不支持」——宁可不显示入口，也不能让用户点了才收到系统
/// 的「应用暂不支持该功能」提示。
PipCapability parsePipProbe(Object? raw) {
  if (raw is! Map) {
    return const PipCapability(supported: false, reason: 'malformed');
  }
  final supported = raw['supported'] == true;
  final reason = raw['reason'];
  return PipCapability(
    supported: supported,
    reason: reason is String && reason.isNotEmpty
        ? reason
        : (supported ? 'ok' : 'malformed'),
  );
}

/// 宽高比 clamp：非法（<=0 / NaN / Infinity）回缺省竖屏，越界裁到系统区间。
double normalizePipAspect(double raw) {
  if (raw.isNaN || raw.isInfinite || raw <= 0) return kDefaultPipAspectRatio;
  return raw.clamp(kMinPipAspectRatio, kMaxPipAspectRatio).toDouble();
}

/// 播放页是否应显示「画中画」菜单项（纯函数，便于单测）。
///
/// [unsupportedVersion] 与 [appVersion] 相等，说明本版本已实试过进入并失败
/// （记录见 `SettingsStore.pipUnsupportedVersion`）→ 不再显示；应用升级后
/// 版本号变化会自动重试探测，避免 ROM 修复后永久失去入口。
bool shouldShowPipEntry({
  required bool isAndroid,
  required bool isTv,
  required PipCapability capability,
  required String unsupportedVersion,
  required String appVersion,
}) {
  if (!isAndroid || isTv) return false;
  if (!capability.supported) return false;
  if (unsupportedVersion.isNotEmpty && unsupportedVersion == appVersion) {
    return false;
  }
  return true;
}

// ---------- 通道调用与状态监听 ----------

PipCapability? _cached;

ValueChanged<bool>? _onChanged;
VoidCallback? _onDismissed;

/// 当前绑定的身份句柄（见 [bindPipStateListener]）。
Object? _boundToken;
bool _handlerInstalled = false;

/// 探测设备是否支持画中画。结果进程内缓存，重复调用不重复过通道。
///
/// [refresh] 为 `true` 时强制重新探测（能力校正场景）。
///
/// **通道异常不写缓存**：引擎重建瞬间等瞬时失败如果被缓存，会变成「本次
/// 运行永久无入口」，而调用方无法区分「真不支持」与「网络/引擎抖动」。
Future<PipCapability> probePipCapability({bool refresh = false}) async {
  if (!Platform.isAndroid) return PipCapability.unsupported;
  if (!refresh && _cached != null) return _cached!;
  try {
    final raw = await _pipChannel.invokeMethod<Object?>('probe');
    _cached = parsePipProbe(raw);
    return _cached!;
  } catch (_) {
    return const PipCapability(supported: false, reason: 'channel_error');
  }
}

/// 手动进入画中画。`false` 表示设备/ROM 拒绝（原生异常同样归一成 `false`）。
Future<bool> enterPip({required double aspectRatio}) async {
  if (!Platform.isAndroid) return false;
  try {
    final ok = await _pipChannel.invokeMethod<bool>('enter', {
      'aspectRatio': normalizePipAspect(aspectRatio),
    });
    return ok == true;
  } catch (_) {
    return false;
  }
}

/// 当前是否处于 PiP（尽力而为；非 Android / 通道失败返回 `false`）。
Future<bool> isInPip() async {
  if (!Platform.isAndroid) return false;
  try {
    return await _pipChannel.invokeMethod<bool>('isInPip') == true;
  } catch (_) {
    return false;
  }
}

/// 注册原生 PiP 事件监听（幂等；播放页 init 时调用一次）。
///
/// - [onChanged]：进入 / 退出 PiP 各回调一次；
/// - [onDismissed]：用户划掉小窗（不是展开），播放页据此暂停。
///
/// 返回**身份句柄**，[unbindPipStateListener] 按句柄比对后才会摘除。必须有
/// 这层配对：跨季换行用 `pushReplacement`，新页先 attach、旧页后 dispose，
/// 无条件摘除会把新页刚注册的回调擦掉（复评 C2；与 media hub 的 owner 配对
/// 同一个坑）。
Object bindPipStateListener({
  ValueChanged<bool>? onChanged,
  VoidCallback? onDismissed,
}) {
  final token = Object();
  if (!Platform.isAndroid) return token;
  _boundToken = token;
  _onChanged = onChanged;
  _onDismissed = onDismissed;
  if (_handlerInstalled) return token;
  _handlerInstalled = true;
  _pipChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'onPipChanged':
        final args = call.arguments;
        final inPip = args is Map ? args['inPip'] == true : args == true;
        _onChanged?.call(inPip);
      case 'onPipClosed':
        _onDismissed?.call();
    }
    return null;
  });
  return token;
}

/// 按身份摘除回调（播放页 dispose）。句柄已不是当前绑定时直接忽略。
void unbindPipStateListener(Object token) {
  if (!identical(token, _boundToken)) return;
  _boundToken = null;
  _onChanged = null;
  _onDismissed = null;
}

/// 测试重置探测缓存与监听回调。
@visibleForTesting
void debugResetPipCapability() {
  _cached = null;
  _boundToken = null;
  _onChanged = null;
  _onDismissed = null;
}
