import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aquan_duanju/core/tts/win/windows_speech_engine.dart';
import 'package:aquan_duanju/core/tts/speech_engine.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 生成一个合法的 PCM wav：默认 16kHz/单声道/16bit、1 秒。
Uint8List wavBytes({int samples = 16000}) {
  const sampleRate = 16000;
  const channels = 1;
  const bits = 16;
  final dataSize = samples * channels * (bits ~/ 8);
  final b = BytesBuilder();
  void tag(String s) => b.add(ascii.encode(s));
  void u32(int v) => b.add(
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List(),
  );
  void u16(int v) => b.add(
    (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List(),
  );

  tag('RIFF');
  u32(36 + dataSize);
  tag('WAVE');
  tag('fmt ');
  u32(16);
  u16(1); // PCM
  u16(channels);
  u32(sampleRate);
  u32(sampleRate * channels * (bits ~/ 8));
  u16(channels * (bits ~/ 8));
  u16(bits);
  tag('data');
  u32(dataSize);
  b.add(Uint8List(dataSize));
  return b.toBytes();
}

/// 假 powershell：按 `-OutJson` / `-OutWav` 写文件，不真的合成。
ProcessRunner fakeRunner({
  int voices = 1,
  List<Map<String, Object>>? markers,
  bool ok = true,
  String error = '',
  bool writeFiles = true,
  int exitCode = 0,
}) {
  return (executable, args) async {
    final jsonPath = args[args.indexOf('-OutJson') + 1];
    if (!writeFiles) return ProcessResult(0, exitCode, '', '');
    if (args.contains('probe')) {
      File(jsonPath).writeAsStringSync(
        jsonEncode(<String, Object>{
          'ok': true,
          'voices': <Map<String, String>>[
            for (var i = 0; i < voices; i++)
              <String, String>{'name': 'Voice$i', 'language': 'zh-CN'},
          ],
        }),
      );
      return ProcessResult(0, exitCode, '', '');
    }
    final wavPath = args[args.indexOf('-OutWav') + 1];
    File(wavPath).writeAsBytesSync(wavBytes());
    File(jsonPath).writeAsStringSync(
      jsonEncode(<String, Object>{
        'ok': ok,
        if (!ok) 'error': error,
        if (ok) 'markers': markers ?? const <Map<String, Object>>[],
      }),
    );
    return ProcessResult(0, exitCode, '', '');
  };
}

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('aquan_win_tts_');
  });
  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  WindowsSpeechEngine engine(ProcessRunner runner, {bool windows = true}) =>
      WindowsSpeechEngine(
        runner: runner,
        tempDirectory: () async => temp,
        isWindows: windows,
      );

  group('可用性探测', () {
    test('非 Windows：不可用且不启动进程', () async {
      var called = false;
      final e = engine((exe, args) async {
        called = true;
        return ProcessResult(0, 0, '', '');
      }, windows: false);

      expect(await e.isAvailable(), isFalse);
      expect(await e.voices(), isEmpty);
      expect(called, isFalse, reason: '非 Windows 不许起 powershell');
    });

    test('本机没语音（voices 为空）→ 不可用', () async {
      final e = engine(fakeRunner(voices: 0));
      expect(await e.isAvailable(), isFalse);
    });

    test('有语音 → 可用，voices() 带出名字与语言', () async {
      final e = engine(fakeRunner(voices: 2));
      expect(await e.isAvailable(), isTrue);
      final voices = await e.voices();
      expect(voices.map((v) => v.id).toList(), <String>['Voice0', 'Voice1']);
      expect(voices.first.displayName, 'zh-CN');
    });

    test('脚本失败（非 0 退出）→ 不可用而不是抛', () async {
      final e = engine(fakeRunner(exitCode: 1));
      expect(await e.isAvailable(), isFalse);
    });
  });

  group('合成与词边界', () {
    test('markers → 词级时间点：字符偏移与音频时间都对，且都加了 offsetBase', () async {
      final e = engine(
        fakeRunner(
          markers: <Map<String, Object>>[
            <String, Object>{'kind': 'WordBoundary', 'textOffset': 0, 'timeMs': 0},
            <String, Object>{
              'kind': 'WordBoundary',
              'textOffset': 4,
              'timeMs': 300,
            },
          ],
        ),
      );

      final segment = await e.synthesize(
        SpeechJob(
          text: '你好世界。',
          voice: const TtsVoice(id: 'Voice0'),
          offsetBaseMs: 500,
          requestIndex: 1,
        ),
      );

      expect(segment.container, 'wav', reason: '走容器无关管线（不洗 mp3 帧）');
      expect(segment.audioMs, 1000, reason: '时长从 wav 头算出来');
      expect(segment.points, hasLength(2));
      expect(segment.points[0].startMs, 500);
      expect(segment.points[0].endMs, 800);
      expect(segment.points[0].charStart, 0);
      expect(segment.points[0].charEnd, 4);
      expect(segment.points[0].text, '你好世界');
      // 最后一个词收到音频末尾。
      expect(segment.points[1].startMs, 800);
      expect(segment.points[1].endMs, 1500);
      expect(segment.points[1].charEnd, 5);
    });

    test('没有 WordBoundary → 报错（不伪造词级）', () async {
      final e = engine(fakeRunner());
      await expectLater(
        e.synthesize(
          SpeechJob(
            text: '一句话。',
            voice: const TtsVoice(id: 'Voice0'),
            offsetBaseMs: 0,
            requestIndex: 1,
          ),
        ),
        throwsA(
          isA<TtsException>().having(
            (x) => x.message,
            'message',
            contains('词边界'),
          ),
        ),
      );
    });

    test('桥报「未安装语音引擎」→ notConfigured（不是网络错误）', () async {
      final e = engine(
        fakeRunner(ok: false, error: '本机未安装语音引擎（AllVoices 为空）'),
      );
      await expectLater(
        e.synthesize(
          SpeechJob(
            text: '一句话。',
            voice: const TtsVoice(id: 'Voice0'),
            offsetBaseMs: 0,
            requestIndex: 1,
          ),
        ),
        throwsA(
          isA<TtsException>().having(
            (x) => x.code,
            'code',
            TtsErrorCode.notConfigured,
          ),
        ),
      );
    });

    test('非 Windows 合成 → notConfigured', () async {
      final e = engine(fakeRunner(), windows: false);
      await expectLater(
        e.synthesize(
          SpeechJob(
            text: 'x',
            voice: const TtsVoice(id: ''),
            offsetBaseMs: 0,
            requestIndex: 1,
          ),
        ),
        throwsA(
          isA<TtsException>().having(
            (x) => x.code,
            'code',
            TtsErrorCode.notConfigured,
          ),
        ),
      );
    });

    test('合成后不留临时文件', () async {
      final e = engine(
        fakeRunner(
          markers: <Map<String, Object>>[
            <String, Object>{'kind': 'WordBoundary', 'textOffset': 0, 'timeMs': 0},
          ],
        ),
      );
      await e.synthesize(
        SpeechJob(
          text: '好。',
          voice: const TtsVoice(id: 'Voice0'),
          offsetBaseMs: 0,
          requestIndex: 1,
        ),
      );
      final leftovers = temp
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('aquan_tts_'))
          .toList();
      expect(leftovers, isEmpty, reason: 'wav/json 都必须删掉');
    });
  });
}
