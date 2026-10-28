import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/widgets/episode_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Episode ep(int number, {String title = '', bool playable = true}) =>
    Episode(id: 'e$number', number: number, title: title, playable: playable);

Widget host(Widget child) => MaterialApp(
      home: Scaffold(body: child),
    );

void main() {
  group('EpisodePickerSheet', () {
    testWidgets('渲染全部集数并高亮当前集', (tester) async {
      await tester.pumpWidget(host(EpisodePickerSheet(
        title: '测试剧',
        episodes: [ep(1), ep(2), ep(3)],
        currentIndex: 1,
        onSelect: (_) {},
      )));
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('选集 · 测试剧'), findsOneWidget);
      expect(find.text('3集'), findsOneWidget);
    });

    testWidgets('有点集标题的集显示标题', (tester) async {
      await tester.pumpWidget(host(EpisodePickerSheet(
        title: '剧',
        episodes: [ep(1), ep(2, title: '大结局')],
        currentIndex: 0,
        onSelect: (_) {},
      )));
      expect(find.text('大结局'), findsOneWidget);
    });

    testWidgets('已缓存集显示下载角标', (tester) async {
      await tester.pumpWidget(host(EpisodePickerSheet(
        title: '剧',
        episodes: [ep(1), ep(2)],
        currentIndex: 0,
        onSelect: (_) {},
        isDownloaded: (e) => e.number == 2,
      )));
      expect(find.byIcon(Icons.download_done), findsOneWidget);
    });

    testWidgets('点选集数回调下标', (tester) async {
      int? picked;
      await tester.pumpWidget(host(EpisodePickerSheet(
        title: '剧',
        episodes: [ep(1), ep(2), ep(3)],
        currentIndex: 0,
        onSelect: (i) => picked = i,
      )));
      await tester.tap(find.text('3'));
      expect(picked, 2);
    });

    testWidgets('locked 的集不可点', (tester) async {
      int? picked;
      await tester.pumpWidget(host(EpisodePickerSheet(
        title: '剧',
        episodes: [ep(1), ep(2, playable: false)],
        currentIndex: 0,
        onSelect: (i) => picked = i,
      )));
      await tester.tap(find.text('2'), warnIfMissed: false);
      expect(picked, isNull);
      await tester.tap(find.text('1'));
      expect(picked, 0);
    });

    testWidgets('集数很多时可滚动', (tester) async {
      final many = [for (var i = 1; i <= 200; i++) ep(i)];
      await tester.pumpWidget(host(EpisodePickerSheet(
        title: '长剧',
        episodes: many,
        currentIndex: 0,
        onSelect: (_) {},
      )));
      expect(find.text('200集'), findsOneWidget);
      await tester.drag(find.byType(GridView), const Offset(0, -600));
      await tester.pumpAndSettle();
      // 滚动后能看到深处的集数（文本存在即网格在滚）。
      expect(find.text('150'), findsOneWidget);
    });
  });

  group('showEpisodePicker', () {
    testWidgets('弹出后选择即关闭并回调', (tester) async {
      int? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showEpisodePicker(
                  context,
                  title: '剧',
                  episodes: [ep(1), ep(2)],
                  currentIndex: 0,
                  onSelect: (i) => picked = i,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(EpisodePickerSheet), findsOneWidget);
      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();
      expect(picked, 1);
      expect(find.byType(EpisodePickerSheet), findsNothing);
    });
  });
}
