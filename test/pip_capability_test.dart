import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/pip/pip_platform.dart';

void main() {
  group('parsePipProbe：格式不符一律判「不支持」', () {
    test('null / 非 Map', () {
      for (final raw in <Object?>[null, 'ok', 1, true, <Object>[]]) {
        final cap = parsePipProbe(raw);
        expect(cap.supported, isFalse, reason: 'raw=$raw');
        expect(cap.reason, 'malformed');
      }
    });

    test('缺 supported 字段', () {
      final cap = parsePipProbe(<Object?, Object?>{'reason': 'ok'});
      expect(cap.supported, isFalse);
      expect(cap.reason, 'ok');
    });

    test('supported=true 且 reason 缺失回落 ok', () {
      final cap = parsePipProbe(<Object?, Object?>{'supported': true});
      expect(cap.supported, isTrue);
      expect(cap.reason, 'ok');
    });

    test('透传原生 reason', () {
      final cap = parsePipProbe(
        <Object?, Object?>{'supported': false, 'reason': 'not_declared'},
      );
      expect(cap.supported, isFalse);
      expect(cap.reason, 'not_declared');
    });
  });

  group('normalizePipAspect：clamp 到系统允许区间', () {
    test('下界', () {
      expect(normalizePipAspect(0.1), kMinPipAspectRatio);
      expect(normalizePipAspect(-2), kDefaultPipAspectRatio);
    });

    test('上界', () {
      expect(normalizePipAspect(5), kMaxPipAspectRatio);
    });

    test('合法值原样返回', () {
      expect(normalizePipAspect(9 / 16), closeTo(9 / 16, 1e-12));
      expect(normalizePipAspect(16 / 9), closeTo(16 / 9, 1e-12));
    });

    test('NaN / Infinity 回落缺省竖屏', () {
      expect(normalizePipAspect(double.nan), kDefaultPipAspectRatio);
      expect(normalizePipAspect(double.infinity), kDefaultPipAspectRatio);
    });
  });

  group('shouldShowPipEntry：入口可见性', () {
    const supported = PipCapability(supported: true);

    test('非 Android / TV 形态不显示', () {
      expect(
        shouldShowPipEntry(
          isAndroid: false,
          isTv: false,
          capability: supported,
          unsupportedVersion: '',
          appVersion: '1.12.22+104',
        ),
        isFalse,
      );
      expect(
        shouldShowPipEntry(
          isAndroid: true,
          isTv: true,
          capability: supported,
          unsupportedVersion: '',
          appVersion: '1.12.22+104',
        ),
        isFalse,
      );
    });

    test('探测未通过不显示', () {
      for (final cap in const <PipCapability>[
        PipCapability(supported: false, reason: 'not_declared'),
        PipCapability(supported: false, reason: 'feature_missing'),
        PipCapability(supported: false, reason: 'sdk_too_low'),
        PipCapability.unsupported,
      ]) {
        expect(
          shouldShowPipEntry(
            isAndroid: true,
            isTv: false,
            capability: cap,
            unsupportedVersion: '',
            appVersion: '1.12.22+104',
          ),
          isFalse,
          reason: cap.reason,
        );
      }
    });

    test('同版本已实试失败 → 不显示', () {
      expect(
        shouldShowPipEntry(
          isAndroid: true,
          isTv: false,
          capability: supported,
          unsupportedVersion: '1.12.22+104',
          appVersion: '1.12.22+104',
        ),
        isFalse,
      );
    });

    test('版本升级后重新显示（ROM 可能修复）', () {
      expect(
        shouldShowPipEntry(
          isAndroid: true,
          isTv: false,
          capability: supported,
          unsupportedVersion: '1.12.22+104',
          appVersion: '1.12.23+105',
        ),
        isTrue,
      );
    });

    test('全部条件满足 → 显示', () {
      expect(
        shouldShowPipEntry(
          isAndroid: true,
          isTv: false,
          capability: supported,
          unsupportedVersion: '',
          appVersion: '1.12.22+104',
        ),
        isTrue,
      );
    });
  });

  group('播放页源码契约（回归锁，1.12.21 挤掉横屏按钮的教训）', () {
    final source = File('lib/screens/player_screen.dart').readAsStringSync();

    test('入口只在「更多」菜单：底栏不得新增画中画按钮', () {
      // 定义 1 次 + `case 'pip'` 调用 1 次。多出来的引用几乎必然是底栏按钮
      // 复活（旧版就是这么把横屏按钮挤出屏幕的）。
      final count = RegExp(r'_enterPip\b').allMatches(source).length;
      expect(count, 2,
          reason: '画中画入口只能出现在「更多」菜单的分支里，不得进底栏');
      expect(source, contains("Text('画中画'"));
    });

    test('PiP 期间控制栏 / 弹幕层 / 浮层带 !_inPip 守卫', () {
      expect(source,
          contains('if (_showControls && !_inPip) _buildControls(context)'),
          reason: '小窗里不得渲染控制栏');
      expect(source, contains('if (_prepared && _danmakuOn && !_inPip)'),
          reason: '小窗里不得渲染弹幕层');
      expect(source, contains('if (_loadError != null && !_inPip)'),
          reason: '小窗里不得渲染错误面板');
    });

    test('自动隐藏与点击显隐在 PiP 期间短路', () {
      final scheduleHide = source.indexOf('void _scheduleHide()');
      final toggleControls = source.indexOf('void _toggleControls()');
      expect(scheduleHide, greaterThan(0));
      expect(toggleControls, greaterThan(0));
      expect(source.substring(scheduleHide, scheduleHide + 300),
          contains('if (_inPip) return;'));
      expect(source.substring(toggleControls, toggleControls + 200),
          contains('if (_inPip) return;'));
    });
  });
}
