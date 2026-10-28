import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/aqua_client.dart';
import '../core/aqua_error.dart';
import '../store/stores.dart';
import '../theme/app_theme.dart';
import '../update/update_service.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';
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
        await scope.follows.refreshCovers(covers);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scope = AppScope.read(context);
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListenableBuilder(
        listenable: Listenable.merge([scope.history, scope.follows]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _UpdateBanner(),
            _Section(
              title: '继续观看',
              action: scope.history.entries.isEmpty
                  ? null
                  : TextButton(
                      onPressed: () =>
                          _confirmClear(context, '清空观看历史？', () async {
                        await scope.history.clear();
                      }),
                      child: const Text('清空'),
                    ),
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
              title: '我的追剧',
              child: scope.follows.entries.isEmpty
                  ? const _EmptyHint('追剧之后，更新一目了然')
                  : Column(
                      children: [
                        for (final f in scope.follows.entries)
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
                            title: Text(f.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
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
              onTap: update.openReleasePage,
            ),
          ),
        );
      },
    );
  }
}

/// 设置面板：主题/默认清晰度/默认倍速/连播/随机起点/重置设备。
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
              'best': '最高',
              '1080p': '1080p',
              '720p': '720p',
              'worst': '最低（省流量）',
            },
            onChanged: (v) => scope.settings.defaultQuality = v,
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
          SwitchListTile(
            secondary: const Icon(Icons.playlist_play),
            title: const Text('自动连播'),
            value: scope.settings.autoNext,
            onChanged: (v) => scope.settings.autoNext = v,
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
              final subtitle = u.checking
                  ? '正在检查…'
                  : u.hasUpdate
                      ? '发现新版本 v${u.latestVersion}，点按前往下载'
                      : (u.error == null ? '当前已是最新' : '检查失败，请稍后再试');
              return ListTile(
                leading: const Icon(Icons.system_update_outlined),
                title: const Text('检查更新'),
                subtitle: Text(subtitle),
                onTap: u.checking
                    ? null
                    : () async {
                        await u.checkManually();
                        if (u.hasUpdate) await u.openReleasePage();
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

  Widget _selectTile<T>(
    BuildContext context, {
    required IconData icon,
    required String title,
    required T value,
    required Map<T, String> items,
    required void Function(T) onChanged,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
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
          subtitle: Text('版本 $_version · 核心 $_core'),
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
      ],
    );
  }
}


/// 备份与恢复：导出观看历史 + 追剧到 JSON 文件；导入时按条目合并（较新者胜）。
class BackupPanel extends StatelessWidget {
  const BackupPanel({super.key});

  Future<void> _export(BuildContext context) async {
    final scope = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final backup = Backup.build(
        await scope.history.exportData(),
        await scope.follows.exportData(),
      );
      final raw = const JsonEncoder.withIndent('  ').convert(backup);
      if (Platform.isAndroid) {
        // Android 没有系统保存对话框：写临时文件走分享面板。
        final dir = await getTemporaryDirectory();
        final file = File(
            '${dir.path}${Platform.pathSeparator}aquan_backup_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.json');
        await file.writeAsString(raw);
        await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
        return;
      }
      final location = await getSaveLocation(
        suggestedName: 'aquan_backup.json',
        acceptedTypeGroups: const [XTypeGroup(label: 'JSON', extensions: ['json'])],
      );
      if (location == null) return;
      await File(location.path).writeAsString(raw);
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
        acceptedTypeGroups: const [XTypeGroup(label: 'JSON', extensions: ['json'])],
      );
      if (file == null) return;
      final raw = await File(file.path).readAsString();
      final (history, follows) = Backup.parse(jsonDecode(raw) as Map<String, dynamic>);
      final h = await scope.history.importData(history);
      final f = await scope.follows.importData(follows);
      messenger.showSnackBar(
          SnackBar(content: Text('已合并：历史 $h 条，追剧 $f 条')));
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.file_upload_outlined),
          title: const Text('导出备份'),
          subtitle: const Text('观看历史 + 追剧，JSON 文件'),
          onTap: () => _export(context),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.file_download_outlined),
          title: const Text('导入恢复'),
          subtitle: const Text('与现有数据合并，较新的记录优先'),
          onTap: () => _import(context),
        ),
      ],
    );
  }
}
