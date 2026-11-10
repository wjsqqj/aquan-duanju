import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/widgets/cast_panel.dart';

CastTarget _target(String id, {bool online = true}) => CastTarget.dlna(
      DlnaDevice(
        udn: id,
        friendlyName: '设备-$id',
        modelName: 'Model-$id',
        manufacturer: 'Maker',
        controlUrl: 'http://192.168.1.9/ctl',
        location: 'http://192.168.1.9/desc.xml',
        online: online,
      ),
    );

List<String> _ids(Iterable<CastTarget> devices) =>
    devices.map((d) => d.id).toList();

void main() {
  group('设备列表顺序（R5）', () {
    // 11-10 用户要求：去掉「上次投屏设备」记忆——投完最后一台再打开面板，
    // 列表不能再把某台设备顶到最前。
    test('未连接时按 钉选 > 名称 > id 排序，无「上次设备」成分', () {
      final a = _target('a');
      final b = _target('b');
      final c = _target('c');
      expect(
        _ids(orderedDevices(live: [c, a, b], pinnedIds: const <String>{})),
        ['a', 'b', 'c'],
      );
      expect(
        _ids(orderedDevices(
            live: [c, a, b], pinnedIds: const <String>{'c'})),
        ['c', 'a', 'b'],
        reason: '钉选仍置顶（与「上次设备」是两个功能）',
      );
    });

    test('点击不重排：连接开始冻结快照，投送成功也不重排', () {
      final a = _target('a');
      final b = _target('b');
      final c = _target('c');
      // 面板当前顺序（连接开始时）作为快照。
      final frozen = orderedDevices(
        live: [a, b, c],
        pinnedIds: const <String>{},
      );
      expect(_ids(frozen), ['a', 'b', 'c']);

      final duringConnect = orderedDevices(
        live: [a, b, c],
        pinnedIds: const <String>{},
        frozen: frozen,
      );
      expect(_ids(duringConnect), _ids(frozen));
    });

    test('连接中扫描刷新：顺序不变，只同步在线状态', () {
      final a = _target('a');
      final b = _target('b');
      final c = _target('c');
      final frozen = <CastTarget>[b, a, c];
      // 扫描刷新：设备顺序全变、b 变为离线、还多出一个新设备 d。
      final live = <CastTarget>[
        _target('c'),
        _target('a'),
        _target('b', online: false),
        _target('d'),
      ];
      final result = orderedDevices(
        live: live,
        pinnedIds: const <String>{},
        frozen: frozen,
      );
      expect(_ids(result), ['b', 'a', 'c'],
          reason: '顺序严格按快照，不重排、不插入新设备');
      expect(result.first.online, isFalse,
          reason: '在线状态来自最新扫描结果');
    });
  });

  group('最近使用写入时机（R5）', () {
    test('castTo 成功才写最近使用', () async {
      var casted = false;
      var remembered = false;
      await castAndRemember(
        cast: () async {
          casted = true;
        },
        remember: () async {
          remembered = true;
        },
      );
      expect(casted, isTrue);
      expect(remembered, isTrue);
    });

    test('castTo 失败不写最近使用', () async {
      var remembered = false;
      await expectLater(
        castAndRemember(
          cast: () async {
            throw StateError('SOAP 500');
          },
          remember: () async {
            remembered = true;
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(remembered, isFalse, reason: '失败设备不能被顶到列表前面');
    });
  });

  group('状态徽标映射（transportState → 中文固定文案）', () {
    test('五态映射 + RUNNING/BUFFERING 别名', () {
      expect(castTransportStateLabel('PLAYING'), '播放中');
      expect(castTransportStateLabel('RUNNING'), '播放中',
          reason: '部分设备回 RUNNING（CastPoll.isRunning 同口径）');
      expect(castTransportStateLabel('PAUSED_PLAYBACK'), '已暂停');
      expect(castTransportStateLabel('TRANSITIONING'), '缓冲中');
      expect(castTransportStateLabel('BUFFERING'), '缓冲中',
          reason: 'Chromecast poll 映射出的 BUFFERING 同显示');
      expect(castTransportStateLabel('STOPPED'), '已停止');
      expect(castTransportStateLabel('NO_MEDIA_PRESENT'), '已停止');
      expect(castTransportStateLabel('playing'), '播放中', reason: '大小写不敏感');
      expect(castTransportStateLabel(' paused_playback '), '已暂停');
    });

    test('未知/空串（尚未轮询到）返回 null：UI 不显示徽标', () {
      expect(castTransportStateLabel(''), isNull);
      expect(castTransportStateLabel('   '), isNull);
      expect(castTransportStateLabel('WHATEVER'), isNull);
    });
  });

  group('TRANSITIONING 抖动消抖（800ms）', () {
    test('窗口内维持上一状态，抖回立即恢复，满窗口后放行', () {
      fakeAsync((async) {
        final d = CastTransitionDebouncer();
        var elapsed = 0;
        d.onElapsed = () => elapsed++;

        expect(d.shouldHold('PLAYING'), isFalse);
        expect(d.shouldHold('TRANSITIONING'), isTrue, reason: '进入抖动即消抖');
        async.elapse(const Duration(milliseconds: 700));
        expect(d.shouldHold('TRANSITIONING'), isTrue, reason: '窗口内维持上一状态');
        expect(d.shouldHold('PAUSED_PLAYBACK'), isFalse,
            reason: '抖回其他状态立即放行并复位计时');
        expect(d.shouldHold('TRANSITIONING'), isTrue, reason: '再次进入重新计时');
        async.elapse(const Duration(milliseconds: 799));
        expect(d.shouldHold('TRANSITIONING'), isTrue, reason: '距重新进入仅 799ms');
        async.elapse(const Duration(milliseconds: 10));
        expect(d.shouldHold('TRANSITIONING'), isFalse, reason: '满 800ms 显示「缓冲中」');
        expect(elapsed, 1, reason: '被打断的窗口不触发回调');
        expect(d.shouldHold('TRANSITIONING'), isFalse,
            reason: '持续 TRANSITIONING 不反复消抖');
        d.dispose();
      });
    });
  });
}
