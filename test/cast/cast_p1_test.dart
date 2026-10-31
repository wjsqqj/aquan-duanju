import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';

DlnaDevice _dlna(String udn) => DlnaDevice(
      udn: udn,
      friendlyName: '客厅电视',
      controlUrl: 'http://127.0.0.1:1/ctrl',
      location: 'http://192.168.1.9/desc.xml',
    );

CastTarget _target(String udn) => CastTarget.dlna(_dlna(udn));

/// 脚本化 transport：poll 序列 + 可选的第二次 setUri 失败。
class _ScriptedTransport implements CastTransport {
  final List<CastPoll> pollScript;
  bool failSecondSetUri = false;
  int setUriCount = 0;
  final calls = <String>[];

  _ScriptedTransport(this.pollScript);

  @override
  Future<void> setUri(Uri url,
      {required String title, String? duration, Uri? subtitleUrl}) async {
    setUriCount++;
    calls.add('setUri:$url');
    if (failSecondSetUri && setUriCount >= 2) {
      throw SoapException('SetAVTransportURI 失败 HTTP 500',
          faultCode: 'UPnPError');
    }
  }

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seekTo(Duration position) async => calls.add('seek');
  @override
  Future<void> setVolume(int percent) async => calls.add('volume:$percent');
  @override
  Future<void> setMute(bool muted) async => calls.add('mute:$muted');

  int _pollIndex = 0;

  @override
  Future<CastPoll> poll() async {
    calls.add('poll');
    final i = _pollIndex.clamp(0, pollScript.length - 1);
    _pollIndex++;
    return pollScript[i];
  }

  @override
  void close() {}
}

const _running = CastPoll(
  transportState: 'RUNNING',
  position: Duration(seconds: 590),
  duration: Duration(minutes: 10),
);
const _ended = CastPoll(
  transportState: 'STOPPED',
  position: Duration(seconds: 596),
  duration: Duration(minutes: 10),
);
const _midStop = CastPoll(
  transportState: 'STOPPED',
  position: Duration(minutes: 2),
  duration: Duration(minutes: 10),
);

void main() {
  test('播完（接近时长结尾）自动连投下一集，会话不中断', () async {
    final transport = _ScriptedTransport([_running, _ended]);
    final controller = CastController(transportFactory: (_) => transport);
    var remoteStopped = 0;
    controller.onRemoteStopped = (_, _) => remoteStopped++;

    await controller.castTo(
      _target('d1'),
      const CastMedia(url: 'http://x/1.mp4', title: '第1集'),
    );
    controller.onNextEpisode = () async =>
        const CastMedia(url: 'http://x/2.mp4', title: '第2集');

    // 等两轮 1s 轮询触发 ended 分支。
    await Future<void>.delayed(const Duration(milliseconds: 2300));

    expect(transport.setUriCount, 2);
    expect(transport.calls.contains('setUri:http://x/2.mp4'), isTrue);
    expect(transport.calls.contains('play'), isTrue);
    expect(controller.state, CastSessionState.casting, reason: '连投后会话继续');
    expect(controller.currentMedia?.title, '第2集');
    expect(remoteStopped, 0, reason: '正常连投不应触发远端停止');
    controller.dispose();
  });

  test('停在中途：视为遥控器手动停止，不连投', () async {
    final transport = _ScriptedTransport([_running, _midStop]);
    final controller = CastController(transportFactory: (_) => transport);
    final stopped = Completer<Duration>();
    controller.onRemoteStopped = (_, position) => stopped.complete(position);

    await controller.castTo(
      _target('d1'),
      const CastMedia(url: 'http://x/1.mp4', title: '第1集'),
    );
    controller.onNextEpisode = () async =>
        const CastMedia(url: 'http://x/2.mp4', title: '第2集');

    final position = await stopped.future.timeout(const Duration(seconds: 3));
    expect(position, const Duration(minutes: 2));
    expect(transport.setUriCount, 1, reason: '不应连投');
    expect(controller.state, CastSessionState.idle);
    controller.dispose();
  });

  test('没有下一集：走远端停止路径', () async {
    final transport = _ScriptedTransport([_running, _ended]);
    final controller = CastController(transportFactory: (_) => transport);
    final stopped = Completer<void>();
    controller.onRemoteStopped = (_, _) => stopped.complete();

    await controller.castTo(
      _target('d1'),
      const CastMedia(url: 'http://x/1.mp4', title: '第1集'),
    );
    controller.onNextEpisode = () async => null;

    await stopped.future.timeout(const Duration(seconds: 3));
    expect(transport.setUriCount, 1);
    expect(controller.state, CastSessionState.idle);
    controller.dispose();
  });

  test('连投推送失败：回退远端停止路径', () async {
    final transport = _ScriptedTransport([_running, _ended])
      ..failSecondSetUri = true;
    final controller = CastController(transportFactory: (_) => transport);
    final stopped = Completer<void>();
    controller.onRemoteStopped = (_, _) => stopped.complete();

    await controller.castTo(
      _target('d1'),
      const CastMedia(url: 'http://x/1.mp4', title: '第1集'),
    );
    controller.onNextEpisode = () async =>
        const CastMedia(url: 'http://x/2.mp4', title: '第2集');

    await stopped.future.timeout(const Duration(seconds: 3));
    expect(controller.state, CastSessionState.idle);
    controller.dispose();
  });

  test('会话结束清空连播提供器', () async {
    final transport = _ScriptedTransport([_running, _midStop]);
    final controller = CastController(transportFactory: (_) => transport);
    final stopped = Completer<void>();
    controller.onRemoteStopped = (_, _) => stopped.complete();

    await controller.castTo(
      _target('d1'),
      const CastMedia(url: 'http://x/1.mp4', title: '第1集'),
    );
    controller.onNextEpisode = () async =>
        const CastMedia(url: 'http://x/2.mp4', title: '第2集');
    await stopped.future.timeout(const Duration(seconds: 3));
    expect(controller.onNextEpisode, isNull, reason: '防止旧闭包跨会话生效');
    controller.dispose();
  });

  test('setMute 透传到 transport', () async {
    final transport = _ScriptedTransport([_running]);
    final controller = CastController(transportFactory: (_) => transport);
    await controller.castTo(
      _target('d1'),
      const CastMedia(url: 'http://x/1.mp4', title: 't'),
    );
    await controller.setMute(true);
    expect(transport.calls.contains('mute:true'), isTrue);
    controller.dispose();
  });
}
