import 'dart:io';
import 'dart:typed_data';

import 'package:aquan_duanju/core/tts/http/http_tts_preview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'speech_fakes.dart';

/// 试听：写临时文件 → 现有播放器打开 → 停/关即删文件。全部用假播放器，无需 mpv。
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tts_preview_');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  TtsPreviewPlayer build(FakePlayer player) => TtsPreviewPlayer(
    directory: () async => dir,
    engineFactory: () => player,
  );

  test('play：写临时文件并交给现有播放链路打开', () async {
    final player = FakePlayer();
    final preview = build(player);

    await preview.play(Uint8List.fromList(List<int>.filled(16, 7)));

    expect(preview.isPlaying, isTrue);
    final path = preview.currentPath!;
    expect(File(path).existsSync(), isTrue);
    expect(File(path).lengthSync(), 16);
    expect(player.opened, hasLength(1), reason: '必须走 PlayerEngine，而不是另起播放器');
    await preview.dispose();
  });

  test('stop 删文件；dispose 连播放器一起释放', () async {
    final player = FakePlayer();
    final preview = build(player);

    await preview.play(Uint8List.fromList(<int>[1, 2, 3]));
    final path = preview.currentPath!;
    await preview.stop();

    expect(File(path).existsSync(), isFalse, reason: '停止即删临时文件');
    expect(preview.isPlaying, isFalse);

    await preview.play(Uint8List.fromList(<int>[4, 5]));
    final second = preview.currentPath!;
    await preview.dispose();
    expect(File(second).existsSync(), isFalse, reason: 'dispose 后不留垃圾');
    expect(preview.isPlaying, isFalse);
  });

  test('空字节：不写文件、不碰播放器', () async {
    final player = FakePlayer();
    final preview = build(player);

    await preview.play(Uint8List(0));

    expect(preview.isPlaying, isFalse);
    expect(player.opened, isEmpty);
  });

  test('再次 play 会先清理上一段（不堆临时文件）', () async {
    final player = FakePlayer();
    final preview = build(player);

    await preview.play(Uint8List.fromList(<int>[1]));
    final first = preview.currentPath!;
    await preview.play(Uint8List.fromList(<int>[2]));

    expect(File(first).existsSync(), isFalse, reason: '旧临时文件必须删');
    expect(player.opened, hasLength(2));
    await preview.dispose();
  });
}
