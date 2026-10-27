import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'core/aqua_api.dart';
import 'core/aqua_client.dart';
import 'screens/home_screen.dart';
import 'store/stores.dart';
import 'theme/app_theme.dart';
import 'widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final settings = await SettingsStore.load();
  final history = HistoryStore();
  final follows = FollowStore();

  // 设备档案放在应用支持目录（Android app 私有目录 / Windows %APPDATA%）。
  final dir = await getApplicationSupportDirectory();
  final client = await AquaClient.create(
    '${dir.path}${Platform.pathSeparator}aquan_device.json',
  );
  final api = AquaApi(client);

  await history.ensureLoaded();
  await follows.ensureLoaded();

  runApp(AquaApp(settings: settings, history: history, follows: follows, api: api));
}

class AquaApp extends StatelessWidget {
  const AquaApp({
    super.key,
    required this.settings,
    required this.history,
    required this.follows,
    required this.api,
  });

  final SettingsStore settings;
  final HistoryStore history;
  final FollowStore follows;
  final AquaApi api;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: '阿圈短剧',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: AppTheme.modeOf(settings),
        home: AppScope(
          notifier: settings,
          api: api,
          settings: settings,
          history: history,
          follows: follows,
          child: const HomeScreen(),
        ),
      ),
    );
  }
}
