import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源管理「批量测速后删除超时源」的契约回归（11-19）。
///
/// 用户确认口径：**只标记不自动删** —— App 不做任何自动判定或自动删除，
/// 只提供「按测速状态筛选 + 手动勾选 + 二次确认后删除」。
///
/// 本测试按本仓既有口径（源码结构断言）锁死：
/// 1) 有按测速状态的筛选入口；
/// 2) 删除走既有 SourcesStore.remove 持久化链路；
/// 3) 批量删除前有二次确认；
/// 4) 不存在「测速完成即自动删除」这类自动删除路径。
void main() {
  final source =
      File('lib/screens/source_manage_screen.dart').readAsStringSync();

  test('有按测速状态（超时/失败/慢速/未测）的筛选入口', () {
    expect(source, contains('enum _ProbeFilter'));
    expect(source, contains("timeout('超时')"));
    expect(source, contains("failed('失败')"));
    expect(source, contains("slow('慢速')"));
    expect(source, contains("untested('未测')"));
  });

  test('批量删除复用 SourcesStore.remove 持久化链路并逐个清理测速状态', () {
    expect(source, contains('await scope.sources.remove(id)'));
    // 测速结果随源一起清理，避免列表残留旧状态。
    expect(source, contains('_probe.remove(id)'));
    expect(source, contains('_selectedForRemoval.remove(id)'));
  });

  test('批量删除前有二次确认（删除不可逆）', () {
    final deleteStart = source.indexOf('Future<void> _deleteSelected');
    expect(deleteStart, greaterThan(0));
    // 用下一个顶层方法作边界（文件是 CRLF 行尾，不能用 '\n  }' 截断）。
    final end = source.indexOf('Widget _bulkRemoveBar', deleteStart);
    expect(end, greaterThan(deleteStart));
    final body = source.substring(deleteStart, end);
    expect(body, contains('showDialog<bool>'));
    expect(body, contains('删除后不可恢复'));
    // 确认前不得调用 remove。
    expect(body.indexOf('showDialog<bool>'),
        lessThan(body.indexOf('await scope.sources.remove(id)')));
  });

  test('只标记不自动删：测速完成路径不含任何删除调用', () {
    final probeAllStart = source.indexOf('Future<void> _probeAll');
    expect(probeAllStart, greaterThan(0));
    final end = source.indexOf('Future<void> _checkOne', probeAllStart);
    expect(end, greaterThan(probeAllStart));
    final body = source.substring(probeAllStart, end);
    expect(body, isNot(contains('sources.remove')),
        reason: '批量测速完成不得触发删除（用户口径：只标记不自动删）');
    expect(body, isNot(contains('deleteSelected')),
        reason: '批量测速完成不得自动触发批量删除');
  });

  test('删除操作全部由用户勾选驱动（勾选集合与筛选一致）', () {
    expect(source, contains('_selectedForRemoval'));
    expect(source, contains('Checkbox('));
    expect(source, contains('全选当前筛选'));
    expect(source, contains('删除所选'));
  });

  test('删除完成提示就地显示在操作条内，不用底部 SnackBar（11-19）', () {
    // 用户实测：删除时弹出的底部 SnackBar 把右下角「全选当前筛选 / 删除所选」
    // 两个按钮整条盖住点不到。改为在操作条内就地显示，2.5s 自动收回。
    final deleteStart = source.indexOf('Future<void> _deleteSelected');
    final end = source.indexOf('Widget _bulkRemoveBar', deleteStart);
    final body = source.substring(deleteStart, end);
    expect(body, isNot(contains('showGlassToast')),
        reason: '删除完成提示不得再用底部 SnackBar（会遮挡批量操作条）');
    expect(body, contains('_bulkNotice'));
    expect(source, contains('_bulkNoticeTimer'));
    // 操作条必须渲染这条就地提示。
    expect(source, contains('if (_bulkNotice != null)'));
  });
}
