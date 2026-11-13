import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/reader/replace_rules.dart';
import '../store/stores.dart';
import '../theme/app_tokens.dart';
import '../widgets/ui/app_gap.dart';
import '../widgets/jelly/jelly_switch.dart';
import '../widgets/ui/app_badge.dart';
import '../widgets/ui/app_card.dart';
import '../widgets/ui/app_icons.dart';
import '../widgets/glass/glass_overlay.dart';
import '../widgets/common.dart';

/// 正文替换规则管理：去广告、去水印、去「本章未完」。
///
/// 规则在阅读页 `_deriveParagraphs` 里逐段执行，改完立即重排当前章。
class ReplaceRulesScreen extends StatelessWidget {
  const ReplaceRulesScreen({super.key, this.bookId = ''});

  /// 当前书籍 id；用于「仅本书」作用域的展示。
  final String bookId;

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).replaceRules;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final rules = store.rules;
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(
            title: const Text('正文替换规则'),
            actions: [
              PopupMenuButton<String>(
                tooltip: '导入导出',
                icon: const Icon(Icons.swap_vert),
                onSelected: (value) async {
                  if (value == 'legado') {
                    // 吸收「阅读」净化规则：剪贴板里的 legado 净化 JSON。
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    final text = data?.text ?? '';
                    final parsed = parseLegadoPurificationRules(text);
                    if (parsed.isEmpty) {
                      if (!context.mounted) return;
                      if (context.mounted) {
                        showGlassToast(context, '剪贴板里没有可识别的净化规则 JSON');
                      }
                      return;
                    }
                    for (final rule in parsed) {
                      await store.add(
                        name: rule.name,
                        pattern: rule.pattern,
                        replacement: rule.replacement,
                        isRegex: rule.isRegex,
                      );
                    }
                    if (!context.mounted) return;
                    if (context.mounted) {
                      showGlassToast(context, '已导入 ${parsed.length} 条净化规则');
                    }
                    return;
                  }
                  if (value == 'export') {
                    final json = const JsonEncoder.withIndent('  ').convert(
                      <String, dynamic>{
                        'rules': [
                          for (final rule in rules)
                            if (!rule.builtin) rule.toJson(),
                        ],
                      },
                    );
                    await Clipboard.setData(ClipboardData(text: json));
                    if (!context.mounted) return;
                    if (context.mounted) {
                      showGlassToast(context, '已复制规则 JSON');
                    }
                    return;
                  }
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  final text = data?.text ?? '';
                  if (text.trim().isEmpty) {
                    if (!context.mounted) return;
                    if (context.mounted) {
                      showGlassToast(context, '剪贴板里没有内容');
                    }
                    return;
                  }
                  try {
                    final parsed = jsonDecode(text);
                    final merged = await store.importData(
                      parsed is Map<String, dynamic>
                          ? parsed
                          : <String, dynamic>{'rules': parsed},
                    );
                    if (!context.mounted) return;
                    if (context.mounted) {
                      showGlassToast(context, '导入 $merged 条规则');
                    }
                  } catch (_) {
                    if (!context.mounted) return;
                    if (context.mounted) {
                      showGlassToast(context, '不是合法的规则 JSON');
                    }
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'export', child: Text('复制自定义规则')),
                  PopupMenuItem(value: 'import', child: Text('从剪贴板导入')),
                  PopupMenuItem(
                    value: 'legado',
                    child: Text('导入 legado 净化规则'),
                  ),
                ],
              ),
              TextButton(
                onPressed: store.restoreBuiltin,
                child: const Text('恢复内置'),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => _edit(context, store, null),
            icon: const Icon(Icons.add),
            label: const Text('新增规则'),
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  '规则按顺序逐段执行；替换后为空的段落会被丢弃。'
                  '正则写法与 Dart RegExp 一致。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
              for (final rule in rules)
                _RuleTile(
                  rule: rule,
                  onToggle: (v) => store.setEnabled(rule.id, v),
                  onEdit: () => _edit(context, store, rule),
                  onDelete: () => store.remove(rule.id),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _edit(
    BuildContext context,
    ReplaceRuleStore store,
    ReplaceRule? rule,
  ) async {
    final nameController = TextEditingController(text: rule?.name ?? '');
    final patternController = TextEditingController(text: rule?.pattern ?? '');
    final replacementController =
        TextEditingController(text: rule?.replacement ?? '');
    var isRegex = rule?.isRegex ?? true;
    var scope = rule?.scope ?? ReplaceScope.global;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(rule == null ? '新增替换规则' : '编辑替换规则'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '名称'),
                ),
                TextField(
                  controller: patternController,
                  decoration: const InputDecoration(
                    labelText: '匹配内容',
                    hintText: r'(本章未完|点击下一页)',
                  ),
                  maxLines: 2,
                ),
                TextField(
                  controller: replacementController,
                  decoration: const InputDecoration(
                    labelText: '替换为（留空即删除）',
                  ),
                ),
                AppGap.v(AppGapSize.s12),
                Row(
                  children: [
                    const Text('正则'),
                    Switch(
                      value: isRegex,
                      onChanged: (v) => setDialogState(() => isRegex = v),
                    ),
                    const Spacer(),
                    SegmentedButton<ReplaceScope>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                            value: ReplaceScope.global, label: Text('全部')),
                        ButtonSegment(
                            value: ReplaceScope.book, label: Text('仅本书')),
                      ],
                      selected: {scope},
                      onSelectionChanged: (values) =>
                          setDialogState(() => scope = values.first),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (!isValidPattern(patternController.text) && isRegex) {
                  showGlassToast(dialogContext, '正则不合法');
                  return;
                }
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    final name = nameController.text.trim();
    final pattern = patternController.text;
    final replacement = replacementController.text;
    nameController.dispose();
    patternController.dispose();
    replacementController.dispose();
    if (saved != true || pattern.isEmpty) return;
    if (rule == null) {
      await store.add(
        name: name,
        pattern: pattern,
        replacement: replacement,
        isRegex: isRegex,
        scope: scope,
        bookId: bookId,
      );
      return;
    }
    await store.update(rule.copyWith(
      name: name,
      pattern: pattern,
      replacement: replacement,
      isRegex: isRegex,
      scope: scope,
    ));
  }
}

class _RuleTile extends StatelessWidget {
  const _RuleTile({
    required this.rule,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final ReplaceRule rule;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    return AppCard.row(
      // 开关行沿用「前导 = 控件」的旧位型；果冻开关（批次④）保持一致手感。
      leading: JellySwitch(value: rule.enabled, onChanged: onToggle),
      title: rule.name,
      titleTrailing: rule.builtin
          ? const AppBadge(text: '内置', tone: AppBadgeTone.neutral)
          : (rule.scope == ReplaceScope.book
              ? Text('本书', style: tokens.caption.copyWith(
                    color: tokens.colors.brand))
              : null),
      subtitle:
          '${rule.pattern}${rule.replacement.isEmpty ? '' : ' → ${rule.replacement}'}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '编辑',
            icon: const Icon(AppIcons.edit, size: 18),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(AppIcons.delete, size: 18),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
