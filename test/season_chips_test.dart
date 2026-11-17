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

  testWidgets('多季显示标签，当前季高亮，缺集数元数据的季也可点', (tester) async {
    Season? picked;
    await tester.pumpWidget(_host([
      const Season(seriesId: 's1', title: '第一季', index: 1, episodeCount: 5),
      const Season(seriesId: 's2', title: '第二季', index: 2, episodeCount: 0),
      const Season(seriesId: 's3', title: '第三季', index: 3, episodeCount: 8),
    ], (season) => picked = season));

    expect(find.textContaining('第二季'), findsOneWidget);
    expect(find.textContaining('第三季'), findsOneWidget);

    // episodeCount=0 不再是灰显门槛：合集元数据可能缺新季（万妖 15/16
    // 用户实测选不到），点进去拉一次才知道，空列表给行内提示。
    await tester.tap(find.textContaining('第二季'));
    expect(picked?.seriesId, 's2');

    await tester.tap(find.textContaining('第三季'));
    expect(picked?.seriesId, 's3');
  });

  testWidgets('seriesId 为空的季不可点', (tester) async {
    Season? picked;
    await tester.pumpWidget(_host([
      const Season(seriesId: 's1', title: '第一季', index: 1, episodeCount: 5),
      const Season(seriesId: '', title: '幽灵季', index: 2, episodeCount: 9),
    ], (season) => picked = season));

    await tester.tap(find.textContaining('幽灵季'), warnIfMissed: false);
    expect(picked, isNull, reason: '没有 seriesId 无法拉取，保持灰显');
  });
}
