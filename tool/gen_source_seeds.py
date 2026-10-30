"""生成 lib/core/sources/source_seed.dart 的内置种子清单。

中文域名统一转 punycode（Dart 的 `Uri` 不做 IDNA 转换，直接发请求会失败）；
路径里的中文保留，`Uri.parse` 会自动做 UTF-8 percent-encoding。

用法：pip install idna && python tool/gen_source_seeds.py
"""
import io
import os

import idna
from urllib.parse import urlsplit, urlunsplit

BASE = [
    ('饭太硬', 'http://www.饭太硬.com/tv'),
    ('摸鱼儿', 'http://我不是.摸鱼儿.com'),
    ('肥猫', 'http://肥猫.com'),
    ('肥猫live', 'http://肥猫.live'),
    ('毒盒', 'https://毒盒.com/tv/'),
    ('动漫城', 'https://www.yingm.cc/dm/dm.json'),
    ('俊佬', 'http://home.jundie.top:81/top98.json'),
    ('欧歌', 'https://play.iptv365.org/欧歌/api.json'),
    ('小米', 'https://play.iptv365.org/小米/api.json'),
    ('巧儿', 'http://pandown.pro/tvbox/tvbox.json'),
    ('传说', 'https://chuanshuo.77blog.cn/tv.json'),
    ('宝盒接口', 'http://宝盒接口.top'),
    ('高天流云', 'https://raw.githubusercontent.com/gaotianliuyun/gao/master/js.json'),
    ('影视仓聚合', 'https://raw.githubusercontent.com/wxrjck/-YSC-/refs/heads/main/wx.json'),
    ('多多聚合', 'https://raw.liucn.cc/box/dm.txt'),
    ('liucn-m', 'https://raw.liucn.cc/box/m.json'),
    ('gitee自建', 'https://gitee.com/lukei7/lib/raw/Luck/自建.json'),
    ('gitee-bls', 'https://gitee.com/blssss/jk/raw/api/bls.json'),
    ('gitee青龙', 'https://gitee.com/yiwu369/6758/raw/master/青龙/1.json'),
    ('dxawi', 'https://dxawi.github.io/0/0.json'),
    ('kjsc0310', 'https://kjsc0310.github.io/tvy/jk9.json'),
    ('影视仓多仓-gitlab', 'https://gitlab.com/ygbh1/666/-/raw/main/dcang/ygbh.json'),
    ('月光宝盒多仓', 'https://jihulab.com/ygbh1/box/-/raw/main/dcang/dc.json'),
    ('月光影视仓', 'https://jihulab.com/ygbh1/box/-/raw/main/dcang/ygbh.json'),
    ('宝盒多仓2', 'https://jihulab.com/ygbh1/box/-/raw/main/dcang/dc2.json'),
    ('多多接口多仓', 'https://jihulab.com/duomv/apps/-/raw/main/fast.json'),
    ('多多多仓', 'https://jihulab.com/duomv/apps/-/raw/main/duo.json'),
    ('影视仓多仓-52bsj', 'http://52bsj.vip:98/xiaohu'),
    ('吾爱仓库', 'http://52bsj.vip:98/wuaihosue'),
    ('云星日记仓库', 'https://itvbox.cc/可视TV/云星日记/仓库.json'),
    ('猎狼多仓', 'http://tvbox.lltv8.top'),
    ('春风影视', 'https://369936.xyz/web119'),
    ('欧哥仓', 'http://tv.nxog.top'),
    ('日后仓', 'http://rihou.cc:66/'),
    ('奇奇多仓', 'https://cn.kstore.space/download/2904/123.txt'),
    ('D佬魔改线路', 'https://download.kstore.space/download/2883/nzk/nzk0722.json'),
    ('蚂蚁线路', 'https://cn.kstore.space/download/2883/0110.txt'),
    ('青龙线路', 'https://6758.kstore.space/1.json'),
    ('fmys', 'http://fmys.top/fmys.json'),
    ('奇奇', 'http://z.qiqiv.cn/123'),
    ('kstore-wex', 'https://9280.kstore.space/wex.json'),
    ('qxys', 'https://7337.kstore.space/qxys/禁止传播.json'),
    ('weixine', 'https://weixine.net/ysc.json'),
    ('zzzzz-tv', 'https://zzzzz.tv/tv/ys.json'),
    ('zzzzz-svip', 'https://zzzzz.tv/tv/svip.json'),
    ('qiaoji8', 'http://cdn.qiaoji8.com/tvbox.json'),
    ('wds-223843', 'https://wds.ecsxs.com/223843.txt'),
]

AGG = [
    ('7xz 合集', 'https://m.7xz.com/softs/43518.html'),
    ('9k9k 合集', 'https://www.9k9k.com/app/52116.html'),
    ('52pk 合集', 'https://m.52pk.com/soft/37066zmfvyf.html'),
    ('niucoo 合集', 'https://m.niucoo.cn/app/14651.html'),
    ('3dmgame 合集', 'https://shouyou.3dmgame.com/ios/532920.html'),
    ('7po 合集', 'https://m.7po.com/rj/11305.html'),
    ('flowus 甲', 'https://flowus.cn/ahuage/share/0cee252a-9d5e-44bf-9603-67844b5dda2b'),
    ('flowus 乙', 'https://flowus.cn/share/1f2076ff-183f-4263-a0a2-6234fb89dcf1'),
    ('月光 dc2', 'https://jihulab.com/ygbh1/box/-/raw/main/dcang/dc2.json'),
    ('月光 ygbh', 'https://jihulab.com/ygbh1/box/-/raw/main/dcang/ygbh.json'),
    ('gitlab 月光', 'https://gitlab.com/ygbh1/666/-/raw/main/dcang/ygbh.json'),
    ('yydsys 聚合', 'https://yydsys.top/duo'),
    ('pastebin 甲', 'https://pastebin.com/raw/5NHaxyGR'),
    ('codeberg drpy', 'https://codeberg.org/AK47/drpy-js/raw/branch/main/js.json'),
    ('CatVod 官方', 'https://raw.githubusercontent.com/FongMi/CatVodSpider/main/json/config.json'),
]

INDEX = [
    ('m_zoo', 'Zoo 接口站', 'https://zoo.ink/tvbox.html'),
    ('m_zhuiju', '追剧接口表', 'https://b.zhuiju.me/p/3'),
    ('m_yue12', '十二月接口站', 'https://0.12yue.de5.net/'),
    ('m_jsnzkpg', 'Jsnzkpg 加密仓',
     'https://gh-proxy.org/https://raw.githubusercontent.com/Jsnzkpg/Jsnzkpg/Jsnzkpg/Jsnzkpg'),
]

OUT = os.path.join('lib', 'core', 'sources', 'source_seed.dart')


def fix(url):
    parts = urlsplit(url)
    host = parts.hostname or ''
    try:
        ascii_host = idna.encode(host, uts46=True).decode()
    except Exception:
        ascii_host = host
    netloc = ascii_host + ((':' + str(parts.port)) if parts.port else '')
    return urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment))


def q(text):
    return text.replace('\\', '\\\\').replace("'", "\\'")


def build():
    lines = []
    for i, (name, url) in enumerate(BASE, 1):
        lines.append(
            "  SourceSeed(id: 'line_%02d', name: '%s', url: '%s'),"
            % (i, q(name), q(fix(url)))
        )
    for i, (name, url) in enumerate(AGG, 1):
        lines.append(
            "  SourceSeed(id: 'agg_%02d', name: '%s', url: '%s', kind: SeedKind.aggregator),"
            % (i, q(name), q(fix(url)))
        )
    for sid, name, url in INDEX:
        lines.append(
            "  SourceSeed(id: '%s', name: '%s', url: '%s', kind: SeedKind.list),"
            % (sid, q(name), q(fix(url)))
        )

    seeds = '\n'.join(lines)

    dart = """// GENERATED FILE — do not edit by hand.
// Run `python tool/gen_source_seeds.py` to regenerate.
//
// 内置种子：48 条直连线路 + 15 个聚合页 + 4 个接口清单页。
// 中文域名已转 punycode（Dart 的 Uri 不做 IDNA 转换）。
//
// ignore_for_file: lines_longer_than_80_chars

/// 种子类型。
enum SeedKind {
  /// 直连配置地址（json / txt 多仓）。
  line('线路'),

  /// 网页，需要先抓页面再提取配置地址。
  aggregator('聚合页'),

  /// 接口清单页，页面里列着多条配置地址。
  index('清单页');

  const SeedKind(this.label);

  final String label;

  static SeedKind fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return SeedKind.line;
  }
}

/// 一条种子。
class SourceSeed {
  const SourceSeed({
    required this.id,
    required this.name,
    required this.url,
    this.kind = SeedKind.line,
    this.builtin = true,
  });

  factory SourceSeed.fromJson(Map<String, dynamic> json) => SourceSeed(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        kind: SeedKind.fromName(json['kind']),
        builtin: json['builtin'] is bool ? json['builtin'] as bool : false,
      );

  final String id;
  final String name;
  final String url;
  final SeedKind kind;

  /// 内置项：用户删除后记进 `hidden`，恢复预置时重新出现。
  final bool builtin;

  SourceSeed copyWith({String? name, String? url, SeedKind? kind}) => SourceSeed(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        kind: kind ?? this.kind,
        builtin: builtin,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'url': url,
        'kind': kind.name,
        'builtin': builtin,
      };
}

/// 内置种子清单。
const List<SourceSeed> kBuiltinSeeds = <SourceSeed>[
%s
];

/// 内置种子按 id 建索引。
final Map<String, SourceSeed> kBuiltinSeedById = <String, SourceSeed>{
  for (final seed in kBuiltinSeeds) seed.id: seed,
};

/// 去重用的 URL 归一化：去 fragment、去尾斜杠、host 小写。
String normalizeSeedUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  try {
    final uri = Uri.parse(trimmed);
    var path = uri.path;
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return uri
        .replace(
          scheme: uri.scheme.toLowerCase(),
          host: uri.host.toLowerCase(),
          path: path,
          fragment: '',
        )
        .toString();
  } catch (_) {
    return trimmed;
  }
}
""" % seeds

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with io.open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write(dart)
    print('wrote', OUT, len(dart), 'chars', len(BASE) + len(AGG) + len(INDEX), 'seeds')


if __name__ == '__main__':
    build()
