/// 内置更新镜像：GitHub 加速通道。
///
/// 两种改写方式：
/// - [UpdateMirrorMode.prefix]：`前缀 + 完整 GitHub URL`（gh-proxy 系）；
/// - [UpdateMirrorMode.hostReplace]：只替换域名（kkgithub 系）。
///
/// 两者都必须严格限定：只接受 https、且 host 在 [kMirrorableHosts] 白名单内的
/// 绝对 URL。不做白名单校验就会被任意地址当成 SSRF 跳板。
///
/// 说明：镜像只做兜底，清单与安装包摘要仍以官方通道为准；镜像返回的
/// SHA-256 仅用于下载完整性校验，不提升信任等级。
enum UpdateMirrorMode {
  /// `https://<prefix>/https://github.com/...`
  prefix,

  /// `https://github.com/...` → `https://kkgithub.com/...`
  hostReplace,
}

class UpdateMirror {
  /// 稳定标识：写进健康缓存，不随展示名变化。
  final String id;
  final String label;
  final UpdateMirrorMode mode;

  /// 前缀，必须以 `/` 结尾（[UpdateMirrorMode.prefix] 时使用）。
  final String prefix;

  /// 旧域名 → 新域名（[UpdateMirrorMode.hostReplace] 时使用）。
  final Map<String, String> hostMap;

  /// 是否支持代理 `api.github.com`（清单接口）。
  final bool proxiesApi;

  const UpdateMirror({
    required this.id,
    required this.label,
    this.mode = UpdateMirrorMode.prefix,
    this.prefix = '',
    this.hostMap = const <String, String>{},
    this.proxiesApi = false,
  });

  /// 把 GitHub 自有域名地址改写为镜像地址；不满足条件时返回 null。
  String? resolve(String originalUrl) {
    final uri = Uri.tryParse(originalUrl);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    if (!kMirrorableHosts.contains(uri.host.toLowerCase())) return null;
    switch (mode) {
      case UpdateMirrorMode.prefix:
        if (!prefix.endsWith('/')) return null;
        return '$prefix$originalUrl';
      case UpdateMirrorMode.hostReplace:
        final target = hostMap[uri.host.toLowerCase()];
        if (target == null || target.isEmpty) return null;
        return uri.replace(host: target).toString();
    }
  }

  /// 清单接口地址的改写；不支持 API 代理的镜像返回 null。
  String? resolveApi(String originalUrl) =>
      proxiesApi ? resolve(originalUrl) : null;

  @override
  String toString() => 'UpdateMirror($id, $mode, ${mode == UpdateMirrorMode.prefix ? prefix : hostMap})';
}

/// 允许参与改写的 GitHub 自有域名。
const Set<String> kMirrorableHosts = {
  'github.com',
  'raw.githubusercontent.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
  'api.github.com',
};

/// 内置镜像（默认尝试顺序；运行时会按连通性探测结果重排）。
///
/// 2026-11-11 直连实测（无代理）。判定标准：Range 取 2 字节必须是可执行头 `MZ`，
/// 只回 200 不算通过——`ghproxy.cfd` 就是回 200 + 49KB HTML 落地页的假镜像。
///
/// | 镜像 | 资产 | 清单 update.json | api.github.com |
/// |---|---|---|---|
/// | gh-proxy.com | 206 ✓ | 200 ✓ | 200 ✓ |
/// | hk.gh-proxy.com | 206 ✓ | 200 ✓ | 200 ✓ |
/// | gh.noki.icu | 206 ✓ | 200 ✓ | 200 ✓ |
/// | cors.isteed.cc | 206 ✓ | 200 ✓ | 403 ✗ |
/// | github.boki.moe | 206 ✓ | 200 ✓ | 404 ✗ |
/// | ghproxy.monkeyray.net | 206 ✓ | 200 ✓ | 403 ✗ |
///
/// 已删除（实测不可用）：`ghfast.top`（连接超时）、`kkgithub.com`（连接失败）、
/// `hub.gitmirror.com`/`gitmirror.com`（域名 NXDOMAIN）、`ghproxy.net`（25s 无响应）、
/// `ghproxy.cfd`（假可用，返回 HTML）、`gh.h233.eu.org`（403）、`slink.ltd`（403）、
/// `gh.api.99988866.xyz`、`ghproxy.1888866.xyz`、`dl.ghpig.top`、`gh.zwy.one`、
/// `raw.ihtw.moe`、`gh.jasonzeng.dev`、`github.akams.cn`、`moeyy.cn`（均无法连通或路径不符）。
///
/// `proxiesApi` 只标记**能代理 api.github.com** 的三个：API 兜底路径需要它；
/// 清单与资产下载走 [UpdateMirror.resolve]，全部六个都能用。
///
/// 当前内置列表没有域名替换型镜像（`kkgithub.com` 已不可用），
/// [UpdateMirrorMode.hostReplace] 保留着，新镜像复活时可直接接入。
const List<UpdateMirror> builtInUpdateMirrors = <UpdateMirror>[
  UpdateMirror(
    id: 'gh-proxy',
    label: 'gh-proxy.com',
    prefix: 'https://gh-proxy.com/',
    proxiesApi: true,
  ),
  UpdateMirror(
    id: 'gh-proxy-hk',
    label: 'gh-proxy.com (HK)',
    prefix: 'https://hk.gh-proxy.com/',
    proxiesApi: true,
  ),
  UpdateMirror(
    id: 'gh-noki',
    label: 'gh.noki.icu',
    prefix: 'https://gh.noki.icu/',
    proxiesApi: true,
  ),
  UpdateMirror(
    id: 'cors-isteed',
    label: 'cors.isteed.cc',
    prefix: 'https://cors.isteed.cc/',
  ),
  UpdateMirror(
    id: 'boki-moe',
    label: 'github.boki.moe',
    prefix: 'https://github.boki.moe/',
  ),
  UpdateMirror(
    id: 'monkeyray',
    label: 'ghproxy.monkeyray.net',
    prefix: 'https://ghproxy.monkeyray.net/',
  ),
];
