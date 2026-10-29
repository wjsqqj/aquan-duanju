import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'update_mirror_health.dart';
import 'update_mirrors.dart';

/// 应用内更新检查：对比 GitHub Releases 的最新 tag 与当前版本。
///
/// 链路：官方 API → 内置镜像（仅支持 API 代理且不在冷却期）。检查失败
/// （无网、GitHub 不可达）静默处理；手动触发时才把错误展示出来。
///
/// 下载：官方资产直链 → 镜像资产兜底；下载后若 Release 提供 `.sha256`
/// 资产，则校验安装包 SHA-256，不匹配直接拒绝安装。
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
  String? _installerShaUrl;
  String? _error;
  String? _sourceLabel;
  String? _downloadSourceLabel;

  final UpdateMirrorHealthStore _health = UpdateMirrorHealthStore();

  bool get checking => _checking;
  bool get hasUpdate => _latestVersion != null;

  /// 最新版本号；没有更新或未检查过时为 null。
  String? get latestVersion => _latestVersion;
  String? get error => _error;

  /// 本次检查实际使用的源（「官方」/「镜像 gh-proxy.com」）。
  String? get sourceLabel => _sourceLabel;

  /// 本次下载实际使用的源。
  String? get downloadSourceLabel => _downloadSourceLabel;

  /// Windows 安装包直链（有更新且最新 Release 带 setup.exe 时非空）。
  String? get windowsInstallerUrl => _installerUrl;

  /// 下载进度（0-1）；不在下载中时为 null。
  final ValueNotifier<double?> downloadProgress = ValueNotifier<double?>(null);

  /// 从 Release assets 里找 Windows 安装包（排除 .sha256）。
  static ({String url, String? shaUrl})? _findWindowsInstaller(dynamic assets) {
    if (assets is! List) return null;
    String? installerName;
    String? installerUrl;
    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) continue;
      final name = asset['name'] as String? ?? '';
      if (name.startsWith('aquan-windows-x64-') &&
          name.endsWith('-setup.exe')) {
        installerName = name;
        installerUrl = asset['browser_download_url'] as String?;
        break;
      }
    }
    if (installerName == null || installerUrl == null) return null;
    String? shaUrl;
    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) continue;
      if (asset['name'] == '$installerName.sha256') {
        shaUrl = asset['browser_download_url'] as String?;
        break;
      }
    }
    return (url: installerUrl, shaUrl: shaUrl);
  }

  /// 下载 Windows 安装包（进度走 [downloadProgress]），校验后静默运行并退出
  /// 本应用交给安装器。仅 Windows 且检查到带安装包的新版本时可用。
  Future<void> downloadAndInstall() async {
    final url = _installerUrl;
    final version = _latestVersion;
    if (url == null || version == null) {
      throw StateError('没有可用的 Windows 安装包');
    }
    downloadProgress.value = 0;
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}${Platform.pathSeparator}aquan-windows-x64-$version-setup.exe');
    final snapshot = await _health.load();
    final candidates = <_DownloadSource>[
      _DownloadSource(url: url, label: '官方'),
      for (final mirror in builtInUpdateMirrors)
        if (!snapshot.isCoolingDown(mirror.id))
          if (mirror.resolve(url) case final mirrored?)
            _DownloadSource(
              url: mirrored,
              label: '镜像 ${mirror.label}',
              mirrorId: mirror.id,
            ),
    ];

    Object? lastError;
    var downloaded = false;
    for (final candidate in candidates) {
      try {
        await _downloadTo(candidate.url, file);
        downloaded = true;
        _downloadSourceLabel = candidate.label;
        await _health.recordDownloadSuccess(candidate.mirrorId);
        break;
      } catch (e) {
        lastError = e;
        if (candidate.mirrorId != null) {
          await _health.recordDownloadFailure(candidate.mirrorId!);
        }
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
    if (!downloaded) {
      downloadProgress.value = null;
      throw Exception('安装包下载失败：${lastError ?? '未知错误'}');
    }

    // SHA-256 校验（Release 提供 .sha256 时；官方优先，镜像兜底）。
    final expected = await _fetchExpectedSha(_installerShaUrl, snapshot);
    if (expected != null) {
      final actual = await _sha256OfFile(file);
      if (actual.toLowerCase() != expected.toLowerCase()) {
        try {
          await file.delete();
        } catch (_) {}
        downloadProgress.value = null;
        throw Exception('安装包校验失败（SHA-256 不匹配），已删除下载文件');
      }
    }
    downloadProgress.value = null;

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
    _sourceLabel = null;
    notifyListeners();
    try {
      final info = await PackageInfo.fromPlatform();
      final snapshot = await _health.load();
      final candidates = <_CheckSource>[
        const _CheckSource(url: _apiUrl, label: '官方'),
        for (final mirror in builtInUpdateMirrors)
          if (mirror.proxiesApi && !snapshot.isCoolingDown(mirror.id))
            if (mirror.resolveApi(_apiUrl) case final mirrored?)
              _CheckSource(
                url: mirrored,
                label: '镜像 ${mirror.label}',
                mirrorId: mirror.id,
              ),
      ];

      Map<String, dynamic>? json;
      Object? lastError;
      for (final candidate in candidates) {
        try {
          final body = await _getString(candidate.url);
          final decoded = jsonDecode(body);
          if (decoded is! Map<String, dynamic>) {
            throw const FormatException('响应不是 JSON 对象');
          }
          json = decoded;
          _sourceLabel = candidate.label;
          if (candidate.mirrorId != null) {
            await _health.recordCheckSuccess(candidate.mirrorId!);
          }
          break;
        } catch (e) {
          lastError = e;
          if (candidate.mirrorId != null) {
            await _health.recordCheckFailure(candidate.mirrorId!);
          }
        }
      }
      if (json == null) {
        throw Exception(lastError ?? '所有更新源均不可用');
      }

      final tag = json['tag_name'] as String? ?? '';
      final latest = tag.startsWith('v') ? tag.substring(1) : tag;
      final current = info.version;
      if (isVersionNewer(latest, current)) {
        _latestVersion = latest;
        _releaseUrl = json['html_url'] as String? ?? _releasesUrl;
        final installer = _findWindowsInstaller(json['assets']);
        _installerUrl = installer?.url;
        _installerShaUrl = installer?.shaUrl;
      } else {
        _latestVersion = null;
        _releaseUrl = null;
        _installerUrl = null;
        _installerShaUrl = null;
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

  Future<String> _getString(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'aquan-duanju');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _downloadTo(String url, File target) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    final part = File('${target.path}.part');
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'aquan-duanju');
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw HttpException('下载返回 ${response.statusCode}');
      }
      final total = response.contentLength;
      final sink = part.openWrite();
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
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
    } catch (_) {
      downloadProgress.value = null;
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// 读取 `.sha256` 资产（官方优先，镜像兜底）；拿不到返回 null。
  Future<String?> _fetchExpectedSha(
      String? shaUrl, MirrorHealthSnapshot snapshot) async {
    if (shaUrl == null || shaUrl.isEmpty) return null;
    final candidates = <String>[
      shaUrl,
      for (final mirror in builtInUpdateMirrors)
        if (!snapshot.isCoolingDown(mirror.id)) ?mirror.resolve(shaUrl),
    ];
    for (final url in candidates) {
      try {
        final body = await _getString(url);
        final match = RegExp(r'\b([0-9a-fA-F]{64})\b').firstMatch(body);
        if (match != null) return match.group(1);
      } catch (_) {
        // 换下一个源。
      }
    }
    return null;
  }

  Future<String> _sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
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

class _CheckSource {
  const _CheckSource({required this.url, required this.label, this.mirrorId});

  final String url;
  final String label;
  final String? mirrorId;
}

class _DownloadSource {
  const _DownloadSource({required this.url, required this.label, this.mirrorId});

  final String url;
  final String label;
  final String? mirrorId;
}
