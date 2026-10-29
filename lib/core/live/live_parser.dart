import 'dart:convert';

/// 直播频道。

// LiveConfig / extractLives 在 ../sources/source_adapter.dart（导入契约的一部分）。
class LiveChannel {
  LiveChannel({required this.name, required List<LiveUrl> urls})
      : urls = List.of(urls);

  final String name;
  final List<LiveUrl> urls;

  /// 当前使用的地址下标（备用地址自动切换推进）。
  int activeIndex = 0;
}

/// 一个地址 + 携带的请求头。
class LiveUrl {
  LiveUrl({required this.url, this.headers = const {}});
  final String url;
  final Map<String, String> headers;
}

/// 频道分组。
class LiveGroup {
  LiveGroup({required this.name, required List<LiveChannel> channels})
      : channels = List.of(channels);

  final String name;
  final List<LiveChannel> channels;
}

/// 直播源解析（webhtv LiveParser 同契约，实现原创）：
/// TXT（`#genre#` 分组 / 多地址 `#` 分隔 / `$线路名` / `url|header`）、
/// M3U（#EXTINF 属性 + #EXTVLCOPT 头）、TVBox lives JSON（新旧两种）。
class LiveParser {
  LiveParser._();

  /// 自动嗅探：JSON → M3U → TXT；全部失败抛 [FormatException]。
  static List<LiveGroup> parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const FormatException('空内容');
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      try {
        final json = jsonDecode(trimmed);
        final groups = parseJson(json);
        if (groups.isNotEmpty) return groups;
      } on FormatException {
        rethrow;
      } catch (_) {
        // 不是 JSON 或结构不符：继续嗅探文本格式。
      }
    }
    if (trimmed.contains('#EXTM3U')) return parseM3u(trimmed);
    final groups = parseTxt(trimmed);
    if (groups.isEmpty) throw const FormatException('无法识别直播源格式');
    return groups;
  }

  // ---------- TXT ----------

  /// TXT 格式：
  /// ```
  /// 央视,#genre#
  /// CCTV1,http://a/1.m3u8#http://b/1.m3u8$备用
  /// CCTV2,http://c/2|ua=okhttp&referer=http://r
  /// ```
  static List<LiveGroup> parseTxt(String text) {
    final groups = <LiveGroup>[];
    LiveGroup? current;
    for (var rawLine in text.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('//') || line.startsWith('#')) {
        continue;
      }
      final comma = line.indexOf(',');
      if (comma <= 0) continue;
      final name = line.substring(0, comma).trim();
      final value = line.substring(comma + 1).trim();
      if (value == '#genre#') {
        current = LiveGroup(name: name, channels: []);
        groups.add(current);
        continue;
      }
      if (current == null) {
        current = LiveGroup(name: '未分组', channels: []);
        groups.add(current);
      }
      final channel = LiveChannel(name: name, urls: []);
      for (final seg in value.split('#')) {
        final url = _parseUrlWithHeaders(seg.trim());
        if (url != null) channel.urls.add(url);
      }
      if (channel.urls.isNotEmpty) current.channels.add(channel);
    }
    return groups;
  }

  /// `http://x/1$线路名` 与 `http://x/1|ua=..&referer=..` 两种后缀。
  static LiveUrl? _parseUrlWithHeaders(String seg) {
    var s = seg;
    Map<String, String>? headers;
    final pipe = s.indexOf('|');
    if (pipe > 0) {
      final tail = s.substring(pipe + 1);
      s = s.substring(0, pipe);
      headers = _parseHeaderText(tail);
    }
    if (!s.startsWith('http://') && !s.startsWith('https://')) return null;
    return LiveUrl(url: s, headers: headers ?? const {});
  }

  static Map<String, String> _parseHeaderText(String text) {
    final out = <String, String>{};
    for (final pair in text.split(RegExp(r'[;&]'))) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final k = pair.substring(0, eq).trim().toLowerCase();
      final v = pair.substring(eq + 1).trim();
      if (k == 'ua' || k == 'user-agent') {
        out['User-Agent'] = v;
      } else if (k == 'referer' || k == 'ref') {
        out['Referer'] = v;
      }
    }
    return out;
  }

  // ---------- M3U ----------

  static List<LiveGroup> parseM3u(String text) {
    final groups = <LiveGroup, List<LiveChannel>>{};
    String? pendingName;
    String? pendingGroup;
    String? pendingUa;
    String? pendingReferer;
    for (var line in text.split(RegExp(r'\r?\n'))) {
      line = line.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF')) {
        pendingGroup =
            RegExp('group-title="([^"]*)"').firstMatch(line)?.group(1);
        // 显示名优先取行尾逗号后的名称；没有再用 tvg-name。
        final comma = line.lastIndexOf(',');
        pendingName =
            comma >= 0 ? line.substring(comma + 1).trim() : null;
        if (pendingName == null || pendingName.isEmpty) {
          pendingName =
              RegExp('tvg-name="([^"]*)"').firstMatch(line)?.group(1);
        }
        pendingUa = null;
        pendingReferer = null;
        continue;
      }
      if (line.startsWith('#EXTVLCOPT:http-user-agent=')) {
        pendingUa = line.substring('#EXTVLCOPT:http-user-agent='.length);
        continue;
      }
      if (line.startsWith('#EXTVLCOPT:http-referrer=')) {
        pendingReferer = line.substring('#EXTVLCOPT:http-referrer='.length);
        continue;
      }
      if (line.startsWith('#')) continue;
      if (line.startsWith('http')) {
        pendingName ??= '未命名频道';
        final group = groups.entries
            .firstWhereOrNull((e) => e.key.name == (pendingGroup ?? '未分组'));
        final key =
            group?.key ?? LiveGroup(name: pendingGroup ?? '未分组', channels: []);
        if (group == null) groups[key] = key.channels;
        final headers = <String, String>{
          'User-Agent': ?pendingUa,
          'Referer': ?pendingReferer,
        };
        key.channels.add(LiveChannel(name: pendingName, urls: [
          LiveUrl(url: line, headers: headers),
        ]));
        pendingName = null;
      }
    }
    return groups.keys
        .where((g) => g.channels.isNotEmpty)
        .map((g) => LiveGroup(name: g.name, channels: g.channels))
        .toList();
  }

  // ---------- JSON ----------

  /// TVBox lives JSON：
  /// 新 `[{group, channels:[{name, urls:[…]}]}]`；
  /// 旧 `[{group, stations:[{name, urls/urls…}]}]`。
  static List<LiveGroup> parseJson(dynamic json) {
    List items;
    if (json is List) {
      items = json;
    } else if (json is Map && json['lives'] is List) {
      items = json['lives'] as List;
    } else {
      return const [];
    }
    final out = <LiveGroup>[];
    for (final item in items) {
      if (item is! Map) continue;
      final groupName =
          (item['group'] ?? item['name'] ?? '未分组').toString();
      final channelList = item['channels'] ?? item['stations'];
      if (channelList is! List) continue;
      final group = LiveGroup(name: groupName, channels: []);
      for (final ch in channelList) {
        if (ch is! Map) continue;
        final name = (ch['name'] ?? '未命名频道').toString();
        final urls = <LiveUrl>[];
        final rawUrls = ch['urls'];
        if (rawUrls is List) {
          for (final u in rawUrls) {
            final parsed = _parseUrlWithHeaders(u.toString());
            if (parsed != null) urls.add(parsed);
          }
        }
        final single = ch['url'] ?? ch['uri'];
        if (urls.isEmpty && single is String) {
          for (final seg in single.split('#')) {
            final parsed = _parseUrlWithHeaders(seg.trim());
            if (parsed != null) urls.add(parsed);
          }
        }
        if (urls.isNotEmpty) {
          group.channels.add(LiveChannel(name: name, urls: urls));
        }
      }
      if (group.channels.isNotEmpty) out.add(group);
    }
    return out;
  }

  /// 统计摘要（导入报告用）。
  static String summarize(List<LiveGroup> groups) =>
      '${groups.length} 个分组 / ${groups.fold<int>(0, (n, g) => n + g.channels.length)} 个频道';
}

extension _FirstWhereOrNull<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}

