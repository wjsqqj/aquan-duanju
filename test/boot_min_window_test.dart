import 'dart:async';

import 'package:aquan_duanju/main.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// E10 引导页最小展示窗（bootMinWindow / BootMinWindowGate）。
///
/// AquaApp._bootstrap 走真实 IO（设备注册/各 store 落盘），无法在测试里
/// 整体 pump；守门逻辑本身抽在 [BootMinWindowGate]，用 fake_async +
/// 注入假时钟（fake_async 不驱动 Stopwatch，生产默认锚点是真实单调表）
/// 直接驱动 hold() 的补齐决策。
void main() {
  group('BootMinWindowGate', () {
    test('快路径：bootstrap 立即完成 → 切换补齐到挂载后 ≥1.4s（标语 sweep 1.1s 完整可见）', () {
      final switchedAt = <Duration>[];
      fakeAsync((async) {
        // 引导页挂载即锚点（t=0）；bootstrap 立即完成，t=0 就到切换守门。
        final gate = BootMinWindowGate(elapsedSinceMount: () => async.elapsed);
        expect(gate.remaining, bootMinWindow, reason: 't=0 需补齐整窗');
        unawaited(gate.hold().then((_) => switchedAt.add(async.elapsed)));
        async.elapse(bootMinWindow - const Duration(milliseconds: 1));
        expect(switchedAt, isEmpty, reason: '1399ms 时还不得切走');
        async.elapse(const Duration(milliseconds: 1));
        expect(switchedAt, [bootMinWindow], reason: '恰在 1400ms 补齐后切换');
        expect(
          async.pendingTimers,
          isEmpty,
          reason: '补齐是一次性 Future.delayed，无常驻 timer 遗留',
        );
      });
    });

    test('慢路径：bootstrap 2s 完成 → 无额外延迟，恰在 2s 切换（只补齐不拖延）', () {
      final switchedAt = <Duration>[];
      fakeAsync((async) {
        final gate = BootMinWindowGate(elapsedSinceMount: () => async.elapsed);
        Future<void> bootstrap() async {
          // 模拟 bootstrap 实际工作耗时 2s。
          await Future<void>.delayed(const Duration(seconds: 2));
          expect(gate.remaining, Duration.zero, reason: '已过最小窗，remaining 必须为零');
          await gate.hold();
          switchedAt.add(async.elapsed);
        }

        unawaited(bootstrap());
        async.elapse(const Duration(seconds: 2));
        expect(switchedAt, [
          const Duration(seconds: 2),
        ], reason: 'bootstrap 已超 1.4s，零额外等待，恰在工作完成点切换');
        expect(async.pendingTimers, isEmpty, reason: '无补齐 timer 排入');
      });
    });
  });
}
