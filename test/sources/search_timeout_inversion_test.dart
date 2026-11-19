import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 影视聚合搜索「超时倒挂」与负缓存的回归（11-19）。
///
/// 用户实测：搜「仙逆」时列出一长串失败源，结果区恒为空态。
///
/// 根因（超时倒挂）：编排器单源超时默认 5s，但
///   - CMS 端点自举单次探测 6s；
///   - JS 源搜索期下载源码 10s（导入期默认值）；
///   - Go syncHttp 单请求 20s。
/// 需要联网自举的源在结果回来前就被编排器掐断 → 全部误判超时。
/// 叠加 90s 负缓存：失败后每次搜索都直接重放失败、且不再发请求，
/// 于是「反复搜同一个词都搜不出内容」。
///
/// 本测试按本仓既有口径（源码结构断言）锁死修复。
void main() {
  test('CMS 端点自举的单次探测超时短于编排器单源预算', () {
    final source =
        File('lib/core/sources/cms_json_adapter.dart').readAsStringSync();
    expect(source, contains('_probeTimeout'));
    expect(source, isNot(contains('timeout: const Duration(seconds: 6))')),
        reason: '6s 探测超时大于 5s 单源预算，必须收敛');
  });

  test('JS 源搜索期下载超时短于编排器单源预算', () {
    final source =
        File('lib/core/sources/spider_js_adapter.dart').readAsStringSync();
    expect(source, contains('_searchDownloadTimeout'));
  });

  test('Go syncHttp 支持可选单请求超时，搜索期传短超时', () {
    final go =
        File('native/bridge/core/sync_http.go').readAsStringSync();
    expect(go, contains('TimeoutMs'));
    expect(go, contains('timeoutMs'));
    final dart = File(
      'lib/core/sources/fongmi/fongmi_spider_runtime.dart',
    ).readAsStringSync();
    expect(dart, contains('timeoutMs'));
  });

  test('负缓存 TTL 收敛且不再重放伪造的失败事件', () {
    final source =
        File('lib/core/sources/search_orchestrator.dart').readAsStringSync();
    expect(source, isNot(contains('Duration(seconds: 90)')),
        reason: '90s 负缓存让失败源在窗口内永远搜不出内容');
    expect(source, contains('negativeTtl = Duration(seconds: 20)'));
    // 负缓存命中只跳过本源，不再 yield 失败事件（原先的
    // `yield SourceFailedEvent(..., '负缓存命中')` 已移除）。
    final negStart = source.indexOf('negativeAt != null');
    final negEnd = source.indexOf('positiveTtl)', negStart);
    expect(negStart, greaterThan(0));
    expect(negEnd, greaterThan(negStart));
    final negBlock = source.substring(negStart, negEnd);
    expect(negBlock, isNot(contains('yield SourceFailedEvent')),
        reason: '负缓存命中不得再伪造失败事件');
  });

  test('单源失败仍不影响其它源（契约不破）', () {
    final source =
        File('lib/core/sources/search_orchestrator.dart').readAsStringSync();
    // worker 内失败走 SourceFailedEvent 逐源上报，不中断整体。
    expect(source, contains('SourceFailedEvent'));
    expect(source, contains('totalBudget'));
  });
}
