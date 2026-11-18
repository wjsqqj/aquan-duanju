import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Go/Dart 方法表双向断言。
///
/// 用源码静态扫描而不是加载 dll：`flutter test` 跑在主机 VM，dll 路径依赖
/// 打包产物，CI 上不保证存在；扫描源码则稳定、离线、可在任意平台运行。
///
/// 覆盖两类漂移：
/// 1. Go 新增了方法，Dart 从没接线（用户看不到新功能，也没人发现）。
/// 2. Dart 调用了 Go 已删除/改名的方法（运行期才报 unknown method）。
void main() {
  /// syncHttp 由 FongMi / Legado 的 JS 运行时直接 `lib.call`，不走 AquaApi。
  /// tmp* 是 core 注释自述的临时调试方法；castDesktopStatus 仅诊断用。
  const allow = <String, String>{
    'syncHttp': 'FongMi / Legado JS 运行时直接 lib.call，不经 AquaApi',
    'tmpTimepoints': 'core 注释自述的临时调试方法',
    'tmpPlayRaw': 'core 注释自述的临时调试方法',
    'castDesktopStatus': '桌面镜像状态，仅诊断用，UI 不需要',
    'getAlbum': '合集展示已由 seasons 覆盖（detail_screen 的「季与合集」），'
        '按 albumId 直接打开暂无入口',
  };

  test('Go 方法表与 Dart 接线双向对齐', () {
    final coreGo = File('native/bridge/core/core.go').readAsStringSync();
    // 方法表有两种书写：独占一行 `"x": fn,`，以及接在函数体后 `}, "x": fn,`。
    final goMethods = <String>{
      for (final m in RegExp(r'^\t"([A-Za-z0-9_]+)":', multiLine: true)
          .allMatches(coreGo))
        m.group(1)!,
      for (final m in RegExp(r'\},\s*"([A-Za-z0-9_]+)":\s*\w+,')
          .allMatches(coreGo))
        m.group(1)!,
    };
    expect(goMethods.length, greaterThan(40),
        reason: 'core.go 方法表正则失效？只解析出 ${goMethods.length} 个方法');

    final api = File('lib/core/aqua_api.dart').readAsStringSync();
    final dartCalls = RegExp(r"\.call\(\s*'([A-Za-z0-9_]+)'")
        .allMatches(api)
        .map((m) => m.group(1)!)
        .toSet();
    expect(dartCalls.length, greaterThan(25),
        reason: 'aqua_api.dart 调用正则失效？只解析出 ${dartCalls.length} 个方法');

    final missingInDart =
        goMethods.difference(dartCalls).difference(allow.keys.toSet());
    final unknownInGo = dartCalls.difference(goMethods);
    final staleAllow = allow.keys.toSet().difference(goMethods);

    expect(
      missingInDart,
      isEmpty,
      reason: '这些 core 方法还没被 Dart 接线：$missingInDart\n'
          '接线，或加进 allow 白名单并写明原因。',
    );
    expect(
      unknownInGo,
      isEmpty,
      reason: 'AquaApi 调用了 core 不存在的方法：$unknownInGo',
    );
    expect(
      staleAllow,
      isEmpty,
      reason: '白名单里的方法已不存在，删掉对应条目：$staleAllow',
    );
  });
}
