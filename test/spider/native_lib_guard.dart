import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// QuickJS 原生桥的库名（`flutter_js` 按这个名字动态加载）。
const String kQuickJsLibName = 'quickjs_c_bridge.dll';

/// 打开这两个用例的环境变量。
///
/// spider 用例本质是**集成测试**：要真实的 QuickJS 原生库 + 真实 HTTP 夹具，
/// 不能混在 `flutter test` 的单元测试里。默认 skip，显式开关才跑。
const String kSpiderTestEnv = 'AQUAN_SPIDER_TESTS';

/// 找 `quickjs_c_bridge.dll`：先看 PATH，再看常见构建目录。
String? findQuickJsLibrary() {
  final path = Platform.environment['PATH'] ?? '';
  for (final dir in path.split(Platform.pathSeparator)) {
    if (dir.trim().isEmpty) continue;
    final candidate =
        File('${dir.trim()}${Platform.pathSeparator}$kQuickJsLibName');
    if (candidate.existsSync()) return candidate.path;
  }
  for (final dir in const <String>[
    'build/windows/x64/runner/Release',
    'build/windows/x64/runner/Debug',
  ]) {
    final candidate = File('$dir${Platform.pathSeparator}$kQuickJsLibName');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

/// 守卫：没显式开启、或缺原生库时**跳过**当前用例。
///
/// 返回 true 表示「可以继续跑」。
bool ensureQuickJsLibrary() {
  if (Platform.environment[kSpiderTestEnv] != '1') {
    markTestSkipped(
      'QuickJS 集成测试默认跳过：用 `tool/run_spider_tests.ps1` 运行'
      '（它会构建原生库、注入 PATH 并设置 $kSpiderTestEnv=1）。',
    );
    return false;
  }
  final path = findQuickJsLibrary();
  if (path == null) {
    markTestSkipped(
      '需要 QuickJS 原生桥 $kQuickJsLibName：'
      '先执行 `flutter build windows --release`，或直接跑 `tool/run_spider_tests.ps1`。',
    );
    return false;
  }
  try {
    // 预加载：Windows 会按模块名复用已加载模块，之后 flutter_js 里的
    // DynamicLibrary.open('quickjs_c_bridge.dll') 就能命中。
    DynamicLibrary.open(path);
  } catch (e) {
    markTestSkipped('$kQuickJsLibName 存在但加载失败：$e');
    return false;
  }
  return true;
}
