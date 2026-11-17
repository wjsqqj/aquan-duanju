import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/widgets/season_chips.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(List<Season> seasons, void Function(Season) onTap) =>
    MaterialApp(
      home: Scaffold(
        body: SeasonChips(
          seasons: seasons,
          currentSeriesId: 's1',
          onTap: onTap,
        ),
      ),
    );

void main() {
  testWidgets('单季不渲染季标签', (tester) async {
    await tester.pumpWidget(_host([
      const Season(seriesId: 's1', title: '第一季', index: 1, episodeCount: 5),
    ], (_) {}));
    expect(find.textContaining('第一季'), findsNothing);
  });

  testWidgets('多季显示标签，当前季高亮，未上线季不可点', (tester) async {
    Season? picked;
    await tester.pumpWidget(_host([
      const Season(seriesId: 's1', title: '第一季', index: 1, episodeCount: 5),
      const Season(seriesId: 's2', title: '第二季', index: 2, episodeCount: 0),
      const Season(seriesId: 's3', title: '第三季', index: 3, episodeCount: 8),
    ], (season) => picked = season));

    expect(find.textContaining('第二季'), findsOneWidget);
    expect(find.textContaining('第三季'), findsOneWidget);

    await tester.tap(find.textContaining('第二季'));
    expect(picked, isNull, reason: '未上线（episodeCount=0）不能点');

    await tester.tap(find.textContaining('第三季'));
    expect(picked?.seriesId, 's3');
  });
}
