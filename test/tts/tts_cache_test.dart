import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aquan_duanju/core/reader/content_signature.dart';
import 'package:aquan_duanju/core/tts/speech_timeline_store.dart';
import 'package:aquan_duanju/core/tts/tts_cache.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造 [count] 个合法 MPEG 音频帧（144 字节/帧，48kbps CBR），用于过缓存的字节阈值。
Uint8List frames(int count) {
  final out = Uint8List(count * 144);
  for (var f = 0; f < count; f++) {
    final o = f * 144;
    out[o] = 0xFF;
    out[o + 1] = 0xF3;
    out[o + 2] = 0x64;
    out[o + 3] = 0x40;
    for (var j = 4; j < 144; j++) {
      out[o + j] = 0x20 + (j % 60);
    }
  }
  return out;
}

SpeechTimeline timelineOf({int audioMs = 1200}) => SpeechTimeline(
  granularity: SpeechGranularity.word,
  audioMs: audioMs,
  words: const <SpeechPoint>[
    SpeechPoint(
      startMs: 0,
      endMs: 600,
      charStart: 0,
      charEnd: 2,
      unitIndex: 0,
      text: '甲乙',
    ),
  ],
  sentences: const <SpeechPoint>[
    SpeechPoint(
      startMs: 0,
      endMs: 1200,
      charStart: 0,
      charEnd: 4,
      unitIndex: 0,
    ),
  ],
  paragraphs: const <ParagraphTiming>[
    ParagraphTiming(
      paragraphIndex: 0,
      charStart: 0,
      charEnd: 4,
      startMs: 0,
      endMs: 1200,
    ),
  ],
);

const List<String> kParagraphs = <String>['甲乙。丙丁。', '戊己。'];

void main() {
  late Directory root;
  late DateTime now;
  const store = SpeechTimelineStore();

  setUp(() {
    root = Directory.systemTemp.createTempSync('tts_cache_test');
    // 注入的时钟必须贴着真实时间：目录 mtime 是真实时间，给它 1970 年会把 LRU 顺序搅乱。
    now = DateTime.now();
  });
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  TtsCache newCache({
    int? maxBytes,
    int quotaMb = TtsCacheLimits.defaultQuotaMb,
  }) => TtsCache(
    rootDirectory: () async => root,
    maxBytes: maxBytes,
    quotaMb: quotaMb,
    clock: () => now,
  );

  TtsCacheKey keyOf({
    String bookId = '7001',
    String chapterId = '8001',
    String engineId = 'edge',
    String voiceId = 'zh-CN-XiaoxiaoNeural',
  }) => TtsCacheKey(
    bookId: bookId,
    chapterId: chapterId,
    engineId: engineId,
    voiceId: voiceId,
  );

  String signature() => paragraphsSignature(kParagraphs);

  /// `<设备档案目录>/audio_cache`。
  Future<String> cacheRoot() async =>
      '${root.path}${Platform.pathSeparator}audio_cache';

  /// `audio_cache/<bookId>`：缓存按书分目录，整本淘汰与整本清除都以它为粒度。
  Future<Directory> bookDir(String bookId) async =>
      Directory('${await cacheRoot()}${Platform.pathSeparator}$bookId');

  Future<File> fileOf(TtsCacheKey key, String extension) async {
    final dir = await bookDir(key.bookId);
    return File('${dir.path}${Platform.pathSeparator}${key.stem}$extension');
  }

  Future<void> putChapter(
    TtsCache cache,
    TtsCacheKey key, {
    int frameCount = 8,
    String? textSignature,
  }) async {
    now = now.add(const Duration(minutes: 1));
    await cache.save(
      key,
      audio: frames(frameCount),
      timeline: timelineOf(),
      textSignature: textSignature ?? signature(),
    );
  }

  group('时间点文件（JSONL）', () {
    test('首行是元信息，其余每行一个点', () {
      final text = store.encode(timelineOf(), signature: 'abcd1234');
      final lines = const LineSplitter().convert(text);
      expect(lines, hasLength(4));
      final meta = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(meta['v'], SpeechTimelineStore.schemaVersion);
      expect(meta['granularity'], 'word');
      expect(meta['audio_ms'], 1200);
      expect(meta['sig'], 'abcd1234');
      expect((jsonDecode(lines[1]) as Map<String, dynamic>)['k'], 'w');
      expect((jsonDecode(lines[2]) as Map<String, dynamic>)['k'], 's');
      expect((jsonDecode(lines[3]) as Map<String, dynamic>)['k'], 'p');
    });

    test('往返后查询结果不变', () {
      final parsed = store.decode(store.encode(timelineOf(), signature: 'xy'));
      expect(parsed, isNotNull);
      expect(parsed!.signature, 'xy');
      expect(parsed.timeline.wordAt(100)?.text, '甲乙');
      expect(parsed.timeline.paragraphAt(1100, paragraphCount: 2), 0);
      expect(parsed.pointCount, 3);
    });

    test('尾行被截断只丢那一行；一个点都不剩则判不可用', () {
      final text = store.encode(timelineOf());
      expect(store.decode('$text{"k":"w","s":')!.pointCount, 3);
      expect(store.decode('{"v":1,"granularity":"word","audio_ms":1}'), isNull);
      expect(store.decode('not json'), isNull);
      expect(store.decode(''), isNull);
    });

    test('版本不符 → 不可用（旧格式不能半半命中）', () {
      final text = store.encode(timelineOf()).replaceFirst('"v":1', '"v":99');
      expect(store.decode(text), isNull);
    });
  });

  group('成对落盘', () {
    test('save 后 lookup 命中，音频与时间点都在', () async {
      final cache = newCache();
      final key = keyOf();
      await putChapter(cache, key);
      final hit = await cache.lookup(key, textSignature: signature());
      expect(hit, isNotNull);
      expect(hit!.audioBytes, 8 * 144);
      expect(hit.timeline.granularity, SpeechGranularity.word);
      expect(hit.timeline.audioMs, 1200);
      expect(hit.timeline.words.single.text, '甲乙');
      expect(File(hit.audioPath).existsSync(), isTrue);
      expect(File(hit.timelinePath).existsSync(), isTrue);
      // 目录约定：<设备档案目录>/audio_cache/<bookId>/<chapterId>-<engineId>-<voiceId>.mp3
      expect(hit.audioPath, contains('audio_cache'));
      expect(hit.audioPath, contains('7001'));
      expect(
        hit.audioPath.endsWith('8001-edge-zh-CN-XiaoxiaoNeural.mp3'),
        isTrue,
      );
      expect(
        hit.timelinePath.endsWith('8001-edge-zh-CN-XiaoxiaoNeural.jsonl'),
        isTrue,
      );
    });

    test('换音色是另一条目（旧条目不被牵连）', () async {
      final cache = newCache();
      final saved = keyOf();
      await putChapter(cache, saved);
      final other = keyOf(voiceId: 'zh-CN-YunxiNeural');
      expect(await cache.lookup(other, textSignature: signature()), isNull);
      expect(await cache.lookup(saved, textSignature: signature()), isNotNull);
      expect((await fileOf(saved, '.mp3')).existsSync(), isTrue);
    });

    test('换引擎也是另一条目', () async {
      final cache = newCache();
      await putChapter(cache, keyOf());
      expect(
        await cache.lookup(
          keyOf(engineId: 'azure'),
          textSignature: signature(),
        ),
        isNull,
      );
    });

    test('倍速不进键：条目主干只有 章节-引擎-音色', () async {
      final cache = newCache();
      final key = keyOf();
      expect(key.stem, '8001-edge-zh-CN-XiaoxiaoNeural');
      expect(key.stem.contains('1.5'), isFalse);
      await putChapter(cache, key);
      // 同一 key 反复 lookup 只命中同一对文件：没有任何「倍速档」会另开条目。
      expect(await cache.lookup(key, textSignature: signature()), isNotNull);
      expect(await cache.lookup(key, textSignature: signature()), isNotNull);
      expect(await (await bookDir('7001')).list().toList(), hasLength(2));
    });

    test('正文指纹复用 contentSignature，改正文即失效并成对删除', () async {
      final cache = newCache();
      final key = keyOf();
      expect(signature(), contentSignature('甲乙。丙丁。\n戊己。'));
      expect(signature(), cache.signatureOf(kParagraphs));
      await putChapter(cache, key);
      final changed = cache.signatureOf(<String>['甲乙。丙丁。', '戊己。改了']);
      expect(await cache.lookup(key, textSignature: changed), isNull);
      expect((await fileOf(key, '.mp3')).existsSync(), isFalse);
      expect((await fileOf(key, '.jsonl')).existsSync(), isFalse);
    });
  });

  group('无效项：成对删除，不固化', () {
    test('全零占位音频 → 判无效，两个文件一起消失', () async {
      final cache = newCache();
      final key = keyOf();
      await putChapter(cache, key);
      (await fileOf(
        key,
        '.mp3',
      )).writeAsBytesSync(List<int>.filled(8 * 144, 0));
      expect(await cache.lookup(key, textSignature: signature()), isNull);
      expect((await fileOf(key, '.mp3')).existsSync(), isFalse);
      expect((await fileOf(key, '.jsonl')).existsSync(), isFalse);
    });

    test('截断音频（低于字节阈值）→ 判无效并成对删除', () async {
      final cache = newCache();
      final key = keyOf();
      await putChapter(cache, key);
      (await fileOf(key, '.mp3')).writeAsBytesSync(frames(2));
      expect(await cache.lookup(key, textSignature: signature()), isNull);
      expect((await fileOf(key, '.mp3')).existsSync(), isFalse);
      expect((await fileOf(key, '.jsonl')).existsSync(), isFalse);
    });

    test('时间点文件损坏 → 判无效并成对删除（留半截音频最危险）', () async {
      final cache = newCache();
      final key = keyOf();
      await putChapter(cache, key);
      (await fileOf(key, '.jsonl')).writeAsStringSync('{坏数据');
      expect(await cache.lookup(key, textSignature: signature()), isNull);
      expect((await fileOf(key, '.mp3')).existsSync(), isFalse);
    });

    test('只剩音频的孤儿 → 一并清掉', () async {
      final cache = newCache();
      final key = keyOf();
      await putChapter(cache, key);
      (await fileOf(key, '.jsonl')).deleteSync();
      expect(await cache.lookup(key, textSignature: signature()), isNull);
      expect((await fileOf(key, '.mp3')).existsSync(), isFalse);
    });

    test('save 自己就拒绝可疑音频：不落盘且删掉旧对', () async {
      final cache = newCache();
      final key = keyOf();
      await putChapter(cache, key);
      await expectLater(
        cache.save(
          key,
          audio: Uint8List.fromList(List<int>.filled(2000, 0)),
          timeline: timelineOf(),
          textSignature: signature(),
        ),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.emptyAudio,
          ),
        ),
      );
      expect((await fileOf(key, '.mp3')).existsSync(), isFalse);
      expect((await fileOf(key, '.jsonl')).existsSync(), isFalse);
    });

    test('save 拒绝没有时间点的内容（不制造「已下载」假象）', () async {
      final cache = newCache();
      final key = keyOf();
      await expectLater(
        cache.save(
          key,
          audio: frames(8),
          timeline: const SpeechTimeline(
            granularity: SpeechGranularity.word,
            audioMs: 100,
          ),
          textSignature: signature(),
        ),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.invalidCache,
          ),
        ),
      );
      expect((await fileOf(key, '.mp3')).existsSync(), isFalse);
    });
  });

  group('配额与按书 LRU', () {
    test('超限整本淘汰最久未读的，当前书永不删', () async {
      final cache = newCache();
      final a = keyOf(bookId: 'book-a', chapterId: '1');
      final b = keyOf(bookId: 'book-b', chapterId: '1');
      final c = keyOf(bookId: 'book-c', chapterId: '1');
      await putChapter(cache, a);
      await putChapter(cache, b);
      await putChapter(cache, c);
      final total = await cache.totalBytes();
      final perBook = total ~/ 3;
      // 上限只留得下两本：从最久未访问的 a 开始整本删。
      final tight = newCache(maxBytes: total - perBook + 1);
      expect(await tight.enforceQuota(keepBookId: c.bookId), greaterThan(0));
      expect((await bookDir('book-a')).existsSync(), isFalse);
      expect((await bookDir('book-b')).existsSync(), isTrue);
      expect((await bookDir('book-c')).existsSync(), isTrue);
      expect(await tight.totalBytes(), lessThanOrEqualTo(tight.maxBytes));
    });

    test('命中会续期，被淘汰的换成次旧的', () async {
      final cache = newCache();
      final a = keyOf(bookId: 'book-a', chapterId: '1');
      final b = keyOf(bookId: 'book-b', chapterId: '1');
      final c = keyOf(bookId: 'book-c', chapterId: '1');
      await putChapter(cache, a);
      await putChapter(cache, b);
      await putChapter(cache, c);
      final total = await cache.totalBytes();
      // 读一次 a：a 变成最新，最久未读换成 b。
      now = now.add(const Duration(minutes: 5));
      expect(await cache.lookup(a, textSignature: signature()), isNotNull);
      final tight = newCache(maxBytes: total - total ~/ 3 + 1);
      await tight.enforceQuota(keepBookId: c.bookId);
      expect((await bookDir('book-a')).existsSync(), isTrue);
      expect((await bookDir('book-b')).existsSync(), isFalse);
    });

    test('removeBook 清整本', () async {
      final cache = newCache();
      final a = keyOf(bookId: 'book-a');
      await putChapter(cache, a);
      expect((await bookDir('book-a')).existsSync(), isTrue);
      await cache.removeBook('book-a');
      expect((await bookDir('book-a')).existsSync(), isFalse);
      expect(await cache.totalBytes(), 0);
    });

    test('默认配额来自集中常量，quotaMb 可注入', () {
      expect(newCache().maxBytes, TtsCacheLimits.defaultQuotaMb * 1024 * 1024);
      expect(newCache(quotaMb: 3).maxBytes, 3 * 1024 * 1024);
      expect(TtsCacheLimits.minAudioBytes, greaterThan(0));
    });
  });
}
