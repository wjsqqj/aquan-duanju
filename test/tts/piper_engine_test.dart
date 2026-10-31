import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aquan_duanju/core/tts/piper/piper_engine.dart';
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
  void u32(int v) =>
      b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u16(int v) =>
      b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());

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

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('piper_');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  PiperSpeechEngine build({
    String exe = 'piper',
    String model = 'model.onnx',
    TextToFileRunner? runner,
  }) => PiperSpeechEngine(
    executable: exe,
    model: model,
    runner: runner,
    tempDirectory: () async => dir,
  );

  FinishingProcess makeModel() => FinishingProcess(dir);

  const job = SpeechJob(
    text: '甲乙。丙丁。',
    voice: TtsVoice(id: ''),
    offsetBaseMs: 5000,
    requestIndex: 1,
  );

  test('caps：wav + 段级精度（绝不伪造句/词边界）', () {
    final engine = build();
    expect(engine.caps.container, 'wav');
    expect(engine.caps.offline, isTrue);
    expect(engine.caps.producesFile, isTrue);
    expect(engine.caps.effectiveGranularity, SpeechGranularity.paragraph);
  });

  test('isAvailable：路径空 / 模型不存在 / --help 失败 → 都不可用', () async {
    expect(await build(exe: '').isAvailable(), isFalse);
    expect(await build(model: '${dir.path}/nope.onnx').isAvailable(), isFalse);

    final model = makeModel();
    final failing = build(
      model: model.path,
      runner: (_, _, _) async => ProcessResult(0, 2, '', ''),
    );
    expect(await failing.isAvailable(), isFalse);

    final ok = build(
      model: model.path,
      runner: (_, _, _) async => ProcessResult(0, 0, 'usage', ''),
    );
    expect(await ok.isAvailable(), isTrue);
  });

  test('合成：wav 落盘 → 一个段级点、时间按 offsetBase 平移、时长来自 RIFF 头', () async {
    final model = makeModel();
    late List<String> seenArgs;
    late String seenStdin;
    final engine = build(
      model: model.path,
      runner: (_, args, stdin) async {
        seenArgs = args;
        seenStdin = stdin;
        final out = args[args.indexOf('--output_file') + 1];
        File(out).writeAsBytesSync(wavBytes());
        return ProcessResult(0, 0, '', '');
      },
    );

    final segment = await engine.synthesize(job);

    expect(seenStdin, job.text, reason: '文本必须从 stdin 喂进去');
    expect(seenArgs, containsAllInOrder(<String>['--model', model.path]));
    expect(segment.container, 'wav');
    expect(segment.audioMs, 1000);
    expect(segment.points, hasLength(1));
    expect(segment.points.single.startMs, 5000);
    expect(segment.points.single.endMs, 6000);
    expect(segment.points.single.charStart, 0);
    expect(segment.points.single.charEnd, job.text.length);
  });

  test('退出码非 0 → transport，stderr 摘要进文案', () async {
    final model = makeModel();
    final engine = build(
      model: model.path,
      runner: (_, _, _) async => ProcessResult(0, 3, '', 'model not found\nbad path'),
    );
    await expectLater(
      engine.synthesize(job),
      throwsA(
        isA<TtsException>()
            .having((e) => e.code, 'code', TtsErrorCode.transport)
            .having((e) => e.message, 'message', contains('model not found')),
      ),
    );
  });

  test('没产出文件 → emptyAudio（不静默播空白）', () async {
    final model = makeModel();
    final engine = build(
      model: model.path,
      runner: (_, _, _) async => ProcessResult(0, 0, '', ''),
    );
    await expectLater(
      engine.synthesize(job),
      throwsA(
        isA<TtsException>().having(
          (e) => e.code,
          'code',
          TtsErrorCode.emptyAudio,
        ),
      ),
    );
  });

  test('合成后不留临时 wav', () async {
    final model = makeModel();
    final engine = build(
      model: model.path,
      runner: (_, args, _) async {
        final out = args[args.indexOf('--output_file') + 1];
        File(out).writeAsBytesSync(wavBytes(samples: 1600));
        return ProcessResult(0, 0, '', '');
      },
    );
    await engine.synthesize(job);
    final left = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('aquan_piper_'))
        .toList();
    expect(left, isEmpty);
  });
}

/// 在临时目录里放一个假模型文件（只需存在，内容无关）。
class FinishingProcess {
  FinishingProcess(Directory dir) {
    _file = File('${dir.path}/model.onnx')..writeAsBytesSync(<int>[1, 2, 3]);
  }

  late final File _file;

  String get path => _file.path;
}
