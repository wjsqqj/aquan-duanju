/// 合成音色的**显示名中文化**。
///
/// 上游（Edge）只给 `FriendlyName`：`Microsoft Xiaoxiao Online (Natural) -
/// Chinese (Mainland)`。设置页直接显示它，用户在「多角色朗读 → 对话音色」里
/// 只看到一串英文，分不出男女、也记不住哪个是哪个（用户实测反馈）。
///
/// 这里只做**展示层**映射：音色 id 仍是 ShortName（缓存键与 `azureVoiceName`
/// 都依赖它），映射不到时也必须给一个干净可读的回退名，不能留空。
library;

/// 已知音色：ShortName 末段 → (中文名, 性别, 风格)。
///
/// 覆盖 Azure 中文常用音色 + 两个方言音色；未收录的走 [_fallback]。
const Map<String, (String, String, String)> _knownVoices =
    <String, (String, String, String)>{
  'Xiaoxiao': ('晓晓', '女声', '温柔'),
  'Xiaoyi': ('晓伊', '女声', '活泼'),
  'Xiaochen': ('晓辰', '女声', '温暖'),
  'Xiaohan': ('晓涵', '女声', '甜美'),
  'Xiaomeng': ('晓梦', '女声', '平静'),
  'Xiaomo': ('晓墨', '女声', '清朗'),
  'Xiaoqiu': ('晓秋', '女声', '温暖'),
  'Xiaorui': ('晓睿', '女声', '知性'),
  'Xiaoshuang': ('晓双', '女声', '纯真'),
  'Xiaoxuan': ('晓萱', '女声', '亲切'),
  'Xiaoyan': ('晓颜', '女声', '知性'),
  'Xiaoyou': ('晓悠', '女声', '温柔'),
  'Xiaozhen': ('晓甄', '女声', '专业'),
  'Xiaobei': ('晓北', '女声', '东北话'),
  'Xiaoni': ('晓妮', '女声', '陕西话'),
  'Yunxi': ('云希', '男声', '活泼'),
  'Yunjian': ('云健', '男声', '激情'),
  'Yunxia': ('云夏', '男声', '少年'),
  'Yunyang': ('云扬', '男声', '专业'),
  'Yunfeng': ('云枫', '男声', '沉稳'),
  'Yunjie': ('云杰', '男声', '专业'),
  'Yunze': ('云泽', '男声', '温暖'),
  'Yunhao': ('云皓', '男声', '阳光'),
};

/// 本机 Windows 语音（SAPI）的英文名 → 中文名。
const Map<String, String> _windowsVoiceNames = <String, String>{
  'huihui': '慧慧',
  'yaoyao': '瑶瑶',
  'kangkang': '康康',
  'hanhan': '涵涵',
  'lili': '丽丽',
  'danny': '丹尼',
  'tracy': '特蕾西',
};

/// locale → 中文说明（用于未知音色的兜底标签）。
const Map<String, String> _localeLabels = <String, String>{
  'zh-CN': '普通话',
  'zh-TW': '国语',
  'zh-HK': '粤语',
  'en-US': '英语',
  'en-GB': '英语',
  'ja-JP': '日语',
  'ko-KR': '韩语',
};

/// 音色显示名：`晓晓（女声·温柔）`；未知音色回退为可读名（非空）。
String ttsVoiceLabelOf({
  required String id,
  String displayName = '',
  String locale = '',
}) {
  final String short = _shortName(id);
  final String effectiveLocale = locale.isNotEmpty
      ? locale
      : (id.contains('-') ? id.split('-').take(2).join('-') : '');

  final known = _knownVoices[short];
  if (known != null) {
    final (name, gender, style) = known;
    return '$name（$gender·$style）';
  }

  // 本机语音：`Microsoft Huihui Desktop - Chinese (Simplified)`。
  final String lower = '$displayName $id'.toLowerCase();
  for (final entry in _windowsVoiceNames.entries) {
    if (lower.contains(entry.key)) {
      return '${entry.value}（本机语音）';
    }
  }

  final String fallback = _fallback(displayName: displayName, id: id, short: short);
  final String? localeLabel = _localeLabels[effectiveLocale];
  if (localeLabel == null || fallback.isEmpty) return fallback;
  return '$fallback（$localeLabel）';
}

/// 短名：`zh-CN-XiaoxiaoNeural` → `Xiaoxiao`；已给短名则原样返回。
String _shortName(String id) {
  if (id.isEmpty) return '';
  final String tail = id.split('-').last;
  return tail.endsWith('Neural')
      ? tail.substring(0, tail.length - 'Neural'.length)
      : tail;
}

/// 回退显示名：去掉 `Microsoft ` 前缀、`Online (Natural)`、地区尾巴与
/// `Neural` 后缀，保留可辨识的角色名；全空时用 id。
String _fallback({
  required String displayName,
  required String id,
  required String short,
}) {
  var name = displayName.trim();
  if (name.isNotEmpty) {
    // `Microsoft Xiaoxiao Online (Natural) - Chinese (Mainland)`
    name = name.replaceFirst(RegExp(r'^Microsoft\s+', caseSensitive: false), '');
    // 地区尾巴整段丢掉（按 ` - ` 切，避免把 `Chinese` 切成 `hinese`）。
    name = name.split(' - ').first.trim();
    name = name.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    name = name.replaceAll(
        RegExp(r'\b(Online|Offline|Natural|Desktop|Multilingual)\b',
            caseSensitive: false),
        '');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    // 只剩 `Xiaoxiao` 这类角色名时优先用中文短名兜底。
    if (name.isNotEmpty) {
      return _knownVoices[name]?.$1 ?? name;
    }
  }
  if (short.isNotEmpty) return _knownVoices[short]?.$1 ?? short;
  return id;
}
