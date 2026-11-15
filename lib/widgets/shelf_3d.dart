/// 3D 立体书架：横滑轮播 + 透视位姿 + 惯性吸附。
///
/// - 每本书按「与视口中线的距离」倾斜/缩放/明暗（[poseFor]），中间一本正立突出；
/// - 松手吸附到最近档位（[ShelfSnapScrollPhysics]），不会停在两本之间；
/// - 封面来自网络或本地文件，取不到时退化为书脊文字（书名竖排）；
/// - 键盘 ← → 可翻书，回车打开。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'jelly/jelly_progress_bar.dart';
import 'motion/fx_curves.dart';
import 'motion/view_swap.dart';
import 'tv_scope.dart';
import 'ui/app_icons.dart';
import '../theme/app_metrics.dart';
import '../core/shelf/shelf_geometry.dart';

/// 扇位角度表（atlas card-fan-intro SCORE 表 [-18,11,-9,17,-4,5]，按
/// spread=20° 归一的系数，实际角度 = 表值 × [kShelfFanSpreadDeg] / 20）。
/// kit dartdoc 常量（atlas 出处）。
const List<double> kShelfFanAnglesDeg = <double>[-18, 11, -9, 17, -4, 5];

/// 扇形收窄：atlas spread 默认 20°，本场景 ×0.6 → 12°（PRD 降编）。
const double kShelfFanSpreadDeg = 12;

/// 弹入窗：780ms（atlas 卡片弹入单拍，曲线 GLIDE）。
const int kShelfFanPopMs = 780;

/// 归位段：460ms（atlas 收回单拍——从中央扇形位收拢到书架槽位）。
const int kShelfFanSettleMs = 460;

/// 依次弹入间隔：70ms（atlas 120+70i 的交错单位）。
const int kShelfFanStaggerMs = 70;

/// 弹入+归位单本总时长（ms）：编排公式用的固定段和。
const int kShelfFanBookMs = kShelfFanPopMs + kShelfFanSettleMs;

/// 书架条目（视图与业务解耦：书架页把阅读记录/本地书映射成它）。
class ShelfBook {
  const ShelfBook({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.coverUrl = '',
    this.coverFile,
    this.percent,
  });

  final String id;
  final String title;
  final String subtitle;

  /// 网络封面。
  final String coverUrl;

  /// 本地封面路径。
  final String? coverFile;

  /// 阅读进度 0..1（null = 不画进度条）。
  final double? percent;
}

/// 吸附物理：松手后落到最近的整档（带一点回弹）。
class ShelfSnapScrollPhysics extends ScrollPhysics {
  const ShelfSnapScrollPhysics({super.parent, this.itemExtent = 118});

  final double itemExtent;

  @override
  ShelfSnapScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      ShelfSnapScrollPhysics(
        parent: buildParent(ancestor),
        itemExtent: itemExtent,
      );

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    // 甩得快就至少前进一档（与 PageScrollPhysics 同语义），否则吸附最近档。
    final page = position.pixels / itemExtent;
    final velocityTolerance = toleranceFor(position).velocity;
    var targetPage = page;
    if (velocity < -velocityTolerance) {
      targetPage = page - 0.5;
    } else if (velocity > velocityTolerance) {
      targetPage = page + 0.5;
    }
    var target = snapTarget(targetPage * itemExtent, itemExtent);
    target = target.clamp(position.minScrollExtent, position.maxScrollExtent);

    if ((target - position.pixels).abs() < 0.5 && velocity.abs() < 1) {
      return null;
    }
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: toleranceFor(position),
    );
  }
}

/// 3D 书架视图。
class Shelf3DView extends StatefulWidget {
  const Shelf3DView({
    super.key,
    required this.books,
    required this.onOpen,
    this.metrics = const ShelfMetrics(),
    this.projection = const ShelfProjection(),
    this.onDelete,
  });

  final List<ShelfBook> books;
  final ValueChanged<ShelfBook> onOpen;
  final ValueChanged<ShelfBook>? onDelete;
  final ShelfMetrics metrics;
  final ShelfProjection projection;

  @override
  State<Shelf3DView> createState() => _Shelf3DViewState();
}

class _Shelf3DViewState extends State<Shelf3DView>
    with SingleTickerProviderStateMixin {
  final _controller = ScrollController();
  int _focused = 0;
  double _offset = 0;

  // ---- 进场扇入（FxShelfFanIn，effect-atlas card-fan-intro 降编 · E5）----

  /// 扇入时钟；null = 直出（reduceMotion / TV / 与视图切换互斥 / 已播完）。
  AnimationController? _intro;

  /// 本 State 生命周期内只判定一次（design §2：首次标记）。
  bool _introPlayed = false;

  /// 编排总时长与交错（ms），按书数在 [kShelfFanStaggerMs] 基础上压缩。
  double _introTotalMs = 0;
  double _introStaggerMs = kShelfFanStaggerMs.toDouble();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureIntro();
  }

  @override
  void didUpdateWidget(covariant Shelf3DView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 书架从空到有书（首建时 books 为空不判定），重试一次进场判定。
    if (oldWidget.books.isEmpty && widget.books.isNotEmpty) _ensureIntro();
  }

  /// 扇入进场：只在 3D 形态首次构建播一次；reduceMotion/TV 直出；与
  /// FxViewSwap 进行中互斥（切换逐行过渡不叠加扇入，design §2）。
  void _ensureIntro() {
    if (_introPlayed || widget.books.isEmpty) return;
    _introPlayed = true;
    if (AppMetrics.reduceMotionEnabled(context)) return;
    if (TvScope.isTvOf(context)) return;
    if (FxViewSwap.swapInProgress) return;
    final int n = widget.books.length;
    // 总时长 = clamp(0.9s + 130ms·n, ≤2.2s)（design §2；编排豁免 ≤2.4s）。
    _introTotalMs = (900 + 130 * n).clamp(900, 2200).toDouble();
    // 末本书弹入+归位要落进总时长：交错按需压缩（大书架）。
    final double budget = _introTotalMs - kShelfFanBookMs;
    _introStaggerMs = n <= 1
        ? 0.0
        : math.min(
            kShelfFanStaggerMs.toDouble(),
            math.max(1.0, budget / (n - 1)),
          );
    // 小书架下限：单本全程（弹入 780 + 归位 460）必须完整落进总时长，
    // 否则归位窗被截断、完成帧出现跳变（900+130n 在 n≤3 时不够）。
    final double needed = kShelfFanBookMs + _introStaggerMs * (n - 1);
    if (_introTotalMs < needed) _introTotalMs = needed;
    _intro = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _introTotalMs.round()),
    )..forward();
  }

  /// 书 i 的进场位姿（null = 不在进场中 / 本书已归位）。
  ///
  /// SCORE 时间轴直译：弹入窗 [i·stagger, i·stagger+780ms]（scale 0→1，
  /// 保持在中央扇形位与扇角）；归位窗尾段 460ms（扇角→0、位置→书架槽位）。
  _FanPose? _fanPoseFor(int index, double dxFromCenter) {
    final AnimationController? intro = _intro;
    if (intro == null || intro.status == AnimationStatus.completed) return null;
    final double elapsedMs = intro.value * _introTotalMs;
    final double start = index * _introStaggerMs;
    final double popT =
        ((elapsedMs - start) / kShelfFanPopMs).clamp(0.0, 1.0).toDouble();
    final double settleT =
        ((elapsedMs - start - kShelfFanPopMs) / kShelfFanSettleMs)
            .clamp(0.0, 1.0)
            .toDouble();
    return _FanPose(
      scale: lerpDouble(0.001, 1, Fx.glide.transform(popT))!,
      angleRad: _fanAngleRad(index) * (1 - Fx.glide.transform(settleT)),
      dx: -dxFromCenter * (1 - Fx.glide.transform(settleT)),
    );
  }

  /// 书 i 的扇位角（atlas 角度表循环取 × 收窄比例）。
  double _fanAngleRad(int index) {
    final double deg =
        kShelfFanAnglesDeg[index % kShelfFanAnglesDeg.length] *
        kShelfFanSpreadDeg /
        20;
    return deg * math.pi / 180;
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    _intro?.dispose();
    _intro = null;
    super.dispose();
  }

  // ---- 测试口（test/motion/shelf_fanin_test.dart）----

  @visibleForTesting
  bool get debugIntroPlayed => _introPlayed;

  /// 扇入时钟真的建过（区分「播过」与「被互斥/门控跳过」）。
  @visibleForTesting
  bool get debugIntroRan => _intro != null;

  @visibleForTesting
  bool get debugIntroActive =>
      _intro != null &&
      _intro!.status != AnimationStatus.completed &&
      _intro!.status != AnimationStatus.dismissed;

  @visibleForTesting
  Duration get debugIntroDuration =>
      Duration(milliseconds: _introTotalMs.round());

  @visibleForTesting
  bool debugFanPoseActive(int index) =>
      _fanPoseFor(index, 0) != null;

  void _onScroll() {
    final next = _controller.hasClients ? _controller.offset : 0.0;
    if ((next - _offset).abs() < 0.01) return;
    setState(() {
      _offset = next;
      _focused = (next / widget.metrics.pitch).round().clamp(
            0,
            math.max(0, widget.books.length - 1),
          );
    });
  }

  void _focus(int index) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target = (index * widget.metrics.pitch)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      _focus((_focused + 1).clamp(0, widget.books.length - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _focus((_focused - 1).clamp(0, widget.books.length - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_focused >= 0 && _focused < widget.books.length) {
        widget.onOpen(widget.books[_focused]);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.books.isEmpty) return const SizedBox.shrink();
    final AnimationController? intro = _intro;
    // null = 直出（reduceMotion / TV / 与切换互斥跳过 / 未判定）：零包装层，
    // 与既有渲染路径同构。
    if (intro == null) return _buildShelf(widget.metrics);
    // 进场中：扇入时钟逐帧驱动（itemBuilder 每拍重算 _FanPose）；完成拍
    // 时钟已停、pose 恒 null（等价稳态渲染）——壳保持不卸，避免完成帧
    // 子树重挂载（hover 状态 / 滚动位置 churn，质检修正）。
    return AnimatedBuilder(
      animation: intro,
      builder: (context, _) => _buildShelf(widget.metrics),
    );
  }

  Widget _buildShelf(ShelfMetrics metrics) {
    return Focus(
      onKeyEvent: _onKey,
      child: LayoutBuilder(builder: (context, constraints) {
        final viewport = constraints.maxWidth;
        final half = viewport / 2;
        // 左右留白：第一本/最后一本也能滚到正中。
        final pad = math.max(24.0, half - metrics.itemExtent / 2);
        return ListView.builder(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          physics: ShelfSnapScrollPhysics(itemExtent: metrics.pitch),
          padding: EdgeInsets.fromLTRB(pad, 18, pad, 18),
          itemCount: widget.books.length,
          itemBuilder: (context, index) {
            final book = widget.books[index];
            final center =
                pad + index * metrics.pitch - _offset + metrics.itemExtent / 2;
            final pose = poseFor(
              offset: center - half,
              halfViewport: half,
              projection: widget.projection,
            );
            final _FanPose? fan = _fanPoseFor(index, center - half);
            return _BookVolume(
              book: book,
              pose: pose,
              metrics: metrics,
              projection: widget.projection,
              index: index,
              focused: index == _focused,
              fan: fan,
              onTap: () => widget.onOpen(book),
              onDelete: widget.onDelete == null
                  ? null
                  : () => widget.onDelete!(book),
            );
          },
        );
      }),
    );
  }
}

/// 进场扇入的单书位姿：缩放（弹入）、扇角与向中央的位移（收拢归位）。
class _FanPose {
  const _FanPose({
    required this.scale,
    required this.angleRad,
    required this.dx,
  });

  /// 弹入缩放 0→1。
  final double scale;

  /// 扇位角（弧度，随归位段收拢到 0）。
  final double angleRad;

  /// 相对书架槽位的横向偏移（负值 = 拉向视口中央）。
  final double dx;
}

class _BookVolume extends StatefulWidget {
  const _BookVolume({
    required this.book,
    required this.pose,
    required this.metrics,
    required this.projection,
    required this.index,
    required this.focused,
    required this.onTap,
    this.fan,
    this.onDelete,
  });

  final ShelfBook book;
  final ShelfPose pose;
  final ShelfMetrics metrics;
  final ShelfProjection projection;
  final int index;
  final bool focused;

  /// 进场扇入位姿；null = 不在进场（既有渲染路径零改动）。
  final _FanPose? fan;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  /// 进场是否仍在进行（弹入中禁 hover/tap 响应，物理进场完成后接管）。
  bool get introActive => fan != null;

  @override
  State<_BookVolume> createState() => _BookVolumeState();
}

class _BookVolumeState extends State<_BookVolume> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = widget.metrics;
    final pose = widget.pose;
    final lift = pose.lift + waveLift(widget.index);
    final width = m.coverWidth + m.spineWidth;

    final matrix = Matrix4.identity()
      ..setEntry(3, 2, widget.projection.perspective)
      ..rotateY(pose.tiltY);

    final cover = _buildCover(theme);

    Widget content = Padding(
      padding: EdgeInsets.only(right: m.gap),
      child: MouseRegion(
        // 进场中旁路 hover（PRD R1：进场完成后物理接管）。
        onEnter: widget.introActive
            ? null
            : (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          // 进场中旁路 tap：扇入未完成的隐形书本不该被点开。
          onTap: widget.introActive ? null : widget.onTap,
          onLongPress: widget.introActive ? null : widget.onDelete,
          child: Transform(
            alignment: Alignment.center,
            transform: matrix,
            child: Opacity(
              opacity: lerpDouble(pose.opacity, 1.0, _hover ? 0.6 : 0)!,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                transform: Matrix4.translationValues(
                  0,
                  -lift - (_hover || widget.focused ? 8 : 0),
                  0,
                ),
                child: SizedBox(
                  width: width,
                  height: m.coverHeight + 22,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // 地面阴影
                      Positioned(
                        left: m.spineWidth,
                        right: 2,
                        bottom: 0,
                        child: Container(
                          height: 12,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.all(Radius.circular(AppSpacing.radiusSm)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black
                                    .withValues(alpha: 0.28 - pose.z * 0.12),
                                blurRadius: 10 + pose.z * 6,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // 书脊
                      Positioned(
                        left: 0,
                        top: 4,
                        bottom: 14,
                        child: Container(
                          width: m.spineWidth,
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.horizontal(
                                left: Radius.circular(3)),
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [
                                theme.colorScheme.primary
                                    .withValues(alpha: 0.85),
                                theme.colorScheme.primary
                                    .withValues(alpha: 0.55),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // 封面
                      Positioned(
                        left: m.spineWidth - 1,
                        top: 4,
                        bottom: 14,
                        right: 0,
                        child: ClipRRect(
                          borderRadius: const BorderRadius.horizontal(
                            right: Radius.circular(4),
                            left: Radius.circular(2),
                          ),
                          child: cover,
                        ),
                      ),
                      // 进度
                      if (widget.book.percent != null)
                        Positioned(
                          left: m.spineWidth,
                          right: 0,
                          bottom: 6,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: JellyProgressBar(value: widget.book.percent),
                          ),
                        ),
                      // 悬停删除
                      if (_hover && widget.onDelete != null)
                        Positioned(
                          right: -6,
                          top: -6,
                          child: Tooltip(
                            message: '移出书架',
                            child: InkWell(
                              onTap: widget.onDelete,
                              customBorder: const CircleBorder(),
                              child: CircleAvatar(
                                radius: 11,
                                backgroundColor:
                                    theme.colorScheme.surfaceContainerHighest,
                                child: Icon(AppIcons.close,
                                    size: 13,
                                    color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // 进场扇入（E5）：intro 在 hover/lift 与位姿矩阵之前（最外层组合）——
    // 弹入缩放 + 扇位角 + 拉向中央的位移；归位完成后 fan 为 null，渲染与
    // 既有路径逐像素一致。
    final _FanPose? fan = widget.fan;
    if (fan != null) {
      content = Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..translateByDouble(fan.dx, 0, 0, 1)
          ..rotateZ(fan.angleRad)
          ..scaleByDouble(fan.scale, fan.scale, fan.scale, 1),
        child: content,
      );
    }
    return content;
  }

  Widget _buildCover(ThemeData theme) {
    final book = widget.book;
    if (book.coverFile != null && book.coverFile!.isNotEmpty) {
      return Image.file(
        File(book.coverFile!),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _placeholder(theme),
      );
    }
    if (book.coverUrl.isNotEmpty) {
      return Image.network(
        book.coverUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _placeholder(theme),
      );
    }
    return _placeholder(theme);
  }

  Widget _placeholder(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.surfaceContainerHighest,
            theme.colorScheme.surfaceContainerHigh,
          ],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(AppSpacing.s6, AppSpacing.s6, AppSpacing.s6, AppSpacing.s6),
      child: Align(
        alignment: Alignment.topCenter,
        child: Text(
          widget.book.title,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(height: 1.25),
        ),
      ),
    );
  }

}
