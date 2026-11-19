import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../theme/app_metrics.dart';
import '../theme/app_tokens.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../widgets/ui/app_gap.dart';
import '../widgets/ui/app_empty_state.dart';
import '../widgets/ui/app_icons.dart';
import '../core/sources/cms_json_adapter.dart';
import '../core/sources/source_adapter.dart';
import '../core/sources/source_checker.dart';
import '../core/sources/source_import.dart';
import '../core/sources/qr_share_server.dart';
import '../core/sources/source_probe.dart';
import '../core/sources/source_registry.dart';
import '../widgets/glass/glass_overlay.dart';
import '../widgets/common.dart';
import 'source_market_screen.dart';

/// 源管理：增删改查 / 开关 / 钉选 / 排序 / 单源检测 / 导入导出 / 清缓存。
class SourceManageScreen extends StatefulWidget {
  const SourceManageScreen({super.key});

  @override
  State<SourceManageScreen> createState() => _SourceManageScreenState();
}

/// 测速结果筛选（只标记不自动删；App 不做自动判定）。
enum _ProbeFilter {
  all('全部'),
  timeout('超时'),
  failed('失败'),
  slow('慢速'),
  untested('未测');

  const _ProbeFilter(this.label);

  final String label;
}

class _SourceManageScreenState extends State<SourceManageScreen> {
  /// 单源测速/检测状态：sourceId → 展示文本。
  final Map<String, ProbeOutcome?> _probe = {};
  final Map<String, String> _checkText = {};
  final Set<String> _probing = {};
  bool _probingAll = false;

  /// 测完重排后回到顶部：好源在最上面，不用再自己往下找。
  final ScrollController _listController = ScrollController();

  /// 测速结果筛选：只标记不自动删（用户 11-19 确认口径）——
  /// App 不做任何自动判定/自动删除，全部由用户勾选并二次确认。
  _ProbeFilter _probeFilter = _ProbeFilter.all;

  /// 批量删除勾选的源 id（手动勾选，非自动判定）。
  final Set<String> _selectedForRemoval = {};

  /// 批量删除进行中：避免重复点击。
  bool _removingSelected = false;

  /// 批量删除完成的就地提示（11-19 用户实测「删除时把右下角按钮遮住了」）。
  ///
  /// 原实现用 `showGlassToast` 弹底部 SnackBar —— SnackBar 贴屏幕底边，
  /// 正好压在同在底部的批量操作条上，「全选当前筛选 / 删除所选」两个按钮
  /// 整条被盖住点不到。改为在操作条内就地显示，2.5s 后自动收回，
  /// 不遮挡任何控件。
  String? _bulkNotice;
  Timer? _bulkNoticeTimer;

  @override
  void dispose() {
    _listController.dispose();
    _bulkNoticeTimer?.cancel();
    super.dispose();
  }

  /// 当前筛选下命中的源（只标记不自动删：这里只做「显示过滤」，
  /// 不删除、不替用户做决定）。
  bool _matchesProbeFilter(SourceConfig s) {
    final probe = _probe[s.id];
    return switch (_probeFilter) {
      _ProbeFilter.all => true,
      _ProbeFilter.timeout => probe?.state == ProbeState.timeout,
      _ProbeFilter.failed => probe?.state == ProbeState.failed,
      _ProbeFilter.slow =>
        probe?.state == ProbeState.ok &&
            probeLevel(probe?.latencyMs ?? 0) == ProbeLevel.slow,
      _ProbeFilter.untested => probe == null,
    };
  }

  /// 筛选后的可见源。
  List<SourceConfig> _visibleSources(List<SourceConfig> sorted) =>
      sorted.where(_matchesProbeFilter).toList();

  /// 测速结果筛选栏：按状态快速定位要清理的源。
  Widget _probeFilterBar(AppScope scope) {
    // 各状态计数：让用户点之前就知道每个分类有多少个。
    var timeout = 0, failed = 0, slow = 0, untested = 0;
    for (final s in scope.sources.all) {
      final probe = _probe[s.id];
      if (probe == null) {
        untested++;
      } else if (probe.state == ProbeState.timeout) {
        timeout++;
      } else if (probe.state == ProbeState.failed) {
        failed++;
      } else if (probeLevel(probe.latencyMs ?? 0) == ProbeLevel.slow) {
        slow++;
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SizedBox(
        // 横向 chip 条给紧高度约束（与全站其它 chip 条同口径 44）：
        // 否则松高度约束下会吃满可用高度，把 chip 拉成全高竖条。
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            for (final f in _ProbeFilter.values)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(switch (f) {
                    _ProbeFilter.all => '${f.label} ${scope.sources.all.length}',
                    _ProbeFilter.timeout => '${f.label} $timeout',
                    _ProbeFilter.failed => '${f.label} $failed',
                    _ProbeFilter.slow => '${f.label} $slow',
                    _ProbeFilter.untested => '${f.label} $untested',
                  }),
                  selected: _probeFilter == f,
                  onSelected: (_) => setState(() => _probeFilter = f),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 批量删除已勾选的源：二次确认（删除不可逆）+ 逐个走既有持久化链路。
  Future<void> _deleteSelected(AppScope scope) async {
    if (_removingSelected || _selectedForRemoval.isEmpty) return;
    final ids = List<String>.of(_selectedForRemoval);
    final names = <String>[
      for (final s in scope.sources.all)
        if (ids.contains(s.id)) s.name,
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除所选的 ${ids.length} 个源？'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('删除后不可恢复，将从本机源列表中移除：'),
              const SizedBox(height: 8),
              for (final n in names.take(20)) Text('· $n'),
              if (names.length > 20) Text('…等 ${names.length} 个'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    setState(() => _removingSelected = true);
    for (final id in ids) {
      await scope.sources.remove(id);
      // 测速结果随源一起清理，避免残留行内状态。
      _probe.remove(id);
      _checkText.remove(id);
      _probing.remove(id);
      _selectedForRemoval.remove(id);
    }
    if (!mounted) return;
    setState(() => _removingSelected = false);
    // 11-19：不再弹底部 SnackBar（会压住同在底部的批量操作条按钮），
    // 改为在操作条内就地提示，2.5s 后自动收回。
    _bulkNoticeTimer?.cancel();
    setState(() => _bulkNotice = '已删除 ${ids.length} 个源');
    _bulkNoticeTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      setState(() => _bulkNotice = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final health = scope.sourceHealth;
    final sorted = sortSourcesForDisplay(
      scope.sources.all,
      scoreOf: (s) => health.scoreOf(s.id),
      latencyOf: (s) => health.latencyOf(s.id),
      // 批量测速进行中不重排（只更新行内结果文本），测完一次性重排。
      // 边测边重排会让列表在用户眼皮底下反复跳动（MoonTVPlus 同款门控）。
      // 结论存在 SourceHealthStore 里：back 回影视聚合后排序口径不变。
      probeOf: _probingAll ? null : (s) => health.probeOf(s.id),
    );
    // 筛选后的可见列表（显示过滤，不改真实次序）。
    final visible = _visibleSources(sorted);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('源管理'),
        actions: [
          IconButton(
            tooltip: '源市场（自动扫描抓源）',
            icon: const Icon(AppIcons.store),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SourceMarketScreen()));
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            tooltip: '批量测速',
            icon: Icon(_probingAll ? AppIcons.hourglass : AppIcons.speed),
            onPressed: _probingAll ? null : () => _probeAll(sorted),
          ),
          IconButton(
            tooltip: '导入',
            icon: const Icon(Icons.download),
            onPressed: () => _importDialog(scope),
          ),
          IconButton(
            tooltip: '扫码导入（手机粘贴提交）',
            icon: const Icon(AppIcons.qrScanner),
            onPressed: () => _showQrImport(context, scope),
          ),
          IconButton(
            tooltip: '导出到手机',
            icon: const Icon(Icons.share_outlined),
            onPressed: () => _showQrExport(context, scope),
          ),
          IconButton(
            tooltip: '导出',
            icon: const Icon(Icons.upload),
            onPressed: () => _exportDialog(scope),
          ),
        ],
      ),
      body: sorted.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppEmptyState(
                    title: '还没有源',
                    description: '去「源市场」扫描抓源，或点右上角导入',
                    icon: AppIcons.empty,
                  ),
                  AppGap.v(AppGapSize.s16),
                  FilledButton.icon(
                    onPressed: () async {
                      await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const SourceMarketScreen()));
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(AppIcons.store),
                    label: const Text('去源市场'),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                _probeFilterBar(scope),
                Expanded(
                  child: ListView.builder(
                  controller: _listController,
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final s = visible[index];
                final probe = _probe[s.id];
                final check = _checkText[s.id];
                final selected = _selectedForRemoval.contains(s.id);
                return ListTile(
                  // 多选勾选框：批量删除的入口（只标记不自动删）。
                  leading: Checkbox(
                    value: selected,
                    onChanged: (v) => setState(() {
                      if (v ?? false) {
                        _selectedForRemoval.add(s.id);
                      } else {
                        _selectedForRemoval.remove(s.id);
                      }
                    }),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(s.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      if (s.kind == SourceKind.spider)
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: Icon(AppIcons.bug, size: 14),
                        )
                      else
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: Icon(AppIcons.liveTv, size: 14),
                        ),
                      if (s.shortDrama)
                        Container(
                          padding: const EdgeInsets.fromLTRB(AppSpacing.s6, 1, AppSpacing.s6, 1),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.all(Radius.circular(AppSpacing.radiusXs)),
                          ),
                          child: Text('短剧',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: theme.colorScheme.onPrimaryContainer)),
                        ),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.api,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      if (_probing.contains(s.id))
                        const Text('测速中…'),
                      if (probe != null) _probeText(probe, theme),
                      if (check != null) Text(check, style: theme.textTheme.bodySmall),
                      if (health.coolingDown(s.id))
                        Text('冷却中（近期失败）',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.error)),
                    ],
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      switch (action) {
                        case 'probe':
                          _probeOne(scope, s);
                        case 'check':
                          await _checkOne(scope, s);
                        case 'pin':
                          await scope.sources.togglePinned(s.id);
                        case 'up':
                          // 排序基于完整列表：筛选只影响显示，不改真实次序。
                          final ids = [
                            for (final x in sorted) x.id,
                          ];
                          final realIndex =
                              sorted.indexWhere((x) => x.id == s.id);
                          if (realIndex > 0) {
                            final tmp = ids[realIndex - 1];
                            ids[realIndex - 1] = ids[realIndex];
                            ids[realIndex] = tmp;
                            await scope.sources.reorder(ids);
                          }
                        case 'edit':
                          await _editDialog(scope, s);
                        case 'remove':
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text('删除「${s.name}」？'),
                              actions: [
                                TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('取消')),
                                FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('删除')),
                              ],
                            ),
                          );
                          if (ok ?? false) await scope.sources.remove(s.id);
                      }
                      if (mounted) setState(() {});
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                          value: 'probe', child: Text('测速')),
                      const PopupMenuItem(
                          value: 'check', child: Text('站点自检')),
                      PopupMenuItem(
                          value: 'pin',
                          child: Text(s.pinned ? '取消钉选' : '钉选置顶')),
                      const PopupMenuItem(value: 'up', child: Text('上移')),
                      const PopupMenuItem(
                          value: 'edit', child: Text('编辑')),
                      const PopupMenuItem(
                          value: 'remove', child: Text('删除')),
                    ],
                  ),
                  isThreeLine: true,
                );
                  },
                ),
              ),
                _bulkRemoveBar(scope, visible),
              ],
            ),
    );
  }

  /// 底部批量操作条：勾选数 + 「全选当前筛选」+ 「删除所选」。
  ///
  /// 只标记不自动删（用户 11-19 确认口径）：这里只提供手动勾选与二次确认，
  /// App 不做任何自动判定或自动删除。
  Widget _bulkRemoveBar(AppScope scope, List<SourceConfig> visible) {
    final theme = Theme.of(context);
    final int selectedCount = _selectedForRemoval.length;
    final bool allSelected = visible.isNotEmpty &&
        visible.every((s) => _selectedForRemoval.contains(s.id));
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(
            children: [
              // 11-19：删除完成提示就地显示在操作条内（不遮挡按钮），
              // 2.5s 后自动收回，露出「已选 N 个」。
              if (_bulkNotice != null)
                Text(_bulkNotice!, style: theme.textTheme.bodySmall)
              else
                Text('已选 $selectedCount 个',
                    style: theme.textTheme.bodySmall),
              const Spacer(),
              TextButton(
                onPressed: visible.isEmpty
                    ? null
                    : () => setState(() {
                          if (allSelected) {
                            _selectedForRemoval
                              ..clear()
                              ..removeAll(visible.map((s) => s.id));
                          } else {
                            _selectedForRemoval.addAll(visible.map((s) => s.id));
                          }
                        }),
                child: Text(allSelected ? '取消全选' : '全选当前筛选'),
              ),
              AppGap.h(AppGapSize.s8),
              FilledButton.icon(
                onPressed: selectedCount == 0 || _removingSelected
                    ? null
                    : () => _deleteSelected(scope),
                icon: const Icon(Icons.delete_outline),
                label: Text(_removingSelected ? '删除中…' : '删除所选'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _probeText(ProbeOutcome probe, ThemeData theme) {
    final tokens = context.app;
    final style = theme.textTheme.bodySmall;
    return switch (probe.state) {
      ProbeState.ok => Text(
          '连接成功 ${probe.latencyMs}ms',
          style: style?.copyWith(
            color: switch (probeLevel(probe.latencyMs ?? 9999)) {
              ProbeLevel.fast => tokens.colors.success,
              ProbeLevel.normal => tokens.colors.warning,
              ProbeLevel.slow => tokens.colors.danger,
            },
          ),
        ),
      ProbeState.timeout =>
        Text('超时', style: style?.copyWith(color: theme.colorScheme.error)),
      ProbeState.failed => Text('失败：${probe.reason}',
          style: style?.copyWith(color: theme.colorScheme.error)),
    };
  }

  /// 主动测速也是一次真实命中：成功写延迟，失败写原因，健康分才有区分度。
  ///
  /// 爬虫源恒返回失败（需 JVM 引擎），写进去会让它永久垫底并进入冷却，故跳过；
  /// 其余方言（cmsJson / cmsXml / spiderJs）都记，测速排序才对所有源一致。
  Future<void> _recordProbeHealth(
      AppScope scope, SourceKind? kind, ProbeOutcome outcome) async {
    if (kind == null || kind == SourceKind.spider) return;
    scope.sourceHealth.rememberProbe(outcome);
    if (outcome.isOk) {
      await scope.sourceHealth.recordSuccess(
          outcome.sourceId, outcome.latencyMs ?? 0);
    } else {
      await scope.sourceHealth
          .recordFailure(outcome.sourceId, outcome.reason);
    }
  }

  Future<void> _probeOne(AppScope scope, SourceConfig s) async {
    // 测速是网络调用，短则几百毫秒长则超时：先给「测速中」反馈，
    // 否则用户点了行内菜单看不到任何动静（「点测试没有反应」的主诉）。
    setState(() => _probing.add(s.id));
    try {
      final outcome = await probeSource(s,
          timeout: Duration(milliseconds: scope.settings.sourcesProbeTimeoutMs));
      await _recordProbeHealth(scope, s.kind, outcome);
      if (!mounted) return;
      setState(() {
        _probing.remove(s.id);
        _probe[s.id] = outcome;
      });
    } catch (_) {
      if (mounted) setState(() => _probing.remove(s.id));
    }
  }

  Future<void> _probeAll(List<SourceConfig> sources) async {
    setState(() => _probingAll = true);
    final scope = AppScope.read(context);
    final kinds = {for (final s in sources) s.id: s.kind};
    var ok = 0;
    var timeout = 0;
    var failed = 0;
    await for (final e in probeSources(sources,
        timeout: Duration(milliseconds: scope.settings.sourcesProbeTimeoutMs))) {
      if (e is ProbeProgress) {
        await _recordProbeHealth(scope, kinds[e.outcome.sourceId], e.outcome);
        if (e.outcome.state == ProbeState.ok) {
          ok++;
        } else if (e.outcome.state == ProbeState.timeout) {
          timeout++;
        } else {
          failed++;
        }
        if (!mounted) return;
        setState(() => _probe[e.outcome.sourceId] = e.outcome);
      }
    }
    if (!mounted) return;
    // 全部测完才重排（此时 probeOf 生效），并回到顶部让最快的源直接可见。
    setState(() => _probingAll = false);
    if (_listController.hasClients) _listController.jumpTo(0);
    if (context.mounted) {
      // 一次提示说清两件事：结果统计 + 可按状态筛选删除（不自动删）。
      final hint = (timeout > 0 || failed > 0)
          ? '，可按「超时 / 失败」筛选后勾选删除（不会自动删除）'
          : '';
      showGlassToast(context,
          '测速完成：$ok 成功 / $timeout 超时 / $failed 失败，已按速度排序$hint');
    }
  }

  Future<void> _checkOne(AppScope scope, SourceConfig s) async {
    if (s.kind == SourceKind.spider) {
      if (context.mounted) {
        showGlassToast(context, '爬虫源暂不支持自检（需桌面爬虫引擎）');
      }
      return;
    }
    setState(() => _checkText[s.id] = '自检中…');
    final result = await checkSource(CmsJsonAdapter(s));
    if (!mounted) return;
    setState(() => _checkText[s.id] = result.friendlyText);
  }

  Future<void> _importDialog(AppScope scope) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入源'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '支持 TVBox 配置 / MoonTV / 多仓 / Base64 / 「名称|地址」文本行。'
                '内容由第三方提供，请自行确认授权与合法性。',
                style: TextStyle(fontSize: 12),
              ),
              AppGap.v(AppGapSize.s8),
              TextField(
                controller: controller,
                maxLines: 6,
                decoration: const InputDecoration(
                  hintText: '粘贴配置文本或接口地址（http://…）',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) return;
    final text = controller.text.trim();
    if (text.isEmpty) return;

    final report = text.startsWith('http://') || text.startsWith('https://')
        ? await SourceImporter.importFromUrl(text)
        : await SourceImporter.importFromText(text);
    if (!mounted) return;
    final added = await scope.sources.addCandidates(report.added);
    if (report.lives.isNotEmpty) {
      await scope.lives.addCandidates(report.lives);
    }
    if (report.parses.isNotEmpty) {
      await scope.marketSites.addParses(report.parses);
    }
    if (!mounted) return;
    final problems = report.failed.length + report.skipped.length;
    if (context.mounted) {
      showGlassToast(context, 
          '导入完成：新增 $added，跳过 ${report.skipped.length}，失败 ${report.failed.length}'
          '${problems > 0 ? '（详情见错误日志）' : ''}');
    }
  }

  /// 扫码导入：桌面生成一次性二维码，手机浏览器粘贴配置提交。
  Future<void> _showQrImport(BuildContext context, AppScope scope) async {
    final server = QrShareServer();
    String status = '正在生成二维码…';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final messenger = ScaffoldMessenger.maybeOf(context);
          Future<void> run() async {
            server.onSubmit = (text) async {
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
              final report = await SourceImporter.importFromText(text);
              final added = await scope.sources.addCandidates(report.added);
              if (report.lives.isNotEmpty) {
                await scope.lives.addCandidates(report.lives);
              }
              if (report.parses.isNotEmpty) {
                await scope.marketSites.addParses(report.parses);
              }
              if (!mounted) return;
              setState(() {});
              messenger?.showSnackBar(SnackBar(
                content: Text('扫码导入完成：新增 $added 个点播源、'
                    '${report.lives.length} 个直播配置'),
              ));
            };
            final url = await server.start();
            if (!mounted) return;
            _qrUrl = url;
            setDialogState(() => status = '手机扫码，在浏览器里粘贴配置提交（5 分钟内有效）');
            Future.delayed(const Duration(minutes: 5), () {
              if (mounted) setDialogState(() => status = '二维码已过期，请重新打开');
            });
          }

          if (status.startsWith('正在生成')) {
            WidgetsBinding.instance.addPostFrameCallback((_) => run());
          }
          return AlertDialog(
            title: const Text('扫码导入配置'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.s8, AppSpacing.s8, AppSpacing.s8, AppSpacing.s8),
                  color: Colors.white,
                  child: QrImageView(
                    data: status.startsWith('正在生成') ? ' ' : _qrUrl ?? ' ',
                    size: 200,
                  ),
                ),
                AppGap.v(AppGapSize.s12),
                Text(status, textAlign: TextAlign.center),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('关闭')),
            ],
          );
        },
      ),
    );
    await server.stop();
  }

  String? _qrUrl;

  /// 导出到手机：生成含当前配置的二维码，手机浏览器查看/复制/下载。
  Future<void> _showQrExport(BuildContext context, AppScope scope) async {
    final sources = scope.sources.all;
    if (sources.isEmpty) {
      if (context.mounted) {
        showGlassToast(context, '还没有可导出的源');
      }
      return;
    }
    final json = const JsonEncoder.withIndent('  ').convert({
      'sites': [
        for (final s in sources)
          {
            'key': s.id,
            'name': s.name,
            'type': s.kind == SourceKind.cmsXml ? 0 : 1,
            'api': s.api,
            if (s.headers.isNotEmpty) 'header': s.headers,
          },
      ],
      'lives': [
        for (final l in scope.lives.all)
          {'name': l.name, 'url': l.url},
      ],
    });
    final server = QrShareServer();
    String status = '正在生成二维码…';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> run() async {
            final url = await server.startExport(json);
            if (!mounted) return;
            _qrUrl = url;
            setDialogState(() => status = '手机扫码查看/复制/下载（5 分钟内有效）');
            Future.delayed(const Duration(minutes: 5), () {
              if (mounted) setDialogState(() => status = '二维码已过期，请重新打开');
            });
          }

          if (status.startsWith('正在生成')) {
            WidgetsBinding.instance.addPostFrameCallback((_) => run());
          }
          return AlertDialog(
            title: const Text('导出到手机'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.s8, AppSpacing.s8, AppSpacing.s8, AppSpacing.s8),
                  color: Colors.white,
                  child: QrImageView(
                    data: status.startsWith('正在生成') ? ' ' : _qrUrl ?? ' ',
                    size: 200,
                  ),
                ),
                AppGap.v(AppGapSize.s12),
                Text(status, textAlign: TextAlign.center),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('关闭')),
            ],
          );
        },
      ),
    );
    await server.stop();
  }

  Future<void> _exportDialog(AppScope scope) async {
    final sources = scope.sources.all;
    if (sources.isEmpty) {
      if (context.mounted) {
        showGlassToast(context, '没有可导出的源');
      }
      return;
    }
    final json = const JsonEncoder.withIndent('  ').convert({
      'sites': [
        for (final s in sources)
          {
            'key': s.id,
            'name': s.name,
            'type': s.kind == SourceKind.cmsXml ? 0 : 1,
            'api': s.api,
            if (s.headers.isNotEmpty) 'header': s.headers,
          }
      ],
    });
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出源（TVBox sites 格式）'),
        content: SingleChildScrollView(
          child: SelectableText(json),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: json));
              if (context.mounted) {
                showGlassToast(context, '已复制到剪贴板');
              }
            },
            child: const Text('复制'),
          ),
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _editDialog(AppScope scope, SourceConfig s) async {
    final nameController = TextEditingController(text: s.name);
    final apiController = TextEditingController(text: s.api);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '名称')),
            TextField(
                controller: apiController,
                decoration: const InputDecoration(labelText: '接口地址')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    // 简化：编辑 = 删除旧的再按新地址入库（保留开关状态）。
    final enabled = s.enabled;
    final pinned = s.pinned;
    await scope.sources.remove(s.id);
    final updated = await scope.sources.addManual(
      name: nameController.text.trim(),
      api: apiController.text.trim(),
      kind: s.kind,
      headers: s.headers,
      note: s.note,
    );
    updated.enabled = enabled;
    updated.pinned = pinned;
    if (mounted) setState(() {});
  }
}
