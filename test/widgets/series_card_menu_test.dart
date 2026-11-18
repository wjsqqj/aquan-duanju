// A1 列表卡片右键/长按收藏菜单：
// - 移动端长按卡片 → 弹出追剧菜单 → 选「想看」→ FollowStore 落 want；
// - 桌面右键（鼠标副键）同样弹菜单；
// - 已追剧时当前态那行画勾；「取消追剧」移除记录；
// - 广告卡（无 seriesId）不挂菜单；长按不触发 onTap。
//
// store 用 testDirectory 注入（不走 AppScope，纯组件测试）；追剧仓先经
// `tester.runAsync` 真实加载一次（widget 测试的 FakeAsync 区里 dart:io
// 不会完成，ensureLoaded 的单飞位必须在进入手势前置好）。
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/tv/tv_mode.dart';
import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:aquan_duanju/widgets/common.dart';
import 'package:aquan_duanju/widgets/tv_scope.dart';

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(child: SizedBox(width: 180, height: 300, child: child)),
  ),
);

SeriesCard _card(
  SeriesSummary item,
  FollowStore follows, {
  VoidCallback? onTap,
}) => SeriesCard(item: item, onTap: onTap ?? () {}, follows: follows);

void main() {
  testWidgets('长按卡片弹追剧菜单，选「想看」落 FollowStore', (tester) async {
    final dir = Directory.systemTemp.createTempSync('aquan_card_menu');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final follows = FollowStore(testDirectory: dir);
    await tester.runAsync(() => follows.ensureLoaded());

    var tapped = false;
    await tester.pumpWidget(
      _wrap(
        _card(
          const SeriesSummary(id: '701', title: '万妖图录', episodeCount: 12),
          follows,
          onTap: () => tapped = true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(follows.isFollowing('701'), isFalse);

    await tester.longPress(find.byType(SeriesCard));
    await tester.pumpAndSettle();

    // 四个菜单项齐全；长按不是点击，onTap 不触发。
    expect(find.text('追剧'), findsOneWidget);
    expect(find.text('想看'), findsOneWidget);
    expect(find.text('已看'), findsOneWidget);
    expect(find.text('取消追剧'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing, reason: '尚未追剧无画勾');
    expect(tapped, isFalse);

    await tester.tap(find.text('想看'));
    await tester.pumpAndSettle();
    expect(find.text('追剧'), findsNothing, reason: '菜单已关闭');
    expect(follows.get('701')?.state, FollowState.want);
    expect(follows.get('701')?.episodeCount, 12);
    expect(tapped, isFalse);
  });

  testWidgets('鼠标右键（副键点击）同样弹出菜单', (tester) async {
    final dir = Directory.systemTemp.createTempSync('aquan_card_menu2');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final follows = FollowStore(testDirectory: dir);
    await tester.runAsync(() => follows.ensureLoaded());

    await tester.pumpWidget(
      _wrap(_card(const SeriesSummary(id: '702', title: '右键剧'), follows)),
    );
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SeriesCard)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('追剧'), findsOneWidget);
    // 菜单里选「追剧」= watching。
    await tester.tap(find.text('追剧'));
    await tester.pumpAndSettle();
    expect(follows.get('702')?.state, FollowState.watching);
  });

  testWidgets('已追剧时当前态画勾；选「取消追剧」移除记录', (tester) async {
    final dir = Directory.systemTemp.createTempSync('aquan_card_menu3');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final follows = FollowStore(testDirectory: dir);
    await tester.runAsync(() => follows.ensureLoaded());
    // 预置一条在看记录（follow() 同步写内存，flush 失败不影响本测试）。
    await tester.runAsync(
      () => follows.follow(
        seriesId: '703',
        title: '已追的剧',
        coverUrl: '',
        episodeCount: 30,
        state: FollowState.watching,
      ),
    );
    expect(follows.get('703')?.state, FollowState.watching);

    await tester.pumpWidget(
      _wrap(
        _card(
          const SeriesSummary(id: '703', title: '已追的剧', episodeCount: 30),
          follows,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(SeriesCard));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsOneWidget, reason: '当前态（在看）画勾');

    await tester.tap(find.text('取消追剧'));
    await tester.pumpAndSettle();
    expect(follows.isFollowing('703'), isFalse);
  });

  testWidgets('广告卡（无 seriesId）不挂菜单', (tester) async {
    final dir = Directory.systemTemp.createTempSync('aquan_card_menu4');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final follows = FollowStore(testDirectory: dir);
    await tester.runAsync(() => follows.ensureLoaded());

    await tester.pumpWidget(
      _wrap(_card(const SeriesSummary(id: '', title: '广告位'), follows)),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(SeriesCard));
    await tester.pumpAndSettle();
    expect(find.text('追剧'), findsNothing);
    expect(find.text('取消追剧'), findsNothing);
    expect(follows.isFollowing(''), isFalse);
  });

  testWidgets('TV 形态不挂菜单', (tester) async {
    final dir = Directory.systemTemp.createTempSync('aquan_card_menu5');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final follows = FollowStore(testDirectory: dir);
    await tester.runAsync(() => follows.ensureLoaded());

    await tester.pumpWidget(
      TvScope(
        formFactor: AppFormFactor.tv,
        child: _wrap(
          _card(const SeriesSummary(id: '704', title: 'TV 剧'), follows),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byType(SeriesCard));
    await tester.pumpAndSettle();
    expect(find.text('追剧'), findsNothing);
  });
}
