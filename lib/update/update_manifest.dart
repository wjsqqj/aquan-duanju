import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

/// `update.json` 清单（TVBox 同构 + 多平台扩展）。
///
/// 最小形态：
/// ```json
/// {"version":"1.5.0","changelog":"…",
///  "assets":{"windows":["https://…/setup.exe"]},
///  "sha256":{"windows":"<64 hex>"}}
/// ```
/// 兼容 TVBox 的 `apk: [url…]`（视作 Android arm64 资产）。
class UpdateManifest {
  const UpdateManifest({
    required this.version,
    this.versionCode = 0,
    this.changelog = '',
    this.assets = const <String, List<String>>{},
    this.sha256 = const <String, String>{},
    this.force = false,
    this.minSupportedVersion = '',
  });

  final String version;

  /// 构建号（Android 的 versionCode，**base** 值）。
  ///
  /// CI 用 `flutter build apk --split-per-abi`，Flutter 会把 APK 的 versionCode
  /// 写成 `1000 * abiVersion + base`，设备侧读到的值带偏移。因此这里只用于
  /// 「版本号相等时」兜底判断，绝不作为主判据（否则会恒判有新版本）。
  final int versionCode;
  final String changelog;

  /// 平台键 → 候选下载地址（按顺序尝试）。
  final Map<String, List<String>> assets;

  /// 平台键 → SHA-256（十六进制，大小写不敏感）；`default` 为通用摘要。
  final Map<String, String> sha256;

  /// 无条件强制更新（清单写了就一定是强制）。
  final bool force;

  /// 最低支持版本：当前版本低于它时强制更新。
  final String minSupportedVersion;

  /// 构建号能否参与比较。
  ///
  /// 需要 base < 1000：`--split-per-abi` 的偏移是 1000 的整数倍，只有这时
  /// 设备侧取余才能还原 base。超出的老版本号一律不参与，避免"永远提示有更新"。
  bool get versionCodeComparable => versionCode > 0 && versionCode < 1000;

  static UpdateManifest? parse(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw.trim());
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final version = (decoded['version'] ??
            decoded['versionName'] ??
            decoded['version_name'] ??
            '')
        .toString()
        .trim();
    final assets = <String, List<String>>{};

    void addAsset(String key, Object? value) {
      final urls = <String>[];
      void addOne(Object? item) {
        if (item is! String) return;
        final url = item.trim();
        if (url.startsWith('http://') || url.startsWith('https://')) {
          urls.add(url);
        }
      }

      if (value is String) {
        addOne(value);
      } else if (value is List) {
        for (final item in value) {
          addOne(item);
        }
      }
      if (urls.isNotEmpty) assets[key] = urls;
    }

    final rawAssets = decoded['assets'] ?? decoded['files'];
    if (rawAssets is Map) {
      rawAssets.forEach((key, value) => addAsset('$key', value));
    }
    // TVBox 旧格式：顶层 apk 数组。
    addAsset('android-arm64-v8a', decoded['apk']);

    final sha = <String, String>{};
    final rawSha = decoded['sha256'];
    if (rawSha is String && rawSha.trim().isNotEmpty) {
      sha['default'] = rawSha.trim();
    } else if (rawSha is Map) {
      rawSha.forEach((key, value) {
        if (value is String && value.trim().isNotEmpty) {
          sha['$key'] = value.trim();
        }
      });
    }

    if (version.isEmpty || assets.isEmpty) return null;
    return UpdateManifest(
      version: version,
      versionCode: _parseVersionCode(
        decoded['versionCode'] ?? decoded['version_code'],
      ),
      changelog: (decoded['changelog'] ?? decoded['notes'] ?? '').toString(),
      assets: assets,
      sha256: sha,
      force: decoded['force'] == true || decoded['force'] == 'true',
      minSupportedVersion:
          (decoded['minSupportedVersion'] ?? decoded['min_supported_version'] ?? '')
              .toString()
              .trim(),
    );
  }

  /// `versionCode` 的宽松解析：写错类型不该让整条清单链失效
  /// （其余字段都是宽松解析，这里保持一致）。
  static int _parseVersionCode(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? 0;
    return 0;
  }

  /// 当前平台键：与 `update.json` 的 `assets` 键一一对应。
  static String currentPlatformKey() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) {
      final abi = Abi.current();
      if (abi == Abi.androidArm64) return 'android-arm64-v8a';
      if (abi == Abi.androidArm) return 'android-armeabi-v7a';
      if (abi == Abi.androidX64) return 'android-x86_64';
      return 'android-arm64-v8a';
    }
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// 当前平台可安装包的候选地址；没有精确键时退到同平台任意键。
  List<String> assetUrlsFor(String platform) {
    final exact = assets[platform];
    if (exact != null && exact.isNotEmpty) return exact;
    if (platform.startsWith('android-')) {
      for (final entry in assets.entries) {
        if (entry.key.startsWith('android-') && entry.value.isNotEmpty) {
          return entry.value;
        }
      }
    }
    return const <String>[];
  }

  String? shaFor(String platform) =>
      sha256[platform] ?? sha256['default'];

  /// 序列化（只用于离线兜底缓存；字段与 [parse] 一一对应）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': version,
    if (versionCode > 0) 'versionCode': versionCode,
    'changelog': changelog,
    'assets': assets,
    'sha256': sha256,
    if (force) 'force': true,
    if (minSupportedVersion.isNotEmpty) 'minSupportedVersion': minSupportedVersion,
  };

  bool isNewerThan(String currentVersion) =>
      compareVersions(version, currentVersion) > 0;

  /// 是否为新版本：语义化版本为主，**仅在两边相等时**用构建号兜底。
  ///
  /// [currentBaseCode] 为设备侧 versionCode 的 base 值（非 Android 传 0 即可，
  /// 传 0 时等价于 [isNewerThan]）。
  bool isNewerThanWithCode(String currentVersion, {int currentBaseCode = 0}) {
    final compared = compareVersions(version, currentVersion);
    if (compared != 0) return compared > 0;
    if (!versionCodeComparable || currentBaseCode <= 0) return false;
    return versionCode > currentBaseCode;
  }

  /// 是否强制更新（不允许取消、不允许跳过）。
  ///
  /// 三种来源任一命中即强制：显式 `force`、低于 `minSupportedVersion`、
  /// 以及 Android 上构建号落后于清单（同为兜底语义）。
  bool isMandatory(String currentVersion, {int currentBaseCode = 0}) {
    if (force) return true;
    if (minSupportedVersion.isNotEmpty &&
        compareVersions(currentVersion, minSupportedVersion) < 0) {
      return true;
    }
    if (versionCodeComparable &&
        currentBaseCode > 0 &&
        currentBaseCode < versionCode) {
      return true;
    }
    return false;
  }

  /// 语义化版本比较：返回 >0 表示 a 比 b 新。
  static int compareVersions(String a, String b) {
    final left = _triple(a);
    final right = _triple(b);
    for (var i = 0; i < 3; i++) {
      if (left[i] != right[i]) return left[i] - right[i];
    }
    return 0;
  }

  static List<int> _triple(String version) {
    final core = version.split('+').first.split('-').first;
    final parts = core.split('.');
    return [
      for (var i = 0; i < 3; i++)
        i < parts.length ? (int.tryParse(parts[i].trim()) ?? 0) : 0,
    ];
  }
}
