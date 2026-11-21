/// 播放错误归因闸门（纯逻辑，无 Flutter 依赖，
/// [player_screen._onPlaybackError] 集成方执行动作）。
///
/// 前提（design.md 边界）：mpv 的异步错误事件**不带**产生它的 loadfile
/// 身份，而播放器引擎跨换线复用（errorStream 订阅只在建引擎时接一次），
/// 上一次尝试的 mpv 错误（如外挂音轨 URL 被列表分隔符切坏后的打开失败）
/// 会在新尝试开播后陆续抵达。「错误属于哪次尝试」只能靠文本自证：mpv 的
/// 打开失败错误几乎都会把目标 URL/路径原样写进文本
/// （`Cannot open file '//host/…'`、`Failed to open https://…`、
/// `Can not open external file //host/…`）。
///
/// 现场（2026-11-21 真机换线风暴）：webplay 尝试的音轨拆分错误触发换线
/// 后，残留错误继续抵达并被算进健康的 v5 尝试 → `Failed to open https.`
/// 判 permanent → 2.5s 内烧掉 5/6 换线预算 → 错误面板。闸门在错误进入
/// 风暴守卫/换线预算/健康分/错误面板**之前**，把「有证据来自退役尝试」的
/// 错误拦下（调用方只记诊断日志并忽略）。
///
/// 保守缺省：抽不到 URL、URL 不属于任何一方（未知 host）、裸片段但当前
/// 尝试有音轨——一律判非残留，宁可多换一次线，不吞真实失败
/// （漏拦的兜底是 75s 加载超时 watchdog，误拦的代价是静默吞真实错误）。
class PlaybackErrorScope {
  /// 退役集合上限（每次 [beginAttempt] 裁剪到最近 16 条）：16 ≈ 最近 8 组
  /// 尝试（每组 video+audio 各一条）。长 binge 播放逼近常量上界，不无界膨胀。
  static const int retiredLimit = 16;

  /// URL 形态 token：mpv 错误文本原样嵌入 URL（转义/百分号原样保留），
  /// 覆盖 `https?://…` 与协议相对 `//…`（路径列表被平台分隔符切开后
  /// **后半条目**的形态）；空白、引号、尖括号、中文标点是文本语境，
  /// 直接终止 token。
  static final RegExp _tokenPattern = RegExp(
    r'''(?:https?://|//)[^\s'"<>，。…]+''',
  );

  /// token 尾部要剥掉的标点：mpv 常把 URL 写进 `Cannot open file '…'` 这类
  /// 句式里，句尾的引号/句号不是 URL 的一部分。
  static const String _trailingPunctuation = ',.;:)]}>\'"';

  /// 裸片段特判的 needle（小写比对）：路径列表切分把 `://` 处切开后，
  /// `https` 独立成一个坏条目，错误文本只剩这个**裸片段**（无 host、无
  /// `://`，URL 正则抽不到），只能按文案形态识别。
  static const List<String> _bareFragments = [
    'failed to open https',
    "cannot open file 'https'",
    'can not open external file https',
  ];

  String _currentVideoUrl = '';
  String _currentAudioUrl = '';
  List<String> _currentUrls = const [];
  Set<String> _currentHosts = const {};
  // 退役集合：FIFO 有界（List 保序裁剪；Set 按 LinkedHashSet 插入序裁剪）。
  final List<String> _retiredUrls = <String>[];
  final Set<String> _retiredHosts = <String>{};

  /// 退役 URL 集合当前条数（诊断/测试用：验证有界性）。
  int get retiredUrlCount => _retiredUrls.length;

  /// 退役 host 集合当前条数（诊断/测试用：验证有界性）。
  int get retiredHostCount => _retiredHosts.length;

  /// 登记一次新尝试：当前 URL 集合换新，上一条的 URL+host 转入退役集合
  /// （FIFO 有界，见 [retiredLimit]）。
  ///
  /// 与新尝试相同的 URL 也会退役（重试同一线路）：判定时 current 先于
  /// retired 检查，同 host 的错误永远优先归「当前」，不产生误拦。
  void beginAttempt({required String videoUrl, String audioUrl = ''}) {
    _retiredUrls.addAll(_currentUrls);
    _retiredHosts.addAll(_currentHosts);
    while (_retiredUrls.length > retiredLimit) {
      _retiredUrls.removeAt(0);
    }
    while (_retiredHosts.length > retiredLimit) {
      _retiredHosts.remove(_retiredHosts.first);
    }
    _currentVideoUrl = videoUrl;
    _currentAudioUrl = audioUrl;
    _currentUrls = <String>{
      if (videoUrl.isNotEmpty) videoUrl,
      if (audioUrl.isNotEmpty) audioUrl,
    }.toList(growable: false);
    final hosts = <String>{};
    for (final url in _currentUrls) {
      final host = _hostOf(url);
      if (host != null) hosts.add(host);
    }
    _currentHosts = hosts;
  }

  /// true = 有证据表明错误来自退役尝试（调用方只记诊断日志并忽略，不得
  /// 影响风暴守卫/换线预算/健康分/_rawPlaybackError/错误面板）。
  bool isStale(String rawError) {
    final tokens = _extractTokens(rawError);
    if (tokens.isEmpty) {
      // 无 URL 可归因：裸片段特判（列表切分 artifacts），不中则保守不拦。
      return _isBareFragmentStale(rawError.toLowerCase());
    }
    // 规则 2（先于规则 3）：任一 token 属于当前尝试 → 它自己的错误。
    // host 相同时「当前」必须优先于「退役」——同音轨换线复用同一 CDN
    // host（query 不同），不能因为 host 也躺在退役集合里就拦掉。
    for (final t in tokens) {
      if (_currentUrls.contains(t.exact) ||
          _currentUrls.contains(t.withScheme)) {
        return false;
      }
      if (t.host != null && _currentHosts.contains(t.host)) return false;
    }
    // 规则 3：token 只能证明来自退役尝试 → 残留。
    for (final t in tokens) {
      if (_retiredUrls.contains(t.exact) ||
          _retiredUrls.contains(t.withScheme)) {
        return true;
      }
      if (t.host != null && _retiredHosts.contains(t.host)) return true;
    }
    // 规则 4（保守缺省）：无证据（未知 host 等）→ 不拦，走既有分类。
    return false;
  }

  /// 从错误文本抽 URL token（去尾部标点、补 scheme、解析 host）。
  List<_ErrorToken> _extractTokens(String raw) {
    final tokens = <_ErrorToken>[];
    for (final match in _tokenPattern.allMatches(raw)) {
      var token = match.group(0)!;
      while (token.isNotEmpty &&
          _trailingPunctuation.contains(token[token.length - 1])) {
        token = token.substring(0, token.length - 1);
      }
      if (token.isEmpty) continue;
      // 协议相对 `//host/…`（路径列表切分的后半条目）：补 `https:` 才能取
      // host，也才能与登记用的完整 URL 精确比对。
      final withScheme = token.startsWith('//') ? 'https:$token' : token;
      tokens.add(
        _ErrorToken(
          exact: token,
          withScheme: withScheme,
          host: _hostOf(withScheme),
        ),
      );
    }
    return tokens;
  }

  /// 裸片段特判：`Failed to open https.` / `Cannot open file 'https'` /
  /// `Can not open external file https.` 这类无 host 可归因的文案。
  ///
  /// 仅当**当前尝试没有外挂音轨**且 videoUrl 是合法 http(s) URL 时判残留：
  /// 外挂音轨错误只能来自 `audio-files` 条目，当前尝试没有音轨，转义修复
  /// 后也不可能再产生该片段 → 只能是退役尝试的残留。当前尝试有音轨时不
  /// 特判（旧 APK 上那是它自己真实的音轨故障，换线是正确行为）；videoUrl
  /// 解析不出 http(s) host 时不特判（坏地址场景的错误必须如实上报）。
  bool _isBareFragmentStale(String lower) {
    if (!_bareFragments.any(lower.contains)) return false;
    if (_currentAudioUrl.isNotEmpty) return false;
    final uri = Uri.tryParse(_currentVideoUrl);
    if (uri == null || uri.host.isEmpty) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    return true;
  }

  /// 从完整 URL 取 host；解析失败或无 host 返回 null（调用方退化为只用
  /// 原字符串精确比对）。
  static String? _hostOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.host;
  }
}

/// 错误文本里抽出的一个 URL token：原样（精确比对）+ 补 scheme 形态
/// （与登记的完整 URL 对齐）+ host（集合归属判定）。
class _ErrorToken {
  const _ErrorToken({
    required this.exact,
    required this.withScheme,
    required this.host,
  });

  final String exact;
  final String withScheme;
  final String? host;
}
