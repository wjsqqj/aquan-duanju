import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/aqua_client.dart';
import '../core/aqua_error.dart';
import '../core/backup_service.dart';
import '../core/download_service.dart';
import '../core/cache_maintenance.dart';
import '../core/error_log.dart';
import '../models/models.dart';
import '../store/stores.dart';
import '../theme/app_theme.dart';
import '../update/update_flow.dart';
import '../update/update_service.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';
import 'book_detail_screen.dart';
import 'bookshelf_screen.dart';
import 'history_screen.dart';
import 'downloads_screen.dart';

/// 我的页：观看历史、追剧、设置、关于（含免责声明）。
class MineScreen extends StatefulWidget {
  const MineScreen({super.key});

  @override
  State<MineScreen> createState() => _MineScreenState();
}

class _MineScreenState extends State<MineScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _refreshedCovers = false;

  /// 追剧状态筛选：'' = 全部，'update' = 有更新，其余是 FollowState.name。
  String _followFilter = '';

  static const _followFilters = <String, String>{
    '': '全部',
    'want': '想看',
    'watching': '在看',
    'watched': '已看',
    'update': '有更新',
  };

  List<FollowEntry> _filteredFollows(List<FollowEntry> entries) {
    switch (_followFilter) {
      case '':
        return entries;
      case 'update':
        return entries.where((e) => e.hasUpdate).toList();
      default:
        return entries.where((e) => e.state.name == _followFilter).toList();
    }
  }

  @override
  void initState() {
    super.initState();
    // 封面 URL 带签名过期（x-expires 约 60 天），打开本页时用批量详情
    // 刷新一次历史/追剧的封面；静默失败，不影响页面。
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshCovers());
  }

  Future<void> _refreshCovers() async {
    if (_refreshedCovers || !mounted) return;
    final scope = AppScope.read(context);
    final ids = <String>{
      for (final h in scope.history.entries) h.seriesId,
      for (final f in scope.follows.entries) f.seriesId,
    };
    if (ids.isEmpty) return;
    _refreshedCovers = true;
    try {
      final all = ids.toList();
      for (var i = 0; i < all.length; i += 10) {
        final batch = all.sublist(i, (i + 10).clamp(0, all.length));
        final details = await scope.api.getSeriesBatch(batch);
        final covers = <String, String>{
          for (final d in details)
            if (d.series != null) d.series!.id: d.series!.coverUrl,
        };
        await scope.history.refreshCovers(covers);
        // 追剧同时记录服务端集数，用于「有更新」提醒。
        await scope.follows.refreshFromDetails(
            details.map((d) => d.series).whereType<Series>().toList());
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scope = AppScope.read(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListenableBuilder(
        listenable:
            Listenable.merge([scope.history, scope.follows, scope.reading]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _UpdateBanner(),
            _Section(
              title: '继续观看',
              action: scope.history.entries.isEmpty
                  ? null
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const HistoryScreen()),
                        ),
                        child: const Text('全部'),
                      ),
                      TextButton(
                        onPressed: () =>
                            _confirmClear(context, '清空观看历史？', () async {
                          await scope.history.clear();
                        }),
                        child: const Text('清空'),
                      ),
                    ]),
              child: scope.history.entries.isEmpty
                  ? const _EmptyHint('看过之后，这里会记录进度')
                  : Column(
                      children: [
                        for (final h in scope.history.entries.take(10))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: SizedBox(
                              width: 56,
                              height: 76,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: CoverImage(url: h.coverUrl),
                              ),
                            ),
                            title: Text(h.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              h.finished
                                  ? '已看完'
                                  : '看到第${h.episode}集 ${_fmtPos(h.position)}',
                            ),
                            onTap: () => openDetail(
                                context, h.seriesId, h.title),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () =>
                                  scope.history.remove(h.seriesId),
                            ),
                          ),
                      ],
                    ),
            ),
            _Section(
              title: '书架',
              action: scope.reading.entries.isEmpty
                  ? null
                  : TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const BookshelfScreen()),
                      ),
                      child: const Text('全部'),
                    ),
              child: scope.reading.entries.isEmpty
                  ? const _EmptyHint('读过的小说和漫画会出现在这里')
                  : Column(
                      children: [
                        for (final e in scope.reading.entries.take(3))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: SizedBox(
                              width: 52,
                              height: 70,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: CoverImage(url: e.coverUrl),
                              ),
                            ),
                            title: Text(e.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              '${e.manga ? '看到' : '读到'} · ${e.chapterTitle}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => openBook(context, e),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => scope.reading.remove(e.bookId),
                            ),
                          ),
                      ],
                    ),
            ),
            _Section(
              title: '我的追剧',
              child: scope.follows.entries.isEmpty
                  ? const _EmptyHint('追剧之后，更新一目了然')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 状态筛选：全部 / 想看 / 在看 / 已看 / 有更新。
                        SizedBox(
                          height: 40,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final f in _followFilters.entries)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    label: Text(f.value),
                                    selected: _followFilter == f.key,
                                    onSelected: (_) => setState(
                                        () => _followFilter = f.key),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        for (final f
                            in _filteredFollows(scope.follows.entries))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: SizedBox(
                              width: 56,
                              height: 76,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: CoverImage(url: f.coverUrl),
                              ),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(f.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                ),
                                if (f.hasUpdate)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text('更新到${f.latestEpisodeCount}集',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color:
                                                theme.colorScheme.onPrimary)),
                                  ),
                              ],
                            ),
                            subtitle: Text(switch (f.state) {
                              FollowState.want => '想看',
                              FollowState.watching => '在看',
                              FollowState.watched => '已看',
                            }),
                            onTap: () =>
                                openDetail(context, f.seriesId, f.title),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => scope.follows.toggle(
                                seriesId: f.seriesId,
                                title: f.title,
                                coverUrl: f.coverUrl,
                                episodeCount: f.episodeCount,
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
            _Section(
              title: '数据',
              child: Column(
                children: [
                  // 我的下载 + 封面刷新入口。
                  ListenableBuilder(
                    listenable: Listenable.merge(
                        [scope.downloads, scope.downloads.store]),
                    builder: (context, _) {
                      final list = scope.downloads.store.seriesList;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.download_outlined),
                        title: const Text('我的下载'),
                        subtitle: Text(list.isEmpty
                            ? '在短剧详情页点「缓存」即可离线观看'
                            : '${list.length} 部剧集已缓存离线可看'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const DownloadsScreen()),
                        ),
                      );
                    },
                  ),
                  const BackupPanel(),
                  const CachePanel(),
                ],
              ),
            ),
            _Section(
              title: '设置',
              child: const SettingsPanel(),
            ),
            _Section(
              title: '关于',
              child: const AboutPanel(),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtPos(double seconds) {
    final m = (seconds / 60).floor();
    if (m >= 1) return '约 $m 分钟';
    return '刚开头';
  }

  Future<void> _confirmClear(
      BuildContext context, String text, Future<void> Function() action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认'),
        content: Text(text),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok == true) await action();
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.action});

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                ?action,
              ],
            ),
            const SizedBox(height: 6),
            child,
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text(text,
              style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        ),
      );
}

/// 有新版本时在「我的」页顶部提示；点了跳 GitHub Releases 下载。
class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: UpdateService.instance,
      builder: (context, _) {
        final update = UpdateService.instance;
        if (!update.hasUpdate) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(Icons.upgrade,
                  color: Theme.of(context).colorScheme.primary),
              title: Text('发现新版本 v${update.latestVersion}'),
              subtitle: const Text('点按前往下载页'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => updateInteractive(context),
            ),
          ),
        );
      },
    );
  }
}

/// 设置面板：主题 / 清晰度 / 倍速 / 历史条数 / 片头片尾 / 播放器高级 / 连播等。
class SettingsPanel extends StatelessWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    return ListenableBuilder(
      listenable: scope.settings,
      builder: (context, _) => Column(
        children: [
          _selectTile<String>(
            context,
            icon: Icons.brightness_6_outlined,
            title: '主题',
            value: scope.settings.themeMode,
            items: const {
              'system': '跟随系统',
              'light': '浅色',
              'dark': '深色',
            },
            onChanged: (v) => scope.settings.themeMode = v,
          ),
          _selectTile<String>(
            context,
            icon: Icons.hd_outlined,
            title: '默认清晰度',
            value: scope.settings.defaultQuality,
            items: const {
              'best': '最高（推荐）',
              '1080p': '1080p',
              '720p': '720p',
              'worst': '最低（省流量）',
            },
            onChanged: (v) => scope.settings.defaultQuality = v,
          ),
          _selectTile<String>(
            context,
            icon: Icons.download_outlined,
            title: '缓存清晰度',
            value: scope.settings.cacheQuality,
            items: const {
              'best': '最高（体积大）',
              '1080p': '1080p',
              '720p': '720p',
              '540p': '540p（推荐）',
              'worst': '最低（最省空间）',
            },
            onChanged: (v) => scope.settings.cacheQuality = v,
          ),
          if (!Platform.isAndroid)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('下载位置'),
              subtitle: Text(_downloadDirLabel(scope)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _chooseDownloadDir(context, scope),
            ),
          _selectTile<int>(
            context,
            icon: Icons.speed_outlined,
            title: '下载限速',
            subtitle: '限制离线缓存的下载速度，避免占满带宽',
            value: scope.settings.downloadSpeedKbps,
            items: const {
              0: '不限速',
              256: '256 KB/s',
              512: '512 KB/s',
              1024: '1 MB/s',
              2048: '2 MB/s',
              5120: '5 MB/s',
            },
            onChanged: (v) => scope.settings.downloadSpeedKbps = v,
          ),
          _selectTile<int>(
            context,
            icon: Icons.downloading,
            title: '同时下载',
            subtitle: '并发集数越高越吃带宽；源站限流时建议保持 1',
            value: scope.settings.downloadConcurrency,
            items: const {1: '1 集', 2: '2 集', 3: '3 集'},
            onChanged: (v) {
              scope.settings.downloadConcurrency = v;
              scope.downloads.concurrency = v;
            },
          ),
          _selectTile<int>(
            context,
            icon: Icons.replay,
            title: '失败自动重试',
            value: scope.settings.downloadRetries,
            items: const {
              0: '不重试',
              1: '重试 1 次',
              2: '重试 2 次',
              3: '重试 3 次',
            },
            onChanged: (v) {
              scope.settings.downloadRetries = v;
              scope.downloads.maxRetries = v;
            },
          ),
          _selectTile<String>(
            context,
            icon: Icons.speed,
            title: '默认倍速',
            value: scope.settings.defaultSpeed,
            items: const {
              '1.0': '1.0x',
              '1.25': '1.25x',
              '1.5': '1.5x',
              '2.0': '2.0x',
            },
            onChanged: (v) => scope.settings.defaultSpeed = v,
          ),
          _selectTile<int>(
            context,
            icon: Icons.history,
            title: '历史记录数量',
            value: scope.settings.historyLimit,
            items: {
              for (final n in SettingsStore.historyLimitOptions) n: '$n 条',
            },
            onChanged: (v) async {
              scope.settings.historyLimit = v;
              await scope.history.applyLimit(v);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.playlist_play),
            title: const Text('自动连播'),
            value: scope.settings.autoNext,
            onChanged: (v) => scope.settings.autoNext = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.content_cut_outlined),
            title: const Text('片头片尾跳过'),
            subtitle: const Text('按剧设置时间点；片头从开头跳，片尾自然播放到末尾前触发'),
            value: scope.settings.skipIntroOutro,
            onChanged: (v) => scope.settings.skipIntroOutro = v,
          ),
          if (Platform.isWindows)
            _selectTile<String>(
              context,
              icon: Icons.memory,
              title: '硬件解码',
              value: scope.settings.hwdecMode,
              items: SettingsStore.hwdecLabels,
              onChanged: (v) => scope.settings.hwdecMode = v,
            ),
          _selectTile<int>(
            context,
            icon: Icons.sd_storage_outlined,
            title: '网络缓冲时长',
            value: scope.settings.cacheSecs,
            items: const {
              5: '5 秒（省内存）',
              10: '10 秒',
              15: '15 秒',
              30: '30 秒（默认）',
              60: '60 秒（弱网）',
              120: '120 秒',
              300: '300 秒（最稳）',
            },
            onChanged: (v) => scope.settings.cacheSecs = v,
          ),
          _selectTile<int>(
            context,
            icon: Icons.av_timer,
            title: '音画同步',
            value: scope.settings.audioDelayMs,
            items: const {
              -500: '音频提前 500ms',
              -200: '音频提前 200ms',
              -100: '音频提前 100ms',
              0: '默认',
              100: '音频延后 100ms',
              200: '音频延后 200ms',
              500: '音频延后 500ms',
            },
            onChanged: (v) => scope.settings.audioDelayMs = v,
          ),
          if (!Platform.isAndroid)
            _selectTile<String>(
              context,
              icon: Icons.aspect_ratio_outlined,
              title: '画面比例',
              value: scope.settings.scale,
              items: SettingsStore.scaleLabels,
              onChanged: (v) => scope.settings.scale = v,
            ),
          _selectTile<int>(
            context,
            icon: Icons.subtitles_outlined,
            title: '字幕字号',
            value: scope.settings.subtitleFontSize,
            items: const {
              36: '小',
              42: '较小',
              48: '标准',
              56: '大',
              64: '特大',
            },
            onChanged: (v) => scope.settings.subtitleFontSize = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.format_size),
            title: const Text('字幕描边'),
            value: scope.settings.subtitleBorder,
            onChanged: (v) => scope.settings.subtitleBorder = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.branding_watermark_outlined),
            title: const Text('字幕背景'),
            subtitle: const Text('半透明黑底，亮画面下更清楚'),
            value: scope.settings.subtitleBackground,
            onChanged: (v) => scope.settings.subtitleBackground = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.shuffle),
            title: const Text('随机看从第 1 集开始'),
            value: scope.settings.randomFromFirst,
            onChanged: (v) => scope.settings.randomFromFirst = v,
          ),
          if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
            SwitchListTile(
              secondary: const Icon(Icons.aspect_ratio),
              title: const Text('播放时窗口适应片源'),
              subtitle: const Text('竖屏剧自动变竖窗口，横屏剧自动变横窗口'),
              value: scope.settings.autoFitWindow,
              onChanged: (v) => scope.settings.autoFitWindow = v,
            ),
          ListenableBuilder(
            listenable: UpdateService.instance,
            builder: (context, _) {
              final u = UpdateService.instance;
              final source = (u.sourceLabel != null && u.sourceLabel != '官方')
                  ? '（${u.sourceLabel}）'
                  : '';
              final subtitle = u.checking
                  ? '正在检查…'
                  : u.hasUpdate
                      ? '发现新版本 v${u.latestVersion}$source，点按前往下载'
                      : (u.error == null
                          ? '当前已是最新$source'
                          : '检查失败，请稍后再试');
              return ListTile(
                leading: const Icon(Icons.system_update_outlined),
                title: const Text('检查更新'),
                subtitle: Text(subtitle),
                onTap: u.checking
                    ? null
                    : () async {
                        await u.checkManually();
                        if (!context.mounted) return;
                        if (u.hasUpdate) {
                          await updateInteractive(context);
                        }
                      },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('重置匿名设备'),
            subtitle: const Text('遇到访问受限时使用'),
            onTap: () async {
              try {
                await scope.api.resetDevice();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已重置，重新拉取数据即可')));
                }
              } on AquaException catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(e.friendlyText)));
                }
              }
            },
          ),
        ],
      ),
    );
  }

  static String _downloadDirLabel(AppScope scope) {
    final custom = scope.settings.downloadDir;
    final active = scope.downloads.baseDir.path;
    if (custom == null) return active;
    return _samePath(custom, active)
        ? active
        : '$custom（不可用，已用 $active）';
  }

  static bool _samePath(String a, String b) =>
      a.toLowerCase().replaceAll('\\', '/') ==
      b.toLowerCase().replaceAll('\\', '/');

  Future<void> _chooseDownloadDir(
      BuildContext context, AppScope scope) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await getDirectoryPath(confirmButtonText: '选择');
      if (picked == null) return;
      if (scope.downloads.hasActiveTasks) {
        messenger.showSnackBar(
            const SnackBar(content: Text('有下载任务正在进行，请完成后再切换目录')));
        return;
      }
      final target = Directory(picked);
      if (!await DownloadService.ensureWritable(target)) {
        messenger.showSnackBar(
            const SnackBar(content: Text('该目录不可写，请换一个位置')));
        return;
      }
      if (!context.mounted) return;
      final mode = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('切换下载位置'),
          content: Text('新位置：${target.path}\n\n'
              '「仅切换」：新下载写到新目录，已有缓存保留原位置（仍可播放）。\n'
              '「迁移已有缓存」：逐集复制并校验后删除原文件，失败的单集保留原位置。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(context, 'switch'),
                child: const Text('仅切换')),
            FilledButton(
                onPressed: () => Navigator.pop(context, 'migrate'),
                child: const Text('迁移已有缓存')),
          ],
        ),
      );
      if (mode == null) return;
      if (mode == 'migrate') {
        final result = await scope.downloads.migrateDownloadsTo(target);
        scope.settings.downloadDir = target.path;
        messenger.showSnackBar(SnackBar(
          content: Text(result.failed > 0
              ? '已迁移 ${result.moved} 集，${result.failed} 集失败（保留原位置）'
              : '已迁移 ${result.moved} 集到新目录'),
        ));
      } else {
        await scope.downloads.setBaseDir(target);
        scope.settings.downloadDir = target.path;
        messenger.showSnackBar(
            const SnackBar(content: Text('已切换下载位置，旧缓存保留在原目录')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('切换失败：$e')));
    }
  }

  Widget _selectTile<T>(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required T value,
    required Map<T, String> items,
    required void Function(T) onChanged,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: PopupMenuButton<T>(
        initialValue: value,
        onSelected: onChanged,
        itemBuilder: (_) => [
          for (final e in items.entries)
            PopupMenuItem(value: e.key, child: Text(e.value)),
        ],
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(items[value] ?? '$value'),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

/// 关于面板：版本、核心版本、免责声明入口。
class AboutPanel extends StatefulWidget {
  const AboutPanel({super.key});

  @override
  State<AboutPanel> createState() => _AboutPanelState();
}

class _AboutPanelState extends State<AboutPanel> {
  String _version = '';
  String _core = '';
  String _build = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await PackageInfo.fromPlatform();
    String core = '';
    try {
      core = AquaClient.coreVersion();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _version = '${info.version}+${info.buildNumber}';
        _core = core;
        // 构建标识：用来确认用户跑的是不是最新包。
        _build = const String.fromEnvironment('AQUAN_BUILD',
            defaultValue: 'dev');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.local_movies_outlined),
          title: const Text('阿圈短剧'),
          subtitle: Text('版本 $_version · 核心 $_core · 构建 $_build'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.description_outlined),
          title: const Text('数据来源与免责声明'),
          subtitle: const Text('本应用基于开源项目 openhongguo，仅供学习'),
          onTap: () => showAboutDialog(
            context: context,
            applicationName: '阿圈短剧',
            applicationVersion: _version,
            children: [
              Text(
                '阿圈短剧的数据来自开源项目 openhongguo（Apache License 2.0）逆向的'
                '红果短剧公开接口，所有内容版权归原平台与权利方所有。\n\n'
                '本项目仅供学习与研究，禁止用于商业用途；请勿用于任何侵犯他人合法权益'
                '的用途。使用本应用即表示您同意上述条款。\n\n'
                '主题色 ${AppTheme.seed}。',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        ListenableBuilder(
          listenable: ErrorLog.instance,
          builder: (context, _) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('错误日志'),
            subtitle: Text(ErrorLog.instance.isEmpty
                ? '本次运行没有错误'
                : '本次运行 ${ErrorLog.instance.length} 条，点按查看 / 复制'),
            onTap: () => _showErrorLog(context),
          ),
        ),
      ],
    );
  }

  Future<void> _showErrorLog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            const Text('错误日志'),
            const Spacer(),
            IconButton(
              tooltip: '复制全部',
              icon: const Icon(Icons.copy_rounded, size: 20),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: ErrorLog.instance.text));
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                      const SnackBar(content: Text('错误日志已复制')));
                }
              },
            ),
            IconButton(
              tooltip: '清空',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: ErrorLog.instance.clear,
            ),
          ],
        ),
        content: Builder(
          builder: (context) {
            final media = MediaQuery.sizeOf(context);
            return SizedBox(
              width: (media.width - 120).clamp(240.0, 640.0),
              height: (media.height * 0.6).clamp(220.0, 480.0),
              child: ListenableBuilder(
                listenable: ErrorLog.instance,
                builder: (context, _) => ErrorLog.instance.isEmpty
                    ? const Center(child: Text('本次运行没有错误'))
                    : const _ErrorLogText(),
              ),
            );
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭')),
        ],
      ),
    );
  }
}

class _ErrorLogText extends StatelessWidget {
  const _ErrorLogText();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: SelectableText(
        ErrorLog.instance.text,
        style: const TextStyle(fontSize: 12, height: 1.45),
      ),
    );
  }
}


/// 备份与恢复：导出观看历史 / 追剧 / 搜索历史 / 片头片尾 / 设置。
///
/// 备份带版本、体积上限与逐项 SHA-256；导入时先校验，再合并，并在恢复前
/// 自动把当前数据快照到 `<数据目录>/backups/`（失败时尽力回滚）。
class BackupPanel extends StatelessWidget {
  const BackupPanel({super.key});

  Future<Map<String, Map<String, dynamic>>> _collect(AppScope scope) async => {
        'history': await scope.history.exportData(),
        'follows': await scope.follows.exportData(),
        'searches': await scope.searches.exportData(),
        'play_skip': await scope.playSkip.exportData(),
        'settings': scope.settings.exportBackup(),
        'sources': await scope.sources.exportData(),
        'source_health': await scope.sourceHealth.exportData(),
        'market_sites': await scope.marketSites.exportData(),
      };

  Future<void> _export(BuildContext context) async {
    final scope = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final info = await PackageInfo.fromPlatform();
      final appVersion = '${info.version}+${info.buildNumber}';
      final files = await _collect(scope);
      final service = DataBackupService();
      if (Platform.isAndroid) {
        // Android 没有系统保存对话框：写临时文件走分享面板。
        final dir = await getTemporaryDirectory();
        final file = File(
            '${dir.path}${Platform.pathSeparator}aquan_backup_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.json');
        await service.exportTo(file.path, files, appVersion: appVersion);
        await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
        return;
      }
      final location = await getSaveLocation(
        suggestedName: 'aquan_backup.json',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json'])
        ],
      );
      if (location == null) return;
      await service.exportTo(location.path, files, appVersion: appVersion);
      messenger.showSnackBar(
          SnackBar(content: Text('已导出到 ${location.path}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  Future<void> _import(BuildContext context) async {
    final scope = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json'])
        ],
      );
      if (file == null) return;
      final service = DataBackupService();
      final backup = await service.readFile(file.path);
      if (!context.mounted) return;
      final labels = backup.files.keys.map(_labelOf).join('、');
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('恢复数据备份？'),
          content: Text(
            '将恢复：$labels\n\n'
            '历史 / 追剧按较新记录合并；搜索历史追加去重；设置与片头片尾以备份为准。\n'
            '恢复前会自动备份当前数据。',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('恢复')),
          ],
        ),
      );
      if (ok != true) return;
      final current = await _collect(scope);
      final result = await service.restore(
        backup,
        currentFiles: current,
        apply: (name, data) async {
          switch (name) {
            case 'history':
              await scope.history.importData(data);
            case 'follows':
              await scope.follows.importData(data);
            case 'searches':
              await scope.searches.importData(data);
            case 'play_skip':
              await scope.playSkip.importData(data);
            case 'settings':
              scope.settings.importBackup(data);
              scope.downloads.concurrency = scope.settings.downloadConcurrency;
              scope.downloads.maxRetries = scope.settings.downloadRetries;
              await scope.history.applyLimit(scope.settings.historyLimit);
            case 'sources':
              await scope.sources.importData(data);
            case 'source_health':
              await scope.sourceHealth.importData(data);
            case 'market_sites':
              await scope.marketSites.importData(data);
          }
        },
      );
      messenger.showSnackBar(SnackBar(
        content: Text('恢复完成：${result.restored.length} 项'
            '${result.preRestorePath == null ? '' : '，恢复前备份已保存'}'),
      ));
    } on DataBackupException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  static String _labelOf(String name) => switch (name) {
        'history' => '观看历史',
        'follows' => '追剧',
        'searches' => '搜索历史',
        'play_skip' => '片头片尾',
        'settings' => '设置',
        'sources' => '影视源',
        'source_health' => '源健康数据',
        'market_sites' => '源市场索引站',
        _ => name,
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.file_upload_outlined),
          title: const Text('导出备份'),
          subtitle: const Text('历史 / 追剧 / 搜索 / 片头片尾 / 设置，JSON 文件'),
          onTap: () => _export(context),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.file_download_outlined),
          title: const Text('导入恢复'),
          subtitle: const Text('校验后合并，恢复前自动备份当前数据'),
          onTap: () => _import(context),
        ),
      ],
    );
  }
}

/// 存储与缓存：盘点应用数据 / 离线缓存 / 孤儿临时文件，并支持一键清理。
class CachePanel extends StatefulWidget {
  const CachePanel({super.key});

  @override
  State<CachePanel> createState() => _CachePanelState();
}

class _CachePanelState extends State<CachePanel> {
  CacheInventory? _inventory;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final scope = AppScope.read(context);
    final inventory = await CacheMaintenance(
      downloadsDirectory: () async => scope.downloads.baseDir,
    ).inspect();
    if (mounted) setState(() => _inventory = inventory);
  }

  Future<void> _clean(BuildContext context) async {
    if (_busy) return;
    final scope = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final result = await CacheMaintenance(
        downloadsDirectory: () async => scope.downloads.baseDir,
      ).cleanOrphans();
      try {
        await DefaultCacheManager().emptyCache();
      } catch (_) {}
      await _refresh();
      messenger.showSnackBar(SnackBar(
        content: Text(result.deleted > 0
            ? '已清理 ${_fmtBytes(result.bytes)} 临时文件（${result.deleted} 个）'
            : '没有可清理的临时文件'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('清理失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openDataDir() async {
    try {
      final dir = await getApplicationSupportDirectory();
      if (Platform.isWindows) {
        await Process.start('explorer', [dir.path],
            mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [dir.path],
            mode: ProcessStartMode.detached);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [dir.path],
            mode: ProcessStartMode.detached);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final inv = _inventory;
    final subtitle = inv == null
        ? '正在统计…'
        : !inv.directoryReadable
            ? '数据目录不可读'
            : '应用数据 ${_fmtBytes(inv.userDataBytes)} · '
                '离线缓存 ${_fmtBytes(inv.downloadBytes)}'
                '${inv.orphanFiles > 0 ? ' · 可清理 ${_fmtBytes(inv.orphanBytes)}' : ''}';
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cleaning_services_outlined),
          title: const Text('存储与缓存'),
          subtitle: Text(subtitle),
          trailing: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton(
                  onPressed: () => _clean(context),
                  child: const Text('清理'),
                ),
        ),
        if (!Platform.isAndroid)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('打开数据目录'),
            subtitle: const Text('备份文件与离线缓存都在这里'),
            onTap: _openDataDir,
          ),
      ],
    );
  }
}

String _fmtBytes(int bytes) {
  if (bytes >= 1 << 30) {
    return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1 << 20) {
    return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1 << 10) {
    return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  }
  return '$bytes B';
}
