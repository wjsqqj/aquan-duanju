import 'dart:convert';

import 'package:crypto/crypto.dart';

/// B 站 WBI 签名（web 端接口风控参数）。
///
/// 算法（社区事实标准）：nav 接口取 `wbi_img.img_url/sub_url` 的文件名拼成
/// 64 字符 mixinKey 原始表，按 MIXIN_TABLE 重排取前 32 位作真实 key；
/// 参数排序后 `md5(query + key)` 追加 `w_rid` 与 `wts`。
class WbiSigner {
  WbiSigner._();

  /// 与 B 站一致的 64 位重排表。
  static const List<int> mixinKeyEncTab = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
    61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
    36, 20, 34, 44, 52,
  ];

  /// 从 img/sub URL 提取文件名得到原始 64 字符表。
  static String rawMixinKey(String imgUrl, String subUrl) {
    final imgName = _fileName(imgUrl);
    final subName = _fileName(subUrl);
    return imgName + subName;
  }

  static String _fileName(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    // 文件名去扩展名（.png/.webp），得到的才是 32 位 hex key。
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 原始表 → 当前生效的 32 位 mixin key（按重排表取位截前 32；每日随 nav 轮换）。
  static String deriveMixinKey(String rawKey) {
    final chars = rawKey.split('');
    final buffer = StringBuffer();
    for (var i = 0; i < 32 && i < mixinKeyEncTab.length; i++) {
      final index = mixinKeyEncTab[i];
      if (index < chars.length) buffer.write(chars[index]);
    }
    return buffer.toString();
  }

  /// 对参数签名：返回带 `wts` + `w_rid` 的最终 query map。
  static Map<String, String> sign(
    Map<String, String> params,
    String mixinKey, {
    int? wts,
  }) {
    final ts = wts ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final merged = <String, String>{...params, 'wts': '$ts'};
    // 值过滤 !()*-'.;~ 等特殊字符（社区标准去字符表），按 key 排序。
    final filtered = merged.map((k, v) => MapEntry(k, _cleanValue(v)));
    final sortedKeys = filtered.keys.toList()..sort();
    final query = sortedKeys
        .map((k) =>
            '${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(filtered[k]!)}')
        .join('&');
    final digest = md5.convert(utf8.encode('$query$mixinKey')).toString();
    return {...filtered, 'w_rid': digest};
  }

  static String _cleanValue(String v) =>
      v.replaceAll(RegExp(r"[!()*'.;~]"), '');
}

/// WBI key 缓存：nav 每日轮换，key 失效（响应 -403）时调用方刷新。
class WbiKeyCache {
  String _mixinKey = '';
  DateTime _fetchedAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isFresh =>
      _mixinKey.isNotEmpty &&
      DateTime.now().difference(_fetchedAt) < const Duration(hours: 12);

  String get mixinKey => _mixinKey;

  void update(String rawKey) {
    _mixinKey = WbiSigner.deriveMixinKey(rawKey);
    _fetchedAt = DateTime.now();
  }

  void invalidate() {
    _mixinKey = '';
    _fetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  }
}
