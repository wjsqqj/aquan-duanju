import 'package:aquan_duanju/core/player/player_engine.dart';
import 'package:aquan_duanju/core/reader/speech/listen_bgm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'speech_fakes.dart';

/// 背景音乐：独立播放器、单曲循环、跟随起停、失败静默。
class _BgmPlayer implements PlayerEngine {
  final FakeStream feed = FakeStream();
  final List<String> calls = <String>[];
  final List<String> opened = <String>[];
  final List<double> volumes = <double>[];
  final List<Duration> seeks = <Duration>[];

  /// 模拟打不开（文件不存在/格式不支持）。
  bool openFails = false;

  @override
  PlayerStream get stream => feed;

  @override
  Future<void> initialize() async => calls.add('init');

  @override
  Future<void> open(Media media, {bool play = true}) async {
    if (openFails) throw StateError('打不开');
    opened.add(media.uri);
    calls.add('open');
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> dispose() async => calls.add('dispose');

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  test('start：建引擎、设音量、打开文件', () async {
    final player = _BgmPlayer();
    final bgm = ListenBgm(engineFactory: () => player);

    await bgm.start('/music/a.mp3', volume: 0.3);

    expect(bgm.isActive, isTrue);
    expect(bgm.file, '/music/a.mp3');
    expect(player.opened, <String>['/music/a.mp3']);
    expect(player.volumes.first, 0.3);
    expect(player.calls, containsAllInOrder(<String>['init', 'open']));
  });

  test('同一文件再次 start：只 resume，不重建播放器', () async {
    final players = <_BgmPlayer>[];
    final bgm = ListenBgm(
      engineFactory: () {
        final player = _BgmPlayer();
        players.add(player);
        return player;
      },
    );
    await bgm.start('/music/a.mp3');
    await bgm.pause();
    await bgm.start('/music/a.mp3');

    expect(players, hasLength(1), reason: '同文件不该重建播放器');
    expect(players.single.calls.where((c) => c == 'play'), isNotEmpty);
  });

  test('播完自动回到开头继续（单曲循环）', () async {
    final player = _BgmPlayer();
    final bgm = ListenBgm(engineFactory: () => player);
    await bgm.start('/music/a.mp3');

    player.feed.completedCtrl.add(true);
    await pumpEventQueue();

    expect(player.seeks, contains(Duration.zero));
    expect(player.calls.where((c) => c == 'play'), isNotEmpty);
  });

  test('暂停后播完事件不再触发循环', () async {
    final player = _BgmPlayer();
    final bgm = ListenBgm(engineFactory: () => player);
    await bgm.start('/music/a.mp3');
    await bgm.pause();

    player.feed.completedCtrl.add(true);
    await pumpEventQueue();

    expect(player.seeks, isEmpty);
  });

  test('空路径 = 关闭：不创建播放器', () async {
    final players = <_BgmPlayer>[];
    final bgm = ListenBgm(
      engineFactory: () {
        final player = _BgmPlayer();
        players.add(player);
        return player;
      },
    );
    await bgm.start('   ');
    expect(players, isEmpty);
    expect(bgm.isActive, isFalse);
  });

  test('打不开时静默放弃（不影响朗读）', () async {
    final player = _BgmPlayer()..openFails = true;
    final bgm = ListenBgm(engineFactory: () => player);

    await bgm.start('/music/broken.mp3');

    expect(bgm.isActive, isFalse);
    expect(player.calls, contains('dispose'), reason: '失败要释放播放器');
  });

  test('stop：停并释放，之后再收到 completed 也不动', () async {
    final player = _BgmPlayer();
    final bgm = ListenBgm(engineFactory: () => player);
    await bgm.start('/music/a.mp3');
    await bgm.stop();

    expect(bgm.isActive, isFalse);
    expect(player.calls, containsAll(<String>['stop', 'dispose']));

    player.feed.completedCtrl.add(true);
    await pumpEventQueue();
    expect(player.seeks, isEmpty);
  });

  test('音量夹在 0..1', () async {
    final player = _BgmPlayer();
    final bgm = ListenBgm(engineFactory: () => player);
    await bgm.start('/music/a.mp3', volume: 5.0);
    expect(player.volumes.first, 1.0);
    await bgm.setVolume(-1);
    expect(player.volumes.last, 0.0);
  });
}
