/// 「继续跟随」药丸与精度徽标的 **widget 层**验证（design.md §5 / §6）。
///
/// 这一支测的是页面真正长出来的那三件事：锁内不跳页 → 锁满弹药丸 → 点药丸立刻补
/// 一次跟随。用一个小页面壳子（`_ReadingPage`）复刻 `reader_screen` 的接线
/// （闸门 + `targetPage` 结果驱动跳页 + `suspended` 决定画不画药丸），而不是把整
/// 条阅读页链路搬进来 —— 后者要 mock 的 store 与插件比行为本身还多，而这里要钉的
/// 只是「谁动了页面 + 时间到没到」。
///
/// 注入时钟是必须的：`tester.pump(duration)` 只推进假异步里的 **Timer**，
/// `DateTime.now()` 仍是真时间；两边按同一个量一起推，才测得出 1500ms 这条线。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/reader/speech_follow_gate.dart';
import 'package:aquan_duanju/widgets/reader/follow_pill.dart';

const int _pageChars = 100;

/// 只装「跟随」这一条链路的最小页面壳：页码 + 药丸。
class _ReadingPage extends StatefulWidget {
  const _ReadingPage({super.key});

  @override
  State<_ReadingPage> createState() => _ReadingPageState();
}

class _ReadingPageState extends State<_ReadingPage> {
  DateTime clock = DateTime(2026, 10, 31, 12);

  /// 跳页次数 = 页面真的调用 `_pager.jumpTo` 的次数（测试里的等价计数器）。
  int jumps = 0;
  int page = 0;
  int currentSentenceStart = 120;

  late final SpeechFollowGate gate = SpeechFollowGate(
    clock: () => clock,
    repaint: () {
      if (mounted) setState(() {});
    },
  );

  @override
  void dispose() {
    gate.dispose();
    super.dispose();
  }

  /// 用户自己翻了页（阅读页里是 `ReaderPager.onIndexChanged`）。
  void userTurnedPage({required int to}) {
    setState(() => page = to);
    gate.noteManualTurn();
  }

  /// 朗读通知：句/段起点决定跳不跳页（词级区间只影响重绘，不进这里）。
  void notifySpeech({required int sentenceStart}) {
    currentSentenceStart = sentenceStart;
    final target = gate.targetPage(
      enabled: true,
      baseCharStart: sentenceStart,
      currentPage: page,
      pageForChar: (charStart) => charStart ~/ _pageChars,
    );
    if (target == null) return;
    jumps++;
    setState(() => page = target);
  }

  /// 点「继续跟随」：清挂起并立刻补一次跟随 —— 朗读本身一个字节都不碰。
  void resumeFollow() {
    setState(gate.resume);
    notifySpeech(sentenceStart: currentSentenceStart);
  }

  /// 用户重新起朗读：阅读页里是 `_startSpeech()` 清挂起，随后 `speech.start()`
  /// 的 notify 触发重绘 —— 壳子里用这一次 setState 表示那条重绘链路。
  void startSpeech() {
    gate.resume();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Center(child: Text('第 $page 页')),
          if (gate.suspended) FollowPill(onTap: resumeFollow),
        ],
      ),
    );
  }
}

/// 把「锁窗口」往前推：注入的时钟与假异步的 Timer 一起推同一个量，缺一边就
/// 测不出真实手感（时钟不动 → 锁永不满；Timer 不动 → 药丸永不到点画出来）。
Future<void> _advance(
  WidgetTester tester,
  _ReadingPageState page,
  Duration by,
) async {
  page.clock = page.clock.add(by);
  await tester.pump(by);
  await tester.pump();
}

void main() {
  Future<_ReadingPageState> pumpPage(WidgetTester tester) async {
    final key = GlobalKey<_ReadingPageState>();
    await tester.pumpWidget(MaterialApp(home: _ReadingPage(key: key)));
    await tester.pump();
    return key.currentState!;
  }

  group('继续跟随药丸', () {
    testWidgets('跟随正常时没有药丸', (tester) async {
      final page = await pumpPage(tester);
      page.notifySpeech(sentenceStart: 120);
      await tester.pump();

      expect(page.page, 1, reason: '没锁就该跟到句所在页');
      expect(page.jumps, 1);
      expect(find.text('继续跟随'), findsNothing);
    });

    testWidgets('锁窗口内不跟随，也不提前弹药丸', (tester) async {
      final page = await pumpPage(tester);
      page.userTurnedPage(to: 3); // 用户自己往后翻了三页

      page.notifySpeech(sentenceStart: 120); // 朗读还停在第 1 页那句上
      expect(page.jumps, 0, reason: '锁内绝不把用户拉回去');
      expect(page.page, 3);

      await _advance(tester, page, const Duration(milliseconds: 1200));
      page.notifySpeech(sentenceStart: 120);
      expect(page.jumps, 0, reason: '锁没满就继续不跟');
      expect(find.text('继续跟随'), findsNothing, reason: '锁没满不该预告药丸');
    });

    testWidgets('锁满后出现药丸，期间朗读照读、页码不动', (tester) async {
      final page = await pumpPage(tester);
      page.userTurnedPage(to: 3);

      await _advance(tester, page, const Duration(milliseconds: 1600));

      expect(
        find.text('继续跟随'),
        findsOneWidget,
        reason: '锁到期就弹药丸，不靠下一个朗读事件',
      );
      expect(find.text('朗读已停在这里'), findsOneWidget);
      expect(page.jumps, 0, reason: '挂起期间仍然不跳页');
      expect(page.page, 3, reason: '不暂停朗读、不改变进度，只是不抢页面');
    });

    testWidgets('点药丸 → 清挂起并立刻补一次跟随', (tester) async {
      final page = await pumpPage(tester);
      page.userTurnedPage(to: 3);
      await _advance(tester, page, const Duration(milliseconds: 1600));
      expect(find.text('继续跟随'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, '继续跟随'));
      await tester.pump();

      expect(page.gate.suspended, isFalse);
      expect(find.text('继续跟随'), findsNothing);
      expect(page.jumps, 1, reason: '点一下就立刻跟到当前句');
      expect(page.page, 1);
    });

    testWidgets('重新起朗读清掉挂起（不该留着药丸碍眼）', (tester) async {
      final page = await pumpPage(tester);
      page.userTurnedPage(to: 3);
      await _advance(tester, page, const Duration(milliseconds: 1600));
      expect(find.text('继续跟随'), findsOneWidget);

      page.startSpeech();
      await tester.pump();

      expect(page.gate.suspended, isFalse);
      expect(find.text('继续跟随'), findsNothing);
    });

    testWidgets('词级推进（句起点不变）一次 jumpTo 都不触发', (tester) async {
      final page = await pumpPage(tester);
      page.notifySpeech(sentenceStart: 120);
      await tester.pump();
      expect(page.jumps, 1);

      // 同一句里往后念：句起点仍是 120，页面已经停在那一页。
      for (var wordStart = 120; wordStart < 196; wordStart += 4) {
        page.notifySpeech(sentenceStart: 120);
      }
      expect(page.jumps, 1, reason: '词级高亮变化不得触发 jumpTo');

      // 句起点跨过页界才跳。
      page.notifySpeech(sentenceStart: 240);
      expect(page.jumps, 2);
      expect(page.page, 2);
    });
  });

  group('精度徽标', () {
    testWidgets('空串 = 没有朗读会话，什么都不画', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SpeechBadge(text: ''))),
      );
      expect(
        find.byType(Text),
        findsNothing,
        reason: '路径未知就不画徽标，绝不编一个精度出来',
      );
    });

    testWidgets('有值就如实显示（文案由控制器算好）', (tester) async {
      for (final text in const <String>[
        '真人音轨·段',
        '智能朗读·段',
        '云合成·词',
      ]) {
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: SpeechBadge(text: text))),
        );
        expect(find.text(text), findsOneWidget);
      }
    });
  });
}
