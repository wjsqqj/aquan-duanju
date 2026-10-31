import 'dart:typed_data';

import 'package:aquan_duanju/core/reader/speech/speech_unit.dart';
import 'package:aquan_duanju/core/tts/mp3_frames.dart';
import 'package:aquan_duanju/core/tts/speech_engine.dart';
import 'package:aquan_duanju/core/tts/tts_composer.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造 [count] 个合法 MPEG-2 Layer III 48kbps 帧：每帧 144 字节 = 24ms。
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

List<int> synchsafe(int value) => <int>[
  (value >> 21) & 0x7F,
  (value >> 14) & 0x7F,
  (value >> 7) & 0x7F,
  value & 0x7F,
];

/// 一张 ID3v2 标签（容器头）：它必须被清洗掉，不参与累计偏移。
Uint8List id3v2({int payload = 512}) {
  final out = Uint8List(10 + payload);
  out[0] = 0x49;
  out[1] = 0x44;
  out[2] = 0x33;
  out[3] = 2;
  out[4] = 4;
  final size = synchsafe(payload);
  out[6] = size[0];
  out[7] = size[1];
  out[8] = size[2];
  out[9] = size[3];
  for (var i = 10; i < out.length; i++) {
    out[i] = 0x20;
  }
  return out;
}

Uint8List join(List<List<int>> parts) {
  final out = <int>[];
  for (final part in parts) {
    out.addAll(part);
  }
  return Uint8List.fromList(out);
}

/// 假引擎：按契约把 [SpeechJob.offsetBaseMs] 平移到时间点上、字符位相对 `job.text`。
///
/// 各种「违约」开关（忘平移 / 自报虚高 / 坐标越界 / 返回占位字节）是为编排层的
/// 兜底行为准备的，真实引擎不需要它们。
class _FakeEngine implements SpeechEngine {
  _FakeEngine({
    this.engineId = 'edge',
    this.capsValue = const TtsCaps(wordBoundary: true),
    this.applyOffset = true,
    this.framesPerJob = 10,
    this.selfReportMs = 1000,
    this.withContainer = false,
    this.overflowCoords = false,
    this.audioOverride,
    this.onCall,
  });

  final String engineId;
  final TtsCaps capsValue;

  /// false = 违约引擎：忘了把 `offsetBaseMs` 加到时间点上。
  final bool applyOffset;
  final int framesPerJob;
  final int selfReportMs;
  final bool withContainer;
  final bool overflowCoords;
  final Uint8List? audioOverride;

  /// 每次被调用时回调（用来模拟「结果迟到时世代已变」）。
  final void Function(SpeechJob job)? onCall;

  final List<SpeechJob> jobs = <SpeechJob>[];

  @override
  String get id => engineId;

  @override
  TtsCaps get caps => capsValue;

  @override
  Future<List<TtsVoice>> voices() async => const <TtsVoice>[];

  @override
  Future<void> dispose() async {}

  @override
  Future<TtsSegment> synthesize(SpeechJob job) async {
    jobs.add(job);
    onCall?.call(job);
    // 让 await 前后的世代判定真的有机会被观察到（同步返回会跳过检查窗口）。
    await Future<void>.delayed(Duration.zero);
    final base = applyOffset ? job.offsetBaseMs : 0;
    final points = <SpeechPoint>[];
    if (overflowCoords) {
      // 违约：字符位冲出 `job.text` 边界（真实引擎不该这样，编排层必须夹住）。
      points.add(
        SpeechPoint(
          startMs: base,
          endMs: base + 50,
          charStart: 0,
          charEnd: job.text.length + 100000,
          unitIndex: 0,
          text: job.text,
        ),
      );
    } else {
      for (var k = 0; k < job.text.length; k++) {
        final ch = job.text[k];
        if (ch.trim().isEmpty) continue; // 引擎不会为空白出 token
        points.add(
          SpeechPoint(
            startMs: base + k * 10,
            endMs: base + k * 10 + 10,
            charStart: k,
            charEnd: k + 1,
            unitIndex: 0,
            text: ch,
          ),
        );
      }
    }
    final body = frames(framesPerJob);
    return TtsSegment(
      audio:
          audioOverride ??
          (withContainer ? join(<List<int>>[id3v2(), body]) : body),
      points: points,
      audioMs: selfReportMs,
    );
  }
}

/// 并发测试专用：可控延迟，记录同时在飞的请求数，可在指定调用号抛错。
class _ConcurrencyEngine implements SpeechEngine {
  _ConcurrencyEngine({
    this.delay = Duration.zero,
    this.failOnCall,
    this.failureCode = TtsErrorCode.rateLimited,
  });

  final Duration delay;

  /// 第几次调用（1 起）抛错；null 表示不失败。
  final int? failOnCall;
  final TtsErrorCode failureCode;

  int calls = 0;
  int _inFlight = 0;
  int maxInFlight = 0;

  @override
  String get id => 'edge';

  @override
  TtsCaps get caps => const TtsCaps(wordBoundary: true);

  @override
  Future<List<TtsVoice>> voices() async => const <TtsVoice>[];

  @override
  Future<void> dispose() async {}

  @override
  Future<TtsSegment> synthesize(SpeechJob job) async {
    calls++;
    final callNo = calls;
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (failOnCall != null && callNo == failOnCall) {
        throw TtsException(failureCode, message: '模拟失败 call=$callNo');
      }
      final base = job.offsetBaseMs;
      final text = job.text;
      final points = <SpeechPoint>[
        SpeechPoint(
          startMs: base,
          endMs: base + 10,
          charStart: 0,
          charEnd: 1,
          unitIndex: 0,
          text: text.isEmpty ? '' : text[0],
        ),
        SpeechPoint(
          startMs: base + 10,
          endMs: base + 20,
          charStart: text.length > 1 ? text.length - 1 : 0,
          charEnd: text.length,
          unitIndex: 0,
          text: text.isEmpty ? '' : text[text.length - 1],
        ),
      ];
      return TtsSegment(
        audio: frames(10),
        points: points,
        audioMs: 240,
      );
    } finally {
      _inFlight--;
    }
  }
}

/// 不落音频文件的实现（未来的系统 TTS）：只能被拒绝。
class _StreamOnlyEngine extends _FakeEngine {
  _StreamOnlyEngine()
    : super(
        engineId: 'system',
        capsValue: const TtsCaps(wordBoundary: false, producesFile: false),
      );
}

const TtsVoice _voice = TtsVoice(id: 'zh-CN-XiaoxiaoNeural');
const int _msPerChunk = 240; // 10 帧 × 24ms

void main() {
  Future<TtsComposition> run(
    SpeechEngine engine,
    List<String> paragraphs, {
    int epoch = 1,
    List<SpeechUnit>? units,
    bool Function(int epoch)? isCurrent,
    int maxChunkChars = kTtsMaxChunkChars,
    void Function(int done, int total)? onProgress,
    // 既有用例保持串行语义（改造前就是串行）；并发行为由「章内并发」组单独钉住。
    int concurrency = 1,
  }) => TtsComposer(maxChunkChars: maxChunkChars).composeChapter(
    engine: engine,
    paragraphs: paragraphs,
    voice: _voice,
    epoch: epoch,
    units: units,
    isCurrent: isCurrent,
    onProgress: onProgress,
    concurrency: concurrency,
  );

  group('合成进度', () {
    test('每完成一块回调一次，done 从 1 递增到 total', () async {
      final events = <(int, int)>[];
      // 小上限：每段独立成块，确保有多块。
      final composition = await run(
        _FakeEngine(),
        <String>['甲乙。', '丙丁。', '戊己。'],
        maxChunkChars: 1,
        onProgress: (done, total) => events.add((done, total)),
      );
      expect(events.length, composition.chunkCount);
      expect(events.map((e) => e.$1).toList(),
          List<int>.generate(events.length, (i) => i + 1));
      for (final event in events) {
        expect(event.$2, composition.chunkCount);
      }
    });

    test('不传 onProgress 也能正常完成（预取路径就是这样调的）', () async {
      final composition = await run(_FakeEngine(), <String>['甲乙。丙丁。']);
      expect(composition.chunkCount, greaterThan(0));
    });
  });

  group('章内并发', () {
    Future<TtsComposition> compose(
      SpeechEngine engine,
      List<String> paragraphs, {
      required int concurrency,
    }) => TtsComposer(maxChunkChars: 1).composeChapter(
      engine: engine,
      paragraphs: paragraphs,
      voice: _voice,
      epoch: 1,
      concurrency: concurrency,
    );

    test('并发结果与串行逐项一致（字节/时长/词点全对齐）', () async {
      const paragraphs = <String>['甲乙。', '丙丁。', '戊己。', '庚辛。'];
      final serial = await compose(
        _ConcurrencyEngine(),
        paragraphs,
        concurrency: 1,
      );
      final parallel = await compose(
        _ConcurrencyEngine(),
        paragraphs,
        concurrency: 3,
      );

      expect(parallel.audio.length, serial.audio.length);
      expect(parallel.audioMsFromBytes, serial.audioMsFromBytes);
      expect(parallel.chunkCount, serial.chunkCount);
      expect(parallel.timeline.words.length, serial.timeline.words.length);
      for (var i = 0; i < serial.timeline.words.length; i++) {
        final a = serial.timeline.words[i];
        final b = parallel.timeline.words[i];
        expect(b.startMs, a.startMs, reason: '词点 #$i 起点必须一致');
        expect(b.endMs, a.endMs, reason: '词点 #$i 终点必须一致');
        expect(b.charStart, a.charStart);
        expect(b.charEnd, a.charEnd);
      }
    });

    test('确实并行：同时在飞的请求数 > 1', () async {
      final engine = _ConcurrencyEngine(delay: const Duration(milliseconds: 10));
      await compose(
        engine,
        const <String>['甲乙。', '丙丁。', '戊己。'],
        concurrency: 3,
      );
      expect(engine.maxInFlight, greaterThan(1));
    });

    test('限流：降级串行重试一次，最终仍能产出整章', () async {
      // 只在第 1 次调用抛 429：并发失败 → 降级串行（第 2 次起都成功）。
      final engine = _ConcurrencyEngine(failOnCall: 1);
      final composition = await compose(
        engine,
        const <String>['甲乙。', '丙丁。', '戊己。'],
        concurrency: 2,
      );
      expect(composition.chunkCount, greaterThan(0));
      expect(
        engine.calls,
        greaterThanOrEqualTo(4),
        reason: '1 次失败 + 降级后至少 3 块',
      );
    });

    test('非限流错误直接上抛（不重跑一遍）', () async {
      final engine = _ConcurrencyEngine(
        failOnCall: 1,
        failureCode: TtsErrorCode.emptyAudio,
      );
      await expectLater(
        compose(engine, const <String>['甲乙。', '丙丁。'], concurrency: 2),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.emptyAudio,
          ),
        ),
      );
    });

    test('并发下的进度回调：次数 == 块数，done 递增到 total', () async {
      final events = <int>[];
      final engine = _ConcurrencyEngine();
      await TtsComposer(maxChunkChars: 1).composeChapter(
        engine: engine,
        paragraphs: const <String>['甲乙。', '丙丁。', '戊己。'],
        voice: _voice,
        epoch: 1,
        concurrency: 2,
        onProgress: (done, total) {
          expect(total, 3);
          events.add(done);
        },
      );
      expect(events.length, 3);
      expect(events.toSet(), <int>{1, 2, 3});
    });
  });

  group('引擎准入与能力位', () {
    test('producesFile=false 的引擎被拒绝，且一次都不调用', () async {
      final engine = _StreamOnlyEngine();
      await expectLater(
        run(engine, <String>['甲乙。丙丁。']),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.unsupportedEngine,
          ),
        ),
      );
      expect(engine.jobs, isEmpty);
      // 文案只走 friendlyText：不允许把内部术语漏给用户。
      expect(
        const TtsException(TtsErrorCode.unsupportedEngine).friendlyText,
        isNotEmpty,
      );
    });

    test('精度位取自引擎能力，不做静默升降级', () async {
      final word = await run(_FakeEngine(), <String>['甲乙。丙丁。']);
      expect(word.timeline.granularity, SpeechGranularity.word);
      expect(word.timeline.words, isNotEmpty);

      final sentence = await run(
        _FakeEngine(capsValue: const TtsCaps(wordBoundary: false)),
        <String>['甲乙。丙丁。'],
      );
      expect(sentence.timeline.granularity, SpeechGranularity.sentence);
      // 句级路径不造词表：拿不到就是拿不到（wordAt 返回 null 由上层决定显示）。
      expect(sentence.timeline.words, isEmpty);
      expect(sentence.timeline.sentences, isNotEmpty);
      expect(sentence.timeline.wordAt(10), isNull);
    });

    test('音色与世代号原样透传给引擎', () async {
      final engine = _FakeEngine();
      await run(engine, <String>['甲乙。'], epoch: 7);
      expect(engine.jobs.single.voice.id, 'zh-CN-XiaoxiaoNeural');
      expect(engine.jobs.single.requestIndex, 7);
      expect(engine.jobs.single.offsetBaseMs, 0);
    });
  });

  group('累计偏移与时长口径', () {
    test('offsetBaseMs = 前序清洗后字节的换算时长，容器头不计入', () async {
      final engine = _FakeEngine(withContainer: true);
      await run(engine, <String>['甲乙。丙丁。'], maxChunkChars: 3);
      expect(engine.jobs, hasLength(2));
      // 每段带 522 字节 ID3v2：若没清洗，第二段偏移会多出 87ms。
      expect(engine.jobs[1].offsetBaseMs, _msPerChunk);
      expect(
        engine.jobs[1].offsetBaseMs,
        mp3BytesToMs(10 * 144, bitrateKbps: kTtsMp3BitrateKbps),
      );
    });

    test('整章时长按总字节换算，不采信引擎自报时长之和', () async {
      final engine = _FakeEngine(selfReportMs: 7200000);
      final result = await run(engine, <String>['甲乙。丙丁。戊己。']);
      expect(engine.jobs, hasLength(1));
      expect(result.audioMsFromBytes, _msPerChunk);
      expect(result.timeline.audioMs, _msPerChunk);
      expect(result.bytes, 10 * 144);
      expect(result.bitrateKbps, kTtsMp3BitrateKbps);
    });

    test('拼接结果只剩音频帧（容器头不留在成品里）', () async {
      final result = await run(_FakeEngine(withContainer: true), <String>[
        '甲乙。丙丁。',
      ], maxChunkChars: 3);
      expect(result.bytes, 2 * 10 * 144);
      expect(result.audioMsFromBytes, 2 * _msPerChunk);
      expect(result.audio[0], 0xFF); // 首字节必须是帧同步
    });

    test('引擎忘加 offset 时编排层补齐；已加的不会被二次平移', () async {
      final done = await run(_FakeEngine(), <String>['甲乙。丙丁。戊己。']);
      final forgotten = await run(_FakeEngine(applyOffset: false), <String>[
        '甲乙。丙丁。戊己。',
      ]);
      expect(
        forgotten.timeline.words.map((w) => w.startMs).toList(),
        done.timeline.words.map((w) => w.startMs).toList(),
      );
      expect(
        forgotten.timeline.words.map((w) => w.charStart).toList(),
        done.timeline.words.map((w) => w.charStart).toList(),
      );
      // 时间点确实落在整章媒体时间轴上（单调不减）。
      final starts = done.timeline.words.map((w) => w.startMs).toList();
      for (var i = 1; i < starts.length; i++) {
        expect(starts[i], greaterThanOrEqualTo(starts[i - 1]));
      }
    });

    test('多块时跨块时间不重叠，句点回推到正确的 unit 与段落', () async {
      final paragraphs = <String>['甲乙。丙丁。', '戊己。庚辛。'];
      final result = await run(_FakeEngine(), paragraphs, maxChunkChars: 6);
      expect(result.chunkCount, 2);
      expect(result.audioMsFromBytes, 2 * _msPerChunk);
      expect(result.timeline.paragraphs, hasLength(2));
      expect(result.timeline.paragraphs[1].startMs, greaterThan(0));
      expect(result.timeline.sentences, hasLength(4));
      expect(
        result.timeline.paragraphAt(2 * _msPerChunk - 1, paragraphCount: 2),
        1,
      );
    });
  });

  group('分块：切片连续、不切断 unit', () {
    test('跨段落只隔换行时合并成一次请求，切片仍是章内连续文本', () async {
      const paragraphs = <String>['甲乙。丙丁。', '戊己。'];
      final chapterText = chapterPlainText(paragraphs);
      final engine = _FakeEngine();
      final result = await run(engine, paragraphs);
      expect(result.chunkCount, 1);
      expect(engine.jobs.single.text, chapterText);
    });

    test('超上限时在 unit 边界封块，每个 unit 完整落在某一次请求里', () async {
      const paragraphs = <String>['甲乙。丙丁。戊己。庚辛。'];
      final chapterText = chapterPlainText(paragraphs);
      final units = splitSpeechUnits(paragraphs);
      expect(units, hasLength(4));
      final engine = _FakeEngine();
      final result = await run(engine, paragraphs, maxChunkChars: 6);
      expect(result.chunkCount, 2);
      expect(engine.jobs[0].text, '甲乙。丙丁。');
      expect(engine.jobs[1].text, '戊己。庚辛。');

      final covered = <int>{};
      for (final job in engine.jobs) {
        expect(chapterText.contains(job.text), isTrue);
        for (var i = 0; i < units.length; i++) {
          // 半截 unit：既不可能是「包含」，也不允许被切成两段送出去。
          if (job.text.contains(units[i].text)) covered.add(i);
          final cut = chapterText.indexOf(job.text) + job.text.length;
          expect(units.any((u) => u.charEnd == cut), isTrue);
        }
      }
      expect(covered.length, units.length);
    });

    test('单个 unit 就超上限：原样交给引擎，不从中间劈开', () async {
      final long = <String>['啊' * 120];
      final units = splitSpeechUnits(long);
      expect(units, hasLength(1));
      final engine = _FakeEngine();
      final result = await run(engine, long, maxChunkChars: 50);
      expect(result.chunkCount, 1);
      expect(engine.jobs.single.text, units.single.text);
      expect(engine.jobs.single.text.length, 120);
    });

    test('调用方传入已切好的 units 时不再切第二刀', () async {
      const paragraphs = <String>['甲乙。丙丁。'];
      final units = splitSpeechUnits(paragraphs, maxUnitChars: 3);
      final engine = _FakeEngine();
      final result = await run(engine, paragraphs, units: units);
      expect(result.timeline.sentences, hasLength(units.length));
    });
  });

  group('坏数据与取消', () {
    test('世代变更后迟到结果被丢弃', () async {
      var currentEpoch = 1;
      final engine = _FakeEngine(
        onCall: (job) => currentEpoch = job.requestIndex + 1,
      );
      await expectLater(
        run(
          engine,
          <String>['甲乙。丙丁。戊己。'],
          epoch: 1,
          isCurrent: (epoch) => epoch == currentEpoch,
        ),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.cancelled,
          ),
        ),
      );
      // 只发过一次请求，也没有把迟到那段拼进结果。
      expect(engine.jobs, hasLength(1));
    });

    test('清洗后没有音频帧（全零占位）判空音频', () async {
      final engine = _FakeEngine(audioOverride: Uint8List(2000));
      await expectLater(
        run(engine, <String>['甲乙。丙丁。']),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.emptyAudio,
          ),
        ),
      );
      expect(engine.jobs, hasLength(1));
    });

    test('引擎返回空正文/无时间点 → 不产出半截时间表', () async {
      await expectLater(
        run(_FakeEngine(), <String>['   ']),
        throwsA(
          isA<TtsException>().having(
            (e) => e.code,
            'code',
            TtsErrorCode.emptyAudio,
          ),
        ),
      );
    });

    test('引擎坐标越界时夹回本段范围，点仍落在章内', () async {
      const paragraphs = <String>['甲乙。丙丁。', '戊己。'];
      final chapterText = chapterPlainText(paragraphs);
      final result = await run(
        _FakeEngine(overflowCoords: true),
        paragraphs,
        maxChunkChars: 6,
      );
      for (final word in result.timeline.words) {
        expect(word.charStart, greaterThanOrEqualTo(0));
        expect(word.charEnd, lessThanOrEqualTo(chapterText.length));
        expect(word.endMs, greaterThanOrEqualTo(word.startMs));
      }
      expect(result.timeline.words.last.charEnd, chapterText.length);
      expect(result.timeline.words.last.unitIndex, 2);
    });
  });

  // 编排层本身不缓存，但时长口径必须与缓存侧一致：留个引用检查防止误改常量。
  test('倍速不进这条链路：时间点只依赖字节', () async {
    final result = await run(_FakeEngine(framesPerJob: 5), <String>['甲乙。']);
    expect(result.audioMsFromBytes, mp3BytesToMs(result.bytes));
    expect(result.audioMsFromBytes, 5 * 24);
    expect(result.chunkCount, 1);
  });
}
