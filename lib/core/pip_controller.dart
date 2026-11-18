/// Android 原生画中画（A6）的唯一 Dart 入口。
///
/// 桌面已有迷你置顶小窗（player_screen 迷你窗态，I 键），本控制器只服务
/// Android 原生 PiP；**非 Android 平台所有方法都是 no-op**（接线点按
/// [Platform.isAndroid] 在控制器内部短路，播放页零分支）。
///
/// ## 通道协议（与 MainActivity.kt 对齐）
///
/// **aquan/pip**（Dart→Kotlin 控制指令）：
/// - `setAutoEnter {enabled:bool, ratio:double}` → `bool`：Android 12+ 用
///   `setPictureInPictureParams.setAutoEnterEnabled` + `setAspectRatio` 实时
///   更新自动进入资格（播放=true、暂停=false）；低版本整条 no-op 不抛错。
///   ratio 原生侧 clamp 到 [1/2.39, 2.39]。
/// - `enterPip {ratio:double}` → `bool`：手动进入（Android 8+；不支持设备
///   返回 false）。
/// - `isInPip` → `bool`：查询当前态。
/// - `probe` → `{supported: bool}`：Android 8+ 且系统特性在位（部分盒子 /
///   车机没有 FEATURE_PICTURE_IN_PICTURE），控制栏按钮据此显隐。
///
/// **aquan/pip**（Kotlin→Dart 事件，[listen] 注册 handler）：
/// - `onPipChanged(bool)`：进入 / 退出 PiP（Manifest configChanges 吸收
///   尺寸变化，Activity 不重建，回推全程有效）。
/// - `onPipClosed`：用户在小窗上点了关闭（Activity 已 onStop）→ 「关小窗
///   =停」，播放页据此暂停并退出；点小窗展开回全屏不会触发（原生按
///   生命周期状态区分两条退出路径）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 原生画中画控制器（单例；播放页直接取 [instance]）。
class PipController {
  PipController._();

  static final PipController instance = PipController._();

  static const MethodChannel _channel = MethodChannel('aquan/pip');

  /// 宽高比 clamp 口径（kaixinguo-android 同款）：系统允许 1:2.39 – 2.39:1。
  static const double minAspectRatio = 1 / 2.39;
  static const double maxAspectRatio = 2.39;

  /// 竖屏短剧缺省比例（拿不到流真实尺寸时的兜底，与迷你窗同口径）。
  static const double defaultAspectRatio = 9 / 16;

  /// 设备能力探测结果（缓存，[probeSupported] 只真正查询一次）。
  bool _probed = false;
  bool _probedSupported = false;

  bool _listening = false;
  bool _inPip = false;

  /// PiP 激活态：true = 当前在系统小窗里（播放页据此强制隐藏控制栏 /
  /// 手势层 / OSD，纯画面播放）。
  bool get inPip => _inPip;

  /// PiP 激活态流（进入 / 退出各推一次）。
  final StreamController<bool> _inPipStream =
      StreamController<bool>.broadcast();
  Stream<bool> get inPipStream => _inPipStream.stream;

  /// 用户关闭了小窗（关=停）。播放页注入；播放页 dispose 时置回 null。
  void Function()? onClosed;

  /// 最近一次发送的 autoEnter / 比例（enter 未显式带比例时用）。
  bool _autoEnter = false;
  double _ratio = defaultAspectRatio;

  /// 注册原生事件监听（幂等；Android 播放页 init 时调用一次）。
  void listen() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPipChanged':
          _setInPip(call.arguments == true);
        case 'onPipClosed':
          onClosed?.call();
      }
      return null;
    });
  }

  /// 设备是否支持画中画（异步探测一次并缓存）。非 Android 恒 false——
  /// 控制栏按钮据此隐藏，桌面迷你窗路径零改动。
  Future<bool> probeSupported() async {
    if (!Platform.isAndroid) return false;
    if (_probed) return _probedSupported;
    _probed = true;
    final result = await _invoke<Map<Object?, Object?>>('probe', null);
    _probedSupported = result?['supported'] == true;
    return _probedSupported;
  }

  /// 播放状态翻转时更新自动进入资格：播放中允许 Home 键自动进小窗，
  /// 暂停即失去资格。ratio 取当前画面宽高比（>0），非法值落到缺省竖屏。
  /// 非 Android / 原生异常全部静默 no-op。
  Future<void> setEnabled(bool playing, double ratio) async {
    if (!Platform.isAndroid) return;
    _autoEnter = playing;
    _ratio = clampRatio(ratio);
    await _invoke('setAutoEnter', {'enabled': playing, 'ratio': _ratio});
  }

  /// 手动进入画中画（控制栏按钮 / Android 8-11 唯一入口）。不支持的设备
  /// 原生返回 false，这里静默。
  Future<bool> enter({double? ratio}) async {
    if (!Platform.isAndroid) return false;
    final double effective = clampRatio(ratio ?? _ratio);
    _ratio = effective;
    final ok = await _invoke<bool>('enterPip', {'ratio': effective}) ?? false;
    if (ok) _autoEnter = true;
    return ok;
  }

  /// 查询当前是否在 PiP 中（尽力而为；非 Android / 失败返回 [inPip] 缓存）。
  Future<bool> isInPip() async {
    if (!Platform.isAndroid) return _inPip;
    final v = await _invoke<bool>('isInPip', null);
    return v ?? _inPip;
  }

  /// 用原生真值对齐单例态（播放页重进时调用）：单例跨页面存活，上一页
  /// 异常离场可能残留旧值。重复值不会重复推流；返回是否已在 PiP 中。
  Future<bool> restoreInPipState() async {
    final bool value = await isInPip();
    _setInPip(value);
    return value;
  }

  /// 比例 clamp：非法（<=0 / NaN）回缺省竖屏，越界裁到系统允许区间。
  static double clampRatio(double ratio) {
    if (ratio <= 0 || ratio.isNaN || ratio.isInfinite) {
      return defaultAspectRatio;
    }
    return ratio.clamp(minAspectRatio, maxAspectRatio).toDouble();
  }

  void _setInPip(bool value) {
    if (_inPip == value) return;
    _inPip = value;
    if (!_inPipStream.isClosed) _inPipStream.add(value);
  }

  Future<T?> _invoke<T>(String method, Map<String, Object?>? args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      // 平台桥未注册（桌面 / 测试宿主）：静默。
      return null;
    } catch (_) {
      // 原生侧已兜异常；这里再兜一层（result 失效等通道层噪音），不外泄。
      return null;
    }
  }

  /// 测试注入 PiP 态（生产路径只由原生事件驱动）。
  @visibleForTesting
  void debugSetInPip(bool value) => _setInPip(value);

  /// 测试重置探测缓存。
  @visibleForTesting
  void debugResetProbe() {
    _probed = false;
    _probedSupported = false;
    _autoEnter = false;
    _ratio = defaultAspectRatio;
  }

  /// 仅供测试核对参数记忆。
  @visibleForTesting
  bool get debugAutoEnter => _autoEnter;

  /// 仅供测试核对参数记忆。
  @visibleForTesting
  double get debugRatio => _ratio;
}
