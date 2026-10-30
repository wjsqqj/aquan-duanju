import 'dart:io';

import 'package:aquan_duanju/core/reader/speech/listen_media_bridge.dart';
import 'package:aquan_duanju/core/reader/speech/listen_media_session.dart';
import 'package:aquan_duanju/core/reader/speech/listen_media_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假的会话实现：记录发布、暴露命令上抛口（不碰任何平台通道）。
class _FakeSession implements ListenMediaSession {
  void Function(ListenMediaCommand cmd, Duration? position)? sink;
  final List<ListenMediaState> published = <ListenMediaState>[];
  bool disposed = false;
  bool throwOnPublish = false;

  @override
  set onCommand(void Function(ListenMediaCommand cmd, Duration? position)? s) =>
      sink = s;

  @override
  Future<void> publish(ListenMediaState state) async {
    // 即使抛异常，桥也必须吞掉——会话失败不许影响播放。
    if (throwOnPublish) throw StateError('session down');
    published.add(state);
  }

  @override
  Future<void> dispose() async => disposed = true;
}

ListenMediaState _state({
  String mediaId = 'c1',
  bool playing = true,
  Duration position = Duration.zero,
  Duration? total,
  bool buffering = false,
  bool canNext = true,
  bool canPrev = false,
}) =>
    ListenMediaState(
      mediaId: mediaId,
      title: '测试书',
      chapterTitle: '第一章',
      artUri: null,
      playing: playing,
      buffering: buffering,
      position: position,
      total: total,
      speed: 1.5,
      chapterIndex: 0,
      chapterCount: 3,
      canNext: canNext,
      canPrev: canPrev,
    );

void main() {
  group('发布状态', () {
    test('publish 原样透传（含 total 为 null、封面为空）', () async {
      final session = _FakeSession();
      final bridge = ListenMediaBridge(session);

      await bridge.publish(_state(total: null));
      await bridge.publish(_state(total: const Duration(minutes: 10)));

      expect(session.published, hasLength(2));
      expect(session.published.first.total, isNull);
      expect(session.published.first.artUri, isNull);
      expect(session.published.last.total, const Duration(minutes: 10));
      expect(session.published.last.speed, 1.5);
    });

    test('会话抛异常被吞：不影响调用方（播放不能被媒体会话拖垮）', () async {
      final session = _FakeSession()..throwOnPublish = true;
      final bridge = ListenMediaBridge(session);

      await expectLater(bridge.publish(_state()), completes);
      expect(session.published, isEmpty);
    });

    test('dispose 之后不再发布', () async {
      final session = _FakeSession();
      final bridge = ListenMediaBridge(session);
      await bridge.dispose();
      await bridge.publish(_state());
      expect(session.disposed, isTrue);
      expect(session.published, isEmpty);
    });
  });

  group('命令派发', () {
    test('派发给当前宿主；position 只在 seekTo 时有意义', () async {
      final session = _FakeSession();
      final bridge = ListenMediaBridge(session);
      final got = <String>[];
      bridge.attach((cmd, pos) {
        got.add('${cmd.name}@${pos?.inSeconds}');
      });

      session.sink!(ListenMediaCommand.toggle, null);
      session.sink!(ListenMediaCommand.nextChapter, null);
      session.sink!(ListenMediaCommand.seekTo, const Duration(seconds: 42));

      expect(got, <String>['toggle@null', 'nextChapter@null', 'seekTo@42']);
    });

    test('未 attach 时静默丢弃（后台按键不许崩）', () async {
      final session = _FakeSession();
      final bridge = ListenMediaBridge(session);
      expect(bridge.hasHandler, isFalse);
      session.sink!(ListenMediaCommand.play, null); // 不抛即可
      expect(bridge.hasHandler, isFalse);
    });

    test('seekTo 缺 position 被丢弃（绝不跳回章节开头）', () async {
      final session = _FakeSession();
      final bridge = ListenMediaBridge(session);
      var calls = 0;
      bridge.attach((_, _) => calls++);

      session.sink!(ListenMediaCommand.seekTo, null);
      expect(calls, 0);

      session.sink!(ListenMediaCommand.seekTo, Duration.zero);
      expect(calls, 1, reason: '显式 0 是合法位置，必须接受');
    });

    test('attach 幂等：同宿主重复挂只保留一份', () async {
      final session = _FakeSession();
      final bridge = ListenMediaBridge(session);
      var calls = 0;
      void handler(ListenMediaCommand cmd, Duration? pos) => calls++;

      bridge.attach(handler);
      bridge.attach(handler);
      session.sink!(ListenMediaCommand.pause, null);
      expect(calls, 1);
    });

    test('旧页 detach 不得擦掉新宿主（新 attach 后旧 dispose 的顺序问题）', () async {
      final session = _FakeSession();
      final bridge = ListenMediaBridge(session);
      final calls = <String>[];
      void oldHandler(ListenMediaCommand cmd, Duration? pos) =>
          calls.add('old:${cmd.name}');
      void newHandler(ListenMediaCommand cmd, Duration? pos) =>
          calls.add('new:${cmd.name}');

      bridge.attach(oldHandler);
      bridge.attach(newHandler); // 新页接管
      bridge.detach(oldHandler); // 旧页销毁（晚了）

      session.sink!(ListenMediaCommand.play, null);
      expect(calls, <String>['new:play'], reason: '新宿主的回调必须还在');
    });

    test('宿主自身抛异常不会冒到平台通道', () async {
      final session = _FakeSession();
      final bridge = ListenMediaBridge(session);
      bridge.attach((cmd, pos) => throw StateError('host bug'));

      expect(() => session.sink!(ListenMediaCommand.play, null), returnsNormally);
    });
  });

  group('平台门控（Windows 上直接可验）', () {
    test('非 Android 返回 Noop 会话，ensure() 给 null', () async {
      if (Platform.isAndroid) return; // 该用例只在桌面跑
      final session = createListenMediaSession();
      expect(session, isA<NoopListenMediaSession>());

      expect(await ListenMediaBridge.ensure(), isNull);
    });

    test('Noop 会话全空转：发布/释放/注入命令都不抛', () async {
      const session = NoopListenMediaSession();
      session.onCommand = (cmd, pos) {};
      await expectLater(session.publish(_state()), completes);
      await expectLater(session.dispose(), completes);
    });
  });
}
