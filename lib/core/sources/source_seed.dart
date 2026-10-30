// GENERATED FILE — do not edit by hand.
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
  list('清单页');

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
  SourceSeed(id: 'line_01', name: '饭太硬', url: 'http://www.xn--sss604efuw.com/tv'),
  SourceSeed(id: 'line_02', name: '摸鱼儿', url: 'http://xn--ihqu10cn4c.xn--v4q818bf34b.com'),
  SourceSeed(id: 'line_03', name: '肥猫', url: 'http://xn--z7x900a.com'),
  SourceSeed(id: 'line_04', name: '肥猫live', url: 'http://xn--z7x900a.live'),
  SourceSeed(id: 'line_05', name: '毒盒', url: 'https://xn--8owq8u.com/tv/'),
  SourceSeed(id: 'line_06', name: '动漫城', url: 'https://www.yingm.cc/dm/dm.json'),
  SourceSeed(id: 'line_07', name: '俊佬', url: 'http://home.jundie.top:81/top98.json'),
  SourceSeed(id: 'line_08', name: '欧歌', url: 'https://play.iptv365.org/欧歌/api.json'),
  SourceSeed(id: 'line_09', name: '小米', url: 'https://play.iptv365.org/小米/api.json'),
  SourceSeed(id: 'line_10', name: '巧儿', url: 'http://pandown.pro/tvbox/tvbox.json'),
  SourceSeed(id: 'line_11', name: '传说', url: 'https://chuanshuo.77blog.cn/tv.json'),
  SourceSeed(id: 'line_12', name: '宝盒接口', url: 'http://xn--6orr3pi6g9uu.top'),
  SourceSeed(id: 'line_13', name: '高天流云', url: 'https://raw.githubusercontent.com/gaotianliuyun/gao/master/js.json'),
  SourceSeed(id: 'line_14', name: '影视仓聚合', url: 'https://raw.githubusercontent.com/wxrjck/-YSC-/refs/heads/main/wx.json'),
  SourceSeed(id: 'line_15', name: '多多聚合', url: 'https://raw.liucn.cc/box/dm.txt'),
  SourceSeed(id: 'line_16', name: 'liucn-m', url: 'https://raw.liucn.cc/box/m.json'),
  SourceSeed(id: 'line_17', name: 'gitee自建', url: 'https://gitee.com/lukei7/lib/raw/Luck/自建.json'),
  SourceSeed(id: 'line_18', name: 'gitee-bls', url: 'https://gitee.com/blssss/jk/raw/api/bls.json'),
  SourceSeed(id: 'line_19', name: 'gitee青龙', url: 'https://gitee.com/yiwu369/6758/raw/master/青龙/1.json'),
  SourceSeed(id: 'line_20', name: 'dxawi', url: 'https://dxawi.github.io/0/0.json'),
  SourceSeed(id: 'line_21', name: 'kjsc0310', url: 'https://kjsc0310.github.io/tvy/jk9.json'),
  SourceSeed(id: 'line_22', name: '影视仓多仓-gitlab', url: 'https://gitlab.com/ygbh1/666/-/raw/main/dcang/ygbh.json'),
  SourceSeed(id: 'line_23', name: '月光宝盒多仓', url: 'https://jihulab.com/ygbh1/box/-/raw/main/dcang/dc.json'),
  SourceSeed(id: 'line_24', name: '月光影视仓', url: 'https://jihulab.com/ygbh1/box/-/raw/main/dcang/ygbh.json'),
  SourceSeed(id: 'line_25', name: '宝盒多仓2', url: 'https://jihulab.com/ygbh1/box/-/raw/main/dcang/dc2.json'),
  SourceSeed(id: 'line_26', name: '多多接口多仓', url: 'https://jihulab.com/duomv/apps/-/raw/main/fast.json'),
  SourceSeed(id: 'line_27', name: '多多多仓', url: 'https://jihulab.com/duomv/apps/-/raw/main/duo.json'),
  SourceSeed(id: 'line_28', name: '影视仓多仓-52bsj', url: 'http://52bsj.vip:98/xiaohu'),
  SourceSeed(id: 'line_29', name: '吾爱仓库', url: 'http://52bsj.vip:98/wuaihosue'),
  SourceSeed(id: 'line_30', name: '云星日记仓库', url: 'https://itvbox.cc/可视TV/云星日记/仓库.json'),
  SourceSeed(id: 'line_31', name: '猎狼多仓', url: 'http://tvbox.lltv8.top'),
  SourceSeed(id: 'line_32', name: '春风影视', url: 'https://369936.xyz/web119'),
  SourceSeed(id: 'line_33', name: '欧哥仓', url: 'http://tv.nxog.top'),
  SourceSeed(id: 'line_34', name: '日后仓', url: 'http://rihou.cc:66/'),
  SourceSeed(id: 'line_35', name: '奇奇多仓', url: 'https://cn.kstore.space/download/2904/123.txt'),
  SourceSeed(id: 'line_36', name: 'D佬魔改线路', url: 'https://download.kstore.space/download/2883/nzk/nzk0722.json'),
  SourceSeed(id: 'line_37', name: '蚂蚁线路', url: 'https://cn.kstore.space/download/2883/0110.txt'),
  SourceSeed(id: 'line_38', name: '青龙线路', url: 'https://6758.kstore.space/1.json'),
  SourceSeed(id: 'line_39', name: 'fmys', url: 'http://fmys.top/fmys.json'),
  SourceSeed(id: 'line_40', name: '奇奇', url: 'http://z.qiqiv.cn/123'),
  SourceSeed(id: 'line_41', name: 'kstore-wex', url: 'https://9280.kstore.space/wex.json'),
  SourceSeed(id: 'line_42', name: 'qxys', url: 'https://7337.kstore.space/qxys/禁止传播.json'),
  SourceSeed(id: 'line_43', name: 'weixine', url: 'https://weixine.net/ysc.json'),
  SourceSeed(id: 'line_44', name: 'zzzzz-tv', url: 'https://zzzzz.tv/tv/ys.json'),
  SourceSeed(id: 'line_45', name: 'zzzzz-svip', url: 'https://zzzzz.tv/tv/svip.json'),
  SourceSeed(id: 'line_46', name: 'qiaoji8', url: 'http://cdn.qiaoji8.com/tvbox.json'),
  SourceSeed(id: 'line_47', name: 'wds-223843', url: 'https://wds.ecsxs.com/223843.txt'),
  SourceSeed(id: 'agg_01', name: '7xz 合集', url: 'https://m.7xz.com/softs/43518.html', kind: SeedKind.aggregator),
  SourceSeed(id: 'agg_02', name: '9k9k 合集', url: 'https://www.9k9k.com/app/52116.html', kind: SeedKind.aggregator),
  SourceSeed(id: 'agg_03', name: '52pk 合集', url: 'https://m.52pk.com/soft/37066zmfvyf.html', kind: SeedKind.aggregator),
  SourceSeed(id: 'agg_04', name: 'niucoo 合集', url: 'https://m.niucoo.cn/app/14651.html', kind: SeedKind.aggregator),
  SourceSeed(id: 'agg_05', name: '3dmgame 合集', url: 'https://shouyou.3dmgame.com/ios/532920.html', kind: SeedKind.aggregator),
  SourceSeed(id: 'agg_06', name: '7po 合集', url: 'https://m.7po.com/rj/11305.html', kind: SeedKind.aggregator),
  SourceSeed(id: 'agg_07', name: 'flowus 甲', url: 'https://flowus.cn/ahuage/share/0cee252a-9d5e-44bf-9603-67844b5dda2b', kind: SeedKind.aggregator),
  SourceSeed(id: 'agg_08', name: 'flowus 乙', url: 'https://flowus.cn/share/1f2076ff-183f-4263-a0a2-6234fb89dcf1', kind: SeedKind.aggregator),
  SourceSeed(id: 'agg_09', name: '月光 dc2', url: 'https://jihulab.com/ygbh1/box/-/raw/main/dcang/dc2.json', kind: SeedKind.aggregator),
  SourceSeed(id: 'agg_10', name: '月光 ygbh', url: 'https://jihulab.com/ygbh1/box/-/raw/main/dcang/ygbh.json', kind: SeedKind.aggregator),
  SourceSeed(id: 'agg_11', name: 'gitlab 月光', url: 'https://gitlab.com/ygbh1/666/-/raw/main/dcang/ygbh.json', kind: SeedKind.aggregator),
  SourceSeed(id: 'agg_12', name: 'yydsys 聚合', url: 'https://yydsys.top/duo', kind: SeedKind.aggregator),
  SourceSeed(id: 'agg_13', name: 'pastebin 甲', url: 'https://pastebin.com/raw/5NHaxyGR', kind: SeedKind.aggregator),
  SourceSeed(id: 'agg_14', name: 'codeberg drpy', url: 'https://codeberg.org/AK47/drpy-js/raw/branch/main/js.json', kind: SeedKind.aggregator),
  SourceSeed(id: 'agg_15', name: 'CatVod 官方', url: 'https://raw.githubusercontent.com/FongMi/CatVodSpider/main/json/config.json', kind: SeedKind.aggregator),
  SourceSeed(id: 'm_zoo', name: 'Zoo 接口站', url: 'https://zoo.ink/tvbox.html', kind: SeedKind.list),
  SourceSeed(id: 'm_zhuiju', name: '追剧接口表', url: 'https://b.zhuiju.me/p/3', kind: SeedKind.list),
  SourceSeed(id: 'm_yue12', name: '十二月接口站', url: 'https://0.12yue.de5.net/', kind: SeedKind.list),
  SourceSeed(id: 'm_jsnzkpg', name: 'Jsnzkpg 加密仓', url: 'https://gh-proxy.org/https://raw.githubusercontent.com/Jsnzkpg/Jsnzkpg/Jsnzkpg/Jsnzkpg', kind: SeedKind.list),
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
    // 不用 `replace(fragment: '')`：那会输出一个尾随 `#`。
    return Uri(
      scheme: uri.scheme.toLowerCase(),
      host: uri.host.toLowerCase(),
      port: uri.hasPort ? uri.port : null,
      path: path == '/' ? '' : path,
      query: uri.hasQuery ? uri.query : null,
    ).toString();
  } catch (_) {
    return trimmed;
  }
}
