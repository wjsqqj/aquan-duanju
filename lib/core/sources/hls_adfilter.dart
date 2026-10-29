/// HLS 清单去广告（MoonTVPlus 关键字表 + webhtv-silent1566 安全阈值，实现原创）。
///
/// 只处理**纯文本清单**：媒体清单剔除广告分片（连同其 EXTINF），主清单只做
/// URI 重写。删除比例超过 50% 判定为误杀，整体回退原文（宁可不净化不误杀）。
class HlsAdFilter {
  HlsAdFilter._();

  /// 广告分片 URI 关键字（MoonTVPlus hls-ad-filter.client.ts 同表）。
  static const adKeywords = [
    'sponsor',
    '/ad/',
    '/ads/',
    'advert',
    'advertisement',
    '/adjump',
    'redtraffic',
  ];

  /// URI 是否命中广告关键字（小写包含匹配）。
  static bool isAdUri(String uri) {
    final lower = uri.toLowerCase();
    for (final k in adKeywords) {
      if (lower.contains(k)) return true;
    }
    return false;
  }

  /// 清单是否主清单（含 STREAM-INF）。
  static bool isMasterManifest(String text) =>
      text.contains('#EXT-X-STREAM-INF');

  /// 统一入口：[rewriteUri] 把（已转绝对的）URI 换成代理 URL。
  static String rewriteManifest(
    String text,
    Uri baseUri,
    String Function(String absUri) rewriteUri,
  ) {
    if (isMasterManifest(text)) {
      return _rewriteMaster(text, baseUri, rewriteUri);
    }
    return _rewriteMedia(text, baseUri, rewriteUri);
  }

  /// 媒体清单：剥 DISCONTINUITY → 剔广告分片（连 EXTINF）→ URI 重写 → 阈值回退。
  static String _rewriteMedia(
    String text,
    Uri baseUri,
    String Function(String absUri) rewriteUri,
  ) {
    final lines = text.split('\n');
    final out = <String>[];
    var total = 0;
    var dropped = 0;
    String? pendingExtInf;

    for (var raw in lines) {
      final line = raw.trimRight();
      final trimmed = line.trim();
      // DISCONTINUITY 定界剥除（MoonTVPlus 简易策略：整段剥除保时间轴连续）。
      if (trimmed == '#EXT-X-DISCONTINUITY') continue;
      if (trimmed.startsWith('#EXTINF')) {
        pendingExtInf = line;
        continue;
      }
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        out.add(line);
        continue;
      }
      // URI 行。
      total++;
      final abs = _absolute(trimmed, baseUri);
      if (isAdUri(abs)) {
        dropped++;
        pendingExtInf = null; // 广告分片连同 EXTINF 一起丢。
        continue;
      }
      if (pendingExtInf != null) {
        out.add(pendingExtInf);
        pendingExtInf = null;
      }
      out.add(rewriteUri(abs));
    }

    // 安全阈值：删除超过一半视为误杀，回退原文（重写 URI 仍要做，否则播放坏）。
    if (total > 0 && dropped * 2 > total) {
      return _rewriteAllUris(text, baseUri, rewriteUri);
    }
    return out.join('\n');
  }

  /// 主清单：只重写码流 URI。
  static String _rewriteMaster(
    String text,
    Uri baseUri,
    String Function(String absUri) rewriteUri,
  ) =>
      _rewriteAllUris(text, baseUri, rewriteUri);

  /// 逐行把非注释行当 URI 重写（主清单与回退路径共用）。
  static String _rewriteAllUris(
    String text,
    Uri baseUri,
    String Function(String absUri) rewriteUri,
  ) {
    final out = <String>[];
    for (var raw in text.split('\n')) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        out.add(raw);
        continue;
      }
      out.add(rewriteUri(_absolute(trimmed, baseUri)));
    }
    return out.join('\n');
  }

  static String _absolute(String ref, Uri baseUri) {
    final uri = Uri.tryParse(ref);
    if (uri == null) return ref;
    if (uri.hasScheme && uri.host.isNotEmpty) return uri.toString();
    try {
      return baseUri.resolve(ref).toString();
    } catch (_) {
      return ref;
    }
  }
}
