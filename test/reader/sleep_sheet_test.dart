/// 唯一定时浮层的验收（implement.md 步骤 6）：
/// - 模式选择直接驱动**传入的** `SleepTimer` 实例并回调宿主持久化；
/// - 剩余时间文本**只**来自 `timer.remaining`（浮层自己不建 Timer）；
/// - 倒数节奏由宿主的 `refresh` 信号驱动（浮层内没有任何定时器）；
/// - 取消（选「关闭」）立即生效。
library;

import 'package:aquan_duanju/core/reader/reader_listen_settings.dart';
import 'package:aquan_duanju/core/reader/speech/sleep_timer.dart';
import 'package:aquan_duanju/widgets/reader/sleep_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _openSheet(
  WidgetTester tester,
  SleepTimer timer,
  VoidCallback onSaved, {
  Listenable? refresh,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () {
              // ignore: discarded_futures
              showListenSleepSheet(
                context,
                timer: timer,
                onSaved: onSaved,
                refresh: refresh,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('模式单选回调组件与宿主：本章播完 → 关闭，立即生效', (
    tester,
  ) async {
    int saved = 0;
    final timer = SleepTimer(clockMs: () => 0);
    await _openSheet(tester, timer, () => saved++);

    await tester.tap(find.text('本章播完'));
    await tester.pumpAndSettle();
    expect(timer.mode, SleepMode.endOfChapter);
    expect(saved, 1);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(timer.mode, SleepMode.off);
    expect(timer.armed, isFalse);
    expect(saved, 2);
  });

  testWidgets('定时档 chips 来自 kSleepMinutePresets，选中即 setMode', (
    tester,
  ) async {
    int saved = 0;
    final timer = SleepTimer(clockMs: () => 0);
    await _openSheet(tester, timer, () => saved++);

    await tester.tap(find.text('定时'));
    await tester.pumpAndSettle();
    expect(timer.mode, SleepMode.minutes);
    // 缺省时长与设置入口同一真值（ReaderListenSettings.kDefaultSleepMinutes）。
    expect(timer.minutes, ReaderListenSettings.kDefaultSleepMinutes);
    for (final m in kSleepMinutePresets) {
      expect(find.text('$m 分'), findsOneWidget);
    }

    await tester.tap(find.text('45 分'));
    await tester.pumpAndSettle();
    expect(timer.mode, SleepMode.minutes);
    expect(timer.minutes, 45);
    expect(saved, 2);
  });

  testWidgets('剩余时间文本只来自 timer.remaining', (tester) async {
    var nowMs = 0;
    final timer = SleepTimer(clockMs: () => nowMs);
    timer.setMode(SleepMode.minutes, minutes: 30);
    // 墙钟口径：首次 tick 只建基线，之后按**真实时间推进**扣（与 position 无关）。
    timer.tick(position: const Duration(minutes: 5));
    nowMs += const Duration(minutes: 10).inMilliseconds;
    timer.tick(position: const Duration(minutes: 15));
    expect(timer.remaining, const Duration(minutes: 20));

    await _openSheet(tester, timer, () {});
    expect(find.textContaining('20:00'), findsOneWidget);

    // 到点 fire 后落回 off：再开浮层不再显示任何剩余时间 —— 文本
    // 只能来自 remaining，浮层没有自己的第二份倒数。
    nowMs += const Duration(minutes: 20).inMilliseconds;
    timer.tick(position: const Duration(minutes: 35));
    expect(timer.mode, SleepMode.off);
    await _openSheet(tester, timer, () {});
    expect(find.textContaining('20:00'), findsNothing);
    expect(find.textContaining('剩余'), findsNothing);
  });

  testWidgets('宿主 refresh 信号驱动倒数重建；不 refresh 时浮层纹丝不动', (
    tester,
  ) async {
    var nowMs = 0;
    final timer = SleepTimer(clockMs: () => nowMs);
    timer.setMode(SleepMode.minutes, minutes: 30);
    timer.tick(position: const Duration(minutes: 5)); // 只建基线
    final refresh = ValueNotifier<int>(0);
    await _openSheet(tester, timer, () {}, refresh: refresh);
    expect(find.textContaining('30:00'), findsOneWidget);

    // 宿主推进墙钟（真实播放的样子）并 notify → 浮层显示新的 remaining。
    nowMs += const Duration(minutes: 7).inMilliseconds;
    timer.tick(position: const Duration(minutes: 12));
    refresh.value = 1;
    await tester.pumpAndSettle();
    expect(find.textContaining('23:00'), findsOneWidget);

    // 关键反证：**不** notify 宿主信号时，即使组件内部已推进，浮层也不自己倒数
    // （浮层里没有 Timer，倒计时不可能凭空跳动）。
    nowMs += const Duration(minutes: 8).inMilliseconds;
    timer.tick(position: const Duration(minutes: 20));
    await tester.pump(const Duration(minutes: 5));
    expect(find.textContaining('23:00'), findsOneWidget);
    expect(find.textContaining('15:00'), findsNothing);

    refresh.value = 2;
    await tester.pumpAndSettle();
    expect(find.textContaining('15:00'), findsOneWidget);
    refresh.dispose();
  });
}
