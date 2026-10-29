/// 内置更新镜像：GitHub 前缀代理。
///
/// 这类镜像把「前缀 + 完整 GitHub URL」拼成可直连地址，因此改写必须严格
/// 限定：只接受 https、且 host 在 [kMirrorableHosts] 白名单内的绝对 URL。
/// 不做白名单校验就会被任意地址当成 SSRF 跳板。
///
/// 说明：镜像只做兜底，清单与安装包摘要仍以官方通道为准；镜像返回的
/// SHA-256 仅用于下载完整性校验，不提升信任等级。
class UpdateMirror {
  /// 稳定标识：写进健康缓存，不随展示名变化。
  final String id;
  final String label;

  /// 前缀，必须以 `/` 结尾。
  final String prefix;

  /// 是否支持代理 `api.github.com`（清单接口）。
  final bool proxiesApi;

  const UpdateMirror({
    required this.id,
    required this.label,
    required this.prefix,
    this.proxiesApi = false,
  });

  /// 把 GitHub 自有域名地址改写为镜像地址；不满足条件时返回 null。
  String? resolve(String originalUrl) {
    if (!prefix.endsWith('/')) return null;
    final uri = Uri.tryParse(originalUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    if (!kMirrorableHosts.contains(uri.host.toLowerCase())) return null;
    return '$prefix$originalUrl';
  }

  /// 清单接口地址的改写；不支持 API 代理的镜像返回 null。
  String? resolveApi(String originalUrl) =>
      proxiesApi ? resolve(originalUrl) : null;

  @override
  String toString() => 'UpdateMirror($id, $prefix)';
}

/// 允许参与前缀拼接的 GitHub 自有域名。
const Set<String> kMirrorableHosts = {
  'github.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
  'api.github.com',
};

/// 内置镜像（按尝试顺序）。
///
/// 2026-10-21 参考 xiugou-tv 的实测结论：gh-proxy.com 同时支持清单接口、
/// Range 与 ETag 透传；ghfast.top 只支持资产（API 返回 403），作为下载兜底。
const List<UpdateMirror> builtInUpdateMirrors = [
  UpdateMirror(
    id: 'gh-proxy',
    label: 'gh-proxy.com',
    prefix: 'https://gh-proxy.com/',
    proxiesApi: true,
  ),
  UpdateMirror(
    id: 'ghfast',
    label: 'ghfast.top',
    prefix: 'https://ghfast.top/',
    proxiesApi: false,
  ),
];
