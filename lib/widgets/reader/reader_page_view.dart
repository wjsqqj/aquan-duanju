import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/reader/reader_annotations.dart';
import '../../core/reader/reader_page_metrics.dart';
import '../../core/reader/reader_paginator.dart';
import '../../core/reader/reader_theme.dart';
import '../../core/reader/reader_typography.dart';

/// 单页渲染所需的全部外观参数（由阅读页每帧按设置计算一次）。
class ReaderPageRenderSpec {
  const ReaderPageRenderSpec({
    required this.typography,
    required this.theme,
    required this.night,
    required this.chapterTitle,
    required this.bookName,
    required this.chapterIndex,
    required this.chapterSize,
    required this.headerHeight,
    required this.footerHeight,
    this.header = const ReaderTipLayout(),
    this.footer = const ReaderTipLayout(),
    this.showHeader = false,
    this.showFooter = false,
    this.progress = 0,
    this.batteryPercent,
    this.markings = const <ReaderMarking>[],
    this.onMarkRequested,
  });

  final ReaderTypography typography;
  final ReaderThemeConfig theme;
  final bool night;

  final String chapterTitle;
  final String bookName;
  final int chapterIndex;
  final int chapterSize;

  final double headerHeight;
  final double footerHeight;

  final ReaderTipLayout header;
  final ReaderTipLayout footer;
  final bool showHeader;
  final bool showFooter;

  final double progress;
  final int? batteryPercent;

  /// 本章划线（渲染时按行区间求交集高亮）。
  final List<ReaderMarking> markings;

  /// 用户点「划线」时回调选中的纯文本，由页面负责换算成章内字符区间。
  final void Function(String selectedText)? onMarkRequested;

  Color get background =>
      Color(night ? theme.backgroundColorNight : theme.backgroundColor);

  Color get foreground =>
      Color(night ? theme.textColorNight : theme.textColor);

  Color get tipColor => foreground.withValues(alpha: 0.55);

  Color get dividerColor => foreground.withValues(alpha: 0.12);

  TextStyle get bodyStyle => typography.bodyStyle(color: foreground);

  TextStyle get titleStyle => typography.titleStyle(color: foreground);

  TextStyle get tipStyle => TextStyle(
        color: tipColor,
        fontSize: (typography.fontSize - 6).clamp(9.0, 14.0),
        height: 1.2,
      );

  EdgeInsets get contentPadding => EdgeInsets.fromLTRB(
        typography.paddingLeft,
        typography.paddingTop,
        typography.paddingRight,
        typography.paddingBottom,
      );
}

/// 一页的渲染。每行用 `softWrap: false + maxLines: 1` 画出来，
/// 物理上不可能二次换行，因此与分页器的测量结果逐行对齐。
///
/// 正文区包一层 [SelectionArea]：长按可选字、可跨行选择、可复制；
/// 选中后菜单里的「划线」把选中文本回传给页面换算成字符区间。
class ReaderPageContent extends StatefulWidget {
  const ReaderPageContent({
    super.key,
    required this.page,
    required this.pageIndex,
    required this.pageSize,
    required this.spec,
  });

  final ReaderPage page;
  final int pageIndex;
  final int pageSize;
  final ReaderPageRenderSpec spec;

  @override
  State<ReaderPageContent> createState() => _ReaderPageContentState();
}

class _ReaderPageContentState extends State<ReaderPageContent> {
  /// 最近一次选区文本。选择过程中会频繁回调，这里只赋值不 setState。
  String _selection = '';

  ReaderPage get page => widget.page;

  ReaderPageRenderSpec get spec => widget.spec;

  @override
  Widget build(BuildContext context) {
    final typography = spec.typography;
    final showTitle = widget.pageIndex == 0 &&
        typography.includeChapterTitle &&
        spec.chapterTitle.trim().isNotEmpty;

    return DecoratedBox(
      decoration: BoxDecoration(color: spec.background),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _BackgroundLayer(spec: spec),
          Padding(
            padding: spec.contentPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (spec.showHeader) ...[
                  _TipRow(
                    layout: spec.header,
                    style: spec.tipStyle,
                    height: spec.headerHeight,
                  ),
                  if (spec.theme.showHeaderLine)
                    Divider(
                        height: 1,
                        thickness: 0.6,
                        color: spec.dividerColor),
                ],
                if (showTitle)
                  Padding(
                    padding: const EdgeInsets.only(bottom: kReaderTitleGap),
                    child: Text(spec.chapterTitle, style: spec.titleStyle),
                  ),
                Expanded(
                  child: SelectionArea(
                    onSelectionChanged: (content) {
                      _selection = content?.plainText.trim() ?? '';
                    },
                    contextMenuBuilder: _buildContextMenu,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final line in page.lines) ...[
                          SizedBox(
                            height: line.height,
                            child: _lineWidget(line),
                          ),
                          if (line.gapAfter > 0)
                            SizedBox(height: line.gapAfter),
                        ],
                      ],
                    ),
                  ),
                ),
                if (spec.showFooter) ...[
                  if (spec.theme.showFooterLine)
                    Divider(
                        height: 1,
                        thickness: 0.6,
                        color: spec.dividerColor),
                  _TipRow(
                    layout: spec.footer,
                    style: spec.tipStyle,
                    height: spec.footerHeight,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContextMenu(
    BuildContext context,
    SelectableRegionState state,
  ) {
    final items = <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        label: '复制',
        onPressed: () {
          final text = _selection;
          state.hideToolbar();
          if (text.isEmpty) return;
          Clipboard.setData(ClipboardData(text: text));
        },
      ),
      if (spec.onMarkRequested != null)
        ContextMenuButtonItem(
          label: '划线',
          onPressed: () {
            final text = _selection;
            state.hideToolbar();
            if (text.isEmpty) return;
            spec.onMarkRequested!(text);
          },
        ),
    ];
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: items,
    );
  }

  /// 一行：有划线交集就用 `Text.rich` 按区间切 span，否则普通 `Text`。
  Widget _lineWidget(ReaderPageLine line) {
    final hits = <ReaderMarking>[
      for (final marking in spec.markings)
        if (marking.overlaps(line.charStart, line.charEnd)) marking,
    ];
    if (hits.isEmpty || line.text.isEmpty) {
      return Text(
        line.text,
        style: spec.bodyStyle,
        softWrap: false,
        maxLines: 1,
        overflow: TextOverflow.clip,
      );
    }

    final length = line.text.length;
    final cuts = <int>{0, length};
    for (final marking in hits) {
      cuts.add((marking.charStart - line.charStart).clamp(0, length));
      cuts.add((marking.charEnd - line.charStart).clamp(0, length));
    }
    final sorted = cuts.toList()..sort();
    final spans = <InlineSpan>[];
    for (var i = 0; i < sorted.length - 1; i++) {
      final start = sorted[i];
      final end = sorted[i + 1];
      if (end <= start) continue;
      final absolute = line.charStart + start;
      ReaderMarking? hit;
      for (final marking in hits) {
        if (marking.charStart <= absolute && absolute < marking.charEnd) {
          hit = marking;
          break;
        }
      }
      spans.add(TextSpan(
        text: line.text.substring(start, end),
        style: hit == null
            ? null
            : TextStyle(backgroundColor: Color(hit.color.argb)),
      ));
    }
    return Text.rich(
      TextSpan(children: spans),
      style: spec.bodyStyle,
      softWrap: false,
      maxLines: 1,
      overflow: TextOverflow.clip,
    );
  }
}

/// 背景层：纯色已由外层 `DecoratedBox` 铺底，这里只叠纹理图。
class _BackgroundLayer extends StatelessWidget {
  const _BackgroundLayer({required this.spec});

  final ReaderPageRenderSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = spec.theme;
    Widget? image;
    if (theme.backgroundKind == ReaderBackgroundKind.asset &&
        theme.backgroundAsset != null) {
      image = Image.asset(
        theme.backgroundAsset!,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, error, stack) => const SizedBox.shrink(),
      );
    } else if (theme.backgroundKind == ReaderBackgroundKind.file &&
        theme.backgroundFile != null) {
      image = Image.file(
        File(theme.backgroundFile!),
        fit: BoxFit.cover,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, error, stack) => const SizedBox.shrink(),
      );
    }
    if (image == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: Opacity(
        opacity: theme.backgroundAlpha.clamp(0.0, 1.0),
        child: image,
      ),
    );
  }
}

class _TipRow extends StatelessWidget {
  const _TipRow({
    required this.layout,
    required this.style,
    required this.height,
  });

  final ReaderTipLayout layout;
  final TextStyle style;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (layout.isEmpty) return SizedBox(height: height);
    return SizedBox(
      height: height,
      child: Row(
        children: [
          Expanded(
            child: Text(
              layout.left,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Text(
              layout.middle,
              style: style,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Text(
              layout.right,
              style: style,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
