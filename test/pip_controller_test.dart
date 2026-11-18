import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/pip_controller.dart';

/// A6 Android 原生画中画：控制器单测 + 播放页接线源码断言。
///
/// PlayerScreen 依赖 mpv 引擎，widget 级装配成本过高；接线证据沿用
/// `test/player_gesture_help_test.dart` 的源码结构断言口径。控制器本体在
/// Windows 测试宿主上跑「非 Android no-op」行为测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PipController 非 Android 宿主 no-op', () {
    final List<MethodCall> calls = <MethodCall>[];
    late StreamSubscription<bool> pipSub;
    final List<bool> pipEvents = <bool>[];

    setUp(() {
      calls.clear();
      pipEvents.clear();
      PipController.instance.debugResetProbe();
      PipController.instance.onClosed = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('aquan/pip'), (
            call,
          ) async {
            calls.add(call);
            return null;
          });
      pipSub = PipController.instance.inPipStream.listen(pipEvents.add);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('aquan/pip'), null);
      unawaited(pipSub.cancel());
      PipController.instance.debugSetInPip(false);
    });

    test('桌面宿主 probeSupported=false，设备能力探测不产生通道流量', () async {
      // Windows 宿主没有 aquan/pip 原生桥：支持性按 false 处理，
      // 控制栏「画中画」按钮随之隐藏（桌面迷你窗路径不受影响）。
      expect(await PipController.instance.probeSupported(), isFalse);
      expect(calls, isEmpty);
    });

    test('播放状态翻转 → setEnabled 全程 no-op，不产生通道流量', () async {
      await PipController.instance.setEnabled(true, 9 / 16);
      await PipController.instance.setEnabled(false, 16 / 9);
      expect(calls, isEmpty);
      expect(PipController.instance.debugAutoEnter, isFalse);
    });

    test('手动 enter() 返回 false，isInPip() 回缓存 false', () async {
      expect(await PipController.instance.enter(), isFalse);
      expect(await PipController.instance.isInPip(), isFalse);
      expect(calls, isEmpty);
    });

    test('inPip 态流：进入/退出各推一次，重复值去重', () async {
      PipController.instance.debugSetInPip(true);
      expect(PipController.instance.inPip, isTrue);
      PipController.instance.debugSetInPip(true); // 重复值不推
      PipController.instance.debugSetInPip(false);
      // broadcast 流事件异步投递：让事件循环跑完再断言。
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(pipEvents, [true, false]);
    });
  });

  group('PipController 比例 clamp（kaixinguo-android 同口径）', () {
    test('非法值回缺省竖屏 9:16', () {
      expect(PipController.clampRatio(0), closeTo(9 / 16, 1e-9));
      expect(PipController.clampRatio(-1.2), closeTo(9 / 16, 1e-9));
      expect(PipController.clampRatio(double.nan), closeTo(9 / 16, 1e-9));
      expect(PipController.clampRatio(double.infinity), closeTo(9 / 16, 1e-9));
    });

    test('越界裁到 [1/2.39, 2.39]', () {
      expect(PipController.clampRatio(3.0), closeTo(2.39, 1e-9));
      expect(PipController.clampRatio(0.2), closeTo(1 / 2.39, 1e-9));
      expect(PipController.clampRatio(2.39), closeTo(2.39, 1e-9));
      expect(PipController.clampRatio(9 / 16), closeTo(9 / 16, 1e-9));
      expect(PipController.clampRatio(16 / 9), closeTo(16 / 9, 1e-9));
    });
  });

  group('播放页接线（源码结构断言）', () {
    String playerSource() =>
        File('lib/screens/player_screen.dart').readAsStringSync();

    test('播放态翻转 → setEnabled(playing, 当前画面比例)', () {
      final source = playerSource();
      final start = source.indexOf(
        '_playingSub = _engine.stream.playing.listen',
      );
      expect(start, greaterThan(0));
      final end = source.indexOf('\n    });', start);
      final body = source.substring(start, end);
      expect(body, contains('PipController.instance.setEnabled'));
      expect(body, contains('_pipAspectRatio'));
    });

    test('换线同步比例：_playStream 里同样推 setEnabled', () {
      final source = playerSource();
      final start = source.indexOf('Future<void> _playStream(');
      expect(start, greaterThan(0));
      final end = source.indexOf('\n  }', start);
      final body = source.substring(start, end);
      expect(body, contains('_currentVideoStream = stream'));
      expect(body, contains('PipController.instance.setEnabled'));
    });

    test('PiP 激活态：控制栏/投屏入口/OSD 强制隐藏', () {
      final source = playerSource();
      expect(source, contains('if (_showControls && !_pipActive)'));
      expect(source, contains("if (!_showControls && !_isTv && !_pipActive)"));
      expect(source, contains('if (_osdText != null && !_pipActive)'));
      expect(source, contains('if (_holdSpeed.active && !_pipActive)'));
      expect(source, contains('if (_overlayValue != null && !_pipActive)'));
      expect(source, contains('if (_mutedHintVisible && !_pipActive)'));
    });

    test('PiP 激活态：画面手势与控制栏显隐全部短路', () {
      final source = playerSource();
      final toggleStart = source.indexOf('void _toggleControls()');
      final toggleEnd = source.indexOf('\n  }', toggleStart);
      expect(
        source.substring(toggleStart, toggleEnd),
        contains('if (_pipActive) return'),
      );
      final tapStart = source.indexOf('void _onSurfaceTap()');
      final tapEnd = source.indexOf('\n  }', tapStart);
      expect(
        source.substring(tapStart, tapEnd),
        contains('if (_pipActive) return'),
      );
    });

    test('关小窗=停：暂停 + 退出播放页，dispose 摘除回调', () {
      final source = playerSource();
      final start = source.indexOf('void _onPipClosed()');
      expect(start, greaterThan(0));
      final end = source.indexOf('\n  }', start);
      final body = source.substring(start, end);
      expect(body, contains('_engine.pause()'));
      expect(body, contains('Navigator.of(context).pop()'));
      expect(body, contains('if (!mounted || _disposed) return'));
      // 单例回调跨页存活：离开播放页必须摘除。
      expect(source, contains('PipController.instance.onClosed = null'));
    });

    test('PiP 按钮只在 Android 支持设备显示，桌面迷你窗路径不变', () {
      final source = playerSource();
      expect(source, contains('if (_pipAvailable)'));
      expect(source, contains('tooltip: \'画中画\''));
      // 桌面迷你置顶小窗保持原样（A6 零改动红线）。
      expect(source, contains('tooltip: _mini ? \'还原窗口 (I)\' : \'迷你置顶 (I)\''));
      expect(source, contains('if (Platform.isAndroid) _initPip()'));
      expect(source, contains('if (Platform.isWindows) _initSmtc()'));
    });
  });

  group('原生侧接线（Manifest / Kotlin 源码断言）', () {
    String manifestSource() =>
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    String mainActivitySource() =>
        File('android/app/src/main/kotlin/com/aquan/duanju/MainActivity.kt')
            .readAsStringSync();

    test('Manifest 声明 supportsPictureInPicture', () {
      final source = manifestSource();
      expect(source, contains('android:supportsPictureInPicture="true"'));
      // PiP 尺寸变化不重建 Activity。
      expect(
        source,
        contains(
          'orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize',
        ),
      );
      expect(source, contains('screenLayout'));
    });

    test('aquan/pip 通道：autoEnter / enterPip / probe / 关闭判定', () {
      final source = mainActivitySource();
      expect(source, contains('"aquan/pip"'));
      expect(source, contains('setAutoEnterEnabled'));
      expect(source, contains('enterPictureInPictureMode'));
      expect(source, contains('setPictureInPictureParams'));
      expect(source, contains('FEATURE_PICTURE_IN_PICTURE'));
      // 比例 clamp 与 seamlessResize 关闭（kaixinguo-android 口径）。
      expect(source, contains('2.39'));
      expect(source, contains('setSeamlessResizeEnabled(false)'));
      // 关小窗=停：退出 PiP 且 Activity 已 onStop 才回推 onPipClosed。
      expect(source, contains('onPictureInPictureModeChanged'));
      expect(source, contains('pipActivityStopped'));
      expect(source, contains('"onPipClosed"'));
    });
  });
}
