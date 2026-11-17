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

  testWidgets('多季显示标签，当前季高亮，集数为 0 的季不展示', (tester) async {
    Season? picked;
    await tester.pumpWidget(_host([
      const Season(seriesId: 's1', title: '第一季', index: 1, episodeCount: 5),
      const Season(seriesId: 's2', title: '第二季', index: 2, episodeCount: 0),
      const Season(seriesId: 's3', title: '第三季', index: 3, episodeCount: 8),
    ], (season) => picked = season));

    // 集数为 0 = 未上线：直接藏掉（用户反馈：灰显又选不到不如不展示）。
    expect(find.textContaining('第二季'), findsNothing);
    expect(find.textContaining('第三季'), findsOneWidget);

    await tester.tap(find.textContaining('第三季'));
    expect(picked?.seriesId, 's3');
  });

  testWidgets('只剩当前季一个可展示时整行不渲染', (tester) async {
    await tester.pumpWidget(_host([
      const Season(seriesId: 's1', title: '第一季', index: 1, episodeCount: 5),
      const Season(seriesId: 's2', title: '第二季', index: 2, episodeCount: 0),
      const Season(seriesId: 's3', title: '第三季', index: 3, episodeCount: 0),
    ], (_) {}));

    expect(find.textContaining('第一季'), findsNothing);
    expect(find.textContaining('第二季'), findsNothing);
    expect(find.textContaining('第三季'), findsNothing);
  });
}
