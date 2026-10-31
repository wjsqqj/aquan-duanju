/// TTS 音频 + 时间点的成对落盘缓存。
///
/// 目录沿用听书音轨的约定（`.trellis/spec/backend/reading-contract.md`）：
/// `<设备档案目录>/audio_cache/<bookId>/<chapterId>-<engineId>-<voiceId>.mp3`
/// 与同名 `.jsonl`。音轨链路的缓存在 core 里下载，这里没有 core 可写，
/// 所以在 Dart 侧维护同一个目录，清理与盘点能跟现有缓存放在一起看。
///
/// 两条不能让步的规则：
/// 1. **键含引擎与音色，不含倍速**：时间点存的是媒体时间轴，倍速由播放器实现。
///    把倍速放进键会让每改一次语速全量重合成（Legado_Max 的实证反模式：
///    `md5(章标题)_md5(引擎url-|-语速-|-段落原文)` 含语速却不含音色 → 改语速重建、
///    换音色仍播旧音频）；反过来音色不进键就会串音色。
/// 2. **无效项成对删除**：只删音频会留下时间点孤儿，只删时间点会留下
///    「音频在、点没了」的半截命中 —— Legado_Max 把静音占位字节固化进
///    SimpleCache 正是这类的坑，这里不允许它发生。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../reader/content_signature.dart';
import 'mp3_frames.dart';
import 'speech_timeline_store.dart';
import 'tts_models.dart';

/// 缓存相关的集中常量。配额可被设置 `listen.tts.quotaMb` 覆盖，其余不建议改。
class TtsCacheLimits {
  const TtsCacheLimits._();

  /// 默认配额（MB），与 design.md §8 的设置默认值一致。
  static const int defaultQuotaMb = 200;

  /// 有效音频的最小字节数。48kbps 下约 170ms —— 一整章不可能这么短，
  /// 低于它只能是截断写入或占位字节。
  static const int minAudioBytes = 1024;

  /// 判定「是不是 mp3」时最多读多少字节（避免为校验复制整个章节）。
  static const int probeBytes = 65536;

  /// 文件名里音色 id 的最大长度（Edge 短名远小于此，纯护栏：Windows 路径长度有限）。
  static const int maxVoiceIdChars = 48;
}

/// 一次缓存命中。
class TtsCacheHit {
  const TtsCacheHit({
    required this.audioPath,
    required this.timelinePath,
    required this.timeline,
    required this.audioBytes,
  });

  final String audioPath;
  final String timelinePath;
  final SpeechTimeline timeline;
  final int audioBytes;
}

/// 缓存条目的坐标。四个要素合起来唯一确定一份产物（**没有倍速**）。
class TtsCacheKey {
  const TtsCacheKey({
    required this.bookId,
    required this.chapterId,
    required this.engineId,
    required this.voiceId,
  });

  final String bookId;
  final String chapterId;
  final String engineId;
  final String voiceId;

  /// 文件名主干（不含扩展名）。每一段都是键要素，所以「换音色重新合成」与
  /// 「改倍速不重新合成」不需要任何额外判断 —— 倍速根本没有入口。
  String get stem =>
      '${_sanitize(chapterId)}-${_sanitize(engineId)}'
      '-${_sanitize(voiceId, maxLength: TtsCacheLimits.maxVoiceIdChars)}';

  /// 路径里的 id 只保留安全字符。书籍/章节 id 是数字串、音色是短名，
  /// 正常输入不会被改动；外来 id 被塞进路径时也不会跳出目录。
  static String _sanitize(String value, {int maxLength = 64}) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safe.isEmpty) return 'x';
    return safe.length <= maxLength ? safe : safe.substring(0, maxLength);
  }
}

/// 一本书的目录占用（配额裁决用）。
class _BookUsage {
  _BookUsage(this.dir, this.bytes, this.lastAccessMs);

  final Directory dir;
  final int bytes;
  final int lastAccessMs;
}

class TtsCache {
  TtsCache({
    Future<Directory> Function()? rootDirectory,
    this.quotaMb = TtsCacheLimits.defaultQuotaMb,
    int? maxBytes,
    DateTime Function()? clock,
    this.store = const SpeechTimelineStore(),
  }) : _rootDirectory = rootDirectory ?? _defaultRoot,

       _maxBytesOverride = maxBytes,
       _clock = clock ?? DateTime.now;

  static Future<Directory> _defaultRoot() => getApplicationSupportDirectory();

  final Future<Directory> Function() _rootDirectory;
  final int quotaMb;
  final int? _maxBytesOverride;
  final DateTime Function() _clock;
  final SpeechTimelineStore store;

  /// 音频总字节上限。`maxBytes` 只为测试注入小上限而存在。
  int get maxBytes {
    final override = _maxBytesOverride;
    if (override != null && override > 0) return override;
    return (quotaMb < 1 ? 1 : quotaMb) * 1024 * 1024;
  }

  /// 正文指纹：与分页缓存、章节缓存同一口径（FNV-1a，`contentSignature`）。
  /// 源站改正文 → 指纹变 → 旧产物判无效重合成。段落以 `'\n'` 相接，与朗读坐标系一致。
  String signatureOf(List<String> paragraphs) =>
      paragraphsSignature(paragraphs);

  /// `<audio_cache>` 目录（与音轨缓存同名，按书分子目录）。
  Future<Directory> audioCacheDir() async {
    final root = await _rootDirectory();
    final dir = Directory('${root.path}${Platform.pathSeparator}audio_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 查缓存。命中要求音频与时间点**都**有效且指纹匹配；任一不满足即成对删除并返回 null。
  ///
  /// 不做「只有音频就先播、没高亮也行」的降级：那正是把占位/截断字节固化下来的入口。
  Future<TtsCacheHit?> lookup(
    TtsCacheKey key, {
    required String textSignature,
    /// 音频容器扩展名（`mp3` / `wav` …）。由引擎的 `caps.container` 决定：
    /// WinRT 系统 TTS 与 Piper 产出的是 wav，按 mp3 去校验会把好文件判坏。
    String extension = 'mp3',
  }) async {
    final dir = await _bookDir(key.bookId);
    if (!await dir.exists()) return null;
    final audio = _audioFile(dir, key, extension);
    // **不存在不等于坏项**：同一 stem 可能只有另一种容器（mp3 vs wav）的产物。
    // 直接进 _validated 会让“音频缺失”走到成对删除，把别人的 .jsonl 删掉。
    if (!await audio.exists()) return null;
    final timeline = _timelineFile(dir, key);
    final parsed = await _validated(
      audio,
      timeline,
      textSignature,
      extension: extension,
    );
    if (parsed == null) {
      await _deletePair(audio, timeline);
      return null;
    }
    await _touch(key.bookId);
    return TtsCacheHit(
      audioPath: audio.path,
      timelinePath: timeline.path,
      timeline: parsed.timeline,
      audioBytes: await audio.length(),
    );
  }

  /// 写缓存（先校验再落盘），写完顺带做一次配额裁决。
  ///
  /// 校验不过就抛 [TtsException] 并删掉同名旧对：宁可不缓存，也不能让坏字节
  /// 以「已下载」的姿态留在磁盘上。
  Future<void> save(
    TtsCacheKey key, {
    required Uint8List audio,
    required SpeechTimeline timeline,
    required String textSignature,
    /// 与 [lookup] 的 `extension` 必须一致，否则会写出“查不到”的孤儿文件。
    String extension = 'mp3',
  }) async {
    final dir = await _bookDir(key.bookId);
    final audioFile = _audioFile(dir, key, extension);
    final timelineFile = _timelineFile(dir, key);
    final zero = allZeroBytes(audio);
    // 非 mp3（wav/pcm）不能按 mp3 帧头判定，只做「非空且非全零」这一层；
    // 严格到帧结构的检查只适用于 mp3 管线。
    final looksValid = extension == 'mp3' ? containsAudioFrame(audio) : true;
    if (audio.length < TtsCacheLimits.minAudioBytes || zero || !looksValid) {
      await _deletePair(audioFile, timelineFile);
      throw TtsException(
        TtsErrorCode.emptyAudio,
        message: '拒绝落盘可疑音频 bytes=${audio.length} allZero=$zero',
      );
    }
    if (timeline.isEmpty) {
      await _deletePair(audioFile, timelineFile);
      throw const TtsException(
        TtsErrorCode.invalidCache,
        message: '拒绝落盘没有时间点的内容',
      );
    }
    if (!await dir.exists()) await dir.create(recursive: true);
    await audioFile.writeAsBytes(audio, flush: true);
    await store.write(timelineFile, timeline, signature: textSignature);
    await _touch(key.bookId);
    await enforceQuota(keepBookId: key.bookId);
  }

  /// 主动失效一对文件（换音色、正文变更、播放器打不开都走它）。
  ///
  /// 删该 stem 下**所有**音频扩展名：容器换了（mp3↔wav）也不能留旧文件占地方。
  Future<void> invalidate(TtsCacheKey key) async {
    final dir = await _bookDir(key.bookId);
    await _deletePair(_audioFile(dir, key, 'mp3'), _timelineFile(dir, key));
    await _deletePair(_audioFile(dir, key, 'wav'), _timelineFile(dir, key));
  }

  /// `audio_cache` 总字节（不含 lru 台账本身）。
  Future<int> totalBytes() async {
    final usages = await _bookUsages();
    var sum = 0;
    for (final usage in usages) {
      sum += usage.bytes;
    }
    return sum;
  }

  /// 按书 LRU 清理：超出上限时从最久未访问的书开始整本删除，[keepBookId] 永不删。
  ///
  /// 粒度是「整本」而不是「单章」：同一本书反复读时局部淘汰会把缓存打散成
  /// 每章都要重新合成，收益远不如整本保留。
  Future<int> enforceQuota({String? keepBookId}) async {
    final lru = await _readLru();
    final usages = await _bookUsages(lru: lru);
    var total = 0;
    for (final usage in usages) {
      total += usage.bytes;
    }
    if (total <= maxBytes) return 0;
    usages.sort((a, b) => a.lastAccessMs.compareTo(b.lastAccessMs));
    final keep = keepBookId == null ? '' : TtsCacheKey._sanitize(keepBookId);
    var freed = 0;
    for (final usage in usages) {
      if (total - freed <= maxBytes) break;
      final id = _dirName(usage.dir);
      if (keep.isNotEmpty && id == keep) continue;
      try {
        await usage.dir.delete(recursive: true);
        freed += usage.bytes;
        lru.remove(id);
      } catch (_) {
        // 单个目录删不掉（文件正被播放器占用等）就跳过，下次再试。
      }
    }
    await _writeLru(lru);
    return freed;
  }

  /// 删掉某本书的全部缓存（「清除朗读缓存」入口用）。
  Future<void> removeBook(String bookId) async {
    final dir = await _bookDir(bookId);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    final lru = await _readLru();
    lru.remove(TtsCacheKey._sanitize(bookId));
    await _writeLru(lru);
  }

  // ---------- 内部 ----------

  Future<Directory> _bookDir(String bookId) async {
    final cache = await audioCacheDir();
    return Directory(
      '${cache.path}${Platform.pathSeparator}${TtsCacheKey._sanitize(bookId)}',
    );
  }

  File _audioFile(Directory dir, TtsCacheKey key, String extension) => File(
    '${dir.path}${Platform.pathSeparator}${key.stem}.$extension',
  );

  File _timelineFile(Directory dir, TtsCacheKey key) =>
      File('${dir.path}${Platform.pathSeparator}${key.stem}.jsonl');

  /// 有效性判定：返回解析好的时间点；任一条不满足返回 `null`（调用方成对删除）。
  ///
  /// 顺序按「便宜的检查在前」：字节数 → 全零 → 帧结构 → 时间点可解析 → 指纹。
  Future<SpeechTimelineFile?> _validated(
    File audio,
    File timeline,
    String textSignature, {
    required String extension,
  }) async {
    try {
      if (!await audio.exists()) return null;
      final bytes = await audio.length();
      if (bytes < TtsCacheLimits.minAudioBytes) return null;
      final cap = bytes < TtsCacheLimits.probeBytes
          ? bytes
          : TtsCacheLimits.probeBytes;
      final head = <int>[];
      await for (final chunk in audio.openRead(0, cap)) {
        head.addAll(chunk);
      }
      if (allZeroBytes(head)) return null;
      // 帧头检查只对 mp3 成立；wav/pcm 按帧头判会把整份合法音频判坏。
      if (extension == 'mp3' && !containsAudioFrame(head)) return null;
      if (!await timeline.exists()) return null;
      final parsed = await store.read(timeline);
      if (parsed == null) return null;
      // 我们写的文件一定带指纹；缺指纹说明是外部或旧格式产物，无法确认正文没变过。
      if (parsed.signature != textSignature) return null;
      return parsed;
    } catch (_) {
      // 读不出来的文件一律按无效处理（不能假设它还能用）。
      return null;
    }
  }

  Future<void> _deletePair(File audio, File timeline) async {
    for (final file in <File>[audio, timeline]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<List<_BookUsage>> _bookUsages({Map<String, dynamic>? lru}) async {
    final ledger = lru ?? await _readLru();
    final cache = await audioCacheDir();
    final result = <_BookUsage>[];
    if (!await cache.exists()) return result;
    await for (final entity in cache.list(followLinks: false)) {
      if (entity is! Directory) continue;
      var bytes = 0;
      var newest = 0;
      try {
        await for (final file in entity.list(followLinks: false)) {
          if (file is! File) continue;
          final stat = await file.stat();
          bytes += stat.size;
          final ms = stat.modified.millisecondsSinceEpoch;
          if (ms > newest) newest = ms;
        }
      } catch (_) {
        continue;
      }
      final id = _dirName(entity);
      final touched = (ledger[id] as num?)?.toInt() ?? 0;
      result.add(
        _BookUsage(entity, bytes, touched > newest ? touched : newest),
      );
    }
    return result;
  }

  String _dirName(Directory dir) {
    final segments = dir.path.split(Platform.pathSeparator);
    return segments.isEmpty ? '' : segments.last;
  }

  File _lruFile(Directory cache) =>
      File('${cache.path}${Platform.pathSeparator}tts_lru.json');

  Future<Map<String, dynamic>> _readLru() async {
    try {
      final file = _lruFile(await audioCacheDir());
      if (!await file.exists()) return <String, dynamic>{};
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeLru(Map<String, dynamic> lru) async {
    try {
      final file = _lruFile(await audioCacheDir());
      // 台账是整份覆盖写：先 tmp 再换名，避免半截 JSON 让所有书都被当成「从未访问」。
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(lru), flush: true);
      await tmp.rename(file.path);
    } catch (_) {}
  }

  Future<void> _touch(String bookId) async {
    final lru = await _readLru();
    lru[TtsCacheKey._sanitize(bookId)] = _clock().millisecondsSinceEpoch;
    await _writeLru(lru);
  }
}
