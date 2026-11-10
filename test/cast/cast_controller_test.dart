import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_diagnostics.dart';
import 'package:aquan_duanju/core/cast/cast_media_type.dart';
import 'package:aquan_duanju/core/cast/cast_recipe.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/didl.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';
import 'package:aquan_duanju/store/stores.dart';

DlnaDevice _device(String udn) => DlnaDevice(
      udn: udn,
      friendlyName: '测试电视',
      controlUrl: 'http://127.0.0.1:1/ctrl',
    );

/// 假 transport：脚本化 poll 结果与故障注入。
class FakeTransport implements CastTransport {
  FakeTransport();

  final List<String> calls = [];
  CastPoll pollResult =
      const CastPoll(transportState: 'RUNNING', position: Duration(seconds: 30));
  Object? setUriError;
  Object? stopError;
  Object? seekError;

  @override
  Future<void> setUri(Uri url,
      {required String title, String? duration, Uri? subtitleUrl}) async {
    calls.add('setUri:$url'
        '${duration == null ? '' : ' duration=$duration'}');
    if (setUriError != null) throw setUriError!;
  }

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (stopError != null) throw stopError!;
  }

  @override
  Future<void> seekTo(Duration position) async {
    calls.add('seek:$position');
    if (seekError != null) throw seekError!;
  }
  @override
  Future<void> setVolume(int percent) async => calls.add('volume:$percent');
  @override
  Future<void> setMute(bool muted) async => calls.add('mute:$muted');

  @override
  Future<CastPoll> poll() async {
    calls.add('poll');
    return pollResult;
  }

  @override
  void close() {}
}

CastMedia _media() =>
    const CastMedia(url: 'http://192.168.1.10/1.m3u8', title: '测试 · 第1集');

CastTarget _target(String udn) => CastTarget.dlna(_device(udn));

/// 兼容层假 transport：捕获 CastLoadRequest（M1-2/M1-8/M3 接线断言用）。
class CapturingCompatTransport implements CastTransport, CastCompatTransport {
  CapturingCompatTransport();

  final List<String> calls = <String>[];
  CastLoadRequest? lastRequest;
  Set<String> sinkAnswer = <String>{'http-get:*:video/mp4:*'};

  /// load 成功时返回的配方（可注入以模拟某台设备只吃 compact+bare）。
  CastRecipe hitRecipe = const CastRecipe(didl: DidlVariant.full);

  /// 轮询结果（连播测试切 STOPPED 触发播完连投）。
  CastPoll pollResult =
      const CastPoll(transportState: 'PLAYING', position: Duration.zero);

  @override
  Future<Set<String>> preflight() async => sinkAnswer;

  @override
  Future<CastRecipe?> load(CastLoadRequest request) async {
    lastRequest = request;
    calls.add('load');
    return hitRecipe;
  }

  @override
  Future<void> setUri(Uri url,
      {required String title, String? duration, Uri? subtitleUrl}) async {
    calls.add('setUri:$url duration=$duration');
  }

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seekTo(Duration position) async {}
  @override
  Future<void> setVolume(int percent) async {}
  @override
  Future<void> setMute(bool muted) async {}
  @override
  Future<CastPoll> poll() async => pollResult;
  @override
  void close() {}
}

void main() {
  test('castTo：connecting → casting，先 setUri 后 play', () async {
    final transport = FakeTransport();
    final controller = CastController(transportFactory: (_) => transport);
    final states = <CastSessionState>[];
    controller.addListener(() => states.add(controller.state));

    await controller.castTo(_target('d1'), _media());

    expect(controller.state, CastSessionState.casting);
    expect(controller.isCasting, isTrue);
    expect(transport.calls.first, startsWith('setUri:http://192.168.1.10/1.m3u8'));
    expect(transport.calls, contains('play'));
    expect(states, contains(CastSessionState.connecting));
    controller.dispose();
  });

  test('castTo 失败：状态回 idle 并向上抛出', () async {
    final transport = FakeTransport()..setUriError = SoapException('设备未响应');
    final controller = CastController(transportFactory: (_) => transport);
    await expectLater(
      controller.castTo(_target('d1'), _media()),
      throwsA(isA<SoapException>()),
    );
    expect(controller.state, CastSessionState.idle);
    controller.dispose();
  });

  test('带起始位置：play 后追加 seek', () async {
    final transport = FakeTransport();
    final controller = CastController(transportFactory: (_) => transport);
    await controller.castTo(
      _target('d1'),
      const CastMedia(
          url: 'http://x/1.m3u8',
          title: 't',
          position: Duration(minutes: 5)),
    );
    expect(transport.calls.where((c) => c.startsWith('seek')), isNotEmpty);
    controller.dispose();
  });

  test('电视端主动停止（poll STOPPED）：onRemoteStopped 触发并回 idle', () async {
    final transport = FakeTransport();
    final controller = CastController(transportFactory: (_) => transport);
    final stopped = Completer<(CastTarget, Duration)>();
    controller.onRemoteStopped = (device, position) =>
        stopped.complete((device, position));

    await controller.castTo(_target('d1'), _media());
    // 1s 轮询：把结果改成 STOPPED。
    transport.pollResult =
        const CastPoll(transportState: 'STOPPED', position: Duration(minutes: 3));

    final (device, position) = await stopped.future.timeout(const Duration(seconds: 3));
    expect(device.id, 'd1');
    expect(position, const Duration(minutes: 3));
    expect(controller.state, CastSessionState.idle);
    expect(controller.currentDevice, isNull);
    controller.dispose();
  });

  test('disconnect：返回最后进度并下发 Stop；Stop 失败回退 Pause', () async {
    final transport = FakeTransport()
      ..pollResult = const CastPoll(
          transportState: 'RUNNING', position: Duration(minutes: 7))
      ..stopError = SoapException('Stop 失败 HTTP 501');
    final controller = CastController(transportFactory: (_) => transport);
    await controller.castTo(_target('d1'), _media());

    final position = await controller.disconnect();
    expect(position, const Duration(minutes: 7));
    expect(transport.calls.contains('stop'), isTrue);
    expect(transport.calls.contains('pause'), isTrue, reason: 'Stop 501 应回退 Pause');
    expect(controller.state, CastSessionState.idle);
    controller.dispose();
  });

  test('暂停/恢复/音量透传到 transport', () async {
    final transport = FakeTransport();
    final controller = CastController(transportFactory: (_) => transport);
    await controller.castTo(_target('d1'), _media());
    await controller.pause();
    await controller.resume();
    await controller.setVolume(40);
    expect(transport.calls.contains('pause'), isTrue);
    expect(transport.calls.contains('play'), isTrue);
    expect(transport.calls.contains('volume:40'), isTrue);
    controller.dispose();
  });

  group('进度拖动（乐观 seek / 失败回读）', () {
    test('seekTo 下发 transport 并乐观对齐本地进度（不等轮询）', () async {
      final transport = FakeTransport()
        ..pollResult = const CastPoll(
            transportState: 'PAUSED_PLAYBACK',
            position: Duration(seconds: 42),
            duration: Duration(minutes: 10));
      final controller = CastController(transportFactory: (_) => transport);
      await controller.castTo(_target('d1'), _media());
      // 先轮询一次拿到真值（42s），再模拟用户拖动。
      await controller.forceRefresh();
      expect(controller.remotePosition, const Duration(seconds: 42));

      await controller.seekTo(const Duration(minutes: 3));

      expect(transport.calls, contains('seek:${const Duration(minutes: 3)}'),
          reason: '拖动结束立即下发 Seek');
      expect(controller.remotePosition, const Duration(minutes: 3),
          reason: '乐观对齐：进度条不回跳，等下一轮轮询用真值校正');
      controller.dispose();
    });

    test('seekTo 失败：本地进度不被乐观值污染，forceRefresh 回读真实位置', () async {
      final transport = FakeTransport()
        ..seekError = SoapException('Seek 失败 HTTP 501', faultCode: 'UPnPError')
        ..pollResult = const CastPoll(
            transportState: 'PAUSED_PLAYBACK',
            position: Duration(seconds: 42),
            duration: Duration(minutes: 10));
      final controller = CastController(transportFactory: (_) => transport);
      await controller.castTo(_target('d1'), _media());
      // 先轮询一次拿到真值（42s），再模拟用户拖动。
      await controller.forceRefresh();
      expect(controller.remotePosition, const Duration(seconds: 42));

      await expectLater(
        controller.seekTo(const Duration(minutes: 5)),
        throwsA(isA<SoapException>()),
      );
      // 失败后本地进度仍是轮询真值（42s），没有乐观漂移。
      expect(controller.remotePosition, const Duration(seconds: 42));
      // 面板失败回读路径：forceRefresh 立即拉真实位置（仍是设备上报值）。
      await controller.forceRefresh();
      expect(controller.remotePosition, const Duration(seconds: 42));
      expect(transport.calls.where((c) => c.startsWith('seek:')).length, 1);
      controller.dispose();
    });
  });

  group('M1 媒体类型与 duration 接线（compat 链）', () {
    test('resolver 接入：.m3u8 → vnd.apple.mpegurl（旧 _mimeForCast 判 mp2t）',
        () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(_target('d1'), _media());
      expect(compat.lastRequest, isNotNull);
      expect(compat.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl');
      controller.dispose();
    });

    test('AC-13：Sink 只有 video/mp4 时也不覆盖 mime', () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:video/mp4:*'};
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(_target('d1'), _media());
      expect(compat.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl');
      controller.dispose();
    });

    test('Sink 拼写选择：Sink 用 x-mpegurl → 照抄设备写法', () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:application/x-mpegurl:*'};
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(_target('d1'), _media());
      expect(compat.lastRequest!.didl.mimeType, 'application/x-mpegurl');
      controller.dispose();
    });

    test('AC-27：真实时长接入 CastLoadRequest 与 DidlRequest', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://192.168.1.10/1.mp4',
          title: '测试 · 第1集',
          duration: Duration(minutes: 2, seconds: 3),
        ),
      );
      expect(compat.lastRequest!.didl.duration, const Duration(minutes: 2, seconds: 3));
      expect(compat.lastRequest!.duration, '0:02:03');
      controller.dispose();
    });

    test('AC-27：时长未知（null）不写 duration', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(_target('d1'), _media());
      expect(compat.lastRequest!.didl.duration, isNull);
      expect(compat.lastRequest!.duration, isNull);
      controller.dispose();
    });

    test('封面透传（AC-2）：CastMedia.coverUrl → DidlRequest.albumArtUrl',
        () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://192.168.1.10/1.mp4',
          title: '测试 · 第1集',
          coverUrl: 'http://192.168.1.10/cover.jpg?w=600',
        ),
      );
      expect(
        compat.lastRequest!.didl.albumArtUrl,
        Uri.parse('http://192.168.1.10/cover.jpg?w=600'),
      );
      controller.dispose();
    });

    test('封面透传：无封面 / 非 http(s) → albumArtUrl null（DIDL 零变化）',
        () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(_target('d1'), _media());
      expect(compat.lastRequest!.didl.albumArtUrl, isNull);

      final compat2 = CapturingCompatTransport();
      final controller2 = CastController(transportFactory: (_) => compat2);
      await controller2.castTo(
        _target('d2'),
        const CastMedia(
          url: 'file:///tmp/x.mp4',
          title: 't',
          coverUrl: 'ftp://x/cover.jpg',
        ),
      );
      expect(compat2.lastRequest!.didl.albumArtUrl, isNull,
          reason: '接收端只认 http(s)，非 http(s) 不写标签');
      controller.dispose();
      controller2.dispose();
    });

    test('标准路径 setUri 也带格式化时长', () async {
      final transport = FakeTransport();
      final controller = CastController(transportFactory: (_) => transport);
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://192.168.1.10/1.mp4',
          title: 't',
          duration: Duration(hours: 1, minutes: 2, seconds: 3),
        ),
      );
      expect(
        transport.calls.where((c) => c.startsWith('setUri')),
        isNotEmpty,
      );
      expect(
        transport.calls.firstWhere((c) => c.startsWith('setUri')),
        contains('duration=1:02:03'),
      );
      controller.dispose();
    });

    test('mimeHint 作为显式 hint 优先于扩展名判定', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://192.168.1.10/1.m3u8',
          title: 't',
          mimeHint: 'application/x-mpegurl',
        ),
      );
      expect(compat.lastRequest!.didl.mimeType, 'application/x-mpegurl');
      controller.dispose();
    });
  });

  group('M3 配方/画像持久化（AC-14）', () {
    Future<Directory> tempDir(String prefix) async {
      final dir = await Directory.systemTemp.createTemp(prefix);
      addTearDown(() => dir.delete(recursive: true));
      return dir;
    }

    File castFile(Directory dir) =>
        File('${dir.path}${Platform.pathSeparator}aquan_cast.json');

    test('落盘 → 新建 controller（模拟重启）→ 直接命中配方不再跑全梯度',
        () async {
      final dir = await tempDir('cast_controller_ac14');
      final store = CastStore(testDirectory: dir);
      await store.ensureLoaded();

      // 第一次投屏：设备只吃 compact+bare（模拟梯度扫描后命中）。
      const hit = CastRecipe(
          didl: DidlVariant.compact,
          protocolInfoTemplate: DidlProtocolInfoTemplate.bare);
      final compat1 = CapturingCompatTransport()..hitRecipe = hit;
      final controller1 = CastController(
        transportFactory: (_) => compat1,
        recipeStore: store.recipes,
        profileStore: store.profiles,
      );
      await controller1.castTo(_target('d1'), _media());
      controller1.dispose();

      // 落盘断言：v4 文件里有 udn 精确键 + 设备画像。
      final json =
          jsonDecode(castFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect(json['version'], 4);
      final recipes = json['recipes'] as Map<String, dynamic>;
      expect(recipes.keys, contains('udn:d1'));
      expect(
        CastRecipe.fromJson(recipes['udn:d1'] as Map<String, dynamic>).didl,
        DidlVariant.compact,
      );
      final profiles = json['profiles'] as Map<String, dynamic>;
      expect(profiles.keys, contains('udn:d1'));
      final profile = profiles['udn:d1'] as Map<String, dynamic>;
      expect(profile['profileId'], 'generic');
      expect(
        (profile['sinkProtocols'] as List).cast<String>(),
        contains('http-get:*:video/mp4:*'),
      );
      expect(
        (profile['capabilities'] as List).cast<String>(),
        contains('getProtocolInfo'),
        reason: '预检成功且 Sink 非空',
      );

      // 模拟重启：新 store + 新 controller（ CapturingCompatTransport 会把
      // 收到的配方链原样透传给断言）。
      final store2 = CastStore(testDirectory: dir);
      await store2.ensureLoaded();
      final compat2 = CapturingCompatTransport()..hitRecipe = hit;
      final controller2 = CastController(
        transportFactory: (_) => compat2,
        recipeStore: store2.recipes,
        profileStore: store2.profiles,
      );
      await controller2.castTo(_target('d1'), _media());

      // 链首 = 记忆的配方（不再从 full+standard 梯度首项扫起）。
      expect(compat2.lastRequest, isNotNull);
      expect(compat2.lastRequest!.recipes.first.didl, DidlVariant.compact);
      expect(compat2.lastRequest!.recipes.first.protocolInfoTemplate,
          DidlProtocolInfoTemplate.bare);
      // 梯度首项紧随其后（命中失败仍可逐级降级）。
      expect(compat2.lastRequest!.recipes[1].didl, DidlVariant.full);
      controller2.dispose();
    });

    test('画像/配方写入时序：投屏成功 remember(recipe) 后 profiles 同步落盘',
        () async {
      final dir = await tempDir('cast_controller_profile');
      final store = CastStore(testDirectory: dir);
      await store.ensureLoaded();
      final compat = CapturingCompatTransport();
      final controller = CastController(
        transportFactory: (_) => compat,
        recipeStore: store.recipes,
        profileStore: store.profiles,
      );
      await controller.castTo(_target('d1'), _media());

      // castTo 返回时（remember 之后）两个表都已落盘。
      final json =
          jsonDecode(castFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect((json['recipes'] as Map).keys, contains('udn:d1'));
      expect((json['profiles'] as Map).keys, contains('udn:d1'));
      // 控制器内存表与 store 同源（CastService.attachStores 接的就是它）。
      expect(store.recipes.lookup(_target('d1')), isNotNull);
      expect(store.profiles.lookup('d1'), isNotNull);
      controller.dispose();
    });

    test('连播换集走 compat.load：full 变体 duration 恢复、不再用旧 setUri',
        () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      var advanced = false;
      controller.onNextEpisode = () async {
        if (advanced) return null;
        advanced = true;
        return const CastMedia(
          url: 'http://192.168.1.10/2.mp4',
          title: '测试 · 第2集',
          duration: Duration(minutes: 2, seconds: 3),
        );
      };
      await controller.castTo(_target('d1'), _media());
      expect(compat.calls.where((c) => c == 'load').length, 1);

      // 电视播完当前集（STOPPED 且位置在结尾）→ 触发连投。
      compat.pollResult = const CastPoll(
        transportState: 'STOPPED',
        position: Duration(minutes: 2, seconds: 10),
        duration: Duration(minutes: 2, seconds: 10),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (compat.calls.where((c) => c == 'load').length < 2 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(compat.calls.where((c) => c == 'load').length, 2,
          reason: '首投 + 连播各一次 compat.load');
      expect(compat.calls.any((c) => c.startsWith('setUri')), isFalse,
          reason: 'M3-5：连播不再走旧 transport.setUri 三件套');
      // 连播请求携带下一集的真实 duration（M2 遗留问题收口，AC-27）。
      expect(compat.lastRequest!.title, '测试 · 第2集');
      expect(compat.lastRequest!.duration, '0:02:03');
      expect(compat.lastRequest!.didl.duration,
          const Duration(minutes: 2, seconds: 3));
      expect(controller.currentMedia?.title, '测试 · 第2集');
      controller.dispose();
    });
  });

  group('M5 兼容模式选路（M5-0 / M5-3 / G5）', () {
    /// 注入记录型转码挂点，返回调用记录列表；[fail] = 模拟中继起不来。
    List<String> hook(CastController controller, {bool fail = false}) {
      final hooked = <String>[];
      controller.transcodeResolver = (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
        hooked.add(m.url);
        return fail ? null : 'http://192.168.1.9:18280/relay/index.m3u8';
      };
      return hooked;
    }

    test('auto + MKV → 本机转码；DIDL 按转码产物 HLS 判定', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      final hooked = hook(controller);
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(hooked, ['http://192.168.1.10/1.mkv'], reason: 'MKV 默认走中继');
      expect(compat.lastRequest!.url.toString(),
          'http://192.168.1.9:18280/relay/index.m3u8');
      expect(compat.lastRequest!.didl.uri.toString(),
          'http://192.168.1.9:18280/relay/index.m3u8');
      expect(compat.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl',
          reason: '转码产物恒为 HLS');
      controller.dispose();
    });

    test('auto + HEVC 提示（MP4 容器）→ 本机转码', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      final hooked = hook(controller);
      await controller.castTo(
        _target('d1'),
        const CastMedia(
            url: 'http://192.168.1.10/1.mp4', title: 't', codecHint: 'hevc'),
      );
      expect(hooked, hasLength(1), reason: 'HEVC/AV1 默认走中继转 H.264');
      expect(compat.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl');
      controller.dispose();
    });

    test('auto + MP4（无编码提示）→ 直投，不触发转码挂点', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      final hooked = hook(controller);
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mp4', title: 't'),
      );
      expect(hooked, isEmpty);
      expect(compat.lastRequest!.url, Uri.parse('http://192.168.1.10/1.mp4'));
      expect(compat.lastRequest!.didl.mimeType, 'video/mp4');
      controller.dispose();
    });

    test('auto + HLS + Sink 含 HLS → 直投；Sink 不含 → 本机转码', () async {
      final supported = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:application/vnd.apple.mpegurl:*'};
      final controller1 = CastController(transportFactory: (_) => supported);
      final hooked1 = hook(controller1);
      await controller1.castTo(_target('d1'), _media());
      expect(hooked1, isEmpty, reason: 'Sink 支持 HLS 时直投');
      expect(supported.lastRequest!.url, Uri.parse('http://192.168.1.10/1.m3u8'));
      controller1.dispose();

      final unsupported = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:video/mp4:*'};
      final controller2 = CastController(transportFactory: (_) => unsupported);
      final hooked2 = hook(controller2);
      await controller2.castTo(_target('d1'), _media());
      expect(hooked2, hasLength(1), reason: 'Sink 无 HLS mime → 走中继');
      expect(unsupported.lastRequest!.didl.mimeType,
          'application/vnd.apple.mpegurl');
      controller2.dispose();
    });

    test('auto + MKV + Sink 无 HLS 有 TS → ts 档：resolver 收 relayFormat=ts，'
        '产物 URL .ts 结尾且 DIDL 判 video/mp2t（AC-4）', () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:video/mp2t:*'};
      final controller = CastController(transportFactory: (_) => compat);
      final formats = <String>[];
      controller.transcodeResolver = (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
        formats.add(relayFormat ?? '');
        return 'http://192.168.1.9:29170/cast/AbCdEf0123456789AbCdEf0123456789/stream.ts';
      };
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(formats, ['ts'], reason: 'Sink 无 HLS 有 TS → ts 档');
      expect(compat.lastRequest!.url.toString(), endsWith('/stream.ts'),
          reason: 'ts 档产物 URL 以 .ts 结尾');
      expect(compat.lastRequest!.didl.mimeType, 'video/mp2t',
          reason: '产物 mime 按 URL 扩展名判，DIDL 与产物同源');
      controller.dispose();
    });

    test('Sink 含 HLS → relayFormat=hls（现状）；Sink 缺失 → hls（证据缺失回落）',
        () async {
      // Sink 含 HLS 时 HLS 源走直投，用 MKV 强制进中继看档位。
      final compat1 = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:application/vnd.apple.mpegurl:*'};
      final controller1 = CastController(transportFactory: (_) => compat1);
      final formats1 = <String>[];
      controller1.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
        formats1.add(relayFormat ?? '');
        return 'http://192.168.1.9:18280/relay/index.m3u8';
      };
      await controller1.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(formats1, ['hls'], reason: 'Sink 含 HLS → hls 档（现状）');
      expect(compat1.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl');
      controller1.dispose();

      final compat2 = CapturingCompatTransport()..sinkAnswer = <String>{};
      final controller2 = CastController(transportFactory: (_) => compat2);
      final formats2 = <String>[];
      controller2.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
        formats2.add(relayFormat ?? '');
        return 'http://192.168.1.9:18280/relay/index.m3u8';
      };
      await controller2.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(formats2, ['hls'], reason: 'Sink 缺失/未知 → hls（不回归）');
      controller2.dispose();
    });

    test('TS 档配方链升级：默认 standard → sinkEntry，Sink TS 拼写进 DIDL',
        () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{
          'http-get:*:video/vnd.dlna.mpeg-tts:DLNA.ORG_PN=MPEG_TS_HD_NA;*'
        };
      final controller = CastController(transportFactory: (_) => compat);
      controller.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
        return 'http://192.168.1.9:29170/cast/AbCdEf0123456789AbCdEf0123456789/stream.ts';
      };
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(compat.lastRequest!.recipes.first.protocolInfoTemplate,
          DidlProtocolInfoTemplate.sinkEntry,
          reason: 'TS 档产物：梯度首项 standard 升级 sinkEntry');
      expect(compat.lastRequest!.didl.mimeType, 'video/vnd.dlna.mpeg-tts',
          reason: '产物 mime 照抄设备 TS 拼写（preferSinkSpelling）');
      controller.dispose();
    });

    test('R3：会话字幕随中继调用透传（relaySubtitleUrl）', () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:video/mp2t:*'};
      final controller = CastController(transportFactory: (_) => compat);
      Uri? passed;
      controller.transcodeResolver = (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
        passed = relaySubtitleUrl;
        return 'http://192.168.1.9:29170/cast/AbCdEf0123456789AbCdEf0123456789/stream.ts';
      };
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://192.168.1.10/1.mkv',
          title: 't',
          subtitleUrl: 'http://192.168.1.10/sub.srt',
        ),
      );
      expect(passed, Uri.parse('http://192.168.1.10/sub.srt'),
          reason: '登记的字幕地址传给适配器 → castRelayStart subtitle_url');
      controller.dispose();
    });

    test('R1：编码提示合并——显式 h264 压过嗅探 hevc（红果优先级回归）', () async {
      // 本地伺服一个 ftyp=hvc1 的 MP4 头：控制器走 defaultSniffHead 真嗅探，
      // 嗅探产出 codecHint=hevc（模拟 CMS 无显式提示源的内容特征）。
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        const size = 8 + 4;
        req.response.add(<int>[
          0, 0, 0, size, ...'ftyp'.codeUnits, ...'hvc1'.codeUnits,
        ]);
        await req.response.close();
      });
      addTearDown(upstream.close);
      final mediaUrl = 'http://127.0.0.1:${upstream.port}/media';

      // 显式 codecHint=h264：合并结果 h264 → 直投不转码（红果行为不回归）。
      final compat1 = CapturingCompatTransport();
      final controller1 = CastController(transportFactory: (_) => compat1);
      final hooked1 = <String>[];
      controller1.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
        hooked1.add(m.url);
        return 'http://192.168.1.9:18280/relay/index.m3u8';
      };
      await controller1.castTo(
        _target('d1'),
        CastMedia(url: mediaUrl, title: 't', codecHint: 'h264'),
      );
      expect(hooked1, isEmpty, reason: '显式 h264 优先于嗅探 hevc → 不转码');
      expect(compat1.lastRequest!.didl.mimeType, 'video/mp4');
      controller1.dispose();

      // 无显式提示：同一内容嗅探 hevc 生效 → 中继转码（AC-2）。
      final compat2 = CapturingCompatTransport();
      final controller2 = CastController(transportFactory: (_) => compat2);
      final hooked2 = <String>[];
      controller2.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
        hooked2.add(m.url);
        return 'http://192.168.1.9:18280/relay/index.m3u8';
      };
      await controller2.castTo(
        _target('d1'),
        CastMedia(url: mediaUrl, title: 't'),
      );
      expect(hooked2, hasLength(1), reason: '嗅探 hevc → auto 中继');
      expect(compat2.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl');
      controller2.dispose();
    });

    test('never：MKV / HLS-无-Sink 都按现状直投，不触发转码挂点', () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:video/mp4:*'};
      final controller = CastController(transportFactory: (_) => compat);
      await controller.recipes
          .setTranscodeMode(_target('d1'), CastTranscodeMode.never);
      final hooked = hook(controller);
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(hooked, isEmpty, reason: '用户显式关闭转码');
      expect(compat.lastRequest!.url, Uri.parse('http://192.168.1.10/1.mkv'));
      expect(compat.lastRequest!.didl.mimeType, 'video/x-matroska');
      controller.dispose();
    });

    test('always：MP4 也走本机转码', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.recipes
          .setTranscodeMode(_target('d1'), CastTranscodeMode.always);
      final hooked = hook(controller);
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mp4', title: 't'),
      );
      expect(hooked, hasLength(1));
      expect(compat.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl');
      controller.dispose();
    });

    test('转码挂点失败（返回 null）→ 回退直投，不算投屏失败', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      final hooked = hook(controller, fail: true);
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(hooked, hasLength(1));
      expect(compat.lastRequest!.url, Uri.parse('http://192.168.1.10/1.mkv'),
          reason: '回退直投原始 URL');
      expect(compat.lastRequest!.didl.mimeType, 'video/x-matroska');
      expect(controller.state, CastSessionState.casting);
      controller.dispose();
    });

    test('viaRelay（URL 已是中继产物，如加密分集）→ 恒直投，不再二次转码',
        () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.recipes
          .setTranscodeMode(_target('d1'), CastTranscodeMode.always);
      final hooked = hook(controller);
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://127.0.0.1:18280/relay/index.m3u8',
          title: 't',
          viaRelay: true,
        ),
      );
      expect(hooked, isEmpty, reason: '中继产物不再套一层转码');
      expect(compat.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl');
      controller.dispose();
    });

    test('Chromecast 播放路径不受选路影响（P0 契约：always 也不挂钩点）', () async {
      final transport = FakeTransport();
      final controller = CastController(transportFactory: (_) => transport);
      final target =
          CastTarget.chromecast(const CastDeviceInfo(host: '127.0.0.1', name: 'CC'));
      await controller.recipes.setTranscodeMode(target, CastTranscodeMode.always);
      final hooked = hook(controller);
      await controller.castTo(
        target,
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(hooked, isEmpty);
      expect(
        transport.calls.first,
        startsWith('setUri:http://192.168.1.10/1.mkv'),
      );
      controller.dispose();
    });
  });

  group('M5-1 字幕（DLNA 不转 VTT / 第三通道）', () {
    test('DLNA 字幕走代理且 SRT 不被转 VTT；媒体响应带 CaptionInfo.sec',
        () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const srtBody = '1\n00:00:01,000 --> 00:00:03,000\n你好世界\n';
      final serverSub = upstream.listen((req) async {
        if (req.uri.path == '/sub.srt') {
          req.response.headers.contentType =
              ContentType('application', 'x-subrip', charset: 'utf-8');
          req.response.write(srtBody);
          await req.response.close();
          return;
        }
        req.response.headers.contentType =
            ContentType('application', 'octet-stream');
        req.response.add(const <int>[1, 2, 3, 4, 5, 6, 7, 8]);
        await req.response.close();
      });
      addTearDown(() async {
        await serverSub.cancel();
        await upstream.close();
      });

      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(
        _target('d1'),
        CastMedia(
          // 媒体也指到本地上游：代理取流要真实可达（不可达 → 502 无第三通道头）。
          url: 'http://127.0.0.1:${upstream.port}/1.mp4',
          title: 't',
          headers: const {'Referer': 'http://origin/'},
          subtitleUrl: 'http://127.0.0.1:${upstream.port}/sub.srt',
        ),
      );

      // DIDL 三件套里的字幕 URL：代理路径 + .srt 扩展名。
      final sub = compat.lastRequest!.didl.subtitleUri!;
      expect(sub.host, '127.0.0.1', reason: '对外 URL host = 目标设备路由源 IP');
      expect(sub.path.endsWith('.srt'), isTrue, reason: 'DLNA 字幕 URL 带 .srt');
      final client = HttpClient();
      final res = await client.getUrl(sub).then((r) => r.close());
      expect(res.headers.contentType?.mimeType, 'text/srt',
          reason: '与 DIDL 声明的 text/srt 一致（修正转 VTT 却声明 srt 的错配）');
      expect(await res.transform(utf8.decoder).join(), srtBody,
          reason: 'SRT 响应体与输入一致（不转 VTT）');

      // 字幕第三通道：媒体响应头带 CaptionInfo.sec = 字幕 URL。
      final mediaRes =
          await client.getUrl(compat.lastRequest!.url).then((r) => r.close());
      expect(mediaRes.headers.value('captioninfo.sec'), sub.toString());
      client.close();
      controller.dispose();
    });
  });

  group('M5-0 AC-22：兼容模式三态按 UDN 记忆', () {
    Future<Directory> tempDir(String prefix) async {
      final dir = await Directory.systemTemp.createTemp(prefix);
      addTearDown(() => dir.delete(recursive: true));
      return dir;
    }

    File castFile(Directory dir) =>
        File('${dir.path}${Platform.pathSeparator}aquan_cast.json');

    test('写配方 → 落盘 → 重启读回（setTranscodeMode）', () async {
      final dir = await tempDir('cast_controller_ac22');
      final store = CastStore(testDirectory: dir);
      await store.ensureLoaded();

      await store.recipes.setTranscodeMode(_target('d1'), CastTranscodeMode.always);
      // 立即读回。
      expect(store.recipes.lookup(_target('d1'))!.transcodeMode,
          CastTranscodeMode.always);
      // 落盘断言。
      final json =
          jsonDecode(castFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect(
        CastRecipe.fromJson(
            ((json['recipes'] as Map<String, dynamic>)['udn:d1'])
                as Map<String, dynamic>)
            .transcodeMode,
        CastTranscodeMode.always,
      );

      // 模拟重启。
      final store2 = CastStore(testDirectory: dir);
      await store2.ensureLoaded();
      expect(store2.recipes.lookup(_target('d1'))!.transcodeMode,
          CastTranscodeMode.always);
    });

    test('用户设置的三态在梯度配方命中后不被冲掉（remember 沿用）', () async {
      final dir = await tempDir('cast_controller_ac22_keep');
      final store = CastStore(testDirectory: dir);
      await store.ensureLoaded();
      await store.recipes.setTranscodeMode(_target('d1'), CastTranscodeMode.never);

      // 梯度扫描命中 compact（返回的配方本身 mode=auto）。
      const hit = CastRecipe(didl: DidlVariant.compact);
      final compat = CapturingCompatTransport()..hitRecipe = hit;
      final controller = CastController(
        transportFactory: (_) => compat,
        recipeStore: store.recipes,
        profileStore: store.profiles,
      );
      await controller.castTo(_target('d1'), _media());

      final saved = store.recipes.lookup(_target('d1'))!;
      expect(saved.didl, DidlVariant.compact, reason: '命中配方正常记忆');
      expect(saved.transcodeMode, CastTranscodeMode.never,
          reason: '用户显式设置的从不不被 auto 冲掉');
      controller.dispose();
    });
  });

  // 中继完成度连播判定（11-09-cast-dlna-android-fix）：实时 event HLS 让
  // 电视把 TrackDuration 报成 0，只看设备 duration 会永远不连投。
  group('中继完成度连播判定（11-09）', () {
    CastRelaySnapshot snap({
      bool ended = true,
      int exitCode = 0,
      Duration duration = const Duration(seconds: 42),
      int segments = 14,
      int lastSegIndex = 13,
      bool stalled = false,
    }) =>
        CastRelaySnapshot(
          format: 'hls',
          segments: segments,
          duration: duration,
          ended: ended,
          endlisted: true,
          stalled: stalled,
          lastAccess: const Duration(seconds: 1),
          exitCode: exitCode,
          lastSegIndex: lastSegIndex,
        );

    Future<bool> waitFor(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return condition();
    }

    int loadCount(CapturingCompatTransport t) =>
        t.calls.where((c) => c == 'load').length;

    test('设备 duration=0：中继清单时长兜底触发连投', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      controller.relaySnapshotReader = () => snap();
      var advanced = false;
      controller.onNextEpisode = () async {
        if (advanced) return null;
        advanced = true;
        return const CastMedia(
            url: 'http://192.168.1.10/2.mp4', title: '测试 · 第2集');
      };
      await controller.castTo(_target('d1'), _media());
      expect(loadCount(compat), 1);

      // 电视报 STOPPED 且 duration=0（真机现状），position 已到清单末尾。
      compat.pollResult = const CastPoll(
        transportState: 'STOPPED',
        position: Duration(seconds: 40),
      );
      expect(await waitFor(() => loadCount(compat) == 2), isTrue,
          reason: '中继 durationMs 兜底应触发连投');
      expect(controller.state, CastSessionState.casting);
      controller.dispose();
    });

    test('position 也不可信：电视已取到最后分片即判播完', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      controller.relaySnapshotReader = () =>
          snap(duration: Duration.zero, segments: 14, lastSegIndex: 13);
      var advanced = false;
      controller.onNextEpisode = () async {
        if (advanced) return null;
        advanced = true;
        return const CastMedia(
            url: 'http://192.168.1.10/2.mp4', title: '测试 · 第2集');
      };
      await controller.castTo(_target('d1'), _media());

      compat.pollResult =
          const CastPoll(transportState: 'STOPPED', position: Duration.zero);
      expect(await waitFor(() => loadCount(compat) == 2), isTrue,
          reason: '分片进度兜底应触发连投');
      controller.dispose();
    });

    test('中继异常退出（code!=0）：不连投，走远端停止', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      controller.relaySnapshotReader = () => snap(exitCode: 1);
      var advanced = false;
      controller.onNextEpisode = () async {
        advanced = true;
        return const CastMedia(
            url: 'http://192.168.1.10/2.mp4', title: '测试 · 第2集');
      };
      Duration? stoppedAt;
      controller.onRemoteStopped = (_, position) => stoppedAt = position;
      await controller.castTo(_target('d1'), _media());

      compat.pollResult =
          const CastPoll(transportState: 'STOPPED', position: Duration.zero);
      expect(await waitFor(() => controller.state == CastSessionState.idle),
          isTrue);
      expect(advanced, isFalse, reason: '内容不完整时不得跳集');
      expect(loadCount(compat), 1);
      expect(stoppedAt, isNotNull);
      controller.dispose();
    });

    test('中继仍在转码（未结束）：不连投', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      controller.relaySnapshotReader = () =>
          snap(ended: false, exitCode: -1, lastSegIndex: 13);
      await controller.castTo(_target('d1'), _media());

      compat.pollResult =
          const CastPoll(transportState: 'STOPPED', position: Duration.zero);
      expect(await waitFor(() => controller.state == CastSessionState.idle),
          isTrue);
      expect(loadCount(compat), 1);
      controller.dispose();
    });

    test('转码挂点收到目标设备 host（产物 URL 用路由源 IP）', () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:video/mp2t:*'};
      final controller = CastController(transportFactory: (_) => compat);
      final hosts = <String>[];
      controller.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
        hosts.add(relayHostHint);
        return 'http://192.168.1.9:29170/cast/tok/index.m3u8';
      };
      await controller.castTo(_target('d1'), _media());
      expect(hosts, isNotEmpty);
      expect(hosts.first, '127.0.0.1',
          reason: 'target.host 来自 controlUrl（测试夹具 127.0.0.1）');
      controller.dispose();
    });
  });

  // 中继档位自动降级（11-09）：国产电视的 Sink 列表普遍不准，靠自述能力
  // 猜格式必然漏；以「实际有没有拉到分片」为证据兜底。
  group('中继档位自动降级（11-09）', () {
    Future<bool> waitFor(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return condition();
    }

    test('HLS 会话无分片取流 → 自动改用 TS 重投一次', () async {
      // Sink 不含 HLS → 选路进 relay；relayFormatFor 无 TS 证据回落 hls
      // （正是「设备 Sink 不准、首投只能试 hls」的真实现场）。
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:video/mp4:*'};
      final controller = CastController(transportFactory: (_) => compat)
        ..relayFormatFallbackDelay = Duration.zero;
      final formats = <String>[];
      controller.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
        formats.add(relayFormat ?? '');
        return formats.length == 1
            ? 'http://192.168.1.9:29170/cast/tok/index.m3u8'
            : 'http://192.168.1.9:29170/cast/tok/stream.ts';
      };
      await controller.castTo(_target('d1'), _media());
      expect(formats, <String>['hls'], reason: 'Sink 含 HLS → 首投走 hls');

      // 电视只取了清单、没有取任何分片（不认 HLS 的典型表现）。
      CastDiagnostics.instance.recordMediaRequest(MediaRequestTrace(
        url: '/cast/tok/index.m3u8',
        method: 'GET',
        statusCode: 200,
        bytesServed: 120,
      ));

      final downgraded = await waitFor(() => formats.length == 2);
      if (!downgraded) {
        fail('未降级。formats=$formats state=${controller.state} '
            'timeline=${CastDiagnostics.instance.timeline.join(' | ')}');
      }
      expect(formats.last, 'ts');
      expect(controller.state, CastSessionState.casting);
      controller.dispose();
    });

    test('已拉到分片则不降级（HLS 在播）', () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:video/mp4:*'};
      final controller = CastController(transportFactory: (_) => compat)
        ..relayFormatFallbackDelay = Duration.zero;
      final formats = <String>[];
      controller.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
        formats.add(relayFormat ?? '');
        return 'http://192.168.1.9:29170/cast/tok/index.m3u8';
      };
      await controller.castTo(_target('d1'), _media());
      CastDiagnostics.instance.recordMediaRequest(MediaRequestTrace(
        url: '/cast/tok/seg_00000.ts',
        method: 'GET',
        statusCode: 206,
        bytesServed: 1024,
      ));
      // 给两轮轮询机会确认不会重投。
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(formats, <String>['hls']);
      controller.dispose();
    });

    test('ts 产物 mime 提示用 video/mpeg（DLNA 通用拼写）', () {
      expect(kRelayProductTsMimeHint, 'video/mpeg');
      expect(isTsMime('video/mpeg'), isTrue);
      // 设备 Sink 有自己的 TS 拼写时照抄设备写法。
      expect(
        preferSinkSpelling('video/mpeg', <String>['http-get:*:video/mp2t:*']),
        'video/mp2t',
      );
    });

    test('播放页预起中继 + 直投：无分片时按 recordUrl 回源重投 ts（11-09 二期）',
        () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:video/mp4:*'};
      final controller = CastController(transportFactory: (_) => compat)
        ..relayFormatFallbackDelay = Duration.zero;
      final hooked = <String>[];
      controller.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
        hooked.add('${m.url}|${relayFormat ?? ''}');
        return 'http://192.168.1.9:29170/cast/tok/stream.ts';
      };
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://192.168.1.9:29170/cast/tok/index.m3u8',
          title: '测试 · 第1集',
          viaRelay: true,
          relaySession: 'S1',
          recordUrl: 'http://192.168.1.10/1.m3u8',
        ),
      );
      // viaRelay → 恒直投，首投不经过转码挂点。
      expect(hooked, isEmpty);

      final downgraded = await waitFor(() => hooked.length == 1);
      if (!downgraded) {
        fail('未降级。state=${controller.state} '
            'timeline=${CastDiagnostics.instance.timeline.join(' | ')}');
      }
      expect(hooked.single, 'http://192.168.1.10/1.m3u8|ts',
          reason: '必须回到源地址并强制 ts');
      controller.dispose();
    });

    // 11-10 真机回归：设备自述**含 HLS**（HiDMR 54 条 Sink）或 Sink 为空
    // （极光TV 0 条）时，旧实现在降级重投里仍选路 direct，把源 CDN 地址又
    // 投了一遍（SOAP fault / 电视端 STOPPED）。forceRelay 必须把这类会话
    // 钉死在本机中继产物上。
    test('Sink 含 HLS 也会被强制改投 ts 中继产物（11-10）', () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:application/vnd.apple.mpegurl:*'};
      final controller = CastController(transportFactory: (_) => compat)
        ..relayFormatFallbackDelay = Duration.zero;
      final hooked = <String>[];
      controller.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
        hooked.add('${m.url}|${relayFormat ?? ''}');
        return 'http://192.168.1.9:29172/cast/tok/stream.ts';
      };
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://192.168.1.9:29172/cast/tok/index.m3u8',
          title: '测试 · 第1集',
          viaRelay: true,
          relaySession: 'S1',
          recordUrl: 'http://192.168.1.10/1.m3u8',
        ),
      );
      expect(hooked, isEmpty, reason: 'viaRelay 首投恒直投');

      final downgraded = await waitFor(() => hooked.length == 1);
      if (!downgraded) {
        fail('未降级。state=${controller.state} '
            'timeline=${CastDiagnostics.instance.timeline.join(' | ')}');
      }
      expect(hooked.single, 'http://192.168.1.10/1.m3u8|ts');
      // 重投必须先 Stop 旧 URI（不 Stop 部分固件继续用旧清单）。
      expect(compat.calls.any((c) => c == 'stop'), isTrue,
          reason: '降级重投前应发 Stop: ${compat.calls}');
      // 最终投送的是 ts 中继产物，不是源地址。
      expect(compat.lastRequest?.url.toString(),
          'http://192.168.1.9:29172/cast/tok/stream.ts');
      controller.dispose();
    });

    test('中继不可用（resolver 返回 null）时降级回滚为直投', () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:application/vnd.apple.mpegurl:*'};
      final controller = CastController(transportFactory: (_) => compat)
        ..relayFormatFallbackDelay = Duration.zero;
      controller.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async => null;
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://192.168.1.9:29172/cast/tok/index.m3u8',
          title: '测试 · 第1集',
          viaRelay: true,
          relaySession: 'S1',
          recordUrl: 'http://192.168.1.10/1.m3u8',
        ),
      );
      // 让降级窗口触发（轮询周期 1s，用 waitFor 而不是固定睡眠）。
      final rolledBack = await waitFor(() => CastDiagnostics.instance.timeline
          .any((l) => l.contains('档位降级未命中本机中继产物')));
      expect(rolledBack, isTrue,
          reason: CastDiagnostics.instance.timeline.join(' | '));
      // 中继起不来 → 回退直投（源地址），且不把「已降级」记成成功。
      expect(compat.lastRequest?.url.toString(), 'http://192.168.1.10/1.m3u8');
      controller.dispose();
    });
  });

  // 同一台电视常同时被 mDNS 发现 AirPlay、被 SSDP 发现 DLNA；误点 AirPlay
  // 会在设备端「先苹果、再切换、最后失败」（11-09 二期）。
  group('设备合并策略（11-09 二期）', () {
    CastTarget dlnaAt(String udn, String host) => CastTarget.dlna(DlnaDevice(
          udn: udn,
          friendlyName: 'TV',
          controlUrl: 'http://$host:49152/ctrl',
        ));
    CastTarget airplayAt(String host) => CastTarget.airplay(
        AirPlayDeviceInfo(host: host, port: 7000, name: 'TV'));

    test('同 IP 已有 DLNA：AirPlay 不加入', () {
      final merged =
          mergeCastTarget(<CastTarget>[dlnaAt('d1', '192.168.1.8')], airplayAt('192.168.1.8'));
      expect(merged.length, 1);
      expect(merged.single.protocol, CastProtocol.dlna);
    });

    test('DLNA 后到：移除同 IP 的 AirPlay', () {
      final merged =
          mergeCastTarget(<CastTarget>[airplayAt('192.168.1.8')], dlnaAt('d1', '192.168.1.8'));
      expect(merged.length, 1);
      expect(merged.single.protocol, CastProtocol.dlna);
    });

    test('纯 AirPlay 设备保留（同 IP 无 DLNA）', () {
      final merged =
          mergeCastTarget(<CastTarget>[dlnaAt('d1', '192.168.1.9')], airplayAt('192.168.1.8'));
      expect(merged.length, 2);
      expect(merged.any((t) => t.protocol == CastProtocol.airplay), isTrue);
    });

    test('同 IP 多个 DLNA 接收端都保留，AirPlay 仍被丢弃', () {
      final merged = mergeCastTarget(
        <CastTarget>[dlnaAt('d1', '192.168.1.8'), dlnaAt('d2', '192.168.1.8')],
        airplayAt('192.168.1.8'),
      );
      expect(merged.length, 2);
      expect(merged.every((t) => t.protocol == CastProtocol.dlna), isTrue);
    });

    test('同 id 更新（在线状态）幂等', () {
      final first = mergeCastTarget(const <CastTarget>[], dlnaAt('d1', '192.168.1.8'));
      final second = mergeCastTarget(first, dlnaAt('d1', '192.168.1.8'));
      expect(second.length, 1);
    });
  });

  // 投送前端点刷新（11-11 真机）：airpin/IQIYI-WMP/Cling 重启后换 control
  // 端口，旧记录让所有 SOAP 动作被回 -1 / 连接被拒。投送前重取描述并用新端点。
  group('投送前端点刷新（11-11）', () {
    CastTarget targetAt(String controlUrl) => CastTarget.dlna(DlnaDevice(
          udn: 'uuid:q3',
          friendlyName: 'Q3',
          controlUrl: controlUrl,
          location: 'http://192.168.31.242:49152/desc.xml',
        ));

    test('描述端点变化 → 用新 controlUrl/serviceType 建 transport', () async {
      final seen = <String>[];
      final services = <String>[];
      final controller = CastController(transportFactory: (t) {
        seen.add(t.dlna!.controlUrl);
        services.add(t.dlna!.serviceType);
        return FakeTransport();
      });
      controller.describeFetcher = (loc) async => DlnaDevice(
            udn: 'uuid:q3',
            friendlyName: 'Q3',
            controlUrl: 'http://192.168.31.242:50000/AVTransport/control',
            serviceType: 'urn:schemas-upnp-org:service:AVTransport:2',
            location: loc,
          );
      await controller.castTo(
        targetAt('http://192.168.31.242:49152/AVTransport/control'),
        _media(),
      );
      expect(seen.single, 'http://192.168.31.242:50000/AVTransport/control');
      expect(services.single, 'urn:schemas-upnp-org:service:AVTransport:2');
      expect(controller.currentDevice?.dlna?.controlUrl,
          'http://192.168.31.242:50000/AVTransport/control',
          reason: '会话内设备指针也要切到新端点');
      controller.dispose();
    });

    test('描述取不到（超时/404）→ 保持旧端点，不阻断投屏', () async {
      final seen = <String>[];
      final controller = CastController(transportFactory: (t) {
        seen.add(t.dlna!.controlUrl);
        return FakeTransport();
      });
      controller.describeFetcher = (loc) async => null;
      await controller.castTo(
        targetAt('http://192.168.31.242:49152/AVTransport/control'),
        _media(),
      );
      expect(seen.single, 'http://192.168.31.242:49152/AVTransport/control');
      controller.dispose();
    });

    test('无 location 的设备（手动录入/test 夹具）不做刷新', () async {
      var called = 0;
      final controller = CastController(transportFactory: (_) => FakeTransport());
      controller.describeFetcher = (loc) async {
        called++;
        return null;
      };
      await controller.castTo(_target('d1'), _media());
      expect(called, 0);
      controller.dispose();
    });
  });

  // 11-09：会话面板进度条的时长来源。电视对中继 HLS 常报 TrackDuration=0，
  // 只用远端值会让整条进度条消失（用户「选不了进度条控制位置」）。
  group('进度条有效时长（11-09）', () {
    CastRelaySnapshot relayOf({
      Duration duration = const Duration(seconds: 42),
      bool ended = false,
      int exitCode = -1,
    }) =>
        CastRelaySnapshot(
          format: 'hls',
          segments: 14,
          duration: duration,
          ended: ended,
          endlisted: ended,
          stalled: false,
          lastAccess: const Duration(seconds: 1),
          exitCode: exitCode,
          lastSegIndex: 3,
        );

    Future<CastController> castOnce(
      CapturingCompatTransport compat, {
      Duration? mediaDuration,
      CastRelaySnapshot? relay,
    }) async {
      final controller = CastController(transportFactory: (_) => compat);
      controller.relaySnapshotReader = relay == null ? null : () => relay;
      await controller.castTo(
        _target('d1'),
        CastMedia(
          url: 'http://192.168.1.10/1.mp4',
          title: '测试 · 第1集',
          duration: mediaDuration,
        ),
      );
      // 远端报 0 的轮询：不得把已知时长打回 0。
      await controller.forceRefresh();
      return controller;
    }

    test('远端报 0 → 回退媒体真实时长', () async {
      final compat = CapturingCompatTransport()
        ..pollResult = const CastPoll(
            transportState: 'PLAYING', position: Duration(seconds: 5));
      final controller =
          await castOnce(compat, mediaDuration: const Duration(minutes: 2));
      expect(controller.remoteDuration, const Duration(minutes: 2));
      controller.dispose();
    });

    test('远端报 0 且媒体无时长 → 回退中继已转出时长', () async {
      final compat = CapturingCompatTransport()
        ..pollResult = const CastPoll(
            transportState: 'PLAYING', position: Duration(seconds: 5));
      final controller = await castOnce(compat, relay: relayOf());
      expect(controller.remoteDuration, const Duration(seconds: 42));
      controller.dispose();
    });

    // 11-11 真机「投屏管理页进度条消失」：中继会话被回收/探针自停后
    // relaySnapshotReader 变成 null（电视本身恒报 TrackDuration=0），
    // 旧实现三路全空 → effectiveDuration 归零 → 进度条整条消失。
    test('中继快照消失后仍保留上次有效时长（进度条不消失）', () async {
      final compat = CapturingCompatTransport()
        ..pollResult = const CastPoll(
            transportState: 'PLAYING', position: Duration(seconds: 5));
      CastRelaySnapshot? relay = relayOf();
      final controller = CastController(transportFactory: (_) => compat);
      controller.relaySnapshotReader = () => relay;
      await controller.castTo(_target('d1'), _media());
      await controller.forceRefresh();
      expect(controller.remoteDuration, const Duration(seconds: 42));

      relay = null; // 会话回收 / 探针 unwatch
      await controller.forceRefresh();
      expect(controller.remoteDuration, const Duration(seconds: 42),
          reason: '同一媒体内保留已知时长，进度条与可拖上限不塌成 0');
      expect(controller.seekUpperBound, greaterThan(Duration.zero));
      controller.dispose();
    });

    test('远端有真实时长时优先用它', () async {
      final compat = CapturingCompatTransport()
        ..pollResult = const CastPoll(
          transportState: 'PLAYING',
          position: Duration(seconds: 5),
          duration: Duration(minutes: 3),
        );
      final controller =
          await castOnce(compat, mediaDuration: const Duration(minutes: 2));
      expect(controller.remoteDuration, const Duration(minutes: 3));
      controller.dispose();
    });

    test('可拖上限：中继未转完 = 已转出；已收尾 = 有效时长', () async {
      final compat = CapturingCompatTransport()
        ..pollResult = const CastPoll(
            transportState: 'PLAYING', position: Duration(seconds: 5));

      final running = await castOnce(compat,
          mediaDuration: const Duration(minutes: 5), relay: relayOf());
      expect(running.seekUpperBound, const Duration(seconds: 42));
      running.dispose();

      final done = await castOnce(
        CapturingCompatTransport()
          ..pollResult = const CastPoll(
              transportState: 'PLAYING', position: Duration(seconds: 5)),
        mediaDuration: const Duration(minutes: 5),
        relay: relayOf(
            duration: const Duration(minutes: 5),
            ended: true,
            exitCode: 0),
      );
      expect(done.seekUpperBound, const Duration(minutes: 5));
      done.dispose();
    });
  });

  group('最近目标 host（11-09 二期）', () {
    test('无会话 → 空串；投屏后 → 当前设备 host', () async {
      final transport = FakeTransport()
        ..pollResult = const CastPoll(transportState: 'PLAYING');
      final controller = CastController(transportFactory: (_) => transport);
      expect(controller.lastTargetHost, '');
      await controller.castTo(_target('d1'), _media());
      expect(controller.lastTargetHost, '127.0.0.1');
      await controller.disconnect();
      controller.dispose();
    });
  });

  // 注意：本组必须在文件最后——ensureInitialized 的测试绑定会接管
  // HttpClient，污染同 isolate 里后续测试的原始网络请求（registerSubtitle
  // 会被打断）。镜像测试需要绑定（MirrorController 的 MethodChannel）。
  group('M5 镜像路径不受选路影响（文件末尾：需要测试绑定）', () {
    test('always 也不挂钩点，镜像流按现状直投', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final transport = FakeTransport();
      final controller = CastController(transportFactory: (_) => transport);
      await controller.recipes
          .setTranscodeMode(_target('d1'), CastTranscodeMode.always);
      final hooked = <String>[];
      controller.transcodeResolver = (m, {relayFormat, relaySubtitleUrl, relayHostHint = ''}) async {
        hooked.add(m.url);
        return 'http://127.0.0.1:18280/relay/index.m3u8';
      };
      await controller.castTo(
        _target('d1'),
        const CastMedia(
            url: 'http://127.0.0.1:18080/stream.ts', title: '屏幕镜像', isMirror: true),
      );
      expect(hooked, isEmpty);
      expect(
        transport.calls.first,
        startsWith('setUri:http://127.0.0.1:18080/stream.ts'),
      );
      await controller.disconnect();
      controller.dispose();
    });
  });
}
