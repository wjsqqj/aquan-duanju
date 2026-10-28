import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'core/aqua_api.dart';
import 'core/aqua_client.dart';
import 'core/aqua_error.dart';
import 'screens/home_screen.dart';
import 'store/stores.dart';
import 'theme/app_theme.dart';
import 'widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final settings = await SettingsStore.load();
  runApp(AquaApp(settings: settings));
}

/// 启动引导：设备注册 / 数据加载失败时给可重试的引导页，
/// 而不是卡死或白屏（fqapp「打开后一直卡在初始化」的同款问题）。
class AquaApp extends StatelessWidget {
  const AquaApp({super.key, required this.settings});

  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '阿圈短剧',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: AppTheme.modeOf(settings),
      home: AquaBootstrap(settings: settings),
    );
  }
}

class AquaBootstrap extends StatefulWidget {
  const AquaBootstrap({super.key, required this.settings});

  final SettingsStore settings;

  @override
  State<AquaBootstrap> createState() => _AquaBootstrapState();
}

class _AquaBootstrapState extends State<AquaBootstrap> {
  AquaApi? _api;
  HistoryStore? _history;
  FollowStore? _follows;
  Object? _error;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _error = null;
    });
    try {
      // 设备档案放应用支持目录（Android 私有目录 / Windows %APPDATA%）。
      final dir = await getApplicationSupportDirectory();
      final client = await AquaClient.create(
        '${dir.path}${Platform.pathSeparator}aquan_device.json',
      );
      final history = HistoryStore();
      final follows = FollowStore();
      await history.ensureLoaded();
      await follows.ensureLoaded();
      if (!mounted) return;
      setState(() {
        _api = AquaApi(client);
        _history = history;
        _follows = follows;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _attempt++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = _api;
    final history = _history;
    final follows = _follows;
    if (api != null && history != null && follows != null) {
      return AppScope(
        notifier: widget.settings,
        api: api,
        settings: widget.settings,
        history: history,
        follows: follows,
        child: const HomeScreen(),
      );
    }
    final text = _error is AquaException
        ? (_error as AquaException).friendlyText
        : '初始化需要联网完成设备注册，请检查网络后重试';
    return Scaffold(
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
    );
  }
}
