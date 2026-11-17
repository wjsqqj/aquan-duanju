import 'package:flutter/foundation.dart';

import '../models/models.dart';

/// 选集面板「按季浏览」的状态控制器（底部选集抽屉与桌面全屏右侧抽屉共用）。
///
/// 二轮反馈的行为变更：点季标签**只切换浏览的季**——拉取该季集数列表展示，
/// 让用户看看那一季有多少集；**不起播**。只有点到某一集才走 [onPlayEpisode]：
/// 同季回集下标，跨季回（季, 该季内下标）。
class SeasonBrowseController extends ChangeNotifier {
  SeasonBrowseController({
    required this.seasons,
    required this.playingSeriesId,
    required this.playingEpisodes,
    required this.playingIndex,
    required this.fetchSeasonEpisodes,
  }) {
    // 播放季的列表调用方已持有，直接入缓存，免去打开面板时的首次请求。
    _cache[playingSeriesId] = playingEpisodes;
    _browseSeason = _seasonOf(playingSeriesId);
  }

  /// 全部季（含未上线的）。
  final List<Season> seasons;

  /// 正在播的季 id。
  final String playingSeriesId;

  /// 正在播的季的集数列表。
  final List<Episode> playingEpisodes;

  /// 正在播的集在 [playingEpisodes] 里的下标。
  final int playingIndex;

  /// 拉取某季全部集数（播放器侧统一走分页聚合）。
  final Future<List<Episode>> Function(String seriesId) fetchSeasonEpisodes;

  final Map<String, List<Episode>> _cache = <String, List<Episode>>{};

  Season? _browseSeason;
  bool _loading = false;

  /// 最近一次「浏览切换」是否加载失败（网格给行内错误提示）。
  bool loadFailed = false;

  /// 当前浏览的季拉到了空列表（元数据没有集数但季可能还没上线）。
  bool seasonEmpty = false;

  /// 防串台令牌：连续点两个季时，慢的旧请求回来不得覆盖新季的列表。
  int _fetchToken = 0;

  /// 当前浏览的季；从未点过季标签时 = 正在播的季。
  Season get current =>
      _browseSeason ?? _seasonOf(playingSeriesId);

  /// 是否正在拉取浏览季的集数。
  bool get loading => _loading;

  /// 当前浏览季的集数列表；未拉到时给空列表（网格显示加载态）。
  List<Episode> get episodes =>
      _cache[current.seriesId] ?? const <Episode>[];

  /// 浏览的是不是正在播的季。
  bool get browsingPlayingSeason => current.seriesId == playingSeriesId;

  /// 当前集高亮下标：浏览其它季时不高亮任何集（-1）。
  int get currentIndex => browsingPlayingSeason ? playingIndex : -1;

  /// 已看完打勾集合：只在浏览播放季时展示，其它季没有观看数据。
  bool watchedFor(Episode episode, Set<int> playingWatched) =>
      browsingPlayingSeason && playingWatched.contains(episode.number);

  /// 切换浏览的季：已缓存直接换，否则拉取。
  ///
  /// 拉取失败时回退到上一个浏览季并重抛，调用方决定要不要再提示。
  Future<void> browse(Season season) async {
    if (season.seriesId.isEmpty || season.seriesId == current.seriesId) {
      return;
    }
    final Season previous = current;
    _browseSeason = season;
    loadFailed = false;
    seasonEmpty = false;
    notifyListeners();
    if (_cache.containsKey(season.seriesId)) {
      seasonEmpty = (_cache[season.seriesId]?.isEmpty ?? false);
      notifyListeners();
      return;
    }
    final int token = ++_fetchToken;
    _loading = true;
    notifyListeners();
    try {
      final episodes = await fetchSeasonEpisodes(season.seriesId);
      // 只在用户仍停在这一季时落地结果。
      if (token == _fetchToken) {
        _cache[season.seriesId] = episodes;
        // 拉到空列表：季还没上线（或元数据缺集数）。停在这一季并给行内
        // 提示，让「未上线为什么还列在这里」自解释。
        seasonEmpty = episodes.isEmpty;
      }
    } catch (_) {
      if (token == _fetchToken) {
        loadFailed = true;
        _browseSeason = previous;
      }
      rethrow;
    } finally {
      if (token == _fetchToken) _loading = false;
      notifyListeners();
    }
  }

  Season _seasonOf(String seriesId) {
    for (final season in seasons) {
      if (season.seriesId == seriesId) return season;
    }
    // 数据异常兜底：播放季不在列表里就用第一个有集数的季。
    return seasons.firstWhere(
      (s) => s.episodeCount > 0,
      orElse: () => seasons.isNotEmpty
          ? seasons.first
          : Season(seriesId: playingSeriesId),
    );
  }
}
