import 'package:aquan_duanju/store/stores.dart';
import 'package:aquan_duanju/widgets/player_guide_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('播放器指南弹层', () {
    testWidgets('桌面端四步：下一步 / 最后一步「开始观看」关闭', (tester) async {
      await tester.pumpWidget(_host(Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => showPlayerGuide(context),
            child: const Text('open'),
          ),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('双击画面切换全屏'), findsOneWidget);
      expect(find.text('下一步'), findsOneWidget);
      expect(find.text('跳过'), findsOneWidget);

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('滚轮调音量，键盘快进快退'), findsOneWidget);

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('长按画面 2 倍速'), findsOneWidget);

      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('全屏时鼠标靠右边缘选集'), findsOneWidget);
      expect(find.text('开始观看'), findsOneWidget);

      await tester.tap(find.text('开始观看'));
      await tester.pumpAndSettle();
      expect(find.text('开始观看'), findsNothing);
    });

    testWidgets('跳过立即关闭，不要求翻完', (tester) async {
      await tester.pumpWidget(_host(Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => showPlayerGuide(context),
            child: const Text('open'),
          ),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('跳过'));
      await tester.pumpAndSettle();
      expect(find.text('跳过'), findsNothing);
    });

    testWidgets('上一步可回退', (tester) async {
      await tester.pumpWidget(_host(Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () => showPlayerGuide(context),
            child: const Text('open'),
          ),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上一步'));
      await tester.pumpAndSettle();
      expect(find.text('双击画面切换全屏'), findsOneWidget);
    });
  });

  group('player.guideSeen', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('默认未看过，写入后读回 true', () async {
      final settings = SettingsStore(await SharedPreferences.getInstance());
      expect(settings.playerGuideSeen, isFalse);
      settings.playerGuideSeen = true;
      expect(settings.playerGuideSeen, isTrue);
    });

    test('不进备份导出（换机应当重新看到）', () async {
      final settings = SettingsStore(await SharedPreferences.getInstance());
      settings.playerGuideSeen = true;
      expect(settings.exportBackup().containsKey('player.guideSeen'), isFalse);
    });
  });
}
