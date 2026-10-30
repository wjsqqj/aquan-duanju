import 'package:aquan_duanju/core/content/cursor_pager.dart';
import 'package:aquan_duanju/core/live/catchup.dart';
import 'package:aquan_duanju/core/live/live_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CursorPager', () {
    CursorPager<String> pager() =>
        CursorPager<String>(idOf: (id) => id, emptyPageLimit: 2);

    test('跨页重复被剔除，保持首次出现顺序', () {
      final p = pager();
      expect(
        p.addPage(page: <String>['a', 'b'], cursor: 'c1', hasMore: true),
        2,
      );
      expect(
        p.addPage(page: <String>['b', 'c'], cursor: 'c2', hasMore: true),
        1,
      );
      expect(p.items, <String>['a', 'b', 'c']);
      expect(p.cursor, 'c2');
      expect(p.hasMore, isTrue);
    });

    test('空页直接判到底', () {
      final p = pager();
      p.addPage(page: <String>['a'], cursor: 'c1', hasMore: true);
      expect(p.addPage(page: <String>[], cursor: 'c2', hasMore: true), 0);
      expect(p.hasMore, isFalse);
      expect(p.exhausted, isTrue);
    });

    test('连续两页零新增判到底（服务端游标不前进）', () {
      final p = pager();
      p.addPage(page: <String>['a'], cursor: 'c1', hasMore: true);
      expect(p.addPage(page: <String>['a'], cursor: 'c2', hasMore: true), 0);
      expect(p.hasMore, isTrue, reason: '第一次零新增只累计，不立刻判死');
      expect(p.addPage(page: <String>['a'], cursor: 'c3', hasMore: true), 0);
      expect(p.hasMore, isFalse);
    });

    test('有新增时重置计数并跟随服务端 hasMore', () {
      final p = pager();
      p.addPage(page: <String>['a'], cursor: 'c1', hasMore: true);
      p.addPage(page: <String>['a'], cursor: 'c2', hasMore: true);
      p.addPage(page: <String>['b'], cursor: 'c3', hasMore: false);
      expect(p.hasMore, isFalse);
      expect(p.items, <String>['a', 'b']);
    });

    test('reset 清空全部状态', () {
      final p = pager();
      p.addPage(page: <String>['a'], cursor: 'c1', hasMore: false);
      p.reset();
      expect(p.items, isEmpty);
      expect(p.cursor, '');
      expect(p.hasMore, isTrue);
      expect(p.contains('a'), isFalse);
    });
  });

  group('回看 URL', () {
    LiveChannel channel({
      String url = 'http://cdn/live/1.m3u8',
      String catchup = '',
      String source = '',
      String correction = '',
      int days = 0,
    }) =>
        LiveChannel(
          name: 'CCTV1',
          urls: [LiveUrl(url: url)],
          catchup: catchup,
          catchupSource: source,
          catchupCorrection: correction,
          catchupDays: days,
        );

    final start = DateTime.utc(2026, 10, 30, 8);
    final end = start.add(const Duration(minutes: 30));

    test('无声明时不可回看', () {
      final c = channel();
      expect(Catchup.canReplay(c), isFalse);
      expect(Catchup.replayUrl(c, start), isNull);
      expect(Catchup.kindOf(c), CatchupKind.none);
    });

    test('playseek 模板替换', () {
      final c = channel(
        url: 'http://cdn/live/1.m3u8?playseek=111-222',
        catchup: 'shift',
      );
      expect(Catchup.canReplay(c), isTrue);
      expect(Catchup.kindOf(c), CatchupKind.playseek);
      final url = Catchup.replayUrl(c, start, end: end)!;
      final from = start.millisecondsSinceEpoch ~/ 1000;
      final to = end.millisecondsSinceEpoch ~/ 1000;
      expect(url, contains('playseek=$from-$to'));
    });

    test('模板占位符替换', () {
      final c = channel(
        catchup: 'default',
        source: 'http://cdn/replay?start={utc}&end={utcend}&len={duration}',
      );
      final url = Catchup.replayUrl(c, start, end: end)!;
      final from = start.millisecondsSinceEpoch ~/ 1000;
      final to = end.millisecondsSinceEpoch ~/ 1000;
      expect(url, contains('start=$from'));
      expect(url, contains('end=$to'));
      expect(url, contains('len=1800'));
      expect(url, isNot(contains('{')));
    });

    test(r'${start}/${end} 形态也能替换', () {
      final c = channel(
        catchup: 'flussonic',
        source: r'http://cdn/timeshift/${start}/${end}/1.m3u8',
      );
      final url = Catchup.replayUrl(c, start, end: end)!;
      final from = start.millisecondsSinceEpoch ~/ 1000;
      final to = end.millisecondsSinceEpoch ~/ 1000;
      expect(url, 'http://cdn/timeshift/$from/$to/1.m3u8');
    });

    test('时间校正：+8h / -30m / +8', () {
      final plus8 = channel(
        catchup: 'default',
        source: 'http://cdn/r?t={utc}',
        correction: '+8h',
      );
      final base = start.millisecondsSinceEpoch ~/ 1000;
      expect(
        Catchup.replayUrl(plus8, start, end: end),
        contains('t=${base + 8 * 3600}'),
      );

      final minus30 = channel(
        catchup: 'default',
        source: 'http://cdn/r?t={utc}',
        correction: '-30m',
      );
      expect(
        Catchup.replayUrl(minus30, start, end: end),
        contains('t=${base - 1800}'),
      );

      final plain8 = channel(
        catchup: 'default',
        source: 'http://cdn/r?t={utc}',
        correction: '+8',
      );
      expect(
        Catchup.replayUrl(plain8, start, end: end),
        contains('t=${base + 8 * 3600}'),
      );
    });

    test('结束早于开始返回 null', () {
      final c = channel(catchup: 'default', source: 'http://cdn/r?t={utc}');
      expect(
        Catchup.replayUrl(c, start, end: start.subtract(const Duration(minutes: 1))),
        isNull,
      );
    });
  });

  group('M3U catchup 解析', () {
    const m3u = '''
#EXTM3U
#EXTINF:-1 tvg-id="cctv1" tvg-name="CCTV1" group-title="央视" catchup="shift" catchup-days="7" catchup-correction="+8h",CCTV1
http://cdn/live/cctv1.m3u8
#EXTINF:-1 tvg-id="cctv2" group-title="央视",CCTV2
http://cdn/live/cctv2.m3u8
''';

    test('属性被读取', () {
      final groups = LiveParser.parseM3u(m3u);
      final channels = groups.expand((g) => g.channels).toList();
      expect(channels.length, 2);

      final cctv1 = channels.first;
      expect(cctv1.name, 'CCTV1');
      expect(cctv1.tvgId, 'cctv1');
      expect(cctv1.catchup, 'shift');
      expect(cctv1.catchupDays, 7);
      expect(cctv1.catchupCorrection, '+8h');
      expect(cctv1.hasCatchup, isTrue);

      final cctv2 = channels.last;
      expect(cctv2.catchup, isEmpty);
      expect(cctv2.hasCatchup, isFalse);
    });

    test('解析出的频道能构造回看地址', () {
      final groups = LiveParser.parseM3u(m3u);
      final cctv1 = groups.first.channels.first;
      final url = Catchup.replayUrl(
        cctv1,
        DateTime.utc(2026, 10, 30, 8),
        end: DateTime.utc(2026, 10, 30, 9),
      );
      // catchup=shift 但地址里没有 playseek，走「追加」分支。
      expect(url, contains('playseek='));
    });
  });
}
