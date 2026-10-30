// 审核修复的回归用例：每条对应 review-report.md 里的一个缺陷 ID。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/backup_service.dart';
import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/live/live_parser.dart';
import 'package:aquan_duanju/core/sources/hls_adfilter.dart';
import 'package:aquan_duanju/core/sources/source_export.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:aquan_duanju/widgets/continuous_chapters.dart';

void main() {
  group('RDR-03 阅读进度 revision', () {
    late Directory dir;
    late ReadingProgressStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('reading_rev_fix');
      store = ReadingProgressStore(testDirectory: dir);
      await store.ensureLoaded();
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<void> write(int chapter, {int? revision}) => store.record(
          bookId: 'book-1',
          title: '书',
          coverUrl: '',
          chapterId: 'c$chapter',
          chapterTitle: '第$chapter章',
          chapterIndex: chapter,
          chapters: 100,
          offset: 0.5,
          revision: revision,
        );

    test('漫画式调用（不传 revision）每次都能更新进度', () async {
      await write(3);
      await write(7);
      expect(store.entry('book-1')!.chapterIndex, 7);
    });

    test('不传 revision 时跨会话仍然单调（重开 store 后继续更新）', () async {
      await write(3);
      final reopened = ReadingProgressStore(testDirectory: dir);
      await reopened.ensureLoaded();
      await reopened.record(
        bookId: 'book-1',
        title: '书',
        coverUrl: '',
        chapterId: 'c9',
        chapterTitle: '第9章',
        chapterIndex: 9,
        chapters: 100,
        offset: 0.5,
      );
      expect(reopened.entry('book-1')!.chapterIndex, 9);
    });

    test('显式 revision 仍保持严格语义：旧快照被丢弃', () async {
      await write(1, revision: 10);
      await write(5, revision: 3);
      expect(store.entry('book-1')!.chapterIndex, 1,
          reason: '显式 revision 更小的写入必须丢弃，防 900ms 防抖旧快照覆盖');
    });

    test('revisionOf 给出可直接续号的当前序号', () async {
      await write(1, revision: 10);
      expect(await store.revisionOf('book-1'), 10);
      expect(await store.revisionOf('missing'), 0);
    });
  });

  group('SHR-01 备份白名单', () {
    test('界面收集的 10 个键都能通过校验', () async {
      final dir = await Directory.systemTemp.createTemp('backup_fix');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final service = DataBackupService(directory: () async => dir);
      final files = <String, Map<String, dynamic>>{
        'history': {
          's1': {
            'series_id': 's1',
            'updated_at': DateTime(2026, 10, 29).toIso8601String(),
          }
        },
        'follows': {
          's1': {
            'series_id': 's1',
            'updated_at': DateTime(2026, 10, 29).toIso8601String(),
          }
        },
        'searches': {
          'queries': <String>['测试'],
        },
        'play_skip': {'items': <String, dynamic>{}},
        'settings': {'theme.mode': 'dark'},
        'sources': {'sources': <dynamic>[]},
        'source_health': <String, dynamic>{},
        'market_sites': <String, dynamic>{},
        'cast': <String, dynamic>{},
        'lives': <String, dynamic>{},
      };
      final backup = await service.build(files);
      expect(backup.files.keys.toSet(), files.keys.toSet());
    });

    test('超出规模上限的容器仍被拒绝', () async {
      final dir = await Directory.systemTemp.createTemp('backup_fix_limit');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final service = DataBackupService(directory: () async => dir);
      await expectLater(
        service.build({
          'sources': {
            'sources': List<dynamic>.filled(20001, <String, dynamic>{}),
          },
        }),
        throwsA(isA<DataBackupException>()),
      );
    });
  });

  group('SRC-11 HLS 尾标签', () {
    test('末尾 #EXT-X-ENDLIST 不被丢弃', () {
      const manifest = '''
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
http://cdn/a1.ts
#EXTINF:6.0,
http://cdn/a2.ts
#EXT-X-ENDLIST
''';
      final out = HlsAdFilter.rewriteManifest(
          manifest, Uri.parse('http://up/i.m3u8'), (abs) => 'PROXY|$abs');
      expect(out.trimRight().endsWith('#EXT-X-ENDLIST'), isTrue,
          reason: '丢掉 ENDLIST 会让 VOD 清单被当成未结束');
      expect(out, contains('PROXY|http://cdn/a2.ts'));
    });
  });

  group('SRC-09 导出 URL 清洗', () {
    test('jsDelivr gh 前缀还原成 raw.githubusercontent', () {
      expect(
        cleanSourceUrl('https://cdn.jsdelivr.net/gh/user/repo@main/tv/x.json'),
        'https://raw.githubusercontent.com/user/repo/main/tv/x.json',
      );
    });

    test('普通加速前缀仍然只剥前缀', () {
      expect(
        cleanSourceUrl('https://ghproxy.com/https://raw.test/a.json'),
        'https://raw.test/a.json',
      );
    });
  });

  group('CST-02 投屏传输状态', () {
    test('标准 PLAYING 视为运行中', () {
      expect(const CastPoll(transportState: 'PLAYING').isRunning, isTrue);
      expect(const CastPoll(transportState: ' running ').isRunning, isTrue);
      expect(const CastPoll(transportState: 'PAUSED_PLAYBACK').isRunning,
          isFalse);
    });
  });

  group('LIVE-03 TXT 线路名', () {
    test(r'$线路名 不进入 URL', () {
      const txt = '央视,#genre#\nCCTV1,http://a/1.m3u8#http://b/1.m3u8\$备用线路\n';
      final groups = LiveParser.parse(txt);
      final urls = groups.single.channels.single.urls;
      expect(urls.map((u) => u.url).toList(),
          ['http://a/1.m3u8', 'http://b/1.m3u8']);
    });
  });

  group('SHR-03 下载列表排序', () {
    test('按最近一次下载时间排序，而不是最大集号那一集', () async {
      final store = DownloadStore();
      DownloadEntry e(String sid, int number, DateTime at) => DownloadEntry(
            seriesId: sid,
            seriesTitle: sid,
            coverUrl: '',
            episodeId: '$sid-$number',
            number: number,
            title: '第$number集',
            filePath: '',
            sizeBytes: 1,
            keyHex: '',
            quality: '',
            downloadedAt: at,
          );
      Future<void> add(DownloadEntry entry) async {
        try {
          await store.record(entry);
        } catch (_) {
          // 测试环境没有 application support 目录：内存里已写入即可。
        }
      }

      await add(e('a', 1, DateTime(2026, 10, 30)));
      await add(e('a', 2, DateTime(2025, 1, 1)));
      await add(e('b', 1, DateTime(2026, 6, 1)));

      expect(store.seriesList.map((s) => s.seriesId).toList(), ['a', 'b']);
    });
  });

  group('RDR-10 连续阅读体跳章', () {
    testWidgets('controller.jumpToChapter 会加载未加载过的章', (tester) async {
      final loaded = <int>[];
      final controller = ContinuousChaptersController();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ContinuousChapters(
            controller: controller,
            chapters: const ['a', 'b', 'c'],
            initialChapter: 0,
            loadChapter: (i, id) async {
              loaded.add(i);
              return List<String>.generate(60, (j) => '$id-p$j');
            },
            onPosition: (_, _, _) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(loaded, [0]);

      controller.jumpToChapter(2);
      await tester.pumpAndSettle();
      expect(loaded, [0, 2],
          reason: '目录跳章必须让复用的 State 换到新章');
    });
  });
}
