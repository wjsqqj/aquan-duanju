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

    testWidgets('打开时定位到当前集并居中', (tester) async {
      // 手机竖屏尺寸：列数更少、内容更高，居中不会被 maxScrollExtent 钳掉。
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final many = [for (var i = 1; i <= 200; i++) ep(i)];
      await tester.pumpWidget(host(EpisodePickerSheet(
        title: '长剧',
        episodes: many,
        currentIndex: 150,
        onSelect: (_) {},
      )));
      await tester.pumpAndSettle();

      final position =
          tester.state<ScrollableState>(find.byType(Scrollable)).position;
      // 不再从第 1 集开始。
      expect(position.pixels, greaterThan(0));

      // 行高按实现的同一套公式估算：列数由网格实际宽度决定。
      final gridRect = tester.getRect(find.byType(GridView));
      final cols = (gridRect.width / (72 + 8)).ceil();
      final rowExtent =
          (gridRect.width - 8 * (cols - 1)) / cols / 1.6 + 8;

      // 无 title 时标签是 i+1，第 151 集 = 下标 150。
      final cell = tester.getRect(find.text('151'));
      expect(gridRect.contains(cell.center), isTrue,
          reason: '当前集应落在视口内：cell=$cell grid=$gridRect');
      // 居中而不是「仅仅可见」：行高含 8dp 行距，理想偏差是半个行距（-4）；
      // PRD 的容差是一个行高（rowExtent），这里用更严的半行距证明居中。
      expect((cell.center.dy - gridRect.center.dy).abs(), lessThan(8),
          reason: 'offset=${position.pixels} rowExtent=$rowExtent');
    });

    testWidgets('currentIndex 为 0 时保持顶部', (tester) async {
      final many = [for (var i = 1; i <= 200; i++) ep(i)];
      await tester.pumpWidget(host(EpisodePickerSheet(
        title: '长剧',
        episodes: many,
        currentIndex: 0,
        onSelect: (_) {},
      )));
      await tester.pumpAndSettle();
      final position =
          tester.state<ScrollableState>(find.byType(Scrollable)).position;
      expect(position.pixels, 0);
    });

    testWidgets('集数少于一屏时定位不产生滚动', (tester) async {
      await tester.pumpWidget(host(EpisodePickerSheet(
        title: '短剧',
        episodes: [ep(1), ep(2), ep(3)],
        currentIndex: 2,
        onSelect: (_) {},
      )));
      await tester.pumpAndSettle();
      final position =
          tester.state<ScrollableState>(find.byType(Scrollable)).position;
      expect(position.maxScrollExtent, 0);
      expect(position.pixels, 0);
    });

    testWidgets('当前集在末尾时滚到底，不产生过冲', (tester) async {
      final many = [for (var i = 1; i <= 200; i++) ep(i)];
      await tester.pumpWidget(host(EpisodePickerSheet(
        title: '长剧',
        episodes: many,
        currentIndex: 190,
        onSelect: (_) {},
      )));
      await tester.pumpAndSettle();
      final position =
          tester.state<ScrollableState>(find.byType(Scrollable)).position;
      expect(position.pixels, position.maxScrollExtent);
      final gridRect = tester.getRect(find.byType(GridView));
      expect(gridRect.contains(tester.getRect(find.text('191')).center), isTrue);
    });
  });

    testWidgets('头部缓存按钮触发 onDownload', (tester) async {
      var downloaded = false;
      await tester.pumpWidget(host(EpisodePickerSheet(
        title: '剧',
        episodes: [ep(1), ep(2)],
        currentIndex: 0,
        onSelect: (_) {},
        onDownload: () => downloaded = true,
      )));
      await tester.tap(find.byIcon(Icons.download_outlined));
      expect(downloaded, isTrue);
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

    testWidgets('模态打开时也定位到当前集（入场动画后不漂移）', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final many = [for (var i = 1; i <= 200; i++) ep(i)];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showEpisodePicker(
                  context,
                  title: '长剧',
                  episodes: many,
                  currentIndex: 150,
                  onSelect: (_) {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final gridRect = tester.getRect(find.byType(GridView));
      final cell = tester.getRect(find.text('151'));
      expect(gridRect.contains(cell.center), isTrue);
      expect((cell.center.dy - gridRect.center.dy).abs(), lessThan(8),
          reason: '模态入场后当前集应仍在视口中间');
    });
  });
}
