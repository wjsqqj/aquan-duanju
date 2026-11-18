import 'package:aquan_duanju/core/bili/api.dart';
import 'package:aquan_duanju/widgets/danmaku_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('danmakuClockAt', () {
    test('暂停时返回基准（同值不通知，零重绘）', () {
      expect(
        danmakuClockAt(
          base: const Duration(seconds: 10),
          baseAtTick: const Duration(seconds: 1),
          tickNow: const Duration(seconds: 5),
          playing: false,
          rate: 1,
        ),
        const Duration(seconds: 10),
      );
    });

    test('倍率 2.0 时前进量翻倍', () {
      expect(
        danmakuClockAt(
          base: const Duration(seconds: 10),
          baseAtTick: const Duration(seconds: 2),
          tickNow: const Duration(seconds: 3),
          playing: true,
          rate: 2.0,
        ),
        const Duration(seconds: 12),
      );
    });

    test('非法倍率按 1.0 处理', () {
      expect(
        danmakuClockAt(
          base: const Duration(seconds: 10),
          baseAtTick: Duration.zero,
          tickNow: const Duration(seconds: 1),
          playing: true,
          rate: 0,
        ),
        const Duration(seconds: 11),
      );
    });
  });

  group('planDanmakuCorrection', () {
    test('150ms 内的误差忽略', () {
      final plan = planDanmakuCorrection(
        measured: const Duration(milliseconds: 10100),
        predicted: const Duration(milliseconds: 10050),
      );
      expect(plan.snap, isFalse);
      expect(plan.amount, Duration.zero);
    });

    test('中误差线性吸收', () {
      final plan = planDanmakuCorrection(
        measured: const Duration(milliseconds: 10500),
        predicted: const Duration(milliseconds: 10000),
      );
      expect(plan.snap, isFalse);
      expect(plan.amount, const Duration(milliseconds: 500));
    });

    test('超过 1s 硬对齐', () {
      final plan = planDanmakuCorrection(
        measured: const Duration(seconds: 30),
        predicted: const Duration(seconds: 10),
      );
      expect(plan.snap, isTrue);
    });
  });

  group('filterDanmakuItems', () {
    test('按屏蔽词剔除', () {
      final items = [
        const DanmakuItem(progressMs: 0, text: '正常弹幕'),
        const DanmakuItem(progressMs: 10, text: '广告私信'),
      ];
      final out = filterDanmakuItems(
        items: items,
        blockWords: const {'广告'},
        mergeSame: false,
      );
      expect(out.map((e) => e.text), ['正常弹幕']);
    });

    test('合并同句', () {
      final items = [
        const DanmakuItem(progressMs: 1000, text: '哈哈哈'),
        const DanmakuItem(progressMs: 1200, text: '哈哈哈'),
      ];
      final out = filterDanmakuItems(
        items: items,
        blockWords: const {},
        mergeSame: true,
      );
      expect(out.length, lessThanOrEqualTo(items.length));
      expect(out.first.text, '哈哈哈');
    });
  });

  testWidgets('位置不变时 Ticker 推进只重绘、不重建', (tester) async {
    final items = <DanmakuItem>[
      const DanmakuItem(progressMs: 0, text: '测试弹幕'),
      const DanmakuItem(progressMs: 100, text: '第二条'),
    ];
    Widget app() => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 300,
              child: DanmakuOverlay(
                items: items,
                position: Duration.zero,
                animating: true,
              ),
            ),
          ),
        );

    await tester.pumpWidget(app());

    final Finder canvas = find.descendant(
      of: find.byType(DanmakuOverlay),
      matching: find.byType(CustomPaint),
    );
    final painterBefore = tester.widget<CustomPaint>(canvas).painter;

    // 推进若干帧：Ticker 会更新时钟并触发 repaint，但不应重建 widget。
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final painterAfter = tester.widget<CustomPaint>(canvas).painter;
    expect(identical(painterBefore, painterAfter), isTrue,
        reason: '位置前进不应触发 rebuild：painter 实例应保持不变');
  });
}
