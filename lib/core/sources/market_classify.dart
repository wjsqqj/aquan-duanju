/// 配置的容器形态。
enum RepoShape {
  single('单仓'),
  multiStoreHouse('多仓'),
  multiUrls('多仓'),
  unknown('无法识别');

  const RepoShape(this.label);

  final String label;

  bool get isMulti =>
      this == RepoShape.multiStoreHouse || this == RepoShape.multiUrls;
}

/// 一条子仓引用。
class RepoChild {
  const RepoChild(this.name, this.url);

  final String name;
  final String url;
}

/// 配置结构识别结果。
class RepoInfo {
  const RepoInfo({
    required this.shape,
    required this.name,
    required this.siteCount,
    required this.cleartextSpiderJar,
    required this.children,
  });

  final RepoShape shape;
  final String name;
  final int siteCount;

  /// `spider` 是明文 http 地址（TVBox 有明文 jar 的安全隐患）。
  final bool cleartextSpiderJar;

  final List<RepoChild> children;

  bool get known => shape != RepoShape.unknown;
}

const List<String> _singleKeys = <String>[
  'sites',
  'parses',
  'lives',
  'spider',
  'api_site',
];

bool _meaningful(Object? value) {
  if (value == null) return false;
  if (value is String) return value.trim().isNotEmpty;
  if (value is List) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}

String _asString(Object? value) {
  if (value == null || value is Map || value is List) return '';
  if (value is bool) return value ? 'true' : 'false';
  return '$value';
}

/// 识别 TVBox 配置形态。对齐 ysc-helper `_classify` 的判定顺序。
RepoInfo? classifyConfig(Map<String, dynamic> json) {
  final storeHouse = json['storeHouse'];
  final urls = json['urls'];

  final storeChildren = <RepoChild>[];
  if (storeHouse is List) {
    for (final item in storeHouse) {
      if (item is! Map) continue;
      final url = _asString(item['sourceUrl']).trim();
      if (url.isEmpty) continue;
      storeChildren.add(RepoChild(_asString(item['sourceName']), url));
    }
  }
  final urlChildren = <RepoChild>[];
  if (urls is List) {
    for (final item in urls) {
      if (item is! Map) continue;
      final url = _asString(item['url']).trim();
      if (url.isEmpty) continue;
      urlChildren.add(RepoChild(_asString(item['name']), url));
    }
  }

  final name = _asString(json['name']).trim();
  final sites = json['sites'];
  final siteCount = sites is List ? sites.length : 0;
  final spider = _asString(json['spider']).trim();
  final cleartextSpiderJar = spider.toLowerCase().startsWith('http://');

  if (storeChildren.isNotEmpty) {
    return RepoInfo(
      shape: RepoShape.multiStoreHouse,
      name: name,
      siteCount: siteCount,
      cleartextSpiderJar: cleartextSpiderJar,
      children: storeChildren,
    );
  }
  if (urlChildren.isNotEmpty) {
    return RepoInfo(
      shape: RepoShape.multiUrls,
      name: name,
      siteCount: siteCount,
      cleartextSpiderJar: cleartextSpiderJar,
      children: urlChildren,
    );
  }
  for (final key in _singleKeys) {
    if (_meaningful(json[key])) {
      return RepoInfo(
        shape: RepoShape.single,
        name: name,
        siteCount: siteCount,
        cleartextSpiderJar: cleartextSpiderJar,
        children: const <RepoChild>[],
      );
    }
  }
  return RepoInfo(
    shape: RepoShape.unknown,
    name: name,
    siteCount: siteCount,
    cleartextSpiderJar: cleartextSpiderJar,
    children: const <RepoChild>[],
  );
}
