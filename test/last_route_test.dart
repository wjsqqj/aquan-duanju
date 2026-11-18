// R1 冷启动会话恢复的数据与追踪层（11-19-ux-resume）：
// - LastRoute JSON 编解码（非法输入忽略回空）；
// - ui.resumeSession / ui.lastRoute 设置键与备份往返；
// - LastRouteTracker：detail/player push 记录、回壳层清除、弹窗不动记录、
//   启动时装载根路由不清键（恢复入口还没读）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aquan_duanju/core/last_route.dart';
import 'package:aquan_duanju/screens/session_resume.dart';
import 'package:aquan_duanju/store/stores.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LastRoute 编解码', () {
    test('detail / player 记录 encode → tryDecode 往返', () {
      final detail = LastRoute.detail(
        seriesId: 's1',
        at: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      final d = LastRoute.tryDecode(detail.encode());
      expect(d, isNotNull);
      expect(d!.kind, LastRouteKind.detail);
      expect(d.seriesId, 's1');
      expect(d.episode, 0);
      expect(d.at, detail.at);

      final player = LastRoute.player(
        seriesId: 's2',
        episode: 3,
        at: DateTime.fromMillisecondsSinceEpoch(1700000001000),
      );
      final p = LastRoute.tryDecode(player.encode());
      expect(p, isNotNull);
      expect(p!.kind, LastRouteKind.player);
      expect(p.seriesId, 's2');
      expect(p.episode, 3);
      expect(p.at, player.at);
    });

    test('非法 JSON / 未知结构 / 空 seriesId / 未知 kind / 缺时间戳 → null', () {
      expect(LastRoute.tryDecode(''), isNull);
      expect(LastRoute.tryDecode('not json {'), isNull);
      expect(LastRoute.tryDecode('123'), isNull);
      expect(LastRoute.tryDecode('["detail"]'), isNull);
      expect(
        LastRoute.tryDecode('{"kind":"detail"}'),
        isNull,
        reason: '空 seriesId',
      );
      expect(
        LastRoute.tryDecode('{"kind":"weird","seriesId":"s1","at":1}'),
        isNull,
        reason: '未知 kind',
      );
      expect(
        LastRoute.tryDecode('{"kind":"detail","seriesId":"s1"}'),
        isNull,
        reason: '缺 at',
      );
    });
  });

  group('设置键与备份往返', () {
    test('ui.resumeSession 默认开；ui.lastRoute 写读 / 清空', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsStore(await SharedPreferences.getInstance());
      expect(s.uiResumeSession, isTrue, reason: '默认开');
      expect(s.uiLastRoute, '');

      s.uiLastRoute = LastRoute.detail(seriesId: 's1').encode();
      expect(LastRoute.tryDecode(s.uiLastRoute)!.seriesId, 's1');
      s.uiLastRoute = '';
      expect(s.uiLastRoute, '', reason: '空串清除持久化键');
    });

    test('ui.resumeSession / ui.lastRoute 进备份导出并可导入', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsStore(await SharedPreferences.getInstance());
      s.uiResumeSession = false;
      final record = LastRoute.player(seriesId: 's9', episode: 7);
      s.uiLastRoute = record.encode();

      final exported = s.exportBackup();
      expect(exported['ui.resumeSession'], false);
      expect(exported['ui.lastRoute'], record.encode());

      SharedPreferences.setMockInitialValues({});
      final s2 = SettingsStore(await SharedPreferences.getInstance());
      s2.importBackup(Map<String, dynamic>.from(exported));
      expect(s2.uiResumeSession, false);
      expect(s2.uiLastRoute, record.encode());
    });

    test('importBackup 对非法 lastRoute 忽略（不留脏值）', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsStore(await SharedPreferences.getInstance());
      s.importBackup(<String, dynamic>{'ui.lastRoute': 'garbage'});
      expect(s.uiLastRoute, '');
      s.importBackup(<String, dynamic>{'ui.lastRoute': 123});
      expect(s.uiLastRoute, '');
    });
  });

  group('LastRouteTracker（导航观察）', () {
    testWidgets('push 记录 / 回壳层清除 / 弹窗不动记录 / 启动装载不清键', (tester) async {
      final seeded = LastRoute.detail(seriesId: 's0');
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ui.lastRoute': seeded.encode(),
      });
      final settings = SettingsStore(await SharedPreferences.getInstance());
      final tracker = LastRouteTracker(settings);

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [tracker],
          home: const Scaffold(body: Center(child: Text('壳层'))),
        ),
      );
      expect(
        LastRoute.tryDecode(settings.uiLastRoute)!.seriesId,
        's0',
        reason: '启动时装载根路由（previousRoute == null）不清键：恢复入口还没读',
      );

      final NavigatorState nav = tester.state(find.byType(Navigator));
      nav.push(
        MaterialPageRoute<void>(
          settings: RouteSettings(
            name: kRouteNameDetail,
            arguments: LastRoute.detail(seriesId: 's2'),
          ),
          builder: (_) => const Scaffold(body: Text('详情')),
        ),
      );
      await tester.pump();
      expect(LastRoute.tryDecode(settings.uiLastRoute)!.seriesId, 's2');

      nav.push(
        MaterialPageRoute<void>(
          settings: RouteSettings(
            name: kRouteNamePlayer,
            arguments: LastRoute.player(seriesId: 's2', episode: 3),
          ),
          builder: (_) => const Scaffold(body: Text('播放')),
        ),
      );
      await tester.pump();
      final playerRecord = LastRoute.tryDecode(settings.uiLastRoute);
      expect(playerRecord!.kind, LastRouteKind.player);
      expect(playerRecord.episode, 3);

      // 弹窗（PopupRoute）不算页面切换：开与关都不动记录。showDialog 的
      // future 要等弹窗关闭才完成，不能在这里 await（会死等下面的 pop）。
      final dialogFuture = showDialog<void>(
        context: nav.context,
        builder: (_) => const AlertDialog(title: Text('提示')),
      );
      await tester.pump();
      await tester.pump();
      expect(
        LastRoute.tryDecode(settings.uiLastRoute)!.episode,
        3,
        reason: '弹窗打开不清记录',
      );
      nav.pop();
      await dialogFuture;
      await tester.pump();
      await tester.pump();
      expect(
        LastRoute.tryDecode(settings.uiLastRoute)!.episode,
        3,
        reason: '弹窗关闭不清记录',
      );

      // 返回：pop 播放页回详情（记录保持），pop 详情回壳层（清除）。
      nav.pop();
      await tester.pump();
      expect(
        LastRoute.tryDecode(settings.uiLastRoute)!.seriesId,
        's2',
        reason: '回到详情页记录保持',
      );
      nav.pop();
      await tester.pump();
      expect(settings.uiLastRoute, '', reason: '回到壳层清除');
    });

    testWidgets('跨季 pushReplacement：新栈顶（新季播放页）更新记录', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsStore(await SharedPreferences.getInstance());
      final tracker = LastRouteTracker(settings);

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [tracker],
          home: const Scaffold(body: Center(child: Text('壳层'))),
        ),
      );
      final NavigatorState nav = tester.state(find.byType(Navigator));
      nav.pushReplacement(
        MaterialPageRoute<void>(
          settings: RouteSettings(
            name: kRouteNamePlayer,
            arguments: LastRoute.player(seriesId: 's-new-season', episode: 1),
          ),
          builder: (_) => const Scaffold(body: Text('新季播放')),
        ),
      );
      await tester.pump();
      expect(
        LastRoute.tryDecode(settings.uiLastRoute)!.seriesId,
        's-new-season',
      );
    });
  });
}
