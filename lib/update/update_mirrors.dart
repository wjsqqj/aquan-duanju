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

/// 内置镜像（默认尝试顺序；运行时会按连通性 + **清单版本号**重排）。
///
/// 2026-11-11 / 2026-11-17 直连实测（无代理）。判定标准：Range 取 2 字节必须是
/// 可执行头 `MZ`，且清单必须能解析出 `version`——只回 200 不算通过
/// （`ghproxy.cfd` 就是回 200 + HTML 落地页的假镜像）。
///
/// | 镜像 | 资产 | 清单 update.json | api.github.com |
/// |---|---|---|---|
/// | gh-proxy.com | 206 ✓ | 200 ✓ | 200 ✓ |
/// | hk.gh-proxy.com | 206 ✓ | 200 ✓ | 200 ✓ |
/// | gh-proxy.org | 206 ✓ | 200 ✓ | 未验证 ✗ |
/// | gh.noki.icu | 503（11-17 不可达） | ✗ | ✗ |
/// | cors.isteed.cc | 206 ✓ | 200 ✓（**CDN 缓存会回旧版本**） | 403 ✗ |
/// | github.boki.moe | 403（11-17 抖动） | 时好时坏 | 404 ✗ |
/// | ghproxy.monkeyray.net | 206 ✓ | 200 ✓ | 403 ✗ |
///
/// 11-17 关键发现：`cors.isteed.cc` 对**不带参数的** `update.json` 稳定返回
/// v1.12.9，而官方已是 v1.12.10；带任意 `?t=<ts>` 立刻返回 v1.12.10。
/// 因此清单请求统一加缓存击穿参数（见 `UpdateService.withManifestCacheBuster`），
/// 并且源选择改为「版本号优先、同版本再比速度」——单靠测速会被旧缓存骗过去。
///
/// 已删除（实测不可用）：`kkgithub.com`（连接失败）、`hub.gitmirror.com`/
/// `gitmirror.com`（NXDOMAIN）、`ghproxy.cfd`（假可用，返回 HTML）、
/// `gh.h233.eu.org`（403）、`slink.ltd`（403）、`gh.api.99988866.xyz`、
/// `ghproxy.1888866.xyz`、`dl.ghpig.top`、`gh.zwy.one`、`raw.ihtw.moe`、
/// `gh.jasonzeng.dev`、`github.akams.cn`、`moeyy.cn`（无法连通或路径不符）、
/// `ghfast.top`/`ghproxy.net`/`gh.llkk.cc`/`github.moeyy.xyz`/`gitproxy.click`/
/// `gh-proxy.net`/`ghproxy.cc`/`ghp.ci`（11-17 复测：超时、JS 落地页或证书失败）。
///
/// `proxiesApi` 只标记**已验证能代理 api.github.com** 的源：API 兜底路径需要它；
/// 清单与资产下载走 [UpdateMirror.resolve]，其余镜像都能用。
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
  // 11-17 新增：清单 / 资产双证据通过，且本机实测最快（清单 0.46s / 资产 0.33s）。
  UpdateMirror(
    id: 'gh-proxy-org',
    label: 'gh-proxy.org',
    prefix: 'https://gh-proxy.org/',
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
