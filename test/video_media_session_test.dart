import 'dart:io';

import 'package:aquan_duanju/core/media_session_hub.dart';
import 'package:aquan_duanju/core/video_media_session.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// A7 视频媒体会话：MediaItem/PlaybackState 拼装、命令分发、让位与
/// 页替换顺序；播放页接线沿用源码结构断言口径（`player_gesture_help_test`）。
///
/// 会话方法与平台通道零耦合（平台门控在 hub），Windows 宿主经
/// `debugAttachHandler` 注入复合 handler 直驱。
class _OtherDelegate implements MediaSessionDelegate {
  @override
  final _NoopHandler handler = _NoopHandler();

  @override
  String get id => 'other';

  @override
  Future<void> onSuspended() async {}
}

class _NoopHandler extends BaseAudioHandler {}

/// 让流事件跑完（rxdart 主题可能异步投递）。
Future<void> flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

VideoMediaState _state({
  String mediaId = 'ep-1',
  String seriesTitle = '测试剧',
  int episodeNumber = 1,
  String? artUri = 'https://cdn.example.com/cover.jpg',
  Duration? duration,
  bool playing = true,
  bool buffering = false,
  Duration position = const Duration(seconds: 30),
  double speed = 1.0,
  bool canNext = true,
  bool canPrev = true,
}) => VideoMediaState(
  mediaId: mediaId,
  seriesTitle: seriesTitle,
  episodeNumber: episodeNumber,
  artUri: artUri,
  duration: duration,
  playing: playing,
  buffering: buffering,
  position: position,
  speed: speed,
  canNext: canNext,
  canPrev: canPrev,
);

void main() {
  group('MediaItem 拼装（design A7：title=剧名·第N集 / album=剧名 / 封面 / 时长）', () {
    test('字段拼装', () {
      final item = buildVideoMediaItem(
        _state(
          mediaId: 'ep-42',
          seriesTitle: '我的短剧',
          episodeNumber: 42,
          artUri: 'https://cdn.example.com/cover.jpg',
          duration: const Duration(seconds: 95),
        ),
      );
      expect(item.id, 'ep-42');
      expect(item.title, '我的短剧 · 第42集');
      expect(item.album, '我的短剧');
      expect(item.artUri, Uri.parse('https://cdn.example.com/cover.jpg'));
      expect(item.duration, const Duration(seconds: 95));
    });

    test('封面缺失/非法：交给系统默认图标，不抛', () {
      expect(buildVideoMediaItem(_state(artUri: null)).artUri, isNull);
      expect(buildVideoMediaItem(_state(artUri: '')).artUri, isNull);
      // 非法串不炸拼装（真值：Uri.tryParse 几乎总能解析出个相对/规整 Uri，
      // 系统取图失败自然回退默认图标）。
      expect(() => buildVideoMediaItem(_state(artUri: '%')), returnsNormally);
      expect(
        () => buildVideoMediaItem(_state(artUri: 'not a uri')),
        returnsNormally,
      );
    });

    test('时长未知透传 null（拿 0 冒充总长会让锁屏进度条一直是满的）', () {
      expect(buildVideoMediaItem(_state(duration: null)).duration, isNull);
    });
  });

  group('PlaybackState 拼装（三键 + 拖动进度）', () {
    test('播放中给 pause 键、暂停给 play 键；prev/next 排布', () {
      final playing = buildVideoPlaybackState(_state(playing: true));
      expect(playing.controls.map((c) => c.action), <MediaAction>[
        MediaAction.skipToPrevious,
        MediaAction.pause,
        MediaAction.skipToNext,
      ]);

      final paused = buildVideoPlaybackState(_state(playing: false));
      expect(paused.controls.map((c) => c.action), <MediaAction>[
        MediaAction.skipToPrevious,
        MediaAction.play,
        MediaAction.skipToNext,
      ]);
    });

    test('canPrev/canNext 边界禁用：compact 索引不越界', () {
      final noPrev = buildVideoPlaybackState(
        _state(canNext: true, canPrev: false),
      );
      expect(noPrev.controls.map((c) => c.action), <MediaAction>[
        MediaAction.pause,
        MediaAction.skipToNext,
      ]);
      expect(noPrev.androidCompactActionIndices, <int>[0, 1]);

      final none = buildVideoPlaybackState(
        _state(canNext: false, canPrev: false),
      );
      expect(none.controls.map((c) => c.action), <MediaAction>[
        MediaAction.pause,
      ]);
      expect(none.androidCompactActionIndices, <int>[0]);
    });

    test('缓冲映射 processingState，位置/倍速透传', () {
      final buffering = buildVideoPlaybackState(_state(buffering: true));
      expect(buffering.processingState, AudioProcessingState.buffering);
      expect(buffering.playing, isTrue);

      final normal = buildVideoPlaybackState(_state(buffering: false));
      expect(normal.processingState, AudioProcessingState.ready);
      expect(normal.updatePosition, const Duration(seconds: 30));
      expect(normal.speed, 1.0);
      expect(normal.systemActions, contains(MediaAction.seek));
    });
  });

  group('VideoMediaSession 命令分发与让位', () {
    setUp(() {
      MediaSessionHub.instance.debugReset();
      MediaSessionHub.instance.debugAttachHandler(MediaHubAudioHandler());
      VideoMediaSession.instance.debugReset();
    });

    tearDown(() {
      MediaSessionHub.instance.debugReset();
      VideoMediaSession.instance.debugReset();
    });

    Future<MediaHubAudioHandler> injectedHub() async {
      final handler = await MediaSessionHub.instance.ensureInit();
      expect(handler, isNotNull);
      return handler!;
    }

    /// 挂一个新宿主（owner 每次新建），返回 owner 供 detach 配对断言。
    Future<Object> attachOwner(List<Object?> got) async {
      final owner = Object();
      await VideoMediaSession.instance.attach(
        owner,
        onPlay: () => got.add('play'),
        onPause: () => got.add('pause'),
        onSeek: (position) => got.add('seek:${position.inSeconds}'),
        onNext: () => got.add('next'),
        onPrev: () => got.add('prev'),
      );
      return owner;
    }

    test('命令 → 播放页回调（含经 hub 路由）', () async {
      final hubHandler = await injectedHub();
      final got = <Object?>[];
      await attachOwner(got);
      await flush();
      expect(MediaSessionHub.instance.activeDelegate?.id, 'video');

      final sessionHandler = VideoMediaSession.instance.handler;
      await sessionHandler.play();
      await sessionHandler.pause();
      await sessionHandler.skipToNext();
      await sessionHandler.skipToPrevious();
      await sessionHandler.seek(const Duration(seconds: 88));
      // 系统侧 stop 退化为暂停；±10s / setSpeed 未提供（倍速真值在 App 内）。
      await sessionHandler.stop();
      await sessionHandler.fastForward();
      await sessionHandler.rewind();
      await sessionHandler.setSpeed(2.0);
      await flush();

      expect(got, <String>[
        'play',
        'pause',
        'next',
        'prev',
        'seek:88',
        'pause',
      ]);

      // 复合路由同链路：系统命令 → hub → 视频桥回调。
      await hubHandler.pause();
      await flush();
      expect(got.last, 'pause');
      expect(got, hasLength(7));
    });

    test('发布：mediaId 不变只更状态，时长变化触发元数据重建', () async {
      await attachOwner(<Object?>[]);
      final sessionHandler = VideoMediaSession.instance.handler;
      final items = <MediaItem?>[];
      final sub = sessionHandler.mediaItem.listen(items.add);

      await VideoMediaSession.instance.publish(
        _state(
          mediaId: 'ep-1',
          duration: const Duration(seconds: 60),
          position: const Duration(seconds: 5),
        ),
      );
      await VideoMediaSession.instance.publish(
        _state(
          mediaId: 'ep-1',
          duration: const Duration(seconds: 60),
          position: const Duration(seconds: 6),
        ),
      );
      await VideoMediaSession.instance.publish(
        _state(
          mediaId: 'ep-1',
          duration: const Duration(seconds: 61),
          position: const Duration(seconds: 6),
        ),
      );
      await flush();
      await sub.cancel();

      // mediaItem 事件：seed(null) + ep-1@60s + ep-1@61s —— 时长变化才重建。
      expect(items, hasLength(3));
      expect(items[0], isNull);
      expect(items[1]?.id, 'ep-1');
      expect(items[1]?.duration, const Duration(seconds: 60));
      expect(items[2]?.duration, const Duration(seconds: 61));

      // playbackState 每次都发（位置外推锚点跟随最新发布）。
      expect(
        sessionHandler.playbackState.value.updatePosition,
        const Duration(seconds: 6),
      );
    });

    test('attach 前发布安全空转（无 handler）', () async {
      expect(VideoMediaSession.instance.debugOwner, isNull);
      await VideoMediaSession.instance.publish(_state());
      expect(() => VideoMediaSession.instance.handler, throwsStateError);
    });

    test('detach 按 owner 配对：新页先 attach、旧页后 dispose 不拆新宿主', () async {
      final hubHandler = await injectedHub();
      final oldGot = <Object?>[];
      final newGot = <Object?>[];
      final oldOwner = await attachOwner(oldGot);
      final newOwner = await attachOwner(newGot);
      expect(identical(oldOwner, newOwner), isFalse);

      await VideoMediaSession.instance.detach(oldOwner); // 旧页 dispose：跳过
      expect(
        MediaSessionHub.instance.activeDelegate?.id,
        'video',
        reason: '跨季 pushReplacement 会话保持连续',
      );
      await hubHandler.play();
      await flush();
      expect(newGot, <String>['play'], reason: '回调已被新页接管');
      expect(oldGot, isEmpty);

      await VideoMediaSession.instance.detach(newOwner); // 新页正常退出
      expect(MediaSessionHub.instance.activeDelegate, isNull);
      await flush();
      expect(
        hubHandler.playbackState.value.processingState,
        AudioProcessingState.idle,
        reason: '退出收敛通知',
      );
      expect(VideoMediaSession.instance.debugOwner, isNull);
      await hubHandler.play();
      await flush();
      expect(newGot, <String>['play'], reason: 'detach 清空回调：按键静默丢弃');
      expect(
        hubHandler.playbackState.value.playing,
        isFalse,
        reason: '无激活委托时命令静默，状态不翻转',
      );
    });

    test('让位：听书接管 → 视频暂停（互斥）', () async {
      final got = <Object?>[];
      await attachOwner(got);
      await flush();

      final listenLike = _OtherDelegate();
      await MediaSessionHub.instance.activate(listenLike);
      expect(got, <String>['pause'], reason: '视频桥让位 = 暂停当前视频');
      expect(MediaSessionHub.instance.activeDelegate?.id, 'other');
    });
  });

  group('接线证据（源码结构断言）', () {
    test('播放页：Android 进入/退出接线与状态同步点齐全', () {
      final source = File('lib/screens/player_screen.dart').readAsStringSync();
      // 进入播放页（Android 门控，与 _initPip 同款）。
      expect(source, contains('if (Platform.isAndroid) _initVideoMedia();'));
      // 命令回调走既有语义（_goNext/_goPrev/_seekTo/_engine）。
      expect(source, contains('onNext: () => _goNext(manual: true)'));
      expect(source, contains('onPrev: () => _goPrev(manual: true)'));
      expect(
        source,
        contains('onSeek: (position) => unawaited(_seekTo(position))'),
      );
      // 事件源接线：每秒进度 + 换集/播放态/缓冲/时长同步 + 退出停用。
      expect(source, contains('_syncVideoMediaPosition();'));
      expect(source, contains('void _syncVideoMedia() {'));
      expect(source, contains('VideoMediaSession.instance.detach(this)'));
    });

    test('听书会话：init 走 hub、活着的发布才激活（finished 收敛不抢会话）', () {
      final source = File('lib/core/reader/speech/listen_media_session.dart')
          .readAsStringSync();
      expect(source, contains('MediaSessionHub.instance.ensureInit()'));
      expect(source, contains('if (!state.finished) {'));
      expect(source, contains('MediaSessionHub.instance.activate(delegate)'));
    });

    test('manifest：audio_service 前台服务 mediaPlayback（熄屏播放前提）', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(manifest, contains('com.ryanheise.audioservice.AudioService'));
      expect(
        manifest,
        contains('android:foregroundServiceType="mediaPlayback"'),
      );
    });
  });
}
