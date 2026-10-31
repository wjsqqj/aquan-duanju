/// HTTP TTS 源的**多源列表**：增删改选 + 旧单源配置迁移。
///
/// 为什么需要它：`listen.tts.source` 只能存一份，用户接了自建 GPT-SoVITS 后想再挂一个
/// 云端网关就得整段重贴。列表把「配置」和「当前选中」分开存：
/// - `listen.tts.sources`：JSON 数组（顺序即展示顺序）；
/// - `listen.tts.sourceId`：当前选中 id（不存在时回落到第一条）。
///
/// 旧键 `listen.tts.source`（单份）**只读兼容**：[list] 会把它当作一条兜底返回，
/// [ensureMigrated] 才真正搬进列表并删旧键 —— 这样即使迁移前断电也不会丢配置。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'http_tts_source.dart';

class TtsSourceStore {
  const TtsSourceStore(this._prefs);

  final SharedPreferences _prefs;

  /// JSON 数组，每项与 `HttpTtsSource.tryParse` 的入参同形。
  static const String sourcesKey = 'listen.tts.sources';

  /// 当前选中的源 id。
  static const String activeIdKey = 'listen.tts.sourceId';

  /// 旧版单源键（只读兼容，迁移后删除）。
  static const String legacyKey = 'listen.tts.source';

  /// 列表里的所有合法源（坏条目静默跳过，绝不让一条脏数据挡住整页）。
  ///
  /// 列表为空但旧单源键有值时，返回那条兜底 —— 迁移由 [ensureMigrated] 负责。
  List<HttpTtsSource> list() {
    final raw = _prefs.getString(sourcesKey);
    final out = <HttpTtsSource>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            final source = HttpTtsSource.tryParse(item);
            if (source != null) out.add(source);
          }
        }
      } catch (_) {
        // 整段坏了就当空列表，旧单源键还能兜底。
      }
    }
    if (out.isEmpty) {
      final legacy = HttpTtsSource.tryParse(_prefs.getString(legacyKey));
      if (legacy != null) out.add(legacy);
    }
    return out;
  }

  /// 当前选中的源；没有可用源时为 null。
  HttpTtsSource? get active {
    final sources = list();
    if (sources.isEmpty) return null;
    final id = _prefs.getString(activeIdKey) ?? '';
    for (final source in sources) {
      if (source.id == id) return source;
    }
    // 选中项被删/从未选过：回落到第一条（而不是让播放直接失败）。
    return sources.first;
  }

  /// 新增或按 id 覆盖（保持原有位置，不产生重复）。
  Future<void> upsert(HttpTtsSource source) async {
    final sources = list();
    final index = sources.indexWhere((s) => s.id == source.id);
    if (index >= 0) {
      sources[index] = source;
    } else {
      sources.add(source);
    }
    await _write(sources);
    // 第一次添加：顺手选中它，避免"存了但不生效"。
    if ((_prefs.getString(activeIdKey) ?? '').isEmpty) {
      await select(source.id);
    }
  }

  /// 删除；若删的正是当前选中项，选回落到的第一条（没有就清空）。
  Future<void> remove(String id) async {
    final sources = list()..removeWhere((s) => s.id == id);
    await _write(sources);
    if ((_prefs.getString(activeIdKey) ?? '') == id) {
      if (sources.isEmpty) {
        await _prefs.remove(activeIdKey);
      } else {
        await select(sources.first.id);
      }
    }
  }

  /// 选中某个 id；不存在则忽略（不改写选中项，避免指向空气）。
  Future<void> select(String id) async {
    final exists = list().any((s) => s.id == id);
    if (!exists) return;
    await _prefs.setString(activeIdKey, id);
  }

  /// 把旧单源键搬进列表（一次性）；已迁移过则什么都不做。
  Future<void> ensureMigrated() async {
    if ((_prefs.getString(sourcesKey) ?? '').isNotEmpty) return;
    final legacy = HttpTtsSource.tryParse(_prefs.getString(legacyKey));
    if (legacy == null) return;
    await _write(<HttpTtsSource>[legacy]);
    await _prefs.setString(activeIdKey, legacy.id);
    await _prefs.remove(legacyKey);
  }

  Future<void> _write(List<HttpTtsSource> sources) async {
    if (sources.isEmpty) {
      await _prefs.remove(sourcesKey);
      return;
    }
    final encoded = jsonEncode(
      sources.map((s) => s.toJson()).toList(growable: false),
    );
    await _prefs.setString(sourcesKey, encoded);
  }
}
