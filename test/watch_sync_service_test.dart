import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aquan_duanju/core/sync/remote_store.dart';
import 'package:aquan_duanju/core/sync/watch_sync_document.dart';
import 'package:aquan_duanju/core/sync/watch_sync_service.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 内存远端（测试替身）：记录调用次数，可控失败与延迟。
class _MemoryStore implements RemoteStore {
  _MemoryStore({this.failPutTimes = 0, this.getDelay = Duration.zero});

  final Map<String, Uint8List> objects = {};
  int getAttempts = 0;
  int putAttempts = 0;
  final List<String> putPaths = [];
  int failPutTimes;
  final Duration getDelay;

  @override
  String get label => 'Memory';

  @override
  Future<Uint8List?> get(String path) async {
    getAttempts++;
    if (getDelay > Duration.zero) await Future<void>.delayed(getDelay);
    return objects[path];
  }

  @override
  Future<List<RemoteObject>> list(String prefix) async => const [];

  @override
  Future<void> ping() async {}

  @override
  Future<void> put(String path, Uint8List bytes) async {
    putAttempts++;
    if (failPutTimes > 0) {
      failPutTimes--;
      throw const RemoteStoreException('模拟上传失败');
    }
    putPaths.add(path);
    objects[path] = bytes;
  }

  WatchSyncDocument? get remoteDoc {
    final bytes = objects[WatchSyncService.remoteDocPath];
    if (bytes == null) return null;
    return WatchSyncDocument.parse(utf8.decode(bytes));
  }
}

WatchSyncDocument remoteDocJson({
  List<Map<String, dynamic>> history = const [],
  List<Map<String, dynamic>> follows = const [],
  List<WatchTombstone> tombstones = const [],
}) => WatchSyncDocument(
  history: history,
  follows: follows,
  tombstones: tombstones,
);

void main() {
  late Directory support;
  late Directory storeDir;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('aquan_watch_sync');
    // 与生产同布局：store JSON 与快照 .bak、墓碑文件同在一个数据目录。
    storeDir = support;
    SharedPreferences.setMockInitialValues({'sync.watchAuto': true});
  });

  tearDown(() async {
    try {
      await support.delete(recursive: true);
    } catch (_) {}
  });

  Future<SettingsStore> settings() async =>
      SettingsStore(await SharedPreferences.getInstance());

  /// 服务：节流/冷却用短窗口（真实 Timer，单测总耗时 <2s）；
  /// 生产参数 15s / 15min 由默认值保证，测试不可为追求速度改默认语义。
  /// [auto] 控制该测试实例的 sync.watchAuto：手动同步组必须关掉，
  /// 否则 record 的变更通知会排自动同步定时器，与手动 syncNow 竞态。
  Future<WatchSyncService> service({
    RemoteStore? remote,
    bool auto = false,
    Duration throttleWindow = const Duration(milliseconds: 50),
    Duration failureCooldown = const Duration(milliseconds: 300),
  }) async {
    SharedPreferences.setMockInitialValues({'sync.watchAuto': auto});
    final svc = WatchSyncService(
      history: HistoryStore(testDirectory: storeDir),
      follows: FollowStore(testDirectory: storeDir),
      settings: await settings(),
      storeOverride: remote,
      supportDirOverride: support,
      throttleWindow: throttleWindow,
      failureCooldown: failureCooldown,
    );
    svc.start();
    return svc;
  }

  Map<String, dynamic> entry(
    String id, {
    required String updatedAt,
    int episode = 1,
  }) {
    return {
      'series_id': id,
      'title': '剧$id',
      'episode': episode,
      'episodes': 10,
      'finished': false,
      'position': 60.0,
      'updated_at': updatedAt,
    };
  }

  /// 恒定晚于测试内任何 record 的时间戳（本机时钟推进不影响结果）。
  String futureStamp() =>
      DateTime.now().add(const Duration(days: 2)).toUtc().toIso8601String();

  /// 轮询等待语义条件成立（最多 8s）：CI 负载下真实 Timer、store 落盘与
  /// 合并耗时都不可控，自动同步测试只断最终结果，不断精确节奏。
  Future<void> pollUntil(
    _MemoryStore remote,
    bool Function() predicate, {
    required String what,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail(
      '8s 内未满足：$what '
      '(getAttempts=${remote.getAttempts}, putAttempts=${remote.putAttempts})',
    );
  }

  /// 轮询等待远端文档出现指定集（最多 8s）：CI 负载下真实 Timer 与
  /// record 落盘通知的先后不可控，自动同步测试断「最终内容」不断节奏。
  Future<void> pollUntilRemoteEpisode(_MemoryStore remote, int episode) async {
    await pollUntil(
      remote,
      () =>
          remote.remoteDoc?.history.any((e) => e['episode'] == episode) ??
          false,
      what: '远端文档出现第 $episode 集',
    );
  }

  group('手动同步（双向合并）', () {
    test('首次同步：本地数据上传云端，无旧远端不留远端 .bak', () async {
      final remote = _MemoryStore();
      final svc = await service(remote: remote);
      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 3,
        episodes: 10,
        episodeId: 'e3',
        position: 120,
      );

      final report = await svc.syncNow();

      expect(report.uploaded, isTrue);
      expect(report.remoteExisted, isFalse);
      expect(remote.putPaths, [WatchSyncService.remoteDocPath]);
      expect(remote.remoteDoc?.history.single['series_id'], 's1');
      expect(
        remote.objects.containsKey('${WatchSyncService.remoteDocPath}.bak'),
        isFalse,
        reason: '云端原本没有文档，没有可保的旧文档',
      );
      // 本地没有要写的增量：不留本地快照。
      expect(
        File('${storeDir.path}/aquan_history.json.bak').existsSync(),
        isFalse,
      );
    });

    test('内容签名相同 → 跳过上传（连续两次同步只 PUT 一次）', () async {
      final remote = _MemoryStore();
      final svc = await service(remote: remote);
      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 1,
        episodes: 10,
        episodeId: 'e1',
        position: 30,
      );

      await svc.syncNow();
      expect(remote.putAttempts, 1);
      final second = await svc.syncNow();
      expect(second.uploaded, isFalse);
      expect(second.summary, contains('无需变更'));
      expect(remote.putAttempts, 1, reason: '内容没变不重复上传');
      expect(remote.getAttempts, 2);
    });

    test('远端较新 → 合并进本地；合并结果与远端一致则不回传', () async {
      final remote = _MemoryStore();
      remote.objects[WatchSyncService.remoteDocPath] = utf8.encode(
        jsonEncode(
          remoteDocJson(
            history: [entry('s1', updatedAt: futureStamp(), episode: 9)],
          ).toJson(),
        ),
      );
      final svc = await service(remote: remote);
      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 1,
        episodes: 10,
        episodeId: 'e1',
        position: 30,
      );

      final report = await svc.syncNow();

      expect(report.historyApplied, 1);
      expect(report.uploaded, isFalse, reason: '合并结果 == 远端内容，签名相同跳写');
      expect(svc.history.get('s1')?.episode, 9, reason: '远端进度已进本地');
    });

    test('远端墓碑命中 → 删除本地条目（不复活）', () async {
      final remote = _MemoryStore();
      final deletedAt = DateTime.now()
          .add(const Duration(days: 2))
          .millisecondsSinceEpoch;
      remote.objects[WatchSyncService.remoteDocPath] = utf8.encode(
        jsonEncode(
          remoteDocJson(
            tombstones: [
              WatchTombstone(
                kind: WatchEntryKind.history,
                id: 's1',
                deletedAt: deletedAt,
              ),
            ],
          ).toJson(),
        ),
      );
      final svc = await service(remote: remote);
      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 1,
        episodes: 10,
        episodeId: 'e1',
        position: 30,
      );

      final report = await svc.syncNow();

      expect(report.historyRemoved, 1);
      expect(report.uploaded, isFalse, reason: '合并结果 == 远端（条目没了只剩墓碑）');
      expect(svc.history.get('s1'), isNull);
    });

    test('上传前快照兜底：旧远端文档留 .bak、本地 JSON 同目录留 .bak', () async {
      final remote = _MemoryStore();
      final svc = await service(remote: remote);
      // 第一轮：本地上传（建立远端基线）。
      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 1,
        episodes: 10,
        episodeId: 'e1',
        position: 30,
      );
      await svc.syncNow();

      // 第二轮：远端有更新的条目要写进本地 → 触发两侧快照。
      remote.objects[WatchSyncService.remoteDocPath] = utf8.encode(
        jsonEncode(
          remoteDocJson(
            history: [entry('s1', updatedAt: futureStamp(), episode: 8)],
          ).toJson(),
        ),
      );
      final report = await svc.syncNow();

      expect(report.historyApplied, 1);
      expect(report.uploaded, isFalse);
      expect(
        remote.objects.containsKey('${WatchSyncService.remoteDocPath}.bak'),
        isFalse,
        reason: '本轮没有上传：远端 .bak 在真正上传前才写',
      );
      // 本地 JSON 快照：应用远端数据前各留一份。
      expect(
        File('${storeDir.path}/aquan_history.json.bak').existsSync(),
        isTrue,
      );
    });

    test('本地有新内容时的上传会先留旧远端 .bak', () async {
      final remote = _MemoryStore();
      final svc = await service(remote: remote);
      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 1,
        episodes: 10,
        episodeId: 'e1',
        position: 30,
      );
      await svc.syncNow(); // 上传 v1
      final v1 = remote.objects[WatchSyncService.remoteDocPath]!;

      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 2,
        episodes: 10,
        episodeId: 'e2',
        position: 45,
      );
      final report = await svc.syncNow(); // 上传 v2

      expect(report.uploaded, isTrue);
      expect(remote.putPaths, [
        WatchSyncService.remoteDocPath,
        '${WatchSyncService.remoteDocPath}.bak',
        WatchSyncService.remoteDocPath,
      ], reason: '上传顺序：先 .bak（旧文档）再新文档');
      expect(remote.objects['${WatchSyncService.remoteDocPath}.bak'], v1);
    });

    test('本地删除记墓碑：落盘保留并随同步上传（远端据此删其他设备）', () async {
      final remote = _MemoryStore();
      final svc = await service(remote: remote);
      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 1,
        episodes: 10,
        episodeId: 'e1',
        position: 30,
      );
      await svc.syncNow();
      expect(remote.remoteDoc?.history, hasLength(1));

      await svc.history.remove('s1');
      // 钩子异步写墓碑文件，稍等落定。
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final tombstoneFile = File(
        '${support.path}/${WatchSyncService.tombstonesFile}',
      );
      expect(tombstoneFile.existsSync(), isTrue);
      final stored =
          jsonDecode(tombstoneFile.readAsStringSync()) as Map<String, dynamic>;
      expect((stored['tombstones'] as List), hasLength(1));

      final report = await svc.syncNow();
      expect(report.uploaded, isTrue);
      expect(remote.remoteDoc?.history, isEmpty);
      expect(remote.remoteDoc?.tombstones.single.id, 's1');
      expect(remote.remoteDoc?.tombstones.single.kind, WatchEntryKind.history);
    });

    test('追剧删除走同一墓碑链路（FollowStore.remove）', () async {
      final remote = _MemoryStore();
      final svc = await service(remote: remote);
      await svc.follows.follow(
        seriesId: 'f1',
        title: '剧',
        coverUrl: '',
        episodeCount: 10,
      );
      await svc.syncNow();

      await svc.follows.remove('f1');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final report = await svc.syncNow();

      expect(report.uploaded, isTrue);
      expect(remote.remoteDoc?.tombstones.single.kind, WatchEntryKind.follow);
    });

    test('未配置远端 → 明确报错（提示先配置）', () async {
      // 无 storeOverride：走真实 SyncConfigStore（mock prefs 为空）。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('sync.config.v1'), isNull);
      final svc = WatchSyncService(
        history: HistoryStore(testDirectory: storeDir),
        follows: FollowStore(testDirectory: storeDir),
        settings: await settings(),
        supportDirOverride: support,
      );
      svc.start();
      await expectLater(svc.syncNow(), throwsA(isA<RemoteStoreException>()));
    });
  });

  group('自动同步（sync.watchAuto）', () {
    test('变更后 15s 窗口节流：窗口结束触发一次上传', () async {
      final remote = _MemoryStore();
      final svc = await service(remote: remote, auto: true);
      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 1,
        episodes: 10,
        episodeId: 'e1',
        position: 30,
      );
      await pollUntil(
        remote,
        () => remote.putAttempts >= 1,
        what: '窗口结束自动上传一次',
      );
      // 上传完成后再过一个窗口：确认节流没有叠出第二轮（窗口 50ms）。
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(remote.putAttempts, 1, reason: '窗口结束自动上传一次');
      // 叠出第二轮时内容没变会签名跳写，PUT 仍是 1：必须看 GET 次数。
      expect(remote.getAttempts, 1, reason: '节流不叠出第二轮');
      expect(remote.remoteDoc?.history.single['series_id'], 's1');
    });

    test('窗口内的多次变更收敛为有限轮次且最终状态上云', () async {
      final remote = _MemoryStore();
      final svc = await service(
        remote: remote,
        auto: true,
        throttleWindow: const Duration(seconds: 2),
      );
      for (var i = 1; i <= 3; i++) {
        await svc.history.record(
          seriesId: 's1',
          title: '剧',
          coverUrl: '',
          episode: i,
          episodes: 10,
          episodeId: 'e$i',
          position: 30,
        );
      }
      // CI 负载下 record 的落盘通知时机不可控，窗口边界跨越按设计补一轮——
      // 断「最终状态完整上云 + 轮数不失控」，不断精确节奏（50ms 级编排
      // 在 CI 上正反两个方向都会偶发翻车，9dbab12 语义断言仍被 3 轮击穿）。
      await pollUntilRemoteEpisode(remote, 3);
      // 老形态 bug 是「每条变更叠出一轮」（3 条变更 → 4+ 轮）或防抖永不触发
      // （远端始终为空、轮询超时）；2s 大窗口下正常收敛 1 轮，补轮少量放行。
      expect(remote.getAttempts, lessThanOrEqualTo(3));
      expect(remote.putAttempts, lessThanOrEqualTo(3));
      expect(remote.remoteDoc?.history.single['episode'], 3);
    });

    test('开关关闭时变更不触发自动同步', () async {
      SharedPreferences.setMockInitialValues({'sync.watchAuto': false});
      final remote = _MemoryStore();
      final svc = await service(remote: remote);
      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 1,
        episodes: 10,
        episodeId: 'e1',
        position: 30,
      );
      // 反向断言：「没有发生」无法轮询，只能靠时间窗观察。
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(remote.getAttempts, 0);
    });

    test('应用远端合并结果不自我触发下一轮（不死循环）', () async {
      final remote = _MemoryStore();
      remote.objects[WatchSyncService.remoteDocPath] = utf8.encode(
        jsonEncode(
          remoteDocJson(
            history: [entry('s1', updatedAt: futureStamp(), episode: 9)],
          ).toJson(),
        ),
      );
      final svc = await service(remote: remote, auto: true);
      await svc.history.record(
        seriesId: 's2',
        title: '另一部',
        coverUrl: '',
        episode: 1,
        episodes: 10,
        episodeId: 'e1',
        position: 30,
      );
      await pollUntil(
        remote,
        () =>
            remote.remoteDoc?.history.any((e) => e['series_id'] == 's2') ??
            false,
        what: '合并后一轮上传完成（s2 落到云端）',
      );
      // 沉降窗口：自同步死循环会在这段时间内叠出额外 GET/PUT。
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(remote.getAttempts, 1, reason: '应用远端数据触发的通知被忽略');
      // 上传 1 轮 = 旧文档 .bak + 新文档共 2 次 PUT（远端已有文档时）。
      expect(remote.putAttempts, 2);
    });

    test('失败后进入冷却：窗口内不再自动重试，冷却过后恢复', () async {
      final remote = _MemoryStore(failPutTimes: 1);
      final svc = await service(remote: remote, auto: true);
      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 1,
        episodes: 10,
        episodeId: 'e1',
        position: 30,
      );
      await pollUntil(remote, () => remote.putAttempts >= 1, what: '第一次尝试失败');
      expect(remote.putAttempts, 1, reason: '第一次尝试失败');

      // 冷却期内的新变更：窗口照排，但触发时被冷却拦下。
      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 2,
        episodes: 10,
        episodeId: 'e2',
        position: 40,
      );
      // 没有发生的事无法轮询：窗口 50ms，观察 250ms（≈5 个窗口）
      // 覆盖冷却期内的触发点。
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(remote.getAttempts, 1, reason: '失败后 300ms 冷却内不重试');

      // 冷却过期后再变更：恢复自动同步。
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 3,
        episodes: 10,
        episodeId: 'e3',
        position: 50,
      );
      await pollUntil(
        remote,
        () => remote.remoteDoc?.history.any((e) => e['episode'] == 3) ?? false,
        what: '冷却过后恢复自动同步',
      );
      expect(remote.getAttempts, 2);
      // putAttempts 含失败的那次（替身在自增后抛错）：失败 1 + 恢复成功 1。
      expect(remote.putAttempts, 2);
      expect(remote.remoteDoc?.history.single['episode'], 3);
    });

    test('同步进行中收到新变更 → 最终状态上云（补轮或新窗口，不丢变更）', () async {
      final remote = _MemoryStore(getDelay: const Duration(milliseconds: 500));
      final svc = await service(remote: remote, auto: true);
      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 1,
        episodes: 10,
        episodeId: 'e1',
        position: 30,
      );
      // 第一轮 get 延迟 500ms 期间再改一次：变更无论落在「同步进行中」
      // （_pending 补轮）还是落在轮间隙（按新窗口重排），最终都必须上云。
      // record 自身完成时机在 CI 负载下不可控，因此不依赖精确落点。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await svc.history.record(
        seriesId: 's1',
        title: '剧',
        coverUrl: '',
        episode: 2,
        episodes: 10,
        episodeId: 'e2',
        position: 40,
      );
      await pollUntilRemoteEpisode(remote, 2);
      expect(remote.getAttempts, inInclusiveRange(1, 3));
      expect(remote.remoteDoc?.history.single['episode'], 2);
    });
  });
}
