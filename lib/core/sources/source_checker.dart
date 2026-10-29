import 'dart:async';

import 'source_adapter.dart';

/// 站点自检（xiugou-tv SiteSelfCheck 同语义）：识别「导入成功但全站空」的假成功。
///
/// 四级链路：分类拉取 → 首分类条数 → 首条详情 → 解析出 ≥1 条可播 URL。
class SourceCheckResult {
  const SourceCheckResult({
    required this.verdict,
    this.categoryCount = 0,
    this.listOk = false,
    this.detailOk = false,
    this.playableUrl = '',
    this.latencyMs = 0,
    this.message = '',
  });

  final SourceCheckVerdict verdict;
  final int categoryCount;
  final bool listOk;
  final bool detailOk;
  final String playableUrl;
  final int latencyMs;
  final String message;

  String get friendlyText => switch (verdict) {
        SourceCheckVerdict.ok => '可用 · 分类 $categoryCount · ${latencyMs}ms',
        SourceCheckVerdict.degraded =>
          '降级可用（${message.isEmpty ? '部分环节缺失' : message}）',
        SourceCheckVerdict.failed => '失败：${message.isEmpty ? '无可用内容' : message}',
        SourceCheckVerdict.timeout => '检测超时',
      };
}

enum SourceCheckVerdict { ok, degraded, failed, timeout }

/// 对单个适配器执行全链路自检。
Future<SourceCheckResult> checkSource(
  SourceAdapter adapter, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final sw = Stopwatch()..start();
  try {
    final result = await _check(adapter);
    return SourceCheckResult(
      verdict: result.verdict,
      categoryCount: result.categoryCount,
      listOk: result.listOk,
      detailOk: result.detailOk,
      playableUrl: result.playableUrl,
      latencyMs: sw.elapsedMilliseconds,
      message: result.message,
    );
  } on TimeoutException {
    return const SourceCheckResult(
        verdict: SourceCheckVerdict.timeout, message: '超时');
  } on SourceException catch (e) {
    return SourceCheckResult(
        verdict: SourceCheckVerdict.failed,
        latencyMs: sw.elapsedMilliseconds,
        message: e.friendlyText);
  } catch (e) {
    return SourceCheckResult(
        verdict: SourceCheckVerdict.failed,
        latencyMs: sw.elapsedMilliseconds,
        message: e.toString());
  }
}

class _CheckState {
  SourceCheckVerdict verdict = SourceCheckVerdict.ok;
  int categoryCount = 0;
  bool listOk = false;
  bool detailOk = false;
  String playableUrl = '';
  String message = '';
}

Future<_CheckState> _check(SourceAdapter adapter) async {
  final state = _CheckState();
  final categories = await adapter.categories();
  state.categoryCount = categories.length;
  if (categories.isEmpty) {
    // 分类空不一定是死站（个别站不给 class），继续试列表。
    final page = await adapter.list(page: 1);
    state.listOk = page.items.isNotEmpty;
    if (!state.listOk) {
      state.verdict = SourceCheckVerdict.failed;
      state.message = '分类与列表均为空';
      return state;
    }
  } else {
    final page = await adapter.list(categoryId: categories.first.id, page: 1);
    state.listOk = page.items.isNotEmpty;
  }

  String? itemId;
  if (state.listOk) {
    final page = await adapter.list(
        categoryId: categories.isEmpty ? null : categories.first.id,
        page: 1);
    itemId = page.items.firstOrNull?.sourceItemId;
  }
  if (itemId == null) {
    state.verdict = SourceCheckVerdict.degraded;
    state.message = '列表无条目';
    return state;
  }

  final series = await adapter.detail(itemId);
  state.detailOk = series.lines.isNotEmpty;
  final playable = await adapter.probePlayable(itemId: itemId);
  state.playableUrl = playable;
  if (!state.detailOk || playable.isEmpty) {
    state.verdict = SourceCheckVerdict.degraded;
    state.message = playable.isEmpty ? '无可播直链' : '详情解析不完整';
    return state;
  }
  return state;
}
