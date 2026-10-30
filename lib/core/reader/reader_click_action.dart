import 'dart:math' as math;
import 'dart:ui';

/// 阅读页九宫格动作。`legadoId` 对齐 legado `ClickActionConfigDialog` 的
/// 动作编号，便于与参考实现互相对照；持久化时存这个 id。
enum ReaderClickAction {
  none(-1, '无动作'),
  menu(0, '呼出菜单'),
  nextPage(1, '下一页'),
  prevPage(2, '上一页'),
  nextChapter(3, '下一章'),
  prevChapter(4, '上一章'),
  prevParagraph(5, '朗读上一段'),
  nextParagraph(6, '朗读下一段'),
  addBookmark(7, '添加书签'),
  editContent(8, '编辑正文'),
  toggleReplace(9, '替换净化'),
  directory(10, '目录'),
  searchContent(11, '全文搜索'),
  syncProgress(12, '同步进度'),
  toggleSpeech(13, '朗读暂停/继续');

  const ReaderClickAction(this.legadoId, this.label);

  final int legadoId;
  final String label;

  /// 本项目暂未实现的动作：编辑器里置灰，点击给一句提示而不是静默失败。
  bool get available => switch (this) {
        ReaderClickAction.editContent ||
        ReaderClickAction.toggleReplace ||
        ReaderClickAction.searchContent ||
        ReaderClickAction.syncProgress =>
          false,
        _ => true,
      };

  /// 未知 id 一律退化成 [none]，避免旧数据把整页点成「什么都不做」。
  static ReaderClickAction fromId(Object? id) {
    final value = id is num ? id.toInt() : int.tryParse('$id');
    if (value == null) return ReaderClickAction.none;
    for (final action in values) {
      if (action.legadoId == value) return action;
    }
    return ReaderClickAction.none;
  }
}

/// 默认映射与 legado 一致：左列上一页、中格呼菜单、右列下一页。
const List<ReaderClickAction> kDefaultClickActions = <ReaderClickAction>[
  ReaderClickAction.prevPage,
  ReaderClickAction.prevPage,
  ReaderClickAction.nextPage,
  ReaderClickAction.prevPage,
  ReaderClickAction.menu,
  ReaderClickAction.nextPage,
  ReaderClickAction.prevPage,
  ReaderClickAction.nextPage,
  ReaderClickAction.nextPage,
];

/// 九宫格槽位下标（行优先）：0 左上 … 8 右下。
const List<String> kClickZoneLabels = <String>[
  '左上', '上中', '右上', //
  '左中', '正中', '右中', //
  '左下', '下中', '右下', //
];

/// 点击分区几何。纯函数，便于单测与在编辑器里画预览。
class ClickZoneLayout {
  const ClickZoneLayout({
    this.topRatio = 0.33,
    this.bottomRatio = 0.33,
    this.edgeInset = 0,
  });

  /// 上区高度占比。
  final double topRatio;

  /// 下区高度占比。
  final double bottomRatio;

  /// 左右两侧内缩 px：内缩区里的点击归到中列，避免与系统返回手势冲突。
  final double edgeInset;

  static const double minBandRatio = 0.15;
  static const double maxBandRatio = 0.45;

  double get _top => topRatio.clamp(minBandRatio, maxBandRatio);
  double get _bottom => bottomRatio.clamp(minBandRatio, maxBandRatio);

  double _insetFor(Size size) =>
      edgeInset.clamp(0.0, math.max(0.0, size.width / 2 - 1));

  /// 点 → 槽位 0..8。越界坐标按边界收敛，不返回 -1。
  int indexFor(Offset position, Size size) {
    if (size.width <= 0 || size.height <= 0) return 4;
    final dx = position.dx.clamp(0.0, size.width);
    final dy = position.dy.clamp(0.0, size.height);
    final inset = _insetFor(size);
    final topEdge = size.height * _top;
    final bottomEdge = size.height * (1 - _bottom);
    final leftEdge = size.width * 0.33;
    final rightEdge = size.width * 0.66;

    final row = dy < topEdge
        ? 0
        : dy > bottomEdge
            ? 2
            : 1;
    final inInset = inset > 0 && (dx < inset || dx > size.width - inset);
    final col = inInset
        ? 1
        : dx < leftEdge
            ? 0
            : dx > rightEdge
                ? 2
                : 1;
    return row * 3 + col;
  }

  /// 九个格子的实际矩形，供编辑器预览与调试用。
  List<Rect> rects(Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return List<Rect>.filled(9, Rect.zero);
    final inset = _insetFor(size);
    final topEdge = h * _top;
    final bottomEdge = h * (1 - _bottom);
    final leftEdge = w * 0.33;
    final rightEdge = w * 0.66;

    double xLookup(int col, bool isStart) {
      if (col == 0) return isStart ? inset : leftEdge;
      if (col == 1) return isStart ? leftEdge : rightEdge;
      return isStart ? rightEdge : w - inset;
    }

    double yLookup(int row, bool isStart) {
      if (row == 0) return isStart ? 0 : topEdge;
      if (row == 1) return isStart ? topEdge : bottomEdge;
      return isStart ? bottomEdge : h;
    }

    return <Rect>[
      for (var row = 0; row < 3; row++)
        for (var col = 0; col < 3; col++)
          Rect.fromLTRB(
            xLookup(col, true),
            yLookup(row, true),
            math.max(xLookup(col, true), xLookup(col, false)),
            math.max(yLookup(row, true), yLookup(row, false)),
          ),
    ];
  }

  ClickZoneLayout copyWith({
    double? topRatio,
    double? bottomRatio,
    double? edgeInset,
  }) =>
      ClickZoneLayout(
        topRatio: topRatio ?? this.topRatio,
        bottomRatio: bottomRatio ?? this.bottomRatio,
        edgeInset: edgeInset ?? this.edgeInset,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'top_ratio': topRatio,
        'bottom_ratio': bottomRatio,
        'edge_inset': edgeInset,
      };

  factory ClickZoneLayout.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ClickZoneLayout();
    double num0(Object? v, double fallback) =>
        v is num ? v.toDouble() : fallback;
    return ClickZoneLayout(
      topRatio: num0(json['top_ratio'], 0.33).clamp(minBandRatio, maxBandRatio),
      bottomRatio:
          num0(json['bottom_ratio'], 0.33).clamp(minBandRatio, maxBandRatio),
      edgeInset: num0(json['edge_inset'], 0).clamp(0.0, 64.0),
    );
  }
}
