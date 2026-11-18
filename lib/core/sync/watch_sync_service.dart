/// 短剧数据云同步服务：追剧 / 观看历史 / 每集进度（HistoryStore + FollowStore）。
///
/// 与书库同步（[BookSyncService]，zip 全量包）完全独立：
/// - 云端为单 JSON 文档 `aquan-watch-sync.json`，一次 GET + 一次 PUT 完成双向合并；
/// - 合并算法在 `watch_sync_document.dart`（纯函数，单测覆盖）；
/// - 本地删除经墓碑传播（180 天过期、2000 条上限），远端墓碑命中删本地；
/// - 上传前快照兜底：远端旧文档 `.bak`、本地 JSON 同目录 `.bak`。
///
/// 自动同步：`sync.watchAuto`（默认关）开启后监听两个 store 的变更通知
/// （ChangeNotifier，非轮询），15s 窗口节流——播放中每 5s 一次的进度写盘
/// 不会把窗口无限推后（纯 debounce 在连播场景永远触发不了），也不会打满
/// WebDAV 请求额度；失败后 15min 冷却，期间不再自动重试。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../store/stores.dart';
import '../error_log.dart';
import 'book_sync.dart' show SyncConfigStore;
import 'remote_store.dart';
import 'watch_sync_document.dart';

/// 同步结果（UI 展示用）。
class WatchSyncReport {
  const WatchSyncReport({
    this.deferred = false,
    this.uploaded = false,
    this.remoteExisted = false,
    this.historyApplied = 0,
    this.followsApplied = 0,
    this.historyRemoved = 0,
    this.followsRemoved = 0,
  });

  /// 已有同步在进行，本轮挂起（结束后自动补一轮）。
  final bool deferred;

  /// 是否向云端上传了新文档。
  final bool uploaded;

  /// 云端原本是否有文档。
  final bool remoteExisted;

  /// 从远端合并进本地的条数（真实写入生效数）。
  final int historyApplied;
  final int followsApplied;

  /// 按远端墓碑删除的本地条数。
  final int historyRemoved;
  final int followsRemoved;

  bool get changed =>
      uploaded ||
      historyApplied > 0 ||
      followsApplied > 0 ||
      historyRemoved > 0 ||
      followsRemoved > 0;

  String get summary {
    if (deferred) return '已有同步在进行，完成后自动补一轮';
    if (!changed) return '远端与本地一致，无需变更';
    final parts = <String>[
      if (historyApplied > 0) '历史 +$historyApplied 条',
      if (followsApplied > 0) '追剧 +$followsApplied 条',
      if (historyRemoved + followsRemoved > 0)
        '按云端删除 ${historyRemoved + followsRemoved} 条',
    ];
    return '已合并：${parts.join('，')}${uploaded ? '；已上传云端' : ''}';
  }
}

/// 短剧数据云同步服务。
class WatchSyncService {
  WatchSyncService({
    required this.history,
    required this.follows,
    this._settings,
    this._configStore,
    this._storeOverride,
    this._supportDirOverride,
    this.throttleWindow = const Duration(seconds: 15),
    this.failureCooldown = const Duration(minutes: 15),
    int Function()? nowMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 云端文档路径（与书库 `backup-*.zip` 不同名，互不覆盖）。
  static const String remoteDocPath = 'aquan-watch-sync.json';
  static const String remoteBakPath = '$remoteDocPath.bak';

  /// 本地墓碑状态文件（删除记录跨重启保留，否则重启后的同步会复活已删条目）。
  static const String tombstonesFile = 'aquan_watch_tombstones.json';

  static const String historyFile = 'aquan_history.json';
  static const String followsFile = 'aquan_follows.json';

  HistoryStore history;
  FollowStore follows;
  final SettingsStore? _settings;

  /// 懒创建（首次同步时落到 SharedPreferences）；测试可注入替身。
  SyncConfigStore? _configStore;
  final RemoteStore? _storeOverride;
  final Directory? _supportDirOverride;
  final int Function() _nowMs;

  /// 变更节流窗口（窗口内首次变更排队，窗口结束触发一次）。
  final Duration throttleWindow;

  /// 自动同步失败冷却期。
  final Duration failureCooldown;

  // ---- 进程内单例（main.dart bootstrap 启动；SyncScreen 复用） ----

  static WatchSyncService? _active;

  /// 当前已启动的实例；null = 未接线（测试环境自行构造临时实例）。
  static WatchSyncService? get maybeActive => _active;

  bool _started = false;
  Timer? _throttleTimer;
  bool _running = false;
  bool _pendingAuto = false;
  bool _inSyncRun = false;
  int? _lastFailureAt;
  List<WatchTombstone> _tombstones = <WatchTombstone>[];
  Future<void>? _tombstonesLoad;
  Future<void> _tombstoneWriteQueue = Future<void>.value();

  void Function(String)? _historyHook;
  void Function(String)? _followHook;

  /// 接线：注册删除钩子（墓碑）+ 变更监听（自动同步触发源）。
  void start() {
    if (_started) return;
    _started = true;
    _active = this;
    _historyHook = (id) => _recordTombstone(WatchEntryKind.history, id);
    _followHook = (id) => _recordTombstone(WatchEntryKind.follow, id);
    history.onEntryRemoved = _historyHook;
    follows.onEntryRemoved = _followHook;
    history.addListener(_onStoresChanged);
    follows.addListener(_onStoresChanged);
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    if (identical(_active, this)) _active = null;
    _throttleTimer?.cancel();
    _throttleTimer = null;
    history.removeListener(_onStoresChanged);
    follows.removeListener(_onStoresChanged);
    // 钩子可能已被其他实例覆盖（仅测试会如此）：只在还是自己的时候清掉。
    if (identical(history.onEntryRemoved, _historyHook)) {
      history.onEntryRemoved = null;
    }
    if (identical(follows.onEntryRemoved, _followHook)) {
      follows.onEntryRemoved = null;
    }
    _historyHook = null;
    _followHook = null;
  }

  bool get _autoEnabled => _settings?.syncWatchAuto ?? false;

  /// store 变更通知 → 自动同步触发源（非轮询）。
  ///
  /// 同步过程自身触发的通知（读盘加载、应用远端合并结果）忽略，
  /// 否则自己同步自己（死循环）。同步间隙用户恰好改了数据且之后再无
  /// 变更的极小窗口由播放进度 5s 一写的节奏自愈。
  void _onStoresChanged() {
    if (_inSyncRun) return;
    if (!_started || !_autoEnabled) return;
    scheduleAutoSync();
  }

  /// 排一轮自动同步：15s 窗口节流。
  ///
  /// 窗口内首次变更起计时，窗口结束触发一次；窗口内后续变更不重置计时
  /// （播放中每 5s 一次进度写盘，纯 debounce 会让连播场景一直传不上去），
  /// 也不会叠出多个窗口（节流，不打满 WebDAV 请求额度）。
  void scheduleAutoSync() {
    if (!_started || !_autoEnabled) return;
    if (_throttleTimer != null) return;
    _throttleTimer = Timer(throttleWindow, () {
      _throttleTimer = null;
      _runAuto();
    });
  }

  Future<void> _runAuto() async {
    if (!_started || !_autoEnabled) return;
    if (_running) {
      _pendingAuto = true; // 同步进行中来了新变更：结束后补一轮
      return;
    }
    final failedAt = _lastFailureAt;
    if (failedAt != null &&
        _nowMs() - failedAt < failureCooldown.inMilliseconds) {
      return; // 失败冷却期内不再自动重试（账号填错时防反复打请求）
    }
    try {
      await syncNow();
      _lastFailureAt = null;
    } catch (e, stack) {
      _lastFailureAt = _nowMs();
      ErrorLog.instance.record('短剧数据自动同步', e, stack);
    }
  }

  /// 立即同步（双向合并）。失败抛异常（手动调用方展示；自动路径自行捕获）。
  Future<WatchSyncReport> syncNow() async {
    if (_running) {
      _pendingAuto = true;
      return const WatchSyncReport(deferred: true);
    }
    _running = true;
    try {
      final report = await _runSync();
      _lastFailureAt = null;
      return report;
    } finally {
      _running = false;
      if (_pendingAuto) {
        _pendingAuto = false;
        // 同步期间本地又有变更：补一轮把最新状态传上去（只对自动路径生效：
        // 手动触发的挂起也走同一出口，变更没发生时合并结果一致、签名跳写）。
        unawaited(Future<void>.microtask(_runAuto));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 同步主流程
  // ---------------------------------------------------------------------------

  Future<WatchSyncReport> _runSync() async {
    final remote = await _resolveRemote();
    await _ensureTombstonesLoaded();
    // 读盘首次加载会 notifyListeners（「数据变了」）：这是同步自己触发的，
    // 不能唤起自动同步，短暂抑制；窗口外用户变更照常触发（进 pending）。
    _inSyncRun = true;
    try {
      await history.ensureLoaded();
      await follows.ensureLoaded();
    } finally {
      _inSyncRun = false;
    }

    // 本地文档（条目 + 本地墓碑）。
    final local = WatchSyncDocument(
      history: [for (final e in history.entries) e.toJson()],
      follows: [for (final e in follows.entries) e.toJson()],
      tombstones: List<WatchTombstone>.of(_tombstones),
    );

    // 下载远端（不存在 = 空文档）；解析失败中止同步，保护云端数据。
    final remoteBytes = await remote.get(remoteDocPath);
    final remoteDoc = remoteBytes == null
        ? WatchSyncDocument.empty()
        : WatchSyncDocument.parse(
            utf8.decode(remoteBytes, allowMalformed: true),
          );
    final nowMs = _nowMs();

    final outcome = mergeWatchDocuments(
      local: local,
      remote: remoteDoc,
      nowMs: nowMs,
    );

    // 应用到本地：先快照兜底（改之前留还原点），再删除、再合并写入。
    // 应用触发的 store 通知是同步自己造成的，短暂抑制（否则自己同步自己）；
    // 窗口极小（毫秒级写盘），窗口外用户变更照常进下一轮。
    var historyApplied = 0;
    var followsApplied = 0;
    var historyRemoved = 0;
    var followsRemoved = 0;
    if (outcome.hasLocalChanges) {
      await _snapshotLocalJson();
      _inSyncRun = true;
      try {
        historyRemoved = await _removeTombstonedHistory(
          outcome.historyTombstoneHits,
        );
        followsRemoved = await _removeTombstonedFollows(
          outcome.followsTombstoneHits,
        );
        if (outcome.historyToApply.isNotEmpty) {
          historyApplied = await history.importData({
            for (final entry in outcome.historyToApply)
              entry['series_id']?.toString() ?? '': entry,
          });
        }
        if (outcome.followsToApply.isNotEmpty) {
          followsApplied = await follows.importData({
            for (final entry in outcome.followsToApply)
              entry['series_id']?.toString() ?? '': entry,
          });
        }
      } finally {
        _inSyncRun = false;
      }
    }

    // 墓碑并集落盘（含过期清理 + 上限裁剪）。
    await _saveTombstones(outcome.document.tombstones);

    // 上传：合并结果与远端内容签名相同 → 跳过（省流量省请求）。
    var uploaded = false;
    if (outcome.document.contentSignature() != remoteDoc.contentSignature()) {
      // 快照兜底：旧远端文档留一份 `.bak`（首次上传没有旧文档，不留）。
      if (remoteBytes != null) {
        try {
          await remote.put(remoteBakPath, remoteBytes);
        } catch (_) {
          // 快照失败不阻断同步（有本地 JSON 快照兜底）。
        }
      }
      final payload = outcome.document.toJson();
      payload['exportedAt'] = _nowMs(); // 不参与签名，纯记录
      await remote.put(remoteDocPath, utf8.encode(jsonEncode(payload)));
      uploaded = true;
    }

    return WatchSyncReport(
      uploaded: uploaded,
      remoteExisted: remoteBytes != null,
      historyApplied: historyApplied,
      followsApplied: followsApplied,
      historyRemoved: historyRemoved,
      followsRemoved: followsRemoved,
    );
  }

  Future<RemoteStore> _resolveRemote() async {
    final override = _storeOverride;
    if (override != null) return override;
    final configStore = _configStore ??= SyncConfigStore();
    final config = await configStore.load();
    if (!config.isConfigured) {
      throw const RemoteStoreException('短剧同步未配置：请先在上方配置 WebDAV / S3');
    }
    return config.buildStore();
  }

  // ---------------------------------------------------------------------------
  // 远端墓碑 → 删本地（带复活检查）
  // ---------------------------------------------------------------------------

  Future<int> _removeTombstonedHistory(List<WatchTombstone> hits) async {
    var removed = 0;
    for (final t in hits) {
      final entry = history.get(t.id);
      if (entry == null) continue;
      // 同步间隙用户又看了这部剧（条目比墓碑新）→ 视为复活，跳过删除。
      if (entry.updatedAt.millisecondsSinceEpoch > t.deletedAt) continue;
      await history.remove(t.id);
      removed++;
    }
    return removed;
  }

  Future<int> _removeTombstonedFollows(List<WatchTombstone> hits) async {
    var removed = 0;
    for (final t in hits) {
      final entry = follows.get(t.id);
      if (entry == null) continue;
      if (entry.updatedAt.millisecondsSinceEpoch > t.deletedAt) continue;
      await follows.remove(t.id);
      removed++;
    }
    return removed;
  }

  // ---------------------------------------------------------------------------
  // 墓碑状态（本地持久化）
  // ---------------------------------------------------------------------------

  /// 本地删除钩子（store 注入）：记墓碑并落盘。
  ///
  /// 同步过程内（含应用远端墓碑）触发的删除不重复记录（不然 deletedAt
  /// 被刷新成「现在」，
  /// 本地墓碑会晚于远端，语义混乱）。
  void _recordTombstone(WatchEntryKind kind, String id) {
    if (_inSyncRun || id.isEmpty) return;
    unawaited(_recordTombstoneAsync(kind, id));
  }

  Future<void> _recordTombstoneAsync(WatchEntryKind kind, String id) async {
    try {
      await _ensureTombstonesLoaded();
      final tombstone = WatchTombstone(kind: kind, id: id, deletedAt: _nowMs());
      final index = _tombstones.indexWhere((t) => t.kind == kind && t.id == id);
      if (index >= 0) {
        _tombstones[index] = tombstone;
      } else {
        _tombstones.add(tombstone);
      }
      await _saveTombstones(_tombstones);
    } catch (e, stack) {
      // 墓碑写失败不阻断用户操作（删除本身已生效）。
      ErrorLog.instance.record('短剧墓碑记录', e, stack);
    }
  }

  Future<void> _ensureTombstonesLoaded() {
    return _tombstonesLoad ??= _loadTombstones();
  }

  Future<void> _loadTombstones() async {
    try {
      final file = File(
        '${(await _supportDir()).path}'
        '${Platform.pathSeparator}$tombstonesFile',
      );
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map<String, dynamic>) return;
      final list = raw['tombstones'];
      if (list is! List) return;
      final loaded = <WatchTombstone>[];
      for (final item in list) {
        final tombstone = WatchTombstone.tryFromJson(item);
        if (tombstone != null) loaded.add(tombstone);
      }
      _tombstones = loaded;
    } catch (_) {
      // 坏文件当空表（不阻断同步；下次删除会重建）。
      _tombstones = <WatchTombstone>[];
    }
  }

  Future<void> _saveTombstones(List<WatchTombstone> tombstones) {
    _tombstones = List<WatchTombstone>.of(tombstones);
    final task = _tombstoneWriteQueue.then((_) async {
      _tombstones = _pruneTombstones(_tombstones, nowMs: _nowMs());
      final file = File(
        '${(await _supportDir()).path}'
        '${Platform.pathSeparator}$tombstonesFile',
      );
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'version': WatchSyncDocument.currentVersion,
          'tombstones': [for (final t in _tombstones) t.toJson()],
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    });
    _tombstoneWriteQueue = task.catchError((_) {});
    return task;
  }

  /// 过期清理（180 天）+ 数量上限（超限清最老）。
  List<WatchTombstone> _pruneTombstones(
    List<WatchTombstone> tombstones, {
    required int nowMs,
  }) {
    final retentionMs = WatchSyncDocument.tombstoneRetention.inMilliseconds;
    final kept = [
      for (final t in tombstones)
        if (t.deletedAt > 0 && nowMs - t.deletedAt <= retentionMs) t,
    ];
    if (kept.length > WatchSyncDocument.tombstoneLimit) {
      kept.sort((a, b) => a.deletedAt.compareTo(b.deletedAt));
      return kept.sublist(kept.length - WatchSyncDocument.tombstoneLimit);
    }
    return kept;
  }

  // ---------------------------------------------------------------------------
  // 快照兜底
  // ---------------------------------------------------------------------------

  /// 写本地数据前，把两个状态 JSON 各留一份（同目录 `.bak`）。
  Future<void> _snapshotLocalJson() async {
    final dir = await _supportDir();
    for (final name in [historyFile, followsFile]) {
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      try {
        if (await file.exists()) {
          await file.copy('${file.path}.bak');
        }
      } catch (_) {
        // 快照失败不阻断同步。
      }
    }
  }

  Future<Directory> _supportDir() async =>
      _supportDirOverride ?? await getApplicationSupportDirectory();
}
