import 'dart:async';

import 'package:aquan_duanju/core/reader/speech/chapter_prefetcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// ChapterPrefetcher 的脱屏单测（design §8）：阈值两条件、时长未知不判、
/// 并发 1（**第二次 pump 时 work 计数仍为 1** —— 去掉闸门这条必挂）、
/// 去重、世代丢弃、失败静默且可重试。
void main() {
  Duration s(int sec) => Duration(seconds: sec);

  group('shouldTrigger 两条件', () {
    test('35% 比例：越过阈值线才触发，线前一律 false', () {
      final p = ChapterPrefetcher();
      // total=1000s → 阈值 350s。
      expect(
        p.shouldTrigger(taskId: 'c2', position: s(349), total: s(1000)),
        isFalse,
      );
      expect(
        p.shouldTrigger(taskId: 'c2', position: s(350), total: s(1000)),
        isTrue,
        reason: '恰好在 35% 线上触发',
      );
    });

    test('剩余 180s：比例未到但快播完也触发（先满足者）', () {
      final p = ChapterPrefetcher();
      // total=400s：35% 线在 140s；position=200s 时剩余 200s 未进 180s 窗口，
      // 但 200 >= 140 已由比例触发——换一个只剩大章节尾部的小剩余场景：
      // total=100s（短章），position=0：比例线 35s 未到，剩余 100s <= 180s。
      expect(
        p.shouldTrigger(taskId: 'c2', position: s(0), total: s(100)),
        isTrue,
      );
      expect(
        p.shouldTrigger(taskId: 'c3', position: s(220), total: s(400)),
        isTrue,
        reason: '比例条件先满足',
      );
      expect(
        p.shouldTrigger(taskId: 'c4', position: s(100), total: s(1000)),
        isFalse,
        reason: '两条件都未到：不许提前发请求',
      );
    });

    test('时长未知（total<=0）不触发：0-position 负数与 0*35%=0 都是误触发', () {
      final p = ChapterPrefetcher();
      expect(
        p.shouldTrigger(taskId: 'c2', position: s(0), total: s(0)),
        isFalse,
      );
      expect(
        p.shouldTrigger(taskId: 'c2', position: s(60), total: Duration.zero),
        isFalse,
      );
      expect(
        p.shouldTrigger(
          taskId: 'c2',
          position: s(60),
          total: const Duration(seconds: -1),
        ),
        isFalse,
      );
      // 拿到真实时长后恢复正常判定。
      expect(
        p.shouldTrigger(taskId: 'c2', position: s(60), total: s(100)),
        isTrue,
      );
    });

    test('已在跑 / 已成功的 taskId 直接 false（去重在判定层就生效）', () async {
      final p = ChapterPrefetcher();
      final gate = Completer<void>();
      var calls = 0;
      final running = p.pump(
        taskId: 'c2',
        epoch: 1,
        isCurrent: (_) => true,
        work: () async {
          calls++;
          await gate.future;
        },
      );
      expect(
        p.shouldTrigger(taskId: 'c2', position: s(0), total: s(10)),
        isFalse,
        reason: '在跑的不算待触发',
      );

      gate.complete();
      await running;
      expect(
        p.shouldTrigger(taskId: 'c2', position: s(0), total: s(10)),
        isFalse,
        reason: '成功过的算去重',
      );
      expect(calls, 1);
    });
  });

  group('pump：并发 1 / 去重 / 世代 / 失败静默', () {
    test('并发 1：在跑时第二次 pump 直接返回，work 计数仍为 1（不排队不叠加）', () async {
      final p = ChapterPrefetcher();
      final gate = Completer<void>();
      var calls = 0;
      final first = p.pump(
        taskId: 'c2',
        epoch: 1,
        isCurrent: (_) => true,
        work: () async {
          calls++;
          await gate.future;
        },
      );
      // Edge 每 chunk 一条全新 WSS 连接，叠加请求等于自找限流：第二次必须
      // 一个 work 都不发起。删掉组件里的在跑闸门本断言必挂。
      await p.pump(
        taskId: 'c3',
        epoch: 1,
        isCurrent: (_) => true,
        work: () async {
          calls++;
        },
      );
      expect(calls, 1, reason: '并发 1：第二次 pump 不得叠加请求');

      gate.complete();
      await first;
      // 跑完解锁：下一次 pump 正常执行。
      await p.pump(
        taskId: 'c3',
        epoch: 1,
        isCurrent: (_) => true,
        work: () async {
          calls++;
        },
      );
      expect(calls, 2);
    });

    test('成功后去重；invalidate() 后可重来（换音色/引擎/close 由宿主调用）', () async {
      final p = ChapterPrefetcher();
      var calls = 0;
      Future<void> ok() async {
        calls++;
      }

      await p.pump(taskId: 'c2', epoch: 1, isCurrent: (_) => true, work: ok);
      await p.pump(taskId: 'c2', epoch: 1, isCurrent: (_) => true, work: ok);
      expect(calls, 1, reason: '_done 去重：成功过的不再发');

      p.invalidate();
      await p.pump(taskId: 'c2', epoch: 2, isCurrent: (_) => true, work: ok);
      expect(calls, 2, reason: '失效后允许对新音色重新预取');
    });

    test('世代过期：await 之后 isCurrent 为假 → 静默丢弃，不写 _done', () async {
      final p = ChapterPrefetcher();
      await p.pump(
        taskId: 'c2',
        epoch: 7,
        isCurrent: (int e) => e != 7, // 切章/换音色后迟到
        work: () async {},
      );
      // 丢弃的表现：去重集没写进去，下一轮仍会触发真实预取。
      expect(
        p.shouldTrigger(taskId: 'c2', position: s(400), total: s(1000)),
        isTrue,
      );
      var calls = 0;
      await p.pump(
        taskId: 'c2',
        epoch: 7,
        isCurrent: (int e) => e != 7,
        work: () async {
          calls++;
        },
      );
      expect(calls, 1, reason: '过期结果不占去重位，重试通路必须保持畅通');
    });

    test('work 抛异常：pump 不抛、播放不受扰、不写 _done（下次可重试）', () async {
      final p = ChapterPrefetcher();
      var attempts = 0;
      Future<void> boom() {
        attempts++;
        // 模拟任意失败（含 TtsException 这类非 Exception 分支也不许漏）。
        return Future<void>.error(StateError('edge 429 rateLimited'));
      }

      await p.pump(taskId: 'c2', epoch: 1, isCurrent: (_) => true, work: boom);
      expect(attempts, 1);
      expect(
        p.shouldTrigger(taskId: 'c2', position: s(400), total: s(1000)),
        isTrue,
        reason: '失败不记成功：下次越过阈值还能重试',
      );

      // 失败后闸门已复位：重试能真的执行。
      var ok = 0;
      await p.pump(
        taskId: 'c2',
        epoch: 1,
        isCurrent: (_) => true,
        work: () async {
          ok++;
        },
      );
      expect(ok, 1, reason: 'catch 里 finally 复位 _running，失败不许把闸门焊死');
    });
  });

  group('invalidate 释放闸门（旧会话不得挡住新会话）', () {
    test('旧 pump 在 await 时：不 invalidate 则新请求被丢弃', () async {
      final p = ChapterPrefetcher();
      final hold = Completer<void>();
      final old = p.pump(
        taskId: 'old',
        epoch: 1,
        isCurrent: (_) => false,
        work: () => hold.future,
      );
      await Future<void>.delayed(Duration.zero);
      expect(p.isRunning, isTrue);

      var newCalls = 0;
      await p.pump(
        taskId: 'new',
        epoch: 2,
        isCurrent: (_) => true,
        work: () async {
          newCalls++;
        },
      );
      expect(newCalls, 0, reason: '并发 1：旧任务在跑时新请求直接丢弃');

      p.invalidate();
      await p.pump(
        taskId: 'new',
        epoch: 2,
        isCurrent: (_) => true,
        work: () async {
          newCalls++;
        },
      );
      expect(newCalls, 1, reason: 'invalidate 后新预取不必等旧合成跑完');
      hold.complete();
      await old;
    });

    test('旧任务收尾时不得误关新任务的闸门', () async {
      final p = ChapterPrefetcher();
      final holdOld = Completer<void>();
      final holdNew = Completer<void>();
      var newCalls = 0;

      final old = p.pump(
        taskId: 'old',
        epoch: 1,
        isCurrent: (_) => false,
        work: () => holdOld.future,
      );
      await Future<void>.delayed(Duration.zero);
      p.invalidate(); // 换音色：闸门连同去重集一起放掉

      final fresh = p.pump(
        taskId: 'new',
        epoch: 2,
        isCurrent: (_) => true,
        work: () async {
          newCalls++;
          await holdNew.future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(p.isRunning, isTrue);

      // 旧那趟现在才收尾：它的 finally 不能把新任务的闸门清掉。
      holdOld.complete();
      await old;
      expect(p.isRunning, isTrue, reason: '旧任务误关闸门 = 并发 1 失效');

      holdNew.complete();
      await fresh;
      expect(p.isRunning, isFalse);
      expect(newCalls, 1);
      // 旧任务的结果已作废，不该占着去重位。
      expect(
        p.shouldTrigger(taskId: 'old', position: s(400), total: s(1000)),
        isTrue,
      );
    });
  });
}
