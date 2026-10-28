import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'cli/command_bus.dart';
import 'cli/instance_server.dart';
import 'cli/launch_command.dart';
import 'cli/player_bus.dart';
import 'cli/search_cli.dart';
import 'core/aqua_api.dart';
import 'core/aqua_client.dart';
import 'core/aqua_error.dart';
import 'core/download_service.dart';
import 'models/models.dart';
import 'screens/detail_screen.dart';
import 'screens/home_screen.dart';
import 'store/stores.dart';
import 'theme/app_theme.dart';
import 'widgets/common.dart';

/// 全局根导航：单实例转交过来的命令（AI 让「搜某部剧并播放」）需要
/// 从 App 顶层直接推详情页。
final rootNavigatorKey = GlobalKey<NavigatorState>();

bool get _isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final command = LaunchCommand.parse(args);
  if (command.kind == 'help') {
    stdout.write(kCliHelp);
    exit(0);
  }
  if (command.kind == 'version') {
    stdout.writeln(AquaClient.coreVersion());
    exit(0);
  }

  final dir = await getApplicationSupportDirectory();
  final sep = Platform.pathSeparator;

  // 已有窗口在跑：把命令转交过去并带回回包，不再开第二个窗口。
  // --search 例外：它始终就地查询（转交过去反而拿不到列表输出）。
  final instanceFile = File('${dir.path}${sep}aquan_instance.json');
  if (!command.isEmpty && command.kind != 'search') {
    final reply = await SingleInstance.forward(instanceFile, command);
    if (reply != null) {
      if (command.json || LaunchCommand.isPlayerKind(command.kind)) {
        stdout.writeln(jsonEncode(reply));
      }
      exit(reply['ok'] == false ? 1 : 0);
    }
  }

  // 只查列表：不启动 UI，打印后退出（AI 助手取列表用）。
  if (command.kind == 'search') {
    await runSearchCli(command, '${dir.path}${sep}aquan_device.json');
  }

  MediaKit.ensureInitialized();
  final settings = await SettingsStore.load();
  final instance = await SingleInstance.listen(
    instanceFile,
    (c) async {
      // 播放控制不依赖 App 状态（PlayerBus 是全局的），直接回包；
      // 开播类命令交给 App 导航，回包只表示已受理。
      if (LaunchCommand.isPlayerKind(c.kind)) {
        return PlayerBus.instance.dispatch(c);
      }
      CommandBus.instance.emit(c);
      return {'ok': true};
    },
    locatorDir: SingleInstance.locatorDir(),
  );
  if (!command.isEmpty) CommandBus.instance.emit(command);
  runApp(AquaApp(settings: settings, instance: instance));
}

/// 启动引导：设备注册 / 数据加载失败时给可重试的引导页，
/// 而不是卡死或白屏（fqapp「打开后一直卡在初始化」的同款问题）。
class AquaApp extends StatefulWidget {
  const AquaApp({super.key, required this.settings, required this.instance});

  final SettingsStore settings;
  final SingleInstance instance;

  @override
  State<AquaApp> createState() => _AquaAppState();
}

class _AquaAppState extends State<AquaApp> {
  AquaApi? _api;
  HistoryStore? _history;
  FollowStore? _follows;
  SearchHistoryStore? _searches;
  DownloadService? _downloads;
  Object? _error;
  int _attempt = 0;
  bool _handlingCommand = false;
  StreamSubscription<LaunchCommand>? _commandSub;

  bool get _ready => _api != null && _history != null && _follows != null;

  @override
  void initState() {
    super.initState();
    _commandSub = CommandBus.instance.stream.listen(_handleCommand);
    _bootstrap();
  }

  @override
  void dispose() {
    _commandSub?.cancel();
    widget.instance.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _error = null;
    });
    try {
      // 设备档案放应用支持目录（Android 私有目录 / 桌面用户配置目录）。
      final dir = await getApplicationSupportDirectory();
      final client = await AquaClient.create(
        '${dir.path}${Platform.pathSeparator}aquan_device.json',
      );
      final history = HistoryStore();
      final follows = FollowStore();
      final searches = SearchHistoryStore();
      final downloads = DownloadStore();
      await history.ensureLoaded();
      await follows.ensureLoaded();
      await searches.ensureLoaded();
      await downloads.ensureLoaded();
      if (!mounted) return;
      final api = AquaApi(client);
      final downloadService = DownloadService(
        store: downloads,
        baseDir: Directory('${dir.path}${Platform.pathSeparator}downloads'),
        resolver:
            defaultResolver(api, () => widget.settings.cacheQuality),
      );
      setState(() {
        _api = api;
        _history = history;
        _follows = follows;
        _searches = searches;
        _downloads = downloadService;
      });
      final pending = CommandBus.instance.takePending();
      if (pending != null) {
        // 此时只是 setState 完，根导航器要等下一帧才挂上；
        // 同步执行会拿不到 navigator，命令被静默丢掉。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _handleCommand(pending);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _attempt++;
      });
    }
  }

  /// 执行 AI / 命令行转交过来的命令；返回值作为单实例通道的回包。
  Future<Map<String, dynamic>> _handleCommand(LaunchCommand command) async {
    if (command.isEmpty || !_ready) return {'ok': true};
    // 播放控制不需要抢窗口焦点，直接下发给当前播放器。
    if (LaunchCommand.isPlayerKind(command.kind)) {
      return PlayerBus.instance.dispatch(command);
    }
    if (_handlingCommand) return {'ok': false, 'error': '上一条命令还在执行'};
    _handlingCommand = true;
    try {
      if (_isDesktop) {
        try {
          await windowManager.show();
          await windowManager.focus();
        } catch (_) {}
      }
      final navigator = rootNavigatorKey.currentState;
      if (navigator == null) return {'ok': false, 'error': '界面未就绪'};
      if (command.kind == 'series') {
        navigator.push(MaterialPageRoute(
          builder: (_) => DetailScreen(
            seriesId: command.value,
            autoplay: true,
            startEpisode: command.episode,
          ),
        ));
        return {'ok': true};
      } else if (command.kind == 'watch') {
        final page = await _api!.search(command.value, pageSize: command.limit);
        if (page.items.isEmpty) {
          _toast('没搜到《${command.value}》');
          return {'ok': false, 'error': '没搜到《${command.value}》'};
        }
        final best = _bestMatch(command.value, page.items);
        navigator.push(MaterialPageRoute(
          builder: (_) => DetailScreen(
            seriesId: best.id,
            title: best.title,
            autoplay: true,
          ),
        ));
        return {'ok': true, 'message': '正在播放《${best.title}》'};
      }
      return {'ok': false, 'error': '未知命令 ${command.kind}'};
    } catch (e) {
      _toast(e is AquaException ? e.friendlyText : '命令执行失败：$e');
      return {'ok': false, 'error': e.toString()};
    } finally {
      _handlingCommand = false;
    }
  }

  /// 搜索结果里挑最匹配的一部：完全相等 > 前缀 > 包含 > 接口第一条。
  static SeriesSummary _bestMatch(String query, List<SeriesSummary> items) {
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final q = norm(query);
    SeriesSummary? best;
    var bestScore = 0;
    for (final item in items) {
      final t = norm(item.title);
      final score = q == t
          ? 100
          : t.startsWith(q)
              ? 80
              : t.contains(q)
                  ? 60
                  : 0;
      if (score > bestScore) {
        bestScore = score;
        best = item;
      }
    }
    return best ?? items.first;
  }

  void _toast(String text) {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) {
      return AppScope(
        notifier: widget.settings,
        api: _api!,
        settings: widget.settings,
        history: _history!,
        follows: _follows!,
        searches: _searches!,
        downloads: _downloads!,
        child: AnimatedBuilder(
          animation: widget.settings,
          builder: (context, _) => MaterialApp(
            title: '阿圈短剧',
            debugShowCheckedModeBanner: false,
            navigatorKey: rootNavigatorKey,
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: AppTheme.modeOf(widget.settings),
            home: const HomeScreen(),
          ),
        ),
      );
    }
    final text = _error is AquaException
        ? (_error as AquaException).friendlyText
        : '初始化需要联网完成设备注册，请检查网络后重试';
    return AnimatedBuilder(
      animation: widget.settings,
      builder: (context, _) => MaterialApp(
        title: '阿圈短剧',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: AppTheme.modeOf(widget.settings),
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.wifi_off_outlined,
                    size: 56, color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(text, textAlign: TextAlign.center),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _bootstrap,
                  icon: const Icon(Icons.refresh),
                  label: Text(_attempt > 0 ? '再试一次' : '重试'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
