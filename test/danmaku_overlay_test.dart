import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aquan_duanju/core/bili/api.dart';
import 'package:aquan_duanju/widgets/danmaku_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  group('effectiveDanmakuScrollMs（宽屏按像素速度校准）', () {
    test('1280 宽保持基准', () {
      expect(effectiveDanmakuScrollMs(8000, 1280), 8000);
    });

    test('1920 宽放慢到 1.28x（≈207px/s）', () {
      expect(effectiveDanmakuScrollMs(8000, 1920), 10240);
    });

    test('2560 宽放慢到 1.71x（≈199px/s）', () {
      expect(
        effectiveDanmakuScrollMs(8000, 2560),
        closeTo(13653, 2),
      );
    });

    test('超宽封顶 2x，不无限放慢', () {
      expect(effectiveDanmakuScrollMs(8000, 3840), 16000);
    });

    test('非法宽度回退到 1500 基准', () {
      expect(effectiveDanmakuScrollMs(8000, 0), 8000);
      expect(effectiveDanmakuScrollMs(8000, double.nan), 8000);
    });
  });

  group('平滑校正常量', () {
    test('速度补偿上限低于肉眼可辨的 8%', () {
      expect(kDanmakuDriftRate, lessThanOrEqualTo(0.08));
      expect(kDanmakuDriftRate, greaterThan(0));
    });

    test('噪声忽略阈值远小于一帧步长之外的误差', () {
      expect(
        kDanmakuDriftIgnore.inMilliseconds,
        lessThan(kDanmakuSnapError.inMilliseconds),
      );
      expect(
        kDanmakuSnapError.inMilliseconds,
        lessThan(danmakuHardSeek.inMilliseconds),
      );
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
      // 合并后不再丢弃重复，而是展示「×N」保留信息量。
      expect(out.first.text, '哈哈哈 ×2');
      expect(out.first.repeat, 2);
    });
  });

  testWidgets('描边走 foreground stroke（不再用 4 向 Shadow）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: DanmakuOverlay(
              items: const [DanmakuItem(progressMs: 0, text: '清晰弹幕')],
              position: Duration.zero,
              stroke: true,
            ),
          ),
        ),
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(DanmakuOverlay),
        matching: find.byType(CustomPaint),
      ),
    );
    final style = (paint.painter as dynamic).textStyle as TextStyle;
    expect(style.shadows ?? const <Shadow>[], isEmpty,
        reason: '阴影描边在对角有缺口，且模糊阴影会让密集弹幕糊成一片');
    final strokeStyle = (paint.painter as dynamic).strokeStyle as TextStyle?;
    expect(strokeStyle, isNotNull, reason: '描边开启时必须提供 stroke 样式');
    final foreground = strokeStyle!.foreground;
    expect(foreground, isNotNull);
    expect(foreground!.style, PaintingStyle.stroke);
    expect(foreground.strokeWidth, greaterThan(0));
  });

  testWidgets('关闭描边时不创建 stroke 样式', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: DanmakuOverlay(
              items: const [DanmakuItem(progressMs: 0, text: '无描边')],
              position: Duration.zero,
              stroke: false,
            ),
          ),
        ),
      ),
    );
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(DanmakuOverlay),
        matching: find.byType(CustomPaint),
      ),
    );
    expect((paint.painter as dynamic).strokeStyle, isNull);
  });

  testWidgets('含 Emoji 的弹幕绕过位图烘焙但不空白', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: DanmakuOverlay(
              items: const [DanmakuItem(progressMs: 0, text: '笑死😂')],
              position: const Duration(seconds: 2),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final state = tester.state(find.byType(DanmakuOverlay));
    final glyphs = (state as dynamic).debugGlyphs as DanmakuGlyphStore;
    // Impeller 不能离屏光栅化彩色 Emoji：必须不烘图（TextPainter 直画）。
    expect(glyphs.debugBuilds, 0,
        reason: 'Emoji 硬烘会得到空图，必须绕过 toImageSync');
  });

  testWidgets('每个 vsync 都推进时钟（无 30fps 阶跃）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: DanmakuOverlay(
              items: const [DanmakuItem(progressMs: 0, text: '逐帧')],
              position: Duration.zero,
            ),
          ),
        ),
      ),
    );
    final state = tester.state(find.byType(DanmakuOverlay));
    var previous = (state as dynamic).debugClock as Duration;
    final deltas = <int>[];
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final now = (state as dynamic).debugClock as Duration;
      deltas.add((now - previous).inMilliseconds);
      previous = now;
    }
    // 首帧可能只走半帧，其余每帧都必须是 ~16ms；一旦存在 0/32ms 交替，
    // 就是 30fps 节流回来了（肉眼「飘过去一顿一顿」的根因）。
    final steady = deltas.skip(1).toList(growable: false);
    expect(steady, isNotEmpty);
    for (final d in steady) {
      expect(d, greaterThanOrEqualTo(15),
          reason: '出现静止帧说明时钟被节流了：$steady');
      expect(d, lessThanOrEqualTo(17),
          reason: '出现跳帧说明时钟被节流了：$steady');
    }
  });

  testWidgets('位置误差按 ≤6% 速度补偿，3 秒内收敛且无瞬移', (tester) async {
    Duration pos = Duration.zero;
    Widget app() => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 300,
              child: DanmakuOverlay(
                items: const [DanmakuItem(progressMs: 0, text: '平滑')],
                position: pos,
              ),
            ),
          ),
        );

    await tester.pumpWidget(app());
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final state = tester.state(find.byType(DanmakuOverlay));
    final before = (state as dynamic).debugClock as Duration;

    // 播放器报告的位置比显示超前 200ms（典型位置事件误差）。
    pos = before + const Duration(milliseconds: 200);
    await tester.pumpWidget(app());
    expect(
      ((state as dynamic).debugError as Duration).inMilliseconds,
      closeTo(200, 1),
      reason: '误差只记录、不直接改显示位置',
    );
    expect((state as dynamic).debugClock as Duration, before,
        reason: '位置事件不得让弹幕瞬移');

    var previous = (state as dynamic).debugClock as Duration;
    final speeds = <double>[];
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final now = (state as dynamic).debugClock as Duration;
      speeds.add((now - previous).inMilliseconds / 16);
      previous = now;
    }
    for (final speed in speeds) {
      expect(speed, greaterThanOrEqualTo(0.93));
      expect(speed, lessThanOrEqualTo(1.07),
          reason: '单帧速度突变超过 7%：$speeds');
    }

    // 3 秒（约 188 帧）内 200ms 误差应被吃干净。
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      ((state as dynamic).debugError as Duration).inMilliseconds.abs(),
      lessThanOrEqualTo(32),
      reason: '3 秒后误差仍未收敛',
    );
  });

  testWidgets('文字位图缓存命中：重复帧不再重新排版', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: DanmakuOverlay(
              items: const [
                DanmakuItem(progressMs: 0, text: '缓存弹幕'),
                DanmakuItem(progressMs: 100, text: '第二条'),
              ],
              position: Duration.zero,
            ),
          ),
        ),
      ),
    );
    final state = tester.state(find.byType(DanmakuOverlay));
    final glyphs = (state as dynamic).debugGlyphs as DanmakuGlyphStore;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    if (glyphs.debugDisabled) {
      // 测试后端不支持 toImageSync：必须已退化为 TextPainter，不允许空白。
      expect(glyphs.debugBuilds, 0);
    } else {
      final builds = glyphs.debugBuilds;
      expect(builds, greaterThan(0), reason: '首帧应烘出位图');
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(glyphs.debugBuilds, builds,
          reason: '同一文本重复出现时不应重新排版/烘图');
    }
  });

  testWidgets('位图路径确实画出像素（不是空白层）', (tester) async {
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 400,
              height: 300,
              child: DanmakuOverlay(
                items: const [DanmakuItem(progressMs: 0, text: '可见弹幕')],
                position: const Duration(seconds: 2),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ByteData? data = await tester.runAsync<ByteData?>(() async {
      final ui.Image image = await boundary.toImage();
      final ByteData? bytes =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return bytes;
    });
    expect(data, isNotNull);

    var opaque = 0;
    final int length = data!.lengthInBytes;
    for (var i = 3; i < length; i += 4) {
      if (data.getUint8(i) > 0) {
        opaque++;
        if (opaque > 100) break;
      }
    }
    expect(opaque, greaterThan(100),
        reason: '弹幕层一个像素都没画出来（位图路径可能画了空白）');
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

  testWidgets('关闭再打开弹幕：重启基准归零，时钟继续前进', (tester) async {
    final items = <DanmakuItem>[
      const DanmakuItem(progressMs: 0, text: '测试弹幕'),
    ];
    var enabled = true;
    Widget app() => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 300,
              child: DanmakuOverlay(
                items: items,
                position: Duration.zero,
                enabled: enabled,
              ),
            ),
          ),
        );

    await tester.pumpWidget(app());
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // 关掉（Ticker stop）再打开（Ticker start：elapsed 从 0 重新计时）。
    enabled = false;
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 500));
    enabled = true;
    await tester.pumpWidget(app());

    final state = tester.state(find.byType(DanmakuOverlay));
    final before = (state as dynamic).debugClock as Duration;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final after = (state as dynamic).debugClock as Duration;
    expect(after - before, greaterThan(const Duration(milliseconds: 200)),
        reason: '重启基准不归零时 elapsed 恒小于基准，时钟会永久冻住');
  });

  testWidgets('位置事件回退不把弹幕拉回来，显式重置才允许回退', (tester) async {
    final items = <DanmakuItem>[
      const DanmakuItem(progressMs: 0, text: '测试弹幕'),
    ];
    Duration pos = const Duration(seconds: 5);
    var epoch = 0;
    Widget app() => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 300,
              child: DanmakuOverlay(
                items: items,
                position: pos,
                animating: true,
                resetEpoch: epoch,
              ),
            ),
          ),
        );

    await tester.pumpWidget(app());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final state = tester.state(find.byType(DanmakuOverlay));
    final before = (state as dynamic).debugClock as Duration;
    expect(before, greaterThanOrEqualTo(const Duration(seconds: 5)));

    // 模拟缓冲/事件乱序导致的位置回退：epoch 不变，时间轴不得倒退。
    pos = const Duration(seconds: 3);
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 16));
    final afterJitter = (state as dynamic).debugClock as Duration;
    expect(afterJitter, greaterThanOrEqualTo(before),
        reason: '位置回退不是 seek，弹幕不能闪现回来');

    // 真正的 seek：epoch 递增，允许回到目标位置。
    epoch++;
    await tester.pumpWidget(app());
    final afterSeek = (state as dynamic).debugClock as Duration;
    expect(afterSeek.inMilliseconds, closeTo(3000, 80));
  });
}
