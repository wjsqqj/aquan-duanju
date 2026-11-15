import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/aqua_api.dart';
import '../core/aqua_error.dart';
import '../core/download_service.dart';
import '../core/books/book_source_store.dart';
import '../core/error_log.dart';
import '../core/image_cache_store.dart';
import '../core/image_key.dart';
import '../core/tv/tv_metrics.dart';
import '../core/reader/reader_speech_controller.dart';
import '../core/sources/auto_source_manager.dart';
import '../models/models.dart';
import '../store/stores.dart';
import '../screens/detail_screen.dart';
import '../theme/app_color.dart';
import '../theme/app_metrics.dart';
import '../theme/app_tokens.dart';
import 'jelly/jelly_press.dart';
import 'loading.dart';
import 'motion/cell_entrance.dart';
import 'motion/fx_damp.dart';
import 'skeleton.dart';
import 'tv_scope.dart';
import 'ui/app_badge.dart';
import 'ui/app_icons.dart';
import 'ui/app_interactive.dart';
import 'ui/app_status_view.dart';
import 'ui/app_toast.dart';

/// 全局单例容器： stores / api 在这里下发（无第三方状态管理依赖）。

class AppScope extends InheritedNotifier<ChangeNotifier> {
  const AppScope({
    super.key,
    required super.notifier,
    required this.api,
    required this.settings,
    required this.history,
    required this.reading,
    required this.listening,
    required this.bookCache,
    required this.follows,
    required this.searches,
    required this.playSkip,
    required this.downloads,
    required this.detailSnapshots,
    required this.sources,
    required this.bookSources,
    required this.sourceHealth,
    required this.marketSites,
    required this.seeds,
    required this.discovery,
    required this.autoSource,
    required this.bookmarks,
    required this.markings,
    required this.replaceRules,
    required this.playbackHealth,
    required this.cast,
    required this.lives,
    required this.readerSettings,
    required this.speech,
    required super.child,
  });

  final AquaApi api;
  final SettingsStore settings;
  final HistoryStore history;
  final ReadingProgressStore reading;
  final ListenProgressStore listening;
  final BookChapterCache bookCache;
  final FollowStore follows;
  final SearchHistoryStore searches;
  final PlaySkipStore playSkip;
  final DownloadService downloads;

  /// 详情页快照缓存（秒开；可再生数据，不进备份）。
  final DetailSnapshotStore detailSnapshots;

  /// 第三方影视源（TVBox / CMS）：配置、健康、源市场索引站。
  final SourcesStore sources;
  final BookSourceStore bookSources;
  final SourceHealthStore sourceHealth;
  final MarketSitesStore marketSites;

  /// 源扫描种子清单（内置线路 / 聚合页 / 清单页 + 用户自定义）。
  final SeedStore seeds;

  /// 自动找源的验证记录与合并快照元信息。
  final SourceDiscoveryStore discovery;

  /// 自动找源调度器（发现 / 验证 / 同步配置 / 重建合并源）。
  final AutoSourceManager autoSource;

  /// 阅读书签。
  final BookmarkStore bookmarks;

  /// 阅读划线/批注。
  final MarkingStore markings;

  /// 正文替换规则（去广告/水印）。
  final ReplaceRuleStore replaceRules;

  /// 播放线路健康度（源|影片|集|线路）。
  final PlaybackHealthStore playbackHealth;

  /// 投屏设备记忆（最近使用 + 钉选）。
  final CastStore cast;

  /// 直播配置（TVBox lives）。
  final LivesStore lives;

  /// 小说阅读器设置（排版 / 点击区 / 动画 / 主题）。
  final ReaderSettingsStore readerSettings;

  /// 全局听书控制器：挂在根上，离开阅读页也能继续读。
  final ReaderSpeechController speech;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  /// 不依赖通知的读取（回调里用）。
  static AppScope read(BuildContext context) {
    final widget = context
        .getElementForInheritedWidgetOfExactType<AppScope>()
        ?.widget;
    if (widget is AppScope) return widget;
    return of(context);
  }
}

/// 一键重置匿名设备：设置页（我的 → 重置匿名设备）与错误面板的「立即重置」
/// 共用这一条恢复路径，文案口径一致。
///
/// 成功提示「已重置，重新拉取数据即可」，调用方据此自行重拉数据；失败按
/// [AquaException.friendlyText] 提示（其余统一「重置设备失败」），异常只进
/// [ErrorLog]。返回是否重置成功。
Future<bool> resetAnonymousDevice(
  BuildContext context,
  Future<void> Function() reset,
) async {
  try {
    await reset();
  } catch (e, stack) {
    ErrorLog.instance.record('重置设备', e, stack);
    if (context.mounted) {
      AppToast.show(
        context,
        e is AquaException ? e.friendlyText : '重置设备失败，请稍后再试',
      );
    }
    return false;
  }
  if (context.mounted) AppToast.show(context, '已重置，重新拉取数据即可');
  return true;
}

/// 统一的三态内容视图：加载骨架 / 错误重试 / 内容。
class LoadView extends StatelessWidget {
  const LoadView({
    super.key,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.child,
    this.empty = false,
    this.emptyText = '这里空空如也',
    this.skeleton = SkeletonLayout.grid,
    this.onResetDevice,
  });

  final bool loading;
  final Object? error;
  final VoidCallback? onRetry;
  final Widget child;
  final bool empty;
  final String emptyText;

  /// 加载态骨架形态：按页面内容结构选择（网格 / 列表 / 详情）。
  ///
  /// 仅为兼容既有调用点保留：页面级加载已统一成转圈（11-06 / D4），
  /// 传什么形态都渲染 `AppLoading`。
  final SkeletonLayout skeleton;

  /// 设备被限/被拒时提供「立即重置」：与「我的 → 重置匿名设备」同一逻辑，
  /// 不必绕道设置页（见 [resetAnonymousDevice]）。
  final VoidCallback? onResetDevice;

  @override
  Widget build(BuildContext context) {
    // 三态统一委托 `AppStatusView`：加载态只有 AppLoading 一种规格。
    if (loading) return const AppStatusView.loading();
    if (error != null) {
      return AppStatusView.error(
        error!,
        onRetry: onRetry,
        onResetDevice: onResetDevice,
      );
    }
    if (empty) {
      return AppStatusView.empty(title: emptyText, icon: AppIcons.empty);
    }
    return child;
  }
}

/// 错误态：翻译 AquaException，给「重试」。
class ErrorRetryView extends StatelessWidget {
  const ErrorRetryView({
    super.key,
    required this.error,
    required this.onRetry,
    this.onResetDevice,
  });

  final Object error;
  final VoidCallback? onRetry;

  /// 仅在设备被限/被拒时提供：弹窗内直接「立即重置」（复用
  /// [resetAnonymousDevice]，即「我的 → 重置匿名设备」的逻辑），不必绕道设置页。
  ///
  /// 限流类错误不该自动重试（会更快耗尽配额），但用户可以主动换一台设备。
  final VoidCallback? onResetDevice;

  @override
  Widget build(BuildContext context) {
    // 展示真实原因：吞成「出了点小问题」会让书源/网络问题无从排查。
    // 容器与按钮复用 `AppStatusView.error`，只有文案口径比它更详细。
    return AppStatusView.error(
      error,
      onRetry: onRetry,
      onResetDevice: onResetDevice,
      message: _diagnose(error),
    );
  }

  /// 非 `AquaException` 时尽量把原始原因带给用户（截断到 260 字，
  /// 避免整段 HTML 错误页把面板撑爆）。
  static String _diagnose(Object error) {
    if (error is AquaException) return error.friendlyText;
    final raw = error
        .toString()
        .replaceFirst(RegExp(r'^Exception: '), '')
        .trim();
    if (raw.isEmpty || raw == 'Exception') return '出了点小问题，请稍后再试';
    return raw.length > 260 ? '${raw.substring(0, 260)}…' : raw;
  }
}

/// 骨架屏（卡片网格的加载占位）。
///
/// 保留为 [SkeletonView] 的薄封装：旧调用点（含 `SkeletonGrid(columns: 1)`）
/// 不需要改，自动获得流光效果。
class SkeletonGrid extends StatelessWidget {
  const SkeletonGrid({super.key, this.columns = 2});

  final int columns;

  @override
  Widget build(BuildContext context) =>
      SkeletonView(layout: SkeletonLayout.grid, columns: columns);
}

/// 剧集卡片：封面（竖版）+ 标题 + 副行（集数/热度/状态）。
class SeriesCard extends StatefulWidget {
  const SeriesCard({
    super.key,
    required this.item,
    required this.onTap,
    this.subtitle,
    this.badge,
    this.tvFocus = false,
  });

  final SeriesSummary item;
  final VoidCallback onTap;
  final String? subtitle;
  final String? badge;

  /// 电视形态：聚焦时放大 + 主色描边。
  ///
  /// 遥控器没有悬停与触摸反馈，不靠焦点视觉用户根本不知道当前选中的是哪张。
  final bool tvFocus;

  @override
  State<SeriesCard> createState() => _SeriesCardState();
}

class _SeriesCardState extends State<SeriesCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppColors colors = tokens.colors;
    final AppMetrics m = tokens.metrics;
    final item = widget.item;
    final sub =
        widget.subtitle ??
        (item.episodeCount > 0 ? '共${item.episodeCount}集' : item.category);
    final badge = widget.badge;
    // 标签 chips：至多 3 个。
    // 这里**不加渐变遮罩**（design.md §4.6 白名单外的用法，且
    // `test/widgets/series_card_meta_test.dart` 断言封面上不能出现渐变）；
    // 可读性靠不透明的 AppBadge 底。
    final tags = item.tags
        .where((t) => t.trim().isNotEmpty)
        .take(3)
        .toList(growable: false);
    final radius = BorderRadius.circular(m.radiusMd);
    final card = InkWell(
      onTap: widget.onTap,
      borderRadius: radius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Hero 源端（E0 共享元素转场）：包在 ClipRRect 内侧、InkWell
                // 之内——飞行副本只含封面本体，徽标/角标不随飞（「一个元素
                // 旅行」）。reduceMotion 时不包 Hero：与详情端不配对即不飞，
                // 自然退化为普通页面转场（两端 radius 同为 radiusMd）。
                ClipRRect(
                  borderRadius: radius,
                  child: AppMetrics.reduceMotionEnabled(context)
                      ? CoverImage(url: item.coverUrl)
                      : Hero(
                          tag: fxHeroSeriesCoverTag(item.id),
                          child: CoverImage(url: item.coverUrl),
                        ),
                ),
                if (badge != null)
                  Positioned(
                    left: m.s6,
                    top: m.s6,
                    child: AppBadge(text: badge),
                  ),
                // 热度/播放量徽标：封面右上（名次/「广告」角标在左上，对角不重叠）。
                if (item.heat > 0 || item.playCount > 0)
                  Positioned(
                    right: m.s6,
                    top: m.s6,
                    child: _CoverStats(item: item),
                  ),
                if (tags.isNotEmpty)
                  Positioned(
                    left: m.s6,
                    right: m.s6,
                    bottom: m.s6,
                    child: Row(
                      spacing: m.s4,
                      children: [
                        for (final tag in tags)
                          Flexible(
                            child: AppBadge(
                              text: tag,
                              tone: AppBadgeTone.neutral,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.only(top: m.s6),
            child: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.title,
            ),
          ),
          Padding(
            padding: EdgeInsets.only(top: m.s2),
            child: Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.label.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
    // 桌面/手机：按压给一点果冻回弹（`JellyPress` 用 Listener，不与 InkWell
    // 抢手势；TV 有自己的聚焦缩放，不叠加，走下面那条分支）
    if (!widget.tvFocus) return JellyPress(child: card);
    final Duration focusDuration = AppMetrics.reduceMotionOf(context, m.micro);
    return Focus(
      // 只监听，不抢焦点：真正的焦点在 InkWell 上，hasFocus 会随子孙变化。
      canRequestFocus: false,
      onFocusChange: (focused) {
        if (focused == _focused) return;
        setState(() => _focused = focused);
      },
      child: AnimatedScale(
        scale: _focused ? kTvFocusScale : 1,
        duration: focusDuration,
        curve: m.microCurve,
        child: AnimatedContainer(
          duration: focusDuration,
          curve: m.microCurve,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(m.radiusMd + m.s2),
            border: _focused
                ? Border.all(color: colors.brand, width: m.focusRing)
                : null,
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: colors.brand.withValues(alpha: 0.35),
                      blurRadius: m.s16 + m.s2,
                    ),
                  ]
                : null,
          ),
          child: card,
        ),
      ),
    );
  }
}

/// 封面右上角的「热度 / 播放量」徽标。
///
/// 压在封面图上，所以底色必须**不透明**（`surface3`）且文字取 `textPrimary`：
/// 半透明黑底 + 白字在浅色主题下会把两种封面读成两种颜色。
class _CoverStats extends StatelessWidget {
  const _CoverStats({required this.item});

  final SeriesSummary item;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppColors colors = tokens.colors;
    final AppMetrics m = tokens.metrics;
    final TextStyle style = tokens.micro.copyWith(color: colors.textPrimary);
    return Container(
      padding: EdgeInsets.fromLTRB(m.s6, m.s2, m.s6, m.s2),
      decoration: BoxDecoration(
        color: colors.surface3,
        borderRadius: BorderRadius.circular(m.radiusPill),
        border: Border.all(color: colors.hairline, width: m.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: m.s6,
        children: [
          if (item.heat > 0)
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: m.s2,
              children: [
                Icon(
                  Icons.local_fire_department,
                  size: m.s12,
                  color: colors.textPrimary,
                ),
                Text(formatCount(item.heat), style: style),
              ],
            ),
          if (item.playCount > 0)
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: m.s2,
              children: [
                // 测试钉死：series_card_meta_test 断言 Icons.play_arrow 本体，
                // 不要换成 AppIcons.play（play_arrow_rounded）。
                Icon(Icons.play_arrow, size: m.s12, color: colors.textPrimary),
                Text(formatCount(item.playCount), style: style),
              ],
            ),
        ],
      ),
    );
  }
}

/// 封面图：三级缓存（内存 LRU → 磁盘 → 核心转码）+ 占位 + 失效兜底。
///
/// 服务端返回的封面 URL 签名固定了 .heic 模板（改扩展名即失效），而
/// Flutter 引擎不解码 HEIC，所以字节经 Go 核心 fetchImage 转成 JPEG 再
/// 解码；磁盘缓存里存的是转码后的字节，key 为原始 URL。封面 URL 有签名
/// 过期时间（x-expires），过期 403 时维持裂图占位兜底。
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.onFetchError,
  });

  final String url;
  final BoxFit fit;

  /// 诊断钩子：封面加载失败时回调。
  ///
  /// 调用方记录 seriesId/标题等诊断信息，**不要记录完整 URL**（带签名参数）。
  final VoidCallback? onFetchError;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    if (url.isEmpty) {
      return _placeholder(tokens, AppIcons.coverPlaceholder);
    }
    final api = AppScope.read(context).api;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final fadeIn = AppMetrics.reduceMotionOf(context, tokens.metrics.hover);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 按展示宽度降采样；约束无界时退回原尺寸（不猜一个上限）。
        final targetWidth =
            constraints.hasBoundedWidth &&
                constraints.maxWidth.isFinite &&
                constraints.maxWidth > 0
            ? (constraints.maxWidth * dpr).round()
            : null;
        return Image(
          image: AquaImageProvider(url, api, targetWidth: targetWidth),
          fit: fit,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) return child;
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: fadeIn,
              child: child,
            );
          },
          errorBuilder: (_, _, _) {
            onFetchError?.call();
            return _placeholder(tokens, AppIcons.coverBroken);
          },
        );
      },
    );
  }

  /// 占位 / 裂图：`surface2` 底 + 三级文字色图标（深浅两套都成立）。
  static Widget _placeholder(AppTokens tokens, IconData icon) => ColoredBox(
    color: tokens.colors.surface2,
    child: Icon(icon, color: tokens.colors.textTertiary),
  );
}

/// 通过 Go 核心转码加载封面（HEIC→JPEG）的 ImageProvider。
/// key 只取 url：同一封面在多个组件里共享一份缓存与解码结果。
class AquaImageProvider extends ImageProvider<AquaImageProvider> {
  const AquaImageProvider(
    this.url,
    this.api, {
    this.targetWidth,
    this.targetHeight,
  });

  final String url;
  final AquaImageFetcher api;

  /// 解码目标尺寸（物理像素）。按展示尺寸降采样，避免 104×140 的小卡片
  /// 去解码 1000px 原图——列表里几十张封面时这是主要的内存与 CPU 开销。
  final int? targetWidth;
  final int? targetHeight;

  @override
  Future<AquaImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<AquaImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    AquaImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1.0,
      informationCollector: () sync* {
        yield StringProperty('AquaImageProvider url', url);
      },
    );
  }

  Future<ui.Codec> _load(
    AquaImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await AquaImageCache.instance.load(key.url, key.api);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(
      buffer,
      getTargetSize: (intrinsicWidth, intrinsicHeight) =>
          key._targetSize(intrinsicWidth, intrinsicHeight),
    );
  }

  /// 计算解码尺寸：只缩小、不放大，保持宽高比。
  ///
  /// 新版 Flutter 的解码回调只提供 `getTargetSize`（没有 cacheWidth/cacheHeight），
  /// 返回 `const TargetImageSize()` 表示按原尺寸解码。
  ui.TargetImageSize _targetSize(int width, int height) {
    final tw = targetWidth;
    final th = targetHeight;
    if ((tw == null && th == null) || width <= 0 || height <= 0) {
      return const ui.TargetImageSize();
    }
    var scale = 1.0;
    if (tw != null && tw > 0 && tw < width) scale = tw / width;
    if (th != null && th > 0 && th < height) {
      final s = th / height;
      if (s < scale) scale = s;
    }
    if (scale >= 1) return const ui.TargetImageSize();
    return ui.TargetImageSize(
      width: (width * scale).round().clamp(1, width),
      height: (height * scale).round().clamp(1, height),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AquaImageProvider &&
      other.url == url &&
      other.targetWidth == targetWidth &&
      other.targetHeight == targetHeight;

  @override
  int get hashCode => Object.hash(url, targetWidth, targetHeight);
}

/// 封面字节的三级缓存：内存 LRU → 磁盘（ImageCacheStore，LRU+上限）→ 核心转码。
/// 磁盘与内存里存的都是转码后可直接解码的字节；相同 URL 的并发请求合并。
///
/// 命中过期项时**立即返回旧字节**，后台刷新走独立低优先级队列：不进
/// [_acquire] 的 6/TV 3 下载闸门，且最多 1 个在跑（其余排队）。
class AquaImageCache {
  AquaImageCache({this.fetchOverride, this.staleChecker, this.onStaleRefresh});

  /// 测试注入点：不给就调 [AquaApi.fetchImage]。
  final Future<AquaImage> Function(String url)? fetchOverride;

  /// 测试注入点：判断某 key 是否需要后台刷新；不给就查磁盘索引的 TTL。
  final Future<bool> Function(String key)? staleChecker;

  /// 过期后台刷新钩子（诊断 / 测试观察用）：真正发起刷新时回调该 url。
  /// 回调在独立任务里触发，不参与 [load] 的返回值。
  final void Function(String url)? onStaleRefresh;

  static AquaImageCache instance = AquaImageCache();

  /// 电视档位：低端盒子常见 1GB 内存 + 弱 CPU，缓存与并发都收紧。
  /// 启动时由 `main.dart` 按运行形态设置，之后不再变。
  bool tvProfile = false;

  /// 内存层双阈值：条数 + 字节。只有条数上限时，512 条大图仍可能吃掉几百 MB。
  int get _maxEntries => tvProfile ? 256 : 512;
  int get _maxBytes => tvProfile ? 48 << 20 : 96 << 20;

  /// 并发下载上限：网格首屏会一次要十几张，全放出去会互相抢带宽，首图更慢。
  ///
  /// 移动端 8：每张封面都是一次 isolate + HTTP + HEIC 转码，6 条并发下 20 张要
  /// 4 轮串行，提到 8 可压到 3 轮；缩略图内存增量可忽略。TV 仍为 3（低端盒子）。
  int get _maxConcurrent => tvProfile ? 3 : 8;

  final Map<String, Uint8List> _memory = {};
  int _memoryBytes = 0;
  final Map<String, Future<Uint8List>> _inFlight = {};

  int _active = 0;
  final List<Completer<void>> _waiters = [];

  // 独立低优先级刷新通道：不占下载闸门，最多 1 个并发，其余 FIFO 排队。
  static const int _maxRefreshInFlight = 1;
  int _refreshInFlight = 0;
  final List<_StaleRefreshTask> _refreshQueue = [];
  final Set<String> _refreshQueued = <String>{};

  /// 载入图片字节。[url] 可带签名：缓存 key 会先规范化（见 `image_key.dart`），
  /// 否则签名一变就整盘 miss，每次都要重新下载 + HEIC 转码。
  Future<Uint8List> load(String url, AquaImageFetcher api) {
    final key = stableImageKey(url);
    return _inFlight.putIfAbsent(key, () => _load(key, url, api));
  }

  Future<Uint8List> _load(String key, String url, AquaImageFetcher api) async {
    try {
      final hit = await cached(key);
      if (hit != null) {
        // 命中即返回；过期检查与刷新都在独立低优先级任务里，不 await。
        _maybeRefreshStale(key, url, api);
        return hit;
      }
      await _acquire();
      try {
        final image = await (fetchOverride ?? api.fetchImage)(url);
        _memoryPut(key, image.bytes);
        try {
          // 存的是转码后的字节；下次直接命中磁盘，不再进核心。
          await ImageCacheStore.instance.put(key, image.bytes);
        } catch (_) {
          // 磁盘缓存失败不影响显示（测试环境没有 path_provider）。
        }
        return image.bytes;
      } finally {
        _release();
      }
    } finally {
      _inFlight.remove(key);
    }
  }

  /// 命中后异步判断过期并排队刷新；任何失败都静默，旧图始终可用。
  void _maybeRefreshStale(String key, String url, AquaImageFetcher api) {
    unawaited(_checkAndQueue(key, url, api));
  }

  Future<void> _checkAndQueue(
    String key,
    String url,
    AquaImageFetcher api,
  ) async {
    bool stale;
    try {
      stale = staleChecker != null
          ? await staleChecker!(key)
          : await ImageCacheStore.instance.isExpired(key);
    } catch (_) {
      return; // 索引不可用：不擅自发起刷新。
    }
    if (!stale || !_refreshQueued.add(key)) return;
    _refreshQueue.add(_StaleRefreshTask(key, url, api));
    _pumpRefresh();
  }

  void _pumpRefresh() {
    if (_refreshInFlight >= _maxRefreshInFlight || _refreshQueue.isEmpty) {
      return;
    }
    final task = _refreshQueue.removeAt(0);
    _refreshInFlight++;
    unawaited(_runRefresh(task));
  }

  Future<void> _runRefresh(_StaleRefreshTask task) async {
    try {
      // 低优先级：先让出事件循环，确保当前可见项的 load 先占下载闸门。
      await Future<void>.delayed(Duration.zero);
      onStaleRefresh?.call(task.url);
      final image = await (fetchOverride ?? task.api.fetchImage)(task.url);
      _memoryPut(task.key, image.bytes);
      try {
        // put 会刷新 fetchedAt，下次命中不再判过期。
        await ImageCacheStore.instance.put(task.key, image.bytes);
      } catch (_) {}
    } catch (_) {
      // 刷新失败静默：旧图仍在，下次命中再试。
    } finally {
      _refreshInFlight--;
      _refreshQueued.remove(task.key);
      _pumpRefresh();
    }
  }

  Future<void> _acquire() async {
    if (_active < _maxConcurrent) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
    _active++;
  }

  void _release() {
    if (_active > 0) _active--;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }

  /// 只查缓存（内存 + 磁盘），不发网络。[key] 会被规范化，幂等。
  Future<Uint8List?> cached(String key) async {
    final normalized = stableImageKey(key);
    final mem = _memoryGet(normalized);
    if (mem != null) return mem;
    try {
      final bytes = await ImageCacheStore.instance.get(normalized);
      if (bytes != null) {
        _memoryPut(normalized, bytes);
        return bytes;
      }
    } catch (_) {
      // 磁盘缓存不可用时退化为纯内存缓存。
    }
    return null;
  }

  Uint8List? _memoryGet(String key) {
    final bytes = _memory.remove(key);
    if (bytes != null) _memory[key] = bytes;
    return bytes;
  }

  void _memoryPut(String key, Uint8List bytes) {
    final old = _memory.remove(key);
    if (old != null) _memoryBytes -= old.length;
    _memory[key] = bytes;
    _memoryBytes += bytes.length;
    while (_memory.length > _maxEntries ||
        (_memoryBytes > _maxBytes && _memory.length > 1)) {
      final oldest = _memory.keys.first;
      final dropped = _memory.remove(oldest);
      if (dropped != null) _memoryBytes -= dropped.length;
    }
  }
}

class _StaleRefreshTask {
  const _StaleRefreshTask(this.key, this.url, this.api);

  final String key;
  final String url;
  final AquaImageFetcher api;
}

/// 封面预取：列表首屏的封面在滚动到之前先拉一次。
///
/// 只预热前 [limit] 张，且走 [AquaImageCache] 的并发闸门；失败静默（真正可见
/// 时 CoverImage 会再请求一次）。预取命中时 `load` 直接返回内存/磁盘字节，
/// 不再占用下载名额。
///
/// 调度按可见性分两级：可见窗口 + 相邻 [neighborCount] 项立即提交，其余进
/// 低优先级队列，且**滚动期间暂停提交**——低优先级预取不会把并发闸门占满，
/// 当前可见的 CoverImage 始终能先拿到名额。可见起点可由 [firstVisibleIndex]
/// 直接给出；缺省时按 SeriesGrid 网格布局从 ScrollNotification 的偏移近似估算
/// （既有调用点无需改动，全部新增参数都有默认值）。
class CoverPrefetch extends StatefulWidget {
  const CoverPrefetch({
    super.key,
    required this.urls,
    required this.child,
    this.limit = 12,
    this.firstVisibleIndex = 0,
    this.visibleCount = 8,
    this.neighborCount = 6,
  });

  final List<String> urls;
  final Widget child;
  final int limit;

  /// 当前首个可见项下标（外部已知时优先用，跳过偏移估算）。
  final int firstVisibleIndex;

  /// 一屏可见项数（用于圈定高优先级窗口）。
  final int visibleCount;

  /// 可见窗口前后各额外预取的项数。
  final int neighborCount;

  @override
  State<CoverPrefetch> createState() => _CoverPrefetchState();
}

class _CoverPrefetchState extends State<CoverPrefetch> {
  String _warmed = '';
  int _generation = 0;
  int _firstVisible = 0;
  bool _scrolling = false;
  final Set<String> _scheduled = <String>{};
  final List<String> _lowQueue = <String>[];
  Timer? _scrollIdle;
  Timer? _pumpTimer;

  @override
  void dispose() {
    _scrollIdle?.cancel();
    _pumpTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final urls = widget.urls
        .take(widget.limit)
        .where((u) => u.isNotEmpty)
        .toList(growable: false);
    final signature = <String>[
      urls.join('|'),
      '${widget.firstVisibleIndex}',
      '${widget.visibleCount}',
      '${widget.neighborCount}',
    ].join('#');
    if (signature != _warmed) {
      _warmed = signature;
      _generation++;
      _scheduled.clear();
      _lowQueue.clear();
      _firstVisible = widget.firstVisibleIndex;
      if (urls.isNotEmpty) {
        final snapshot = List<String>.of(urls);
        final gen = _generation;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _schedule(snapshot, gen),
        );
      }
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: widget.child,
    );
  }

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification) {
      _scrolling = true;
      _scrollIdle?.cancel();
      _scrollIdle = Timer(const Duration(milliseconds: 120), _onScrollIdle);
      final next = _estimateFirstVisible(n.metrics.pixels);
      if (next != _firstVisible) {
        _firstVisible = next;
        _promoteVisible();
      }
    } else if (n is ScrollEndNotification) {
      _onScrollIdle();
    }
    return false; // 不吞通知，GridView 自己还要用。
  }

  void _onScrollIdle() {
    _scrollIdle?.cancel();
    _scrollIdle = null;
    _scrolling = false;
    _pumpLow(_generation);
  }

  /// 按 SeriesGrid 的 SliverGridDelegateWithFixedCrossAxisCount 反推首个可见行。
  /// 只用于排优先级，近似即可；外部给了 [CoverPrefetch.firstVisibleIndex] 时
  /// 直接采用精确值。
  int _estimateFirstVisible(double pixels) {
    if (widget.firstVisibleIndex != 0) return widget.firstVisibleIndex;
    if (pixels <= 0) return 0;
    final cols = seriesGridColumns(context, null);
    final width = MediaQuery.sizeOf(context).width;
    // 与 SeriesGrid / SliverSeriesGrid 共用同一组布局常量，改网格时不必两处同步。
    final itemWidth =
        (width - _gridPadding.horizontal - (cols - 1) * _gridCrossSpacing) /
        cols;
    if (itemWidth <= 0) return 0;
    final rowHeight = itemWidth / _gridChildAspectRatio + _gridMainSpacing;
    final row = (pixels / rowHeight).floor();
    return (row * cols).clamp(0, widget.urls.length);
  }

  void _schedule(List<String> urls, int gen) {
    if (!mounted || gen != _generation) return;
    final from = (_firstVisible - widget.neighborCount).clamp(0, urls.length);
    final to = (_firstVisible + widget.visibleCount + widget.neighborCount)
        .clamp(0, urls.length);
    // 高优先级：可见 + 相邻，按到可见起点的距离排序后先提交。
    final high = <int>[for (var i = from; i < to; i++) i]
      ..sort(
        (a, b) =>
            (a - _firstVisible).abs().compareTo((b - _firstVisible).abs()),
      );
    for (final i in high) {
      if (_scheduled.add(urls[i])) _submit(urls[i]);
    }
    // 其余按顺序进低优先级队列，滚动时暂停提交。
    for (var i = 0; i < urls.length; i++) {
      if (i >= from && i < to) continue;
      final url = urls[i];
      if (_scheduled.add(url)) _lowQueue.add(url);
    }
    _pumpLow(gen);
  }

  /// 可见窗口变化：把新窗口内的项立即提交，插到低优先级队列前面。
  void _promoteVisible() {
    if (!mounted) return;
    final urls = widget.urls
        .take(widget.limit)
        .where((u) => u.isNotEmpty)
        .toList(growable: false);
    final from = (_firstVisible - widget.neighborCount).clamp(0, urls.length);
    final to = (_firstVisible + widget.visibleCount + widget.neighborCount)
        .clamp(0, urls.length);
    for (var i = from; i < to; i++) {
      final url = urls[i];
      if (_scheduled.add(url)) {
        _lowQueue.remove(url);
        _submit(url);
      }
    }
  }

  void _pumpLow(int gen) {
    _pumpTimer?.cancel();
    if (!mounted || gen != _generation || _scrolling || _lowQueue.isEmpty) {
      return;
    }
    // 低优先级节流：每 60ms 只放一个，避免瞬时占满并发闸门。
    _pumpTimer = Timer(const Duration(milliseconds: 60), () {
      if (!mounted || gen != _generation) return;
      if (!_scrolling && _lowQueue.isNotEmpty) {
        _submit(_lowQueue.removeAt(0));
      }
      _pumpLow(gen);
    });
  }

  void _submit(String url) {
    if (!mounted) return;
    final api = AppScope.read(context).api;
    unawaited(
      AquaImageCache.instance
          .load(url, api)
          .then((_) {}, onError: (Object _) {}),
    );
  }
}

/// 网格列数：与 [SeriesGrid]、[SliverSeriesGrid] 共用同一套断点。
///
/// 电视形态下走 [tvColumnsFor]（少一档、封面更大），其余形态沿用原断点。
int seriesGridColumns(BuildContext context, int? columns) {
  if (columns != null) return columns;
  final width = MediaQuery.sizeOf(context).width;
  if (TvScope.isTvOf(context)) return tvColumnsFor(width);
  return width >= 1100
      ? 6
      : width >= 800
      ? 4
      : width >= 560
      ? 3
      : 2;
}

// -----------------------------------------------------------------------------
// 网格布局常量：`SeriesGrid` / `SliverSeriesGrid` / `CoverPrefetch` 的估算共用
// 同一组值，避免「改了一处、预取算在另一处」。
// -----------------------------------------------------------------------------

/// 卡片高宽比：0.62（封面竖版 + 两行文字）。
const double _gridChildAspectRatio = 0.62;

/// 行间距。
const double _gridMainSpacing = 14;

/// 列间距。
const double _gridCrossSpacing = 12;

/// 网格默认内边距（与 `SliverSeriesGrid.padding` 的默认值一致）。
const EdgeInsets _gridPadding = EdgeInsets.fromLTRB(12, 8, 12, 24);

/// 网格条目按 id first-wins 保序去重（E0 质检遗留防护）：服务端把同一部剧
/// 回进两页时，同路由出现两个同 id 的 SeriesCard 会撞 Hero tag（debug 断言
/// 崩，见 fx-motion-contract 的「重复 tag」条）。childCount / 加载更多 / 点击
/// 全部用去重后的列表。
List<SeriesSummary> _dedupeSeriesById(List<SeriesSummary> items) {
  final List<SeriesSummary> deduped = <SeriesSummary>[];
  final Set<String> seen = <String>{};
  for (final SeriesSummary item in items) {
    if (seen.add(item.id)) deduped.add(item);
  }
  return deduped;
}

/// 剧集网格的 sliver 版本：与 [SeriesGrid] 共用列数规则与卡片，但把网格拼进
/// 外层 [CustomScrollView]，让页面只有一个滚动视口。
///
/// 为什么需要它：用 `SliverFillRemaining(hasScrollBody: true)` 包 `SeriesGrid`
/// 会得到**第二个独立滚动源**——滚动网格时外层 scroll offset 不变，任何依赖
/// 外层 offset 的效果（如发现页历史条自动收起/回顶展开）都会失效。
///
/// 入场（E1）：首屏条目（index < cols×3）按 index 交错播 [FxCellEntrance]
/// smear 入场，每 id 只播一次（`_entered` 集合——滚动往返/重建不重播）；
/// 触底加载的新条目即时入场；TV 不启用（焦点导航要求立即可见）；
/// reduceMotion 在组件内部直跳终态。
class SliverSeriesGrid extends StatefulWidget {
  const SliverSeriesGrid({
    super.key,
    required this.items,
    required this.onTap,
    this.hasMore = false,
    this.onLoadMore,
    this.columns,
    this.badgeOf,
    this.padding = _gridPadding,
  });

  final List<SeriesSummary> items;
  final void Function(SeriesSummary item) onTap;
  final bool hasMore;
  final VoidCallback? onLoadMore;
  final int? columns;
  final String? Function(SeriesSummary item)? badgeOf;
  final EdgeInsets padding;

  @override
  State<SliverSeriesGrid> createState() => _SliverSeriesGridState();
}

class _SliverSeriesGridState extends State<SliverSeriesGrid> {
  /// 已播过入场动画的条目 id（每 id 只播一次）。
  final Set<String> _entered = <String>{};

  @override
  Widget build(BuildContext context) {
    final cols = seriesGridColumns(context, widget.columns);
    final tv = TvScope.isTvOf(context);
    final List<SeriesSummary> items = _dedupeSeriesById(widget.items);
    final int childCount = items.length + (widget.hasMore ? cols : 0);
    return SliverPadding(
      padding: widget.padding,
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          childAspectRatio: _gridChildAspectRatio,
          mainAxisSpacing: _gridMainSpacing,
          crossAxisSpacing: _gridCrossSpacing,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          if (index >= items.length) {
            // 触底加载更多：与原 GridView 版本一致，构建到最后一项时触发。
            if (widget.hasMore && widget.onLoadMore != null) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => widget.onLoadMore!(),
              );
            }
            // 电视上这个转圈不能占焦点：否则方向键会停在「加载更多」上。
            return const ExcludeFocus(
              child: Center(child: AppLoading.inline()),
            );
          }
          final item = items[index];
          final bool fresh = _entered.add(item.id);
          Widget cell = SeriesCard(
            item: item,
            onTap: () => widget.onTap(item),
            badge: widget.badgeOf?.call(item),
            tvFocus: tv,
          );
          if (!tv) {
            cell = FxCellEntrance(
              key: ValueKey(item.id),
              play: fresh,
              // 首屏（一屏 ≈ 3 行）才交错，触底新条目即时入场。
              delay: fresh && index < cols * 3
                  ? fxCellStaggerDelay(index)
                  : Duration.zero,
              child: cell,
            );
          }
          return FocusTraversalOrder(
            // 显式序号：网格的行列顺序必须与视觉一致，不能依赖构建顺序。
            order: NumericFocusOrder(index.toDouble()),
            child: cell,
          );
        }, childCount: childCount),
      ),
    );
  }
}

/// 双列剧集瀑布网格（自带滚动控制器与加载更多回调）。
/// 「加载更多」失败时的底部重试块。
///
/// 为什么不自动重试：触底加载是由占位项重建时的 post-frame 触发的，
/// 失败后若继续自动触发，就会形成 失败 → setState → 重建 → 触底 → 再失败
/// 的无限请求（旧版搜索页就是这样一边转圈一边打接口）。
class LoadMoreRetryTile extends StatelessWidget {
  const LoadMoreRetryTile({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppTokens tokens = context.app;
    final AppMetrics m = tokens.metrics;
    return Padding(
      padding: EdgeInsets.all(m.s12),
      child: AppInteractive(
        onTap: onTap,
        radius: BorderRadius.circular(m.radiusSm),
        padding: EdgeInsets.fromLTRB(m.s12, m.s8, m.s12, m.s8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: m.s6,
          children: [
            Icon(
              AppIcons.refresh,
              size: m.s16 + m.s2,
              color: tokens.colors.brand,
            ),
            Text(
              '加载失败，点按重试',
              style: tokens.caption.copyWith(color: tokens.colors.brand),
            ),
          ],
        ),
      ),
    );
  }
}

/// 双列剧集瀑布网格（自带滚动控制器与加载更多回调）。
/// 「加载更多」失败时的底部重试块。
///
/// 为什么不自动重试：触底加载是由占位项重建时的 post-frame 触发的，
/// 失败后若继续自动触发，就会形成 失败 → setState → 重建 → 触底 → 再失败
/// 的无限请求（旧版搜索页就是这样一边转圈一边打接口）。
///
/// 入场/去重契约与 [SliverSeriesGrid] 相同（[FxCellEntrance] 每 id 一次、
/// 按 id first-wins 去重防 Hero 撞 tag）。
class SeriesGrid extends StatefulWidget {
  const SeriesGrid({
    super.key,
    required this.items,
    required this.onTap,
    this.hasMore = false,
    this.onLoadMore,
    this.header,
    this.columns,
    this.badgeOf,
    this.controller,
    this.loadMoreFailed = false,
    this.onRetryLoadMore,
  });

  final List<SeriesSummary> items;
  final void Function(SeriesSummary item) onTap;
  final bool hasMore;
  final VoidCallback? onLoadMore;
  final Widget? header;
  final int? columns;

  /// 上一次"加载更多"失败了：底部改成可点按的重试块，并且**不再自动触发**
  /// 加载（否则 失败 → setState → 重建 → 触底 → 再失败 会形成无休止请求）。
  final bool loadMoreFailed;

  /// 重试块被点按时回调。[loadMoreFailed] 为 true 时才用得到。
  final VoidCallback? onRetryLoadMore;

  /// 外部滚动控制器（页面要放「回到顶部」时必须传）；不给则由 GridView 自建。
  final ScrollController? controller;

  /// 每张卡片左上角的角标（如榜单名次）；不给则与原来一致，不显示角标。
  final String? Function(SeriesSummary item)? badgeOf;

  @override
  State<SeriesGrid> createState() => _SeriesGridState();
}

class _SeriesGridState extends State<SeriesGrid> {
  /// 已播过入场动画的条目 id（每 id 只播一次）。
  final Set<String> _entered = <String>{};

  @override
  Widget build(BuildContext context) {
    final cols = seriesGridColumns(context, widget.columns);
    final tv = TvScope.isTvOf(context);
    final List<SeriesSummary> items = _dedupeSeriesById(widget.items);
    final int childCount =
        items.length +
        (widget.hasMore ? cols : 0) +
        (widget.header != null ? 1 : 0);
    return CoverPrefetch(
      urls: [for (final item in items) item.coverUrl],
      // 覆盖一整页（默认 20 条）：少一点"滚到才现抓"的等待。
      limit: TvScope.isTvOf(context) ? 12 : 24,
      child: GridView.builder(
        controller: widget.controller,
        padding: _gridPadding,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          childAspectRatio: _gridChildAspectRatio,
          mainAxisSpacing: _gridMainSpacing,
          crossAxisSpacing: _gridCrossSpacing,
        ),
        itemCount: childCount,
        itemBuilder: (context, index) {
          if (widget.header != null && index == 0) return widget.header!;
          final i = index - (widget.header != null ? 1 : 0);
          if (i >= items.length) {
            // 触底加载更多；失败态下不挂触发器，改由用户点按重试。
            if (widget.hasMore &&
                !widget.loadMoreFailed &&
                widget.onLoadMore != null) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => widget.onLoadMore!(),
              );
            }
            // 电视上转圈/重试块都不占焦点。
            return ExcludeFocus(
              child: Center(
                child: widget.loadMoreFailed
                    ? LoadMoreRetryTile(onTap: widget.onRetryLoadMore)
                    : AppLoading.inline(),
              ),
            );
          }
          final item = items[i];
          final bool fresh = _entered.add(item.id);
          Widget cell = SeriesCard(
            item: item,
            onTap: () => widget.onTap(item),
            badge: widget.badgeOf?.call(item),
            tvFocus: tv,
          );
          if (!tv) {
            cell = FxCellEntrance(
              key: ValueKey(item.id),
              play: fresh,
              delay: fresh && i < cols * 3
                  ? fxCellStaggerDelay(i)
                  : Duration.zero,
              child: cell,
            );
          }
          return FocusTraversalOrder(
            order: NumericFocusOrder(i.toDouble()),
            child: cell,
          );
        },
      ),
    );
  }
}

/// 把热度/播放数格式化成「4102万热度」。
String formatCount(int n) {
  if (n >= 100000000) {
    final v = n / 100000000;
    return '${_trim(v)}亿';
  }
  if (n >= 10000) {
    final v = n / 10000;
    return '${_trim(v)}万';
  }
  return '$n';
}

String _trim(double v) {
  if (v >= 100) return v.toStringAsFixed(0);
  if (v >= 10) return v.toStringAsFixed(1);
  return v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1);
}

/// 数字转中文序数（1→第1集，直接用数字即可）。
String episodeLabel(int n) => '第$n集';

/// 随机工具：洗牌（对 RangeError 免疫）。
void shuffleList<T>(List<T> list, {math.Random? rng}) => list.shuffle(rng);

/// 桌面端横向条：常显滚动条 + 鼠标按住拖动 + 垂直滚轮转横向滚动。
///
/// 旧实现用 `PrimaryScrollController` 注入 controller，但横向 `ListView` 在桌面
/// 平台不会继承它（`ScrollView` 只对纵向 / iOS-macOS 继承），于是
/// `controller.hasClients` 恒为 false：滚轮空转、也没有滚动条，表现为「不能左右
/// 移动」。这里改为组件自持 controller 并显式传给内部 `ListView`。
///
/// 手势约定（xiugou-tv `HorizontalScrollArea` 同款）：只把 `dy` 映射到横向，
/// `dx` 留给 Scrollable，避免双倍滚动；鼠标补进 dragDevices，桌面才能按住拖。
class HorizontalScrollStrip extends StatefulWidget {
  const HorizontalScrollStrip({
    super.key,
    required this.children,
    this.height = 52,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
  });

  /// 横向排列的条目（chip 等）。条目自带右侧间距。
  final List<Widget> children;
  final double height;
  final EdgeInsetsGeometry padding;

  @override
  State<HorizontalScrollStrip> createState() => _HorizontalScrollStripState();
}

class _HorizontalScrollStripState extends State<HorizontalScrollStrip>
    with SingleTickerProviderStateMixin {
  final ScrollController _controller = ScrollController();

  /// 滚轮目标的指数滑行器（E1）：滚轮不再 jumpTo 直跳，而是逐帧逼近目标。
  /// rate 8 是 atlas horizontal-wheel-strip 的 kit 级常量；epsilon 放宽到
  /// 0.5px（位移域，默认 0.01 是 squash 那种小值域用的，这里白追 499 帧）。
  late final FxDamper _wheelDamper = FxDamper(
    vsync: this,
    rate: 8,
    epsilon: 0.5,
    onUpdate: _onWheelGlideTick,
  );

  @override
  void dispose() {
    _wheelDamper.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 滑行推进：把阻尼值落到滚动位置（jumpTo 是位置指令，滑行感来自 damper
  /// 的指数逼近）。落点再夹一次实际 extent，防 children 变化后越界。
  void _onWheelGlideTick(double value) {
    if (!_controller.hasClients) return;
    _controller.jumpTo(value.clamp(0.0, _controller.position.maxScrollExtent));
  }

  /// 用户拖拽 / 滚动条接管滚动时，把阻尼钉回当前 offset 并停表——防双源
  /// 打架（用户位移与滑行残留目标互相覆盖）。trackpad 双指滚动走
  /// PointerPanZoomStart，同样要停。
  void _alignDamperToOffset(PointerEvent? event) {
    if (!_controller.hasClients) return;
    _wheelDamper.jumpTo(_controller.offset);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final double delta = event.scrollDelta.dy;
    if (delta == 0 || !_controller.hasClients) return;
    // 连发滚轮以滑行目标为基累计（此刻 offset 还在逐帧逼近，直接取 offset
    // 会把快速连滚折损成一小步）。滑行中 target 即基；静止时取实际 offset
    // （对齐拖拽/滚动条接管后的真实位置）。
    final double base = _wheelDamper.isTicking
        ? _wheelDamper.target
        : _controller.offset;
    final double target = (base + delta).clamp(
      0.0,
      _controller.position.maxScrollExtent,
    );
    if (AppMetrics.reduceMotionEnabled(context)) {
      // reduceMotion：滑行退回 jumpTo（位移无动画语义）。
      _wheelDamper.jumpTo(target);
      _controller.jumpTo(target);
      return;
    }
    _wheelDamper.target = target;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          // 桌面鼠标默认不在 dragDevices 里，补上才能按住左右拖。
          dragDevices: const {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
            PointerDeviceKind.invertedStylus,
          },
        ),
        child: Listener(
          onPointerDown: _alignDamperToOffset,
          onPointerPanZoomStart: _alignDamperToOffset,
          onPointerSignal: _onPointerSignal,
          child: Scrollbar(
            controller: _controller,
            thumbVisibility: true,
            thickness: 3,
            radius: const Radius.circular(2),
            scrollbarOrientation: ScrollbarOrientation.bottom,
            child: ListView(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              padding: widget.padding,
              children: widget.children,
            ),
          ),
        ),
      ),
    );
  }
}
