import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/ops_switches.dart';
import '../store/stores.dart';
import 'update_downloader.dart';
import 'update_errors.dart';
import 'update_manifest.dart';
import 'update_mirror_health.dart';
import 'update_mirror_probe.dart';
import 'update_mirrors.dart';

/// 后台更新的生命周期。
enum UpdateDownloadPhase {
  /// 没有进行中的更新任务。
  idle,

  /// 正在后台下载安装包。
  downloading,

  /// 下载完成，正在做 SHA-256 校验。
  verifying,

  /// 已下载并校验通过，等待安装（关闭自动安装时停在这里）。
  ready,

  /// 已调起安装器。
  installing,

  /// 下载/校验/安装失败，可重试。
  failed,
}

/// 应用内更新：清单（`update.json`）优先，GitHub Releases API 兜底。
///
/// 链路：
/// 1. 清单候选 = 用户配置地址（英文逗号分隔）或内置默认 → 逐个尝试，镜像
///    仅在健康、可代理该地址且**探测可连通**时加入；`ETag` 命中 304 时复用上次 payload。
/// 2. 清单不可达 → 退回 GitHub Releases API（老路径，保证始终有兜底）。
/// 3. 下载 = 清单给的资产地址顺序 → 镜像兜底；`.part` + `Range` 断点续传，
///    单源失败退避重试；校验不过删文件换下一个源（不中止，多镜像自救）。
/// 4. 安装 = Android 先做包名/签名预检与未知来源授权，再调系统安装器；
///    Windows 静默安装后由安装器自动拉起新版本；其它平台跳发布页。
class UpdateService extends ChangeNotifier {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  static const _releasesUrl =
      'https://github.com/wjsqqj/aquan-duanju/releases';
  static const _apiUrl =
      'https://api.github.com/repos/wjsqqj/aquan-duanju/releases/latest';

  /// 默认清单：Release 资产。
  ///
  /// 2026-11-11 实测去掉了原来的第二个候选
  /// `raw.githubusercontent.com/.../main/update.json`：仓库里根本没有 `update.json`
  /// （只有 `update.example.json`），该地址经镜像取到的是 GitHub 的 404，
  /// 每次检查都白跑一个源。
  static const List<String> _defaultManifestUrls = <String>[
    'https://github.com/wjsqqj/aquan-duanju/releases/latest/download/update.json',
  ];

  /// 自动检查节流窗口：手动检查不受限，且同样刷新时间戳。
  static const Duration quietCheckInterval = Duration(hours: 24);

  /// 单个源的重试退避（首次失败后依次等待）。
  static const List<Duration> _retryDelays = <Duration>[
    Duration(milliseconds: 1500),
    Duration(seconds: 4),
  ];

  /// 只对「快速失败」重试：连接超时本身就要十几秒，再重试只会把弱网下的
  /// 总耗时翻倍（5 个镜像 × 3 次 × 30s 是不可接受的）。
  static const Duration _fastFailureWindow = Duration(seconds: 8);

  static const MethodChannel _channel = MethodChannel('aquan/update');

  SettingsStore? _settings;

  bool _checking = false;
  bool _mandatory = false;

  /// 本次结果来自「上次成功获取的清单」（在线源全部不可用时的兜底）。
  bool _manifestStale = false;
  String? _latestVersion;
  String? _releaseUrl;
  String? _error;
  String? _sourceLabel;
  String? _downloadSourceLabel;
  String? _changelog;

  /// 清单里当前平台的安装包候选；API 兜底时只有一条。
  List<String> _assetUrls = const <String>[];
  String? _expectedSha;
  String? _installerShaUrl;
  String _expectedShaLabel = '';

  /// 按清单地址缓存 ETag 与解析结果（内存态；重启重新取）。
  final Map<String, _ManifestCacheEntry> _manifestCache =
      <String, _ManifestCacheEntry>{};

  final UpdateMirrorHealthStore _health = UpdateMirrorHealthStore();
  final UpdateMirrorProbe _probe = UpdateMirrorProbe();

  /// 安装器结果的等待者：调起安装器后由 update_flow 短暂等待。
  Completer<UpdateInstallException?>? _installOutcome;

  /// 安装轮次 token：Kotlin 侧回传，用来丢弃上一轮迟到的安装结果。
  int _installToken = 0;

  bool _installHandlerInstalled = false;
  String? _ownPackageName;
  Set<String>? _ownSigners;

  bool get checking => _checking;
  bool get hasUpdate => _latestVersion != null;

  /// 本次更新是否强制（弹窗不可取消、不可跳过）。
  bool get mandatory => _mandatory;

  /// 清单是否来自离线兜底（可能不是最新）。
  bool get manifestStale => _manifestStale;

  String? get latestVersion => _latestVersion;
  String? get error => _error;
  String? get changelog => _changelog;

  /// 本次检查实际使用的源（「官方清单」/「自定义」/「镜像 gh-proxy.com」/「GitHub API」）。
  String? get sourceLabel => _sourceLabel;

  /// 本次下载实际使用的源。
  String? get downloadSourceLabel => _downloadSourceLabel;

  /// 是否有可在应用内安装的包（Windows/Android 且清单给出资产）。
  bool get canInstallInApp =>
      hasUpdate &&
      _assetUrls.isNotEmpty &&
      (Platform.isWindows || Platform.isAndroid);

  /// 兼容旧入口：Windows 安装包直链是否存在。
  String? get windowsInstallerUrl =>
      Platform.isWindows && _assetUrls.isNotEmpty ? _assetUrls.first : null;

  /// 下载进度（0-1）；不在下载中时为 null。
  final ValueNotifier<double?> downloadProgress = ValueNotifier<double?>(null);

  UpdateDownloadPhase _phase = UpdateDownloadPhase.idle;
  int _downloadedBytes = 0;
  int _totalBytes = 0;
  double _downloadSpeedBps = 0;
  String? _downloadError;
  File? _downloadedFile;
  bool _cancelRequested = false;

  final UpdateDownloader _downloader = UpdateDownloader();

  UpdateDownloadPhase get downloadPhase => _phase;

  /// 下载或校验中（UI 用这个禁用重复操作）。
  bool get isDownloading =>
      _phase == UpdateDownloadPhase.downloading ||
      _phase == UpdateDownloadPhase.verifying;

  int get downloadedBytes => _downloadedBytes;

  /// 安装包总字节；0 表示服务端没给。
  int get totalBytes => _totalBytes;

  /// 实时速度（B/s）。
  double get downloadSpeedBps => _downloadSpeedBps;

  String? get downloadError => _downloadError;

  /// 是否已下载完成、等安装。
  bool get updateReady => _phase == UpdateDownloadPhase.ready;

  /// 下载完成后是否自动安装：强制更新忽略设置。
  @visibleForTesting
  static bool shouldAutoInstall({
    required UpdateDownloadPhase phase,
    required bool mandatory,
    required bool settingEnabled,
  }) =>
      phase == UpdateDownloadPhase.ready && (mandatory || settingEnabled);

  /// 绑定设置（更新源地址）。在应用启动完成后调用。
  void attachSettings(SettingsStore settings) {
    _settings = settings;
    _installInstallResultHandler();
  }

  /// 用户改了更新源地址：丢掉 ETag 缓存与镜像探测结果，下次检查重新取。
  void resetManifestCache() {
    _manifestCache.clear();
    _probe.invalidate();
    _error = null;
    notifyListeners();
  }

  Future<void> checkQuietly() => _check(manual: false);

  Future<void> checkManually() => _check(manual: true);

  bool get _throttled {
    final last = _settings?.lastUpdateCheckAt ?? 0;
    if (last <= 0) return false;
    final elapsed = DateTime.now().millisecondsSinceEpoch - last;
    return elapsed >= 0 && elapsed < quietCheckInterval.inMilliseconds;
  }

  Future<void> _check({required bool manual}) async {
    // 运维急停只拦自动检查；用户手动点仍然放行（否则没法自救）。
    if (!manual && OpsSwitches.disableAutoUpdate) return;
    if (_checking) return;
    // 后台下载/待安装期间不重新检查：新一轮清单会把目标版本和资产地址覆盖掉。
    if (_phase != UpdateDownloadPhase.idle &&
        _phase != UpdateDownloadPhase.failed) {
      return;
    }
    // 24h 节流只约束自动检查：启动一次查一次会让 GitHub 侧无谓限流。
    if (!manual && _throttled) return;
    _checking = true;
    _error = null;
    _sourceLabel = null;
    notifyListeners();
    try {
      final info = await PackageInfo.fromPlatform();
      final baseCode =
          Platform.isAndroid ? baseCodeFromBuildNumber(info.buildNumber) : 0;
      final snapshot = await _health.load();
      final platform = UpdateManifest.currentPlatformKey();

      final manifest = await _fetchFirstManifest(snapshot, platform);
      if (manifest != null) {
        await _persistManifest(manifest);
        _applyManifest(
          manifest,
          info.version,
          platform,
          baseCode: baseCode,
          manual: manual,
        );
        _settings?.lastUpdateCheckAt = DateTime.now().millisecondsSinceEpoch;
        return;
      }

      // 清单完全不可达：退回 GitHub Releases API。
      try {
        await _checkViaApi(info.version, snapshot);
        _settings?.lastUpdateCheckAt = DateTime.now().millisecondsSinceEpoch;
        return;
      } catch (_) {
        // 兜底：所有在线源都不可用时，用上次成功获取的清单。
        // 日常设备没有代理，GitHub 时常打不开；宁可提示一个可能略旧的版本，
        // 也不要让用户以为"没有更新"。
        final cached = await _loadPersistedManifest();
        if (cached == null) rethrow;
        _manifestStale = true;
        _applyManifest(
          cached,
          info.version,
          platform,
          baseCode: baseCode,
          manual: manual,
        );
        _sourceLabel = '上次成功清单（离线）';
        _error = null;
        return;
      }
    } catch (e) {
      _error = e.toString();
      if (!manual) _error = null;
      _clearUpdate();
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  /// 从设备 versionCode 还原 base 值；还原不了返回 0（此时禁用构建号兜底）。
  ///
  /// `flutter build apk --split-per-abi` 会把 versionCode 写成
  /// `1000 * abiVersion + base`，base < 1000 时取余即可还原。base 涨到 1000
  /// 以上后取余不可靠，`% 1000 == 0` 一律当作"无法还原"而不是硬算，
  /// 以免出现"版本号相同却永远提示有更新"。
  @visibleForTesting
  static int baseCodeFromBuildNumber(String buildNumber) {
    final code = int.tryParse(buildNumber.trim()) ?? 0;
    if (code <= 0) return 0;
    if (code < 1000) return code;
    final base = code % 1000;
    return base == 0 ? 0 : base;
  }

  void _applyManifest(
    UpdateManifest manifest,
    String currentVersion,
    String platform, {
    required int baseCode,
    required bool manual,
  }) {
    if (!manifest.isNewerThanWithCode(currentVersion, currentBaseCode: baseCode)) {
      _clearUpdate();
      return;
    }
    final mandatory = manifest.isMandatory(currentVersion, currentBaseCode: baseCode);
    // 用户跳过过的版本：自动检查不再打扰；手动检查照旧提示；强制更新压过跳过。
    if (!manual &&
        !mandatory &&
        isSkippedVersion(
          manifest.version,
          _settings?.skippedUpdateVersion ?? '',
        )) {
      _clearUpdate();
      return;
    }
    _mandatory = mandatory;
    _latestVersion = manifest.version;
    _changelog = manifest.changelog;
    _releaseUrl =
        'https://github.com/wjsqqj/aquan-duanju/releases/tag/v${manifest.version}';
    _assetUrls = manifest.assetUrlsFor(platform);
    _expectedSha = manifest.shaFor(platform);
    _installerShaUrl = null;
    _expectedShaLabel = _expectedSha == null ? '清单未提供摘要' : '清单 SHA-256';
  }

  /// 用户点「跳过此版本」：写入设置并清掉当前提示。
  Future<void> skipCurrentVersion() async {
    final version = _latestVersion;
    if (version == null) return;
    _settings?.skippedUpdateVersion = version;
    _clearUpdate();
    notifyListeners();
  }

  List<String> get _manifestBaseUrls {
    final configured = _settings?.updateUrlList ?? const <String>[];
    return configured.isEmpty ? _defaultManifestUrls : configured;
  }

  Future<UpdateManifest?> _fetchFirstManifest(
    MirrorHealthSnapshot snapshot,
    String platform,
  ) async {
    final urls = _manifestBaseUrls;
    if (urls.isEmpty) return null;
    final configured = _settings?.updateUrlList ?? const <String>[];
    final directLabel = configured.isEmpty ? '官方清单' : '自定义';

    for (final url in urls) {
      final targets = <UpdateDownloadSource>[
        UpdateDownloadSource(url: url, label: directLabel),
      ];
      for (final mirror in builtInUpdateMirrors) {
        if (snapshot.isCoolingDown(mirror.id)) continue;
        final mirrored = mirror.resolve(url);
        if (mirrored == null) continue;
        targets.add(UpdateDownloadSource(
          url: mirrored,
          label: '镜像 ${mirror.label}',
          mirrorId: mirror.id,
        ));
      }

      if (targets.length == 1) {
        // 用户配的是非 GitHub 地址（自建清单）：没有镜像能改写，直接试。
        final manifest = await _attemptManifest(targets.first);
        if (manifest != null) {
          _sourceLabel = targets.first.label;
          return manifest;
        }
        continue;
      }

      // 先测速再决定顺序：直连也参与，直连被墙时第一个试的就是最快的镜像。
      final probe = await _probe.probe(url, includeDirect: true);
      final ordered =
          orderByProbe(targets, probe, (s) => s.mirrorId ?? kDirectProbeId);

      for (final source in ordered) {
        final manifest = await _attemptManifest(source);
        if (manifest == null) {
          if (source.mirrorId != null) {
            await _health.recordCheckFailure(source.mirrorId!);
          }
          continue;
        }
        if (source.mirrorId != null) {
          // 镜像给的清单不可全信：只接受指向本仓库 Release 的安装包地址，
          // 否则等于让镜像决定"从哪下、下什么"。
          final assets = manifest.assetUrlsFor(platform);
          if (assets.isEmpty || !assets.every(isTrustedAssetUrl)) {
            await _health.recordCheckFailure(source.mirrorId!);
            continue;
          }
          await _health.recordCheckSuccess(source.mirrorId!);
        }
        _sourceLabel = source.label;
        return manifest;
      }
    }
    return null;
  }

  /// 安装包地址必须指向本仓库的 Release。
  ///
  /// 镜像可以代理清单，但不能替我们决定"从哪下、下什么"——否则一个不受控的
  /// 镜像就能把安装包换成自己的（Windows 侧还是静默安装）。
  @visibleForTesting
  static bool isTrustedAssetUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return false;
    if (uri.host.toLowerCase() != 'github.com') return false;
    return uri.path
        .toLowerCase()
        .startsWith('/wjsqqj/aquan-duanju/releases/');
  }

  /// 按探测结果重排镜像：可达的按延迟升序在前，未探测到/不可达的排在后面。
  ///
  /// **只排序、不丢弃**：探测是纯优化。任何"探测说不可用"都不足以把镜像从
  /// 候选里删掉，否则探测一抖动就会把镜像兜底整轮清空、直连被墙时更新直接不可用。
  @visibleForTesting
  static List<T> orderByProbe<T>(
    List<T> items,
    MirrorProbeResult? probe,
    String Function(T item) idOf,
  ) {
    if (probe == null || probe.isEmpty || items.length < 2) return items;
    final rank = <String, int>{
      for (var i = 0; i < probe.reachableIds.length; i++)
        probe.reachableIds[i]: i,
    };
    final ordered = List<T>.of(items);
    ordered.sort((a, b) {
      final left = rank[idOf(a)];
      final right = rank[idOf(b)];
      if (left == null && right == null) return 0;
      if (left == null) return 1;
      if (right == null) return -1;
      return left.compareTo(right);
    });
    return ordered;
  }

  // ---------------- 离线兜底：持久化上次成功清单 ----------------

  static const String _cachedManifestFileName = 'aquan_update_last_manifest.json';

  Future<File> _cachedManifestFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(
      '${dir.path}${Platform.pathSeparator}$_cachedManifestFileName',
    );
  }

  Future<void> _persistManifest(UpdateManifest manifest) async {
    try {
      final file = await _cachedManifestFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(<String, dynamic>{
          'savedAt': DateTime.now().millisecondsSinceEpoch,
          'manifest': manifest.toJson(),
        }),
        flush: true,
      );
    } catch (_) {
      // 缓存写失败不影响本次检查。
    }
  }

  Future<UpdateManifest?> _loadPersistedManifest() async {
    try {
      final file = await _cachedManifestFile();
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;
      final decoded = jsonDecode(content);
      if (decoded is! Map) return null;
      final raw = decoded['manifest'];
      if (raw is! Map) return null;
      return UpdateManifest.parse(jsonEncode(raw));
    } catch (_) {
      return null;
    }
  }

  /// 单个源的清单请求：网络异常按 [_retryDelays] 退避重试，
  /// 内容无效（非 200 / 解析失败）直接放弃——重试同一份坏内容没有意义。
  Future<UpdateManifest?> _attemptManifest(UpdateDownloadSource source) async {
    for (var attempt = 0; attempt <= _retryDelays.length; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(_retryDelays[attempt - 1]);
      }
      final stopwatch = Stopwatch()..start();
      try {
        return await _fetchManifest(source);
      } catch (_) {
        // 网络抖动：快速失败才值得重试；超时说明链路本身不通，直接换源。
        if (stopwatch.elapsed >= _fastFailureWindow) return null;
      }
    }
    return null;
  }

  Future<UpdateManifest?> _fetchManifest(UpdateDownloadSource source) async {
    final cached = _manifestCache[source.url];
    final response = await _get(source.url, etag: cached?.etag);
    if (response.statusCode == HttpStatus.notModified && cached != null) {
      return cached.manifest;
    }
    if (response.statusCode != HttpStatus.ok) return null;
    final manifest = UpdateManifest.parse(response.body);
    if (manifest == null) return null;
    _manifestCache[source.url] = _ManifestCacheEntry(
      etag: response.etag,
      manifest: manifest,
    );
    return manifest;
  }

  /// GitHub Releases API 兜底（原路径）。
  Future<void> _checkViaApi(
    String currentVersion,
    MirrorHealthSnapshot snapshot,
  ) async {
    final candidates = <UpdateDownloadSource>[
      const UpdateDownloadSource(url: _apiUrl, label: 'GitHub API'),
      for (final mirror in builtInUpdateMirrors)
        if (mirror.proxiesApi && !snapshot.isCoolingDown(mirror.id))
          if (mirror.resolveApi(_apiUrl) case final mirrored?)
            UpdateDownloadSource(
              url: mirrored,
              label: '镜像 ${mirror.label}（API）',
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
    if (UpdateManifest.compareVersions(latest, currentVersion) <= 0) {
      _clearUpdate();
      return;
    }
    final asset = _findInstaller(json['assets']);
    _mandatory = false;
    _latestVersion = latest;
    _changelog = (json['body'] as String? ?? '').trim();
    _releaseUrl = json['html_url'] as String? ?? _releasesUrl;
    _assetUrls = asset?.urls ?? const <String>[];
    _expectedSha = null;
    _installerShaUrl = asset?.shaUrl;
    _expectedShaLabel = asset?.shaUrl == null ? '未校验' : 'Release SHA-256';
  }

  /// 从 Release assets 里找当前平台的安装包。
  static _ReleaseAsset? _findInstaller(dynamic assets) {
    if (assets is! List) return null;
    final patterns = Platform.isWindows
        ? <bool Function(String)>[
            (name) =>
                name.startsWith('aquan-windows-x64-') &&
                name.endsWith('-setup.exe'),
          ]
        : <bool Function(String)>[
            (name) => name == _androidAssetName(),
            (name) => name.startsWith('aquan-') && name.endsWith('.apk'),
          ];
    for (final pattern in patterns) {
      for (final asset in assets) {
        if (asset is! Map<String, dynamic>) continue;
        final name = asset['name'] as String? ?? '';
        final url = asset['browser_download_url'] as String?;
        if (!pattern(name) || url == null) continue;
        // API 也可能经镜像代理：只接受指向本仓库 Release 的地址。
        if (!isTrustedAssetUrl(url)) continue;
        String? shaUrl;
        for (final other in assets) {
          if (other is! Map<String, dynamic>) continue;
          if (other['name'] == '$name.sha256') {
            shaUrl = other['browser_download_url'] as String?;
            break;
          }
        }
        return _ReleaseAsset(urls: <String>[url], shaUrl: shaUrl);
      }
    }
    return null;
  }

  static String _androidAssetName() {
    final abi = UpdateManifest.currentPlatformKey();
    return switch (abi) {
      'android-armeabi-v7a' => 'aquan-armeabi-v7a.apk',
      'android-x86_64' => 'aquan-x86_64.apk',
      _ => 'aquan-arm64-v8a.apk',
    };
  }

  void _clearUpdate() {
    // 后台下载/待安装期间不能被一次"检查失败"清空，否则安装时会丢失目标版本。
    if (_phase != UpdateDownloadPhase.idle &&
        _phase != UpdateDownloadPhase.failed) {
      return;
    }
    _mandatory = false;
    _manifestStale = false;
    _latestVersion = null;
    _releaseUrl = null;
    _assetUrls = const <String>[];
    _expectedSha = null;
    _installerShaUrl = null;
    _changelog = null;
  }

  /// 开始后台下载（幂等）。
  ///
  /// 已有任务在跑时直接返回；已下载完成时等价于「立即安装」。
  /// 失败不会抛给调用方——后台任务的结果通过 [downloadPhase] /
  /// [downloadError] 暴露，UI 据此显示重试入口。
  Future<void> startBackgroundDownload() async {
    switch (_phase) {
      case UpdateDownloadPhase.downloading:
      case UpdateDownloadPhase.verifying:
      case UpdateDownloadPhase.installing:
        return;
      case UpdateDownloadPhase.ready:
        await installDownloaded();
        return;
      case UpdateDownloadPhase.idle:
      case UpdateDownloadPhase.failed:
        break;
    }

    final version = _latestVersion;
    if (version == null) throw StateError('没有可用的更新包');
    if (!canInstallInApp) throw StateError('当前平台没有可安装的更新包');

    _downloadError = null;
    _downloadedBytes = 0;
    _totalBytes = 0;
    _downloadSpeedBps = 0;
    _cancelRequested = false;
    _phase = UpdateDownloadPhase.downloading;
    downloadProgress.value = 0;
    notifyListeners();

    await _runDownload(version);
  }

  Future<void> _runDownload(String version) async {
    var verifyFailures = 0;
    try {
      final dir = await getTemporaryDirectory();
      await _cleanupOldPackages(dir);
      final extension = Platform.isAndroid ? 'apk' : 'exe';
      final target = File(
          '${dir.path}${Platform.pathSeparator}aquan-update-$version.$extension');
      _downloadedFile = target;

      final snapshot = await _health.load();
      final sources = await _downloadSources(snapshot);
      final expected =
          _expectedSha ?? await _fetchExpectedSha(_installerShaUrl);
      if (sources.isEmpty) {
        throw const UpdateDownloadException('没有可用的下载源');
      }

      // 兜底：上次已经下完但安装被取消/失败时，直接复用，不重新下载。
      // 对没有代理的设备来说，重下一次几十兆的安装包代价很高。
      if (expected != null && await target.exists()) {
        try {
          final existing = await _sha256OfFile(target);
          if (existing.toLowerCase() == expected.toLowerCase()) {
            _downloadSourceLabel = '上次下载的安装包';
            _downloadedBytes = await target.length();
            _totalBytes = _downloadedBytes;
            await _markReadyAndMaybeInstall(target);
            return;
          }
        } catch (_) {
          // 读不动就走正常下载。
        }
        await _safeDelete(target);
      }

      _downloadSourceLabel = null;
      final result = await _downloader.download(
        sources: sources,
        target: target,
        onProgress: _onDownloadProgress,
        isCancelled: () => _cancelRequested,
        validate: (file) async {
          if (expected == null) return true;
          final ok =
              (await _sha256OfFile(file)).toLowerCase() == expected.toLowerCase();
          if (!ok) verifyFailures++;
          return ok;
        },
        onSourceFailure: (source, error) {
          final id = source.mirrorId;
          if (id != null) {
            unawaited(_health.recordDownloadFailure(id));
          }
        },
      );

      _downloadSourceLabel = result.source.label;
      _downloadedBytes = result.bytes;
      _totalBytes = result.bytes;
      _downloadSpeedBps = 0;
      _phase = UpdateDownloadPhase.verifying;
      notifyListeners();

      final id = result.source.mirrorId;
      if (id != null) {
        await _health.recordDownloadSuccess(id);
      }
      await _markReadyAndMaybeInstall(target);
    } on DownloadCancelled {
      _resetDownloadState();
    } on UpdateInstallException catch (error) {
      _failDownload(error);
    } on UpdateDownloadException catch (error) {
      final kind = downloadFailureKind(verifyFailures);
      _failDownload(UpdateInstallException(
        kind,
        updateFailureMessage(kind),
        detail: error.cause?.toString() ?? error.message,
      ));
    } catch (error) {
      _failDownload(UpdateInstallException(
        UpdateFailureKind.network,
        updateFailureMessage(UpdateFailureKind.network),
        detail: error.toString(),
      ));
    }
  }

  void _onDownloadProgress(DownloadProgress progress) {
    _downloadedBytes = progress.received;
    _totalBytes = progress.total;
    _downloadSpeedBps = progress.bytesPerSecond;
    downloadProgress.value = progress.fraction;
    notifyListeners();
  }

  Future<void> _markReadyAndMaybeInstall(File target) async {
    // 校验期间点了取消：不要继续安装。包留在临时目录，下次可复用。
    if (_cancelRequested) {
      _resetDownloadState();
      return;
    }
    _downloadedFile = target;
    _phase = UpdateDownloadPhase.ready;
    downloadProgress.value = null;
    _downloadSpeedBps = 0;
    notifyListeners();
    if (shouldAutoInstall(
      phase: _phase,
      mandatory: _mandatory,
      settingEnabled: _settings?.autoInstallUpdate ?? true,
    )) {
      await installDownloaded();
    }
  }

  void _failDownload(UpdateInstallException error) {
    _phase = UpdateDownloadPhase.failed;
    _downloadError = error.message;
    _downloadSpeedBps = 0;
    downloadProgress.value = null;
    notifyListeners();
  }

  void _resetDownloadState() {
    _phase = UpdateDownloadPhase.idle;
    _cancelRequested = false;
    _downloadSpeedBps = 0;
    _downloadedBytes = 0;
    _totalBytes = 0;
    downloadProgress.value = null;
    _downloadedFile = null;
    _downloadError = null;
    notifyListeners();
  }

  /// 取消后台下载（强制更新不可取消）。保留分片供下次续传。
  void cancelDownload() {
    if (_mandatory) return;
    if (_phase != UpdateDownloadPhase.downloading &&
        _phase != UpdateDownloadPhase.verifying) {
      return;
    }
    _cancelRequested = true;
    // 看门狗最多 200ms 内会读到取消标记并断开连接。
    notifyListeners();
  }

  /// 安装已下载的包（后台自动安装关闭时由用户点击）。
  Future<void> installDownloaded() async {
    final file = _downloadedFile;
    if (file == null || !await file.exists()) {
      _resetDownloadState();
      throw UpdateInstallException(
        UpdateFailureKind.network,
        '安装包已不存在，请重新下载更新。',
      );
    }
    try {
      await _install(file);
    } on UpdateInstallException catch (error) {
      _failDownload(error);
      rethrow;
    }
  }

  /// 兼容旧入口：启动后台下载并等待本轮结束（下载 + 自动安装的调起）。
  Future<void> downloadAndInstall() async {
    await startBackgroundDownload();
  }

  /// 下载候选：直连 + 镜像，按**安装包地址**实测吞吐排序。
  ///
  /// 用资产地址而不是清单地址去测速：代理对 release 资产与大文件的支持常常
  /// 不一致（有的能取清单但下不动安装包），只有对真实资产测过才算数。
  Future<List<UpdateDownloadSource>> _downloadSources(
    MirrorHealthSnapshot snapshot,
  ) async {
    final out = <UpdateDownloadSource>[];
    if (_assetUrls.isEmpty) return out;
    final probe = await _probe.probe(_assetUrls.first, includeDirect: true);
    for (final url in _assetUrls) {
      final targets = <UpdateDownloadSource>[
        UpdateDownloadSource(url: url, label: '官方'),
      ];
      for (final mirror in builtInUpdateMirrors) {
        if (snapshot.isCoolingDown(mirror.id)) continue;
        final mirrored = mirror.resolve(url);
        if (mirrored == null) continue;
        targets.add(UpdateDownloadSource(
          url: mirrored,
          label: '镜像 ${mirror.label}',
          mirrorId: mirror.id,
        ));
      }
      // 上次下载成功的源优先：健康记录比一次测速更能代表真实吞吐。
      final lastGood = snapshot.lastGoodDownloadSource;
      final ordered = orderByProbe(
        targets,
        probe,
        (s) => s.mirrorId ?? kDirectProbeId,
      );
      if (lastGood != null) {
        final index = ordered.indexWhere((s) => s.mirrorId == lastGood);
        if (index > 0) {
          final preferred = ordered.removeAt(index);
          ordered.insert(0, preferred);
        }
      }
      out.addAll(ordered);
    }
    return out;
  }

  Future<void> _install(File file) async {
    _phase = UpdateDownloadPhase.installing;
    notifyListeners();
    if (Platform.isWindows) {
      await _installWindows(file);
      return;
    }
    if (Platform.isAndroid) {
      await _installAndroid(file);
      // 已交给系统安装器：回到 idle，用户在安装器里取消后还能再试。
      _phase = UpdateDownloadPhase.idle;
      notifyListeners();
      // 系统安装器的结果异步回来；取不到结果（多数机型）就当作已交给系统处理。
      final failure = await waitInstallOutcome(const Duration(seconds: 90));
      if (failure == null ||
          failure.kind == UpdateFailureKind.userCancelled) {
        return;
      }
      _failDownload(failure);
      return;
    }
    await openReleasePage();
  }

  /// Windows：校验 PE 头 → 静默安装 → 确认安装器还活着才退出。
  ///
  /// 旧实现启动安装器后固定 800ms 就 `exit(0)`：安装器被 AV 拦下/启动失败时，
  /// 应用已经退出，用户只看到"更新后打不开"。现在安装器提前退出就不退应用，
  /// 把错误显示在状态卡片里。
  Future<void> _installWindows(File file) async {
    if (!await file.exists() || await file.length() < 1024) {
      throw UpdateInstallException(
        UpdateFailureKind.installFailed,
        '安装包不完整，请在「我的」页重新下载更新。',
      );
    }

    // 镜像返回 HTML 落地页时不能拿去执行（SHA 缺失时这是最后一道闸）。
    RandomAccessFile? reader;
    try {
      reader = await file.open();
      final header = await reader.read(2);
      if (header.length < 2 || header[0] != 0x4D || header[1] != 0x5A) {
        await _safeDelete(file);
        _downloadedFile = null;
        throw UpdateInstallException(
          UpdateFailureKind.installFailed,
          '安装包格式不正确，请在「我的」页重新下载更新。',
        );
      }
    } finally {
      await reader?.close();
    }

    final process = await Process.start(
      file.path,
      const ['/SILENT', '/FORCECLOSEAPPLICATIONS', '/NORESTART'],
      mode: ProcessStartMode.detached,
    );

    // -1 = 3 秒内没退出（正常，安装器正在解包）；其它值 = 提前退出。
    var earlyExit = -1;
    try {
      earlyExit = await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () => -1,
      );
    } catch (_) {
      earlyExit = -1;
    }
    if (earlyExit != -1) {
      throw UpdateInstallException(
        UpdateFailureKind.installFailed,
        '安装程序未能启动（可能被安全软件拦截），请在「我的」页重试或去发布页手动下载。',
        detail: '安装器退出码 $earlyExit',
      );
    }

    // 给安装器一点时间接管窗口，然后退出（装完由 aquan.iss 自动拉起新版本）。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    exit(0);
  }

  /// Android：预检 → 授权 → 调起系统安装器。
  ///
  /// 三步的顺序不能换：签名不一致时先跳授权/安装器只是让用户白跑一趟。
  Future<void> _installAndroid(File file) async {
    await _precheckApk(file);
    await _ensureInstallPermission();

    _installOutcome = Completer<UpdateInstallException?>();
    _installToken = 0;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'installApk',
        <String, dynamic>{'path': file.path},
      );
      if (result?['launched'] != true) {
        throw UpdateInstallException(
          UpdateFailureKind.installFailed,
          updateFailureMessage(UpdateFailureKind.installFailed),
          detail: result?['code']?.toString(),
        );
      }
      final token = result?['token'];
      _installToken = token is int ? token : 0;
    } on PlatformException catch (e) {
      throw UpdateInstallException(
        UpdateFailureKind.installFailed,
        updateFailureMessage(UpdateFailureKind.installFailed),
        detail: '${e.code}: ${e.message}',
      );
    } on MissingPluginException {
      throw UpdateInstallException(
        UpdateFailureKind.installFailed,
        '当前版本不支持应用内安装，请到发布页手动下载。',
      );
    }
  }

  /// 包名 + 签名预检。任何一步取不到数据都不阻断安装（预检不能成为新的失败点）。
  Future<void> _precheckApk(File file) async {
    Map<String, dynamic>? info;
    try {
      info = await _channel.invokeMapMethod<String, dynamic>(
        'inspectApk',
        <String, dynamic>{'path': file.path},
      );
    } catch (_) {
      return;
    }
    if (info == null) return;
    final error = info['error'];
    if (error is String && error.isNotEmpty) return;

    final expectedPackage = await _ownPackage();
    final actualPackage = info['packageName'] as String?;
    if (expectedPackage != null &&
        actualPackage != null &&
        actualPackage != expectedPackage) {
      await _safeDelete(file);
      throw UpdateInstallException(
        UpdateFailureKind.packageMismatch,
        updateFailureMessage(UpdateFailureKind.packageMismatch),
        detail: '包名 $actualPackage',
      );
    }

    final signers = (info['signers'] as List?)
            ?.whereType<String>()
            .where((s) => s.isNotEmpty)
            .toSet() ??
        const <String>{};
    if (signers.isEmpty) return;
    final current = await _ownSignerDigests();
    if (current.isEmpty) return;
    if (current.intersection(signers).isEmpty) {
      await _safeDelete(file);
      throw UpdateInstallException(
        UpdateFailureKind.signatureMismatch,
        updateFailureMessage(UpdateFailureKind.signatureMismatch),
        detail: 'APK 签名 ${signers.first}',
      );
    }
  }

  Future<void> _ensureInstallPermission() async {
    bool allowed;
    try {
      allowed = await _channel.invokeMethod<bool>('canInstallPackages') ?? true;
    } catch (_) {
      return;
    }
    if (allowed) return;
    bool granted = false;
    try {
      granted =
          await _channel.invokeMethod<bool>('requestInstallPermission') ?? false;
    } catch (_) {
      return;
    }
    if (granted) return;
    throw UpdateInstallException(
      UpdateFailureKind.permissionDenied,
      updateFailureMessage(UpdateFailureKind.permissionDenied),
    );
  }

  Future<String?> _ownPackage() async {
    if (_ownPackageName != null) return _ownPackageName;
    try {
      final info = await PackageInfo.fromPlatform();
      _ownPackageName = info.packageName;
      return _ownPackageName;
    } catch (_) {
      return null;
    }
  }

  Future<Set<String>> _ownSignerDigests() async {
    final cached = _ownSigners;
    if (cached != null) return cached;
    try {
      final list = await _channel.invokeListMethod<String>('currentSignature');
      final out = <String>{
        ...?(list?.where((s) => s.isNotEmpty)),
      };
      // 读不到就別缓存：一次通道失败不该让本进程后续的签名预检永久失效。
      if (out.isNotEmpty) _ownSigners = out;
      return out;
    } catch (_) {
      return const <String>{};
    }
  }

  /// 等待安装器结果（可被用户取消 / 签名冲突等）。
  ///
  /// 超时返回 null：多数机型的安装器不返回结果，或安装成功后本进程已被替换，
  /// 这种情况不能当作失败。
  Future<UpdateInstallException?> waitInstallOutcome(Duration timeout) async {
    final completer = _installOutcome;
    if (completer == null) return null;
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }

  void _installInstallResultHandler() {
    if (_installHandlerInstalled || !Platform.isAndroid) return;
    _installHandlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'installResult') return null;
      final args = call.arguments;
      if (args is! Map) return null;
      // 上一轮安装的迟到回调不能用来给这一轮定性。
      final token = args['token'];
      if (token is int && token != _installToken) return null;
      final code = args['code']?.toString() ?? 'unknown';
      final message = args['message']?.toString();
      final failure = _failureForInstallCode(code, message);
      final completer = _installOutcome;
      if (completer != null && !completer.isCompleted) {
        completer.complete(failure);
      }
      return null;
    });
  }

  /// 安装器状态码 → 失败类型；`unknown` / `success` / `pendingUserAction`
  /// 都不算失败（拿不到结果时不能凭空报错）。
  static UpdateInstallException? _failureForInstallCode(
    String code,
    String? message,
  ) {
    switch (code) {
      case 'aborted':
        return UpdateInstallException(
          UpdateFailureKind.userCancelled,
          updateFailureMessage(UpdateFailureKind.userCancelled),
          detail: message,
        );
      case 'conflict':
        return UpdateInstallException(
          UpdateFailureKind.signatureMismatch,
          updateFailureMessage(UpdateFailureKind.signatureMismatch),
          detail: message,
        );
      case 'incompatible':
        return UpdateInstallException(
          UpdateFailureKind.installFailed,
          '系统拒绝了本次安装：不允许降级或与已安装版本不兼容。请到发布页手动下载。',
          detail: message,
        );
      case 'blocked':
      case 'invalid':
      case 'storage':
      case 'failure':
        return UpdateInstallException(
          UpdateFailureKind.installFailed,
          updateFailureMessage(UpdateFailureKind.installFailed),
          detail: message ?? code,
        );
      default:
        return null;
    }
  }

  /// 打开发布页让用户手动下载。
  Future<void> openReleasePage() async {
    final url = Uri.parse(_releaseUrl ?? _releasesUrl);
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      // 没有浏览器等极端环境：忽略，用户可手动访问。
    }
  }

  // ---------------- HTTP ----------------

  Future<_HttpText> _get(String url, {String? etag}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'aquan-duanju');
      if (etag != null && etag.isNotEmpty) {
        request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      }
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode == HttpStatus.notModified) {
        await response.drain<void>();
        return _HttpText(response.statusCode, '', etag);
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return _HttpText(response.statusCode, '', null);
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 20));
      final newEtag = response.headers.value(HttpHeaders.etagHeader);
      return _HttpText(response.statusCode, body, newEtag);
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _getString(String url) async {
    final response = await _get(url);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    return response.body;
  }

  /// 读取 `.sha256` 资产（官方优先，镜像兜底）；拿不到返回 null。
  Future<String?> _fetchExpectedSha(String? shaUrl) async {
    if (shaUrl == null || shaUrl.isEmpty) return null;
    final snapshot = await _health.load();
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

  /// 清 7 天前的旧安装包（xiugou-tv 同策略：只删自己认识的文件）。
  Future<void> _cleanupOldPackages(Directory dir) async {
    try {
      final now = DateTime.now();
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last.toLowerCase();
        if (!name.startsWith('aquan-update-')) continue;
        try {
          final stat = await entity.stat();
          if (now.difference(stat.modified) < const Duration(days: 7)) {
            continue;
          }
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 语义化版本比较：latest 的主/次/补丁任一大于 current 即认为有更新。
  static bool isVersionNewer(String latest, String current) =>
      UpdateManifest.compareVersions(latest, current) > 0;

  /// 该版本是否已被用户「跳过此版本」。
  ///
  /// 只影响自动检查；强制更新压过跳过（是否强制由调用方先判断）。
  static bool isSkippedVersion(String candidate, String skippedVersion) {
    if (skippedVersion.isEmpty) return false;
    return UpdateManifest.compareVersions(candidate, skippedVersion) <= 0;
  }

  /// 全部源都失败时的错误分型：期间发生过校验失败就归为「校验失败」，
  /// 否则才是网络问题——两者对用户的下一步动作完全不同。
  static UpdateFailureKind downloadFailureKind(int verifyFailures) =>
      verifyFailures > 0
          ? UpdateFailureKind.checksumMismatch
          : UpdateFailureKind.network;

  /// 摘要来源说明（UI 展示「是否校验」）。
  String get integrityLabel => _expectedShaLabel;
}

class _ManifestCacheEntry {
  const _ManifestCacheEntry({required this.etag, required this.manifest});

  final String? etag;
  final UpdateManifest manifest;
}

class _HttpText {
  const _HttpText(this.statusCode, this.body, this.etag);

  final int statusCode;
  final String body;
  final String? etag;
}

class _ReleaseAsset {
  const _ReleaseAsset({required this.urls, this.shaUrl});

  final List<String> urls;
  final String? shaUrl;
}
