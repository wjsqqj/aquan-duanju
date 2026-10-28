import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// 应用内更新检查：对比 GitHub Releases 的最新 tag 与当前版本。
///
/// 检查失败（无网、GitHub 不可达）静默处理——这是增值功能，不阻塞使用；
/// 手动触发时才把错误展示出来。
class UpdateService extends ChangeNotifier {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  static const _releasesUrl =
      'https://github.com/wjsqqj/aquan-duanju/releases';
  static const _apiUrl =
      'https://api.github.com/repos/wjsqqj/aquan-duanju/releases/latest';

  bool _checking = false;
  String? _latestVersion;
  String? _releaseUrl;
  String? _installerUrl;
  String? _error;

  bool get checking => _checking;
  bool get hasUpdate => _latestVersion != null;

  /// 最新版本号；没有更新或未检查过时为 null。
  String? get latestVersion => _latestVersion;
  String? get error => _error;

  /// Windows 安装包直链（有更新且最新 Release 带 setup.exe 时非空）。
  String? get windowsInstallerUrl => _installerUrl;

  /// 下载进度（0-1）；不在下载中时为 null。
  final ValueNotifier<double?> downloadProgress = ValueNotifier<double?>(null);

  /// 从 Release assets 里找 Windows 安装包（排除 .sha256）。
  static String? _findWindowsInstaller(dynamic assets) {
    if (assets is! List) return null;
    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) continue;
      final name = asset['name'] as String? ?? '';
      if (name.startsWith('aquan-windows-x64-') &&
          name.endsWith('-setup.exe')) {
        return asset['browser_download_url'] as String?;
      }
    }
    return null;
  }

  /// 下载 Windows 安装包（进度走 [downloadProgress]），然后静默运行并退出
  /// 本应用交给安装器。仅 Windows 且检查到带安装包的新版本时可用。
  Future<void> downloadAndInstall() async {
    final url = _installerUrl;
    final version = _latestVersion;
    if (url == null || version == null) {
      throw StateError('没有可用的 Windows 安装包');
    }
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}${Platform.pathSeparator}aquan-windows-x64-$version-setup.exe');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'aquan-duanju');
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw HttpException('下载返回 ${response.statusCode}');
      }
      final total = response.contentLength;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          if (total > 0) {
            downloadProgress.value = received / total;
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } catch (_) {
      downloadProgress.value = null;
      client.close(force: true);
      rethrow;
    }
    downloadProgress.value = null;
    client.close(force: true);
    await Process.start(
      file.path,
      const ['/SILENT', '/FORCECLOSEAPPLICATIONS'],
      mode: ProcessStartMode.detached,
    );
    // 给安装器一点启动时间，然后退出让它接管（安装完需重新打开应用）。
    await Future<void>.delayed(const Duration(milliseconds: 800));
    exit(0);
  }

  /// 静默检查（应用启动后调用）。失败不打扰。
  Future<void> checkQuietly() => _check(manual: false);

  /// 手动检查（设置里点按钮）。失败给错误信息。
  Future<void> checkManually() => _check(manual: true);

  Future<void> _check({required bool manual}) async {
    if (_checking) return;
    _checking = true;
    _error = null;
    notifyListeners();
    try {
      final info = await PackageInfo.fromPlatform();
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12);
      final request = await client.getUrl(Uri.parse(_apiUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'aquan-duanju');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw HttpException('GitHub 返回 ${response.statusCode}');
      }
      final body =
          await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 15));
      client.close(force: true);
      final json = jsonDecode(body);
      if (json is! Map<String, dynamic>) {
        throw const FormatException('响应不是 JSON 对象');
      }
      final tag = json['tag_name'] as String? ?? '';
      final latest = tag.startsWith('v') ? tag.substring(1) : tag;
      final current = info.version;
      if (isVersionNewer(latest, current)) {
        _latestVersion = latest;
        _releaseUrl = json['html_url'] as String? ?? _releasesUrl;
        _installerUrl = _findWindowsInstaller(json['assets']);
      } else {
        _latestVersion = null;
        _releaseUrl = null;
        _installerUrl = null;
      }
    } catch (e) {
      // 静默检查失败就当没有更新；手动检查时把原因留出来。
      _error = e.toString();
      if (!manual) _error = null;
      if (_latestVersion == null) _releaseUrl = null;
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// 打开发布页让用户下载（不自动下载安装，用户保留控制权）。
  Future<void> openReleasePage() async {
    final url = Uri.parse(_releaseUrl ?? _releasesUrl);
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      // 没有浏览器等极端环境：忽略，用户可手动访问。
    }
  }

  /// 语义化版本比较：latest 的主/次/补丁任一大于 current 即认为有更新。
  static bool isVersionNewer(String latest, String current) {
    final a = _versionTriple(latest);
    final b = _versionTriple(current);
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  static List<int> _versionTriple(String version) {
    final core = version.split('+').first.split('-').first;
    final parts = core.split('.');
    return [
      for (var i = 0; i < 3; i++)
        i < parts.length ? (int.tryParse(parts[i]) ?? 0) : 0,
    ];
  }
}
