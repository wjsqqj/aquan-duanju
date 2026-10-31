import 'package:aquan_duanju/core/reader/speech/notification_permission.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 通知权限：只申请一次、失败不抛、非 Android 不去碰通道。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(NotificationPermission.channel, (
      call,
    ) async {
      calls.add(call.method);
      switch (call.method) {
        case 'hasPermission':
          return false;
        case 'requestPermission':
          return false;
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(NotificationPermission.channel, null);
  });

  test('非 Android：直接 true，且不碰通道（桌面/测试环境）', () async {
    expect(await NotificationPermission.ensure(isAndroid: false), isTrue);
    expect(await NotificationPermission.has(isAndroid: false), isTrue);
    expect(calls, isEmpty, reason: '非 Android 不许调用通道');
  });

  test('已授予：ensure 直接 true，不应再发申请', () async {
    messenger.setMockMethodCallHandler(NotificationPermission.channel, (
      call,
    ) async {
      calls.add(call.method);
      return call.method == 'hasPermission' ? true : null;
    });

    expect(await NotificationPermission.ensure(isAndroid: true), isTrue);
    expect(calls, <String>['hasPermission'], reason: '已授予就不要重复申请');
  });

  test('未授予 → 先查再申请，申请通过返回 true', () async {
    messenger.setMockMethodCallHandler(NotificationPermission.channel, (
      call,
    ) async {
      calls.add(call.method);
      return call.method == 'requestPermission' ? true : false;
    });

    expect(await NotificationPermission.ensure(isAndroid: true), isTrue);
    expect(calls, <String>['hasPermission', 'requestPermission']);
  });

  test('用户拒绝：返回 false，但不抛（不阻塞播放）', () async {
    expect(await NotificationPermission.ensure(isAndroid: true), isFalse);
    expect(calls, <String>['hasPermission', 'requestPermission']);
  });

  test('通道抛异常（旧安装包）：返回 false，不冒泡', () async {
    messenger.setMockMethodCallHandler(NotificationPermission.channel, (
      call,
    ) async {
      throw PlatformException(code: 'unavailable');
    });

    await expectLater(
      NotificationPermission.ensure(isAndroid: true),
      completion(isFalse),
    );
    await expectLater(
      NotificationPermission.has(isAndroid: true),
      completion(isFalse),
    );
  });

  test('has：只查不申请', () async {
    await NotificationPermission.has(isAndroid: true);
    expect(calls, <String>['hasPermission']);
  });
}
