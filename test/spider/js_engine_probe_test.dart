// JS 引擎能力探针（PoC 基线）：验证 QuickJS FFI 上
// 1) 同步求值；2) JS 通过 sendMessage 同步调 Dart 并拿回对象（宿主返回 JSON
//    字符串经桥接解码为 JS 对象）。
// 运行前置：flutter build windows --debug 后把 build/windows/x64/runner/Debug
// 加入 PATH（quickjs_c_bridge.dll）。
// 本探针常驻：作为 spider 运行时（10-30-spider-js-runtime）的技术基线回归。
// ignore_for_file: invalid_use_of_protected_member
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_js/flutter_js.dart';

import 'native_lib_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('QuickJS 同步求值 + 同步宿主回调', () async {
    // 没有 QuickJS 原生桥就跳过（flutter test 是纯 Dart VM，加载不了插件原生库）。
    if (!ensureQuickJsLibrary()) return;
    final runtime = getJavascriptRuntime();
    // init/initChannelFunctions 是 protected 成员，但 getJavascriptRuntime 不会
    // 自动调用它们；官方 example 也直调，这里同样直调并显式标注。
    // init/initChannelFunctions 是 protected 成员；getJavascriptRuntime 不会自动
    // 调用它们，官方 example 也是直调（本文件顶部已 ignore_for_file）。
    runtime.init(); // console/setTimeout 桥接。
    runtime
        .initChannelFunctions(); // 注入 sendMessage（必须先于 onMessage：会清空注册表）。
    runtime.onMessage('httpGet', (args) {
      // 模拟宿主 HTTP：返回 JSON 字符串（桥接会解码成 JS 对象）。
      return '{"code":200,"body":"OK"}';
    });

    // typeof 校验 sendMessage 全局存在。
    expect(runtime.evaluate('typeof sendMessage').stringResult, 'function');
    // 垫片：宿主返回值可能是 JSON 字符串或已解码对象（平台/调用路径差异），
    // 统一归一化成对象——这是 spider 运行时宿主 API 的固定模式。
    runtime.evaluate('''
      function normalize(v) { return typeof v === 'string' ? JSON.parse(v) : v; }
    ''');
    final result = runtime.evaluate('''
      var resp = normalize(sendMessage('httpGet', JSON.stringify({url: 'http://x/1'})));
      JSON.stringify({code: resp.code, body: resp.body});
    ''');
    expect(result.stringResult, contains('"code":200'));
    expect(result.stringResult, contains('"body":"OK"'));
    runtime.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
