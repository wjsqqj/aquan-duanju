import 'dart:io';
import 'dart:typed_data';

import 'package:aquan_duanju/core/tts/speech_engine.dart';
import 'package:aquan_duanju/core/tts/tts_cache.dart';
import 'package:aquan_duanju/core/tts/tts_composer.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 容器无关化：wav/pcm 引擎（WinRT 系统 TTS、Piper）能走完编排与缓存，
/// 同时 mp3 管线行为逐字节不变。
class _WavEngine implements SpeechEngine {
  _WavEngine({required this.audioMs});

  final int audioMs;

  /// 固定 1024 字节「不是 mp3」的负载。
  static const int bytes = 1024;

  @override
  String get id => 'wav-test';

  @override
  TtsCaps get caps =>
      const TtsCaps(wordBoundary: false, offline: true, container: 'wav');

  @override
  Future<List<TtsVoice>> voices() async => const <TtsVoice>[];

  @override
  Future<TtsSegment> synthesize(SpeechJob job) async => TtsSegment(
    // 刻意给"不是 mp3 帧"的字节：只要走帧清洗就会被判空。
    audio: Uint8List.fromList(List<int>.filled(bytes, 7)),
    points: <SpeechPoint>[
      SpeechPoint(
        startMs: job.offsetBaseMs,
        endMs: job.offsetBaseMs + (audioMs > 0 ? audioMs : 0),
        charStart: 0,
        charEnd: job.text.length,
        unitIndex: 0,
        text: job.text,
      ),
    ],
    audioMs: audioMs,
    container: 'wav',
  );

  @override
  Future<void> dispose() async {}
}

SpeechTimeline _timeline(int ms) => SpeechTimeline(
  granularity: SpeechGranularity.sentence,
  audioMs: ms,
  sentences: <SpeechPoint>[
    SpeechPoint(startMs: 0, endMs: ms, charStart: 0, charEnd: 4, unitIndex: 0),
  ],
  paragraphs: <ParagraphTiming>[
    ParagraphTiming(
      paragraphIndex: 0,
      charStart: 0,
      charEnd: 4,
      startMs: 0,
      endMs: ms,
    ),
  ],
);

void main() {
  group('编排层：非 mp3 直通', () {
    Future<TtsComposition> compose(SpeechEngine engine) => TtsComposer()
        .composeChapter(
          engine: engine,
          paragraphs: const <String>['第一句。第二句。'],
          voice: const TtsVoice(id: 'v'),
          epoch: 1,
          isCurrent: (_) => true,
        );

    test('wav 字节原样拼接，不做 mp3 帧清洗；时长用自报值', () async {
      final composition = await compose(_WavEngine(audioMs: 1000));

      expect(
        composition.audio.length,
        1024,
        reason: 'wav 不能被摘掉 ID3/帧头（那会把好音频剪坏）',
      );
      expect(composition.audioMsFromBytes, 1000, reason: '非 mp3 用自报时长');
      expect(composition.timeline.audioMs, greaterThanOrEqualTo(1000));
      expect(composition.timeline.paragraphs, isNotEmpty);
    });

    test('非 mp3 但没自报时长 → 报错而不是猜一个', () async {
      await expectLater(
        compose(_WavEngine(audioMs: 0)),
        throwsA(
          isA<TtsException>().having(
            (e) => e.message,
            'message',
            contains('非 mp3'),
          ),
        ),
      );
    });
  });

  group('缓存：扩展名跟随容器', () {
    late Directory dir;
    late TtsCache cache;
    late TtsCacheKey key;
    late String signature;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('tts_container_');
      cache = TtsCache(rootDirectory: () async => dir);
      key = TtsCacheKey(
        bookId: 'b1',
        chapterId: 'c1',
        engineId: 'wav-test',
        voiceId: 'v',
      );
      signature = cache.signatureOf(const <String>['第一句。']);
      await cache.save(
        key,
        audio: Uint8List.fromList(List<int>.filled(1024, 3)),
        timeline: _timeline(1000),
        textSignature: signature,
        extension: 'wav',
      );
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('wav 能命中；用 mp3 去查必须 miss 且不误删 wav 的配对文件', () async {
      expect(
        await cache.lookup(key, textSignature: signature, extension: 'wav'),
        isNotNull,
      );
      // 关键：另一种容器的 miss 走的是「不存在」而不是「坏项」，不许删别人的 jsonl。
      expect(
        await cache.lookup(key, textSignature: signature, extension: 'mp3'),
        isNull,
      );
      expect(
        await cache.lookup(key, textSignature: signature, extension: 'wav'),
        isNotNull,
        reason: 'mp3 的 lookup 不能把 wav 的时间点删掉',
      );
    });

    test('invalidate 清掉所有容器的产物', () async {
      await cache.invalidate(key);
      expect(
        await cache.lookup(key, textSignature: signature, extension: 'wav'),
        isNull,
      );
    });
  });

  test('mp3 路径默认值不变：caps/segment 的 container 默认就是 mp3', () {
    expect(const TtsCaps().container, 'mp3');
    expect(
      TtsSegment(
        audio: _empty,
        points: const <SpeechPoint>[],
        audioMs: 0,
      ).container,
      'mp3',
    );
  });
}

final Uint8List _empty = Uint8List(0);
