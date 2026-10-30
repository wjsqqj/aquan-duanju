/// 自动跟随闸门（design.md §5）的**时间语义**：锁 1500ms → 期间手动翻过页才转挂起
/// → 只有点「继续跟随」才回来。
///
/// 抽成纯 Dart 状态机而不是整页 widget 测试：整条阅读页链路要 mock 的插件
/// （AppScope 二十多个 store、wakelock 通道、翻页手势）比这套行为本身还多，
/// 而这里三条不变量都只跟「时间 + 谁动了页面」有关：
/// 1. **锁内不跟随**，但锁本身不挂起（点了下菜单不该变成「朗读不跟了」）；
/// 2. **句优先**：跳页只看底纹区间起点 → 词级推进一次 `jumpTo` 都不许发生；
/// 3. 挂起是**终态**，不靠下一个朗读事件解锁，且全程不涉及播放与进度。
///
/// 结算点刻意放在 `shouldFollow()`（页面在朗读回调里走的那条路）而不是
/// `suspended` getter：`suspended` 会在 build 里被读，getter 里触发重绘回调就是
/// 「build 期间 setState」。
library;

import 'package:aquan_duanju/core/reader/speech_follow_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pageChars = 100;
  int pageForChar(int charStart) => charStart ~/ pageChars;

  late DateTime clock;
  late int repaints;
  late SpeechFollowGate gate;

  /// 建一个「时钟由测试推着走」的闸门：真实 `DateTime.now` 在 flutter_test 里
  /// 不会跟着断言前进，注入时钟才钉得住 1500ms 这条锁窗口。
  SpeechFollowGate buildGate() {
    clock = DateTime(2026, 10, 31, 12);
    repaints = 0;
    return SpeechFollowGate(
      clock: () => clock,
      repaint: () => repaints++,
    );
  }

  void advance(Duration by) => clock = clock.add(by);

  /// 页面里「这一次朗读通知要不要跳页」的等价调用；返回非 null 就是会 `jumpTo`。
  int? jumpTarget({
    required int? sentenceStart,
    required int currentPage,
    bool enabled = true,
  }) =>
      gate.targetPage(
        enabled: enabled,
        baseCharStart: sentenceStart,
        currentPage: currentPage,
        pageForChar: pageForChar,
      );

  setUp(() => gate = buildGate());

  group('没锁的时候正常跟', () {
    test('句起点在别的页 → 给出目标页', () {
      expect(jumpTarget(sentenceStart: 120, currentPage: 0), 1);
    });

    test('句起点就在当前页 → null（不重复 jumpTo）', () {
      expect(jumpTarget(sentenceStart: 20, currentPage: 0), isNull);
    });

    test('关掉自动跟随 / 没有句区间（没朗读、高亮关、换章中）→ 一律不跳', () {
      expect(
        jumpTarget(sentenceStart: 120, currentPage: 0, enabled: false),
        isNull,
      );
      expect(jumpTarget(sentenceStart: null, currentPage: 0), isNull);
    });
  });

  group('句优先：词级推进绝不跳页', () {
    test('同一句里词一个个亮起来 → 一次跳页都没有', () {
      // 当前句起点固定在 120，词区间在句内往前爬（卡拉OK）。
      var jumps = 0;
      for (var wordStart = 120; wordStart < 160; wordStart += 4) {
        // 词起点在往前爬（10ms 一个），但句起点没动 → 只该重绘，不该跳页。
        if (jumpTarget(sentenceStart: 120, currentPage: 1) != null) jumps++;
      }
      expect(jumps, 0, reason: '词级高亮变化不得触发 jumpTo（design.md §5）');
      // 句起点自己跨过页界，才允许跳。
      expect(jumpTarget(sentenceStart: 220, currentPage: 1), 2);
    });

    test('锁内即使句跨页也不跳，点药丸恢复后补上', () {
      gate.noteManualTurn();
      expect(jumpTarget(sentenceStart: 120, currentPage: 0), isNull);
      advance(const Duration(milliseconds: 1600));
      // 锁满后转了挂起 → 仍然不跳，等用户点药丸。
      expect(jumpTarget(sentenceStart: 120, currentPage: 0), isNull);
      gate.resume();
      expect(jumpTarget(sentenceStart: 120, currentPage: 0), 1);
    });
  });

  group('手动翻页：锁 → 挂起 → 药丸', () {
    test('锁窗口内不跟随、也不挂起', () {
      gate.noteManualTurn();
      advance(const Duration(milliseconds: 1400));
      expect(gate.shouldFollow(), isFalse);
      expect(gate.suspended, isFalse);
      expect(repaints, 0);
    });

    test('锁满后转挂起，并回调一次重绘（药丸的显示时机）', () {
      gate.noteManualTurn();
      advance(const Duration(milliseconds: 1600));
      expect(gate.shouldFollow(), isFalse);
      expect(gate.suspended, isTrue);
      expect(repaints, 1);
      // 挂起是终态：过多久都不会自己变回跟随。
      advance(const Duration(seconds: 30));
      expect(gate.shouldFollow(), isFalse);
      expect(gate.suspended, isTrue);
      expect(repaints, 1);
    });

    test('点「继续跟随」→ 清挂起、立即可跟', () {
      gate.noteManualTurn();
      advance(const Duration(milliseconds: 1600));
      expect(gate.shouldFollow(), isFalse);
      expect(gate.suspended, isTrue);

      gate.resume();

      expect(gate.suspended, isFalse);
      expect(gate.shouldFollow(), isTrue);
      expect(jumpTarget(sentenceStart: 120, currentPage: 0), 1);
    });

    test('重新起朗读同样清掉挂起（用户明确要跟随）', () {
      gate.noteManualTurn();
      advance(const Duration(milliseconds: 1600));
      expect(gate.shouldFollow(), isFalse);
      expect(gate.suspended, isTrue);

      gate.resume();
      expect(gate.suspended, isFalse);
    });

    test('只是开了菜单（noteUserAction）→ 锁一下但绝不挂起', () {
      gate.noteUserAction();
      expect(gate.shouldFollow(), isFalse, reason: '锁内先不跟，免得页面被拉走');
      advance(const Duration(milliseconds: 1600));
      expect(gate.shouldFollow(), isTrue);
      expect(gate.suspended, isFalse);
      expect(repaints, 0);
    });

    test('锁期间没翻页：锁满后直接恢复跟随', () {
      gate.noteUserAction();
      advance(const Duration(milliseconds: 1600));
      expect(jumpTarget(sentenceStart: 120, currentPage: 0), 1);
    });

    test('挂起期间再翻一次页不会重复弹药丸（重绘只有一次）', () {
      gate.noteManualTurn();
      advance(const Duration(milliseconds: 1600));
      expect(gate.shouldFollow(), isFalse);
      expect(repaints, 1);

      gate.noteManualTurn();
      advance(const Duration(milliseconds: 1600));
      expect(gate.shouldFollow(), isFalse);
      expect(gate.suspended, isTrue);
      expect(repaints, 1, reason: '状态没变就不该再触发重绘');
    });
  });

  group('挂起时机不依赖朗读事件', () {
    // 这一组用**真实时钟 + 真实定时器**：证明结算不靠下一个朗读通知。
    test('锁窗口到点自己转挂起并回调', () async {
      repaints = 0;
      final live = SpeechFollowGate(
        lockWindow: const Duration(milliseconds: 30),
        repaint: () => repaints++,
      );
      addTearDown(live.dispose);
      live.noteManualTurn();
      expect(live.suspended, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        live.suspended,
        isTrue,
        reason: '靠内部结算定时器，不靠下一个朗读通知',
      );
      expect(repaints, 1);
    });

    test('dispose 之后不再有回调', () async {
      repaints = 0;
      final live = SpeechFollowGate(
        lockWindow: const Duration(milliseconds: 30),
        repaint: () => repaints++,
      );
      live.noteManualTurn();
      live.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(repaints, 0);
    });
  });
}
