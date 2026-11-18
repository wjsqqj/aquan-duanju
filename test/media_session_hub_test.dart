import 'dart:io';

import 'package:aquan_duanju/core/media_session_hub.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// A7 复合路由：命令分发、互斥让位、非 Android no-op。
///
/// Windows 测试宿主跑不了 `AudioService.init`——复合逻辑本身与平台通道
/// 零耦合，测试经 `debugAttachHandler` 注入预构建 handler 直驱。
class _FakeDelegate implements MediaSessionDelegate {
  _FakeDelegate(this.id);

  @override
  final String id;

  /// 覆写为具体类型：测试直接读命令记录（协变返回类型合法）。
  @override
  final _FakeHandler handler = _FakeHandler();

  int suspendedCount = 0;

  @override
  Future<void> onSuspended() async => suspendedCount++;
}

class _FakeHandler extends BaseAudioHandler {
  final List<String> commands = <String>[];

  @override
  Future<void> play() async => commands.add('play');

  @override
  Future<void> pause() async => commands.add('pause');

  @override
  Future<void> stop() async => commands.add('stop');

  @override
  Future<void> skipToNext() async => commands.add('next');

  @override
  Future<void> skipToPrevious() async => commands.add('prev');

  @override
  Future<void> seek(Duration position) async =>
      commands.add('seek:${position.inSeconds}');
}

/// 让流事件跑完（rxdart 主题可能异步投递）。
Future<void> flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('MediaHubAudioHandler 复合路由命令分发', () {
    test('无激活委托时命令静默丢弃（后台按键不许崩）', () async {
      final hub = MediaHubAudioHandler();
      await hub.play();
      await hub.pause();
      await hub.seek(Duration.zero);
      expect(hub.activeDelegate, isNull);
    });

    test('命令只到激活委托，换手后旧委托不再收命令', () async {
      final hub = MediaHubAudioHandler();
      final a = _FakeDelegate('a');
      final b = _FakeDelegate('b');

      hub.attachDelegate(a);
      await hub.play();
      await hub.seek(const Duration(seconds: 7));
      expect(a.handler.commands, <String>['play', 'seek:7']);
      expect(b.handler.commands, isEmpty);

      hub.attachDelegate(b);
      await hub.pause();
      await hub.stop();
      expect(b.handler.commands, <String>['pause', 'stop']);
      // 换手后 a 不再收命令。
      expect(a.handler.commands, <String>['play', 'seek:7']);
    });

    test('attachDelegate 幂等：重复接管无副作用', () async {
      final hub = MediaHubAudioHandler();
      final a = _FakeDelegate('a');
      hub.attachDelegate(a);
      hub.attachDelegate(a);
      await hub.skipToNext();
      expect(a.handler.commands, <String>['next']);
      expect(hub.activeDelegate, same(a));
    });

    test('状态镜像：接管即回放宿主现态，后续发布跟随', () async {
      final hub = MediaHubAudioHandler();
      final a = _FakeDelegate('a');
      a.handler.mediaItem.add(const MediaItem(id: 'ep-1', title: '第1集'));

      hub.attachDelegate(a);
      a.handler.playbackState.add(PlaybackState(playing: true));
      await flush();

      expect(hub.mediaItem.value?.id, 'ep-1');
      expect(hub.playbackState.value.playing, isTrue);
    });

    test('让位先断镜像：旧宿主让位期间的发布不再进通知', () async {
      final hub = MediaHubAudioHandler();
      final a = _FakeDelegate('a');
      final b = _FakeDelegate('b');

      hub.attachDelegate(a);
      hub.attachDelegate(b);
      a.handler.playbackState.add(PlaybackState(playing: true));
      await flush();

      expect(hub.playbackState.value.playing, isFalse);
    });

    test('detachDelegate 只认当前激活委托；collapse 收敛为 idle', () async {
      final hub = MediaHubAudioHandler();
      final a = _FakeDelegate('a');
      final b = _FakeDelegate('b');

      hub.attachDelegate(a);
      hub.attachDelegate(b);
      hub.detachDelegate(a); // 不是激活委托：无害跳过
      expect(hub.activeDelegate, same(b));

      b.handler.playbackState.add(PlaybackState(playing: true));
      await flush();
      expect(hub.playbackState.value.playing, isTrue);

      hub.detachDelegate(b);
      expect(hub.activeDelegate, isNull);
      expect(
        hub.playbackState.value.playing,
        isTrue,
        reason: 'detach 只断镜像不收敛，收敛必须显式 collapse',
      );

      hub.collapse();
      await flush();
      expect(
        hub.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      expect(hub.playbackState.value.playing, isFalse);
      expect(hub.mediaItem.value, isNull);
    });
  });

  group('MediaSessionHub 互斥让位序列', () {
    setUp(() {
      MediaSessionHub.instance.debugReset();
      MediaSessionHub.instance.debugAttachHandler(MediaHubAudioHandler());
    });

    tearDown(() => MediaSessionHub.instance.debugReset());

    Future<MediaHubAudioHandler> hubHandler() async {
      final handler = await MediaSessionHub.instance.ensureInit();
      expect(handler, isNotNull, reason: '测试已注入 handler');
      return handler!;
    }

    test('activate B 让位 A：A 被暂停（onSuspended）、命令路由切到 B', () async {
      final hub = MediaSessionHub.instance;
      final handler = await hubHandler();
      final a = _FakeDelegate('a');
      final b = _FakeDelegate('b');

      await hub.activate(a);
      expect(hub.activeDelegate?.id, 'a');
      expect(a.handler.commands, isEmpty, reason: 'activate 不发命令');

      await hub.activate(b);
      expect(a.suspendedCount, 1);
      expect(hub.activeDelegate?.id, 'b');

      await handler.play();
      await flush();
      expect(b.handler.commands, <String>['play']);
      expect(a.handler.commands, isEmpty, reason: '让位后命令不再进 A');
    });

    test('被让位的宿主不许自己抢回，当前宿主退场后解除锁定', () async {
      final hub = MediaSessionHub.instance;
      final a = _FakeDelegate('a');
      final b = _FakeDelegate('b');

      await hub.activate(a);
      await hub.activate(b); // A 被让位
      await hub.activate(a); // A 在途发布抢回：拒绝
      expect(hub.activeDelegate?.id, 'b');
      expect(b.suspendedCount, 0, reason: '不许横跳');

      await hub.deactivate(b); // B 退场：解锁
      await hub.activate(a); // 宿主真活着（如回到听书页点播放）：可接管
      expect(hub.activeDelegate?.id, 'a');
      expect(a.suspendedCount, 1, reason: '解锁后接管不再触发一次让位');
    });

    test('当前宿主退场：收敛通知（idle）', () async {
      final hub = MediaSessionHub.instance;
      final handler = await hubHandler();
      final a = _FakeDelegate('a');

      await hub.activate(a);
      a.handler.playbackState.add(PlaybackState(playing: true));
      await flush();
      expect(handler.playbackState.value.playing, isTrue);

      await hub.deactivate(a);
      await flush();
      expect(hub.activeDelegate, isNull);
      expect(handler.playbackState.value.playing, isFalse);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      expect(handler.mediaItem.value, isNull);
    });

    test('deactivate 只认当前激活委托', () async {
      final hub = MediaSessionHub.instance;
      final a = _FakeDelegate('a');
      final b = _FakeDelegate('b');

      await hub.activate(a);
      await hub.activate(b);
      await hub.deactivate(a); // 不是激活委托：无害跳过
      expect(hub.activeDelegate?.id, 'b');
    });
  });

  group('非 Android 平台 no-op', () {
    test('未 init 时 ensureInit 返回 null，activate/deactivate 全空转', () async {
      if (Platform.isAndroid) return; // 该用例只在桌面跑
      MediaSessionHub.instance.debugReset();
      final hub = MediaSessionHub.instance;
      final a = _FakeDelegate('a');

      expect(await hub.ensureInit(), isNull);
      await hub.activate(a);
      await hub.deactivate(a);
      expect(hub.activeDelegate, isNull);
      expect(a.suspendedCount, 0);
    });
  });
}
