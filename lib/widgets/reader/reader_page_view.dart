import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/reader/reader_annotations.dart';
import '../../core/reader/reader_page_metrics.dart';
import '../../core/reader/reader_paginator.dart';
import '../../core/reader/reader_speech_settings.dart';
import '../../core/reader/reader_theme.dart';
import '../../core/reader/reader_typography.dart';
import 'speech_span_layout.dart';

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
    this.speechBase,
    this.speechActive,
    this.speechStyle = SpeechHighlightStyle.highlight,
    this.speechColorArgb = kSpeechColorFollowTheme,
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

  /// 朗读底纹区间（章内坐标 `[start, end)`）：TTS 路径是当前句，音轨路径退化为段落。
  /// `null` 表示这一帧不画底纹（`listen.highlight` 关、或朗读未开始）。
  final (int, int)? speechBase;

  /// 当前**词**的实心区间；精度不足（音轨路径、句级引擎）时恒 `null`。
  final (int, int)? speechActive;

  /// 词的画法：底色 / 下划线 / 删除线 / 波浪线（dotted 近似）/ 描边。
  final SpeechHighlightStyle speechStyle;

  /// 高亮色 ARGB；[kSpeechColorFollowTheme] 表示跟随主题的日/夜两套黄。
  final int speechColorArgb;

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

  /// 一行：朗读区间或划线交集落到这一行时才切 `Text.rich`，否则走普通 `Text` 快路径。
  ///
  /// 切分与朗读高亮**共用** [lineSpansFor]（`speech_span_layout.dart`）：改造前划线
  /// 切 span、朗读整行铺 `ColoredBox`，两套切分各自为政，「词 ∩ 划线」的优先级
  /// 无处落地（`frontend/reader-paging-contract.md` §9.2）。
  ///
  /// 排版结构一个字都没动：仍然是 `SizedBox(height: line.height)` 里一个
  /// `softWrap:false + maxLines:1 + overflow:clip` 的 Text，span 只加装饰不改文本，
  /// 因此高亮不可能引起二次换行。
  Widget _lineWidget(ReaderPageLine line) {
    final base = spec.speechBase;
    final active = spec.speechActive;
    final needSpans = line.text.isNotEmpty &&
        lineNeedsSpans(
          lineCharStart: line.charStart,
          lineCharEnd: line.charEnd,
          markings: spec.markings,
          base: base,
          active: active,
        );
    if (!needSpans) {
      return Text(
        line.text,
        style: spec.bodyStyle,
        softWrap: false,
        maxLines: 1,
        overflow: TextOverflow.clip,
      );
    }
    final spans = lineSpansFor(
      lineText: line.text,
      lineCharStart: line.charStart,
      lineCharEnd: line.charEnd,
      markings: spec.markings,
      base: base,
      active: active,
      style: spec.speechStyle,
      colorArgb: spec.speechColorArgb,
      night: spec.night,
      // 段首缩进只参与测量、不占章内字符位（§9.1）：首行行内下标比绝对字符位
      // 多出缩进长度，不补回来高亮会整体左移。
      indentChars:
          line.firstOfParagraph ? spec.typography.paragraphIndent.length : 0,
      foregroundArgb: spec.night
          ? spec.theme.textColorNight
          : spec.theme.textColor,
    );
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
