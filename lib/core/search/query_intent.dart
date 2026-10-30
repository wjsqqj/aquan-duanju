/// 自然语言搜索意图解析（纯规则，不依赖模型与网络）。
///
/// 输入一句人话，拆成「关键词 + 结构化条件」：
/// ```
/// 2024年9分以上的悬疑剧
///   → year=2024, minScore=9, genre=悬疑, kind=电视剧, keyword=''
/// 周星驰的喜剧
///   → people=[周星驰], genre=喜剧
/// 韩剧
///   → region=韩国, kind=电视剧
/// ```
///
/// 设计原则：**宁可少识别，也不吞字**。所有被识别出来的片段都会从原文里剔除，
/// 剩下的部分原样作为关键词；识别出的结构化条件只用于过滤，不替换关键词。
class QueryIntent {
  const QueryIntent({
    required this.raw,
    this.keyword = '',
    this.yearFrom,
    this.yearTo,
    this.minScore,
    this.kinds = const <String>{},
    this.genres = const <String>{},
    this.regions = const <String>{},
    this.people = const <String>[],
    this.role = '',
  });

  /// 原始输入。
  final String raw;

  /// 剔除结构化片段后剩下的关键词。
  final String keyword;

  final int? yearFrom;
  final int? yearTo;
  final double? minScore;

  /// 内容类型：短剧 / 电视剧 / 电影 / 动漫 / 综艺 / 小说 / 漫画。
  final Set<String> kinds;

  /// 题材：悬疑 / 喜剧 / 古装 …
  final Set<String> genres;

  /// 地区：国产 / 韩国 / 日本 / 欧美 …
  final Set<String> regions;

  /// 演员或导演名。
  final List<String> people;

  /// `actor` / `director` / 空（没显式标注）。
  final String role;

  bool get isEmpty =>
      keyword.isEmpty &&
      yearFrom == null &&
      minScore == null &&
      kinds.isEmpty &&
      genres.isEmpty &&
      regions.isEmpty &&
      people.isEmpty;

  /// 给用户看的一行摘要，如「2024年 · 悬疑 · 评分≥9」。
  String get summary {
    final parts = <String>[];
    if (yearFrom != null) {
      parts.add(yearTo != null && yearTo != yearFrom
          ? '$yearFrom-$yearTo年'
          : '$yearFrom年');
    }
    if (minScore != null) parts.add('评分≥${_trimNum(minScore!)}');
    if (regions.isNotEmpty) parts.add(regions.join('/'));
    if (kinds.isNotEmpty) parts.add(kinds.join('/'));
    if (genres.isNotEmpty) parts.add(genres.join('/'));
    if (people.isNotEmpty) {
      parts.add('${role == 'director' ? '导演' : (role == 'actor' ? '主演' : '')}'
          '${people.join('/')}');
    }
    return parts.join(' · ');
  }

  /// 建议的搜索词。
  ///
  /// 服务端目前只有关键词匹配，没有「年份/评分/类型」这类独立筛选字段，
  /// 所以把结构化条件**翻译回搜索词**而不是丢掉：
  /// - 有关键词时：关键词 + 人物（「喜剧 周星驰」）；
  /// - 纯条件句时：题材 + 类型 + 地区 + 年份（「悬疑 电视剧 2024」）。
  String get searchTerms {
    final parts = <String>[];
    if (keyword.isNotEmpty) {
      parts.add(keyword);
    } else {
      if (genres.isNotEmpty) parts.add(genres.first);
    }
    parts.addAll(people);
    if (keyword.isEmpty) {
      if (kinds.isNotEmpty) parts.add(kinds.first);
      if (regions.isNotEmpty) parts.add(regions.first);
    }
    if (yearFrom != null) parts.add('$yearFrom');
    return parts.join(' ').trim();
  }

  static String _trimNum(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

  // ---------- 词表 ----------

  static const Map<String, String> _kindWords = <String, String>{
    '短剧': '短剧',
    '微短剧': '短剧',
    '电视剧': '电视剧',
    '连续剧': '电视剧',
    '剧集': '电视剧',
    '电影': '电影',
    '影片': '电影',
    '动漫': '动漫',
    '动画': '动漫',
    '番剧': '动漫',
    '综艺': '综艺',
    '小说': '小说',
    '漫画': '漫画',
  };

  static const List<String> _genreWords = <String>[
    '悬疑',
    '推理',
    '甜宠',
    '科幻',
    '喜剧',
    '搞笑',
    '动作',
    '古装',
    '都市',
    '恐怖',
    '惊悚',
    '爱情',
    '犯罪',
    '战争',
    '武侠',
    '奇幻',
    '青春',
    '家庭',
    '职场',
    '历史',
    '冒险',
    '剧情',
    '热血',
  ];

  static const Map<String, String> _regionWords = <String, String>{
    '国产': '国产',
    '内地': '国产',
    '大陆': '国产',
    '港台': '港台',
    '香港': '香港',
    '台湾': '台湾',
    '日韩': '日韩',
    '韩国': '韩国',
    '韩剧': '韩国',
    '日本': '日本',
    '日剧': '日本',
    '美剧': '欧美',
    '美国': '欧美',
    '欧美': '欧美',
    '英国': '欧美',
    '泰国': '泰国',
    '泰剧': '泰国',
  };

  /// `X的Y` 里 X 不可能是人名的常见词。
  static const Set<String> _peopleStopWords = <String>{
    '我',
    '你',
    '他',
    '她',
    '它',
    '我们',
    '你们',
    '他们',
    '她们',
    '这个',
    '那个',
    '这些',
    '那些',
    '什么',
    '最近',
    '今年',
    '去年',
    '明年',
    '今天',
    '昨天',
    '好看',
    '最好',
    '经典',
    '热门',
    '高分',
    '推荐',
    '类似',
    '同款',
    '免费',
    '最新',
    '以上',
    '以下',
    '之间',
    '左右',
    '这种',
    '那种',
  };

  /// 高频中文姓氏：`X的Y` 里 X 首字必须在这里，才当人名。
  ///
  /// 没有词典时这是最省事又足够准的判据——「最好看的悬疑剧」不会因为
  /// 「最好看」刚好 3 个字就被认成人名。
  static const Set<String> _surnames = <String>{
    '赵', '钱', '孙', '李', '周', '吴', '郑', '王', '冯', '陈',
    '蒋', '沈', '韩', '杨', '朱', '秦', '许', '何', '吕', '施',
    '张', '孔', '曹', '严', '华', '金', '魏', '陶', '姜', '谢',
    '邹', '苏', '潘', '葛', '范', '彭', '鲁', '马', '苗', '方',
    '俞', '任', '袁', '柳', '唐', '薛', '雷', '贺', '倪', '汤',
    '罗', '毕', '郝', '安', '常', '傅', '齐', '康', '伍', '余',
    '顾', '孟', '黄', '穆', '萧', '尹', '姚', '邵', '汪', '毛',
    '米', '戴', '宋', '庞', '熊', '纪', '舒', '项', '祝', '董',
    '梁', '杜', '阮', '蓝', '贾', '江', '郭', '梅', '林', '钟',
    '徐', '高', '夏', '蔡', '田', '樊', '胡', '霍', '万', '卢',
    '莫', '房', '解', '丁', '邓', '洪', '石', '崔', '程', '陆',
    '荣', '翁', '刘', '白', '怀', '蒲', '卓', '蒙', '池', '乔',
    '翟', '谭', '劳', '姬', '申', '桑', '桂', '牛', '温', '庄',
    '晏', '柴', '阎', '艾', '向', '古', '易', '戈', '廖', '居',
    '文', '寇', '欧', '沃', '利', '越', '隆', '师', '巩', '聂',
    '辛', '简', '饶', '曾', '沙', '丰', '关', '查', '荆', '红',
    '游', '权', '盖', '益', '桓',
  };

  static final RegExp _yearRange =
      RegExp(r'(20\d{2})\s*[-~到至]\s*(20\d{2})\s*年?');
  static final RegExp _yearSingle = RegExp(r'(20\d{2})\s*年');
  static final RegExp _yearBare = RegExp(r'(?<!\d)(20\d{2})(?!\d)');
  static final RegExp _score =
      RegExp(r'(?:评分|得分)?\s*(\d{1,2}(?:\.\d)?)\s*分\s*(?:以上|\+|往上)?');
  static final RegExp _scorePrefix = RegExp(r'评分\s*(\d{1,2}(?:\.\d)?)');
  static final RegExp _rolePerson =
      RegExp(r'(主演|演员|导演)\s*[:：]?\s*([\u4e00-\u9fa5]{2,4})');
  static final RegExp _possessive = RegExp(r'([\u4e00-\u9fa5]{2,4})的');

  /// 解析一句自然语言。
  static QueryIntent parse(String input) {
    final raw = input.trim();
    if (raw.isEmpty) return const QueryIntent(raw: '');

    var rest = raw;
    int? yearFrom;
    int? yearTo;
    double? minScore;
    final kinds = <String>{};
    final genres = <String>{};
    final regions = <String>{};
    final people = <String>[];
    var role = '';

    String take(RegExp pattern) {
      final match = pattern.firstMatch(rest);
      if (match == null) return '';
      rest = rest.replaceRange(match.start, match.end, ' ');
      return match.group(0) ?? '';
    }

    // 1) 近 N 年。
    if (rest.contains('近三年') || rest.contains('最近三年')) {
      final now = DateTime.now().year;
      yearFrom = now - 2;
      yearTo = now;
      rest = rest.replaceAll('近三年', ' ').replaceAll('最近三年', ' ');
    }

    // 2) 年份区间优先于单年。
    final rangeText = take(_yearRange);
    if (rangeText.isNotEmpty) {
      final m = _yearRange.firstMatch(rangeText)!;
      yearFrom = int.tryParse(m.group(1)!);
      yearTo = int.tryParse(m.group(2)!);
    } else {
      final singleText = take(_yearSingle);
      if (singleText.isNotEmpty) {
        final m = _yearSingle.firstMatch(singleText)!;
        yearFrom = int.tryParse(m.group(1)!);
        yearTo = yearFrom;
      } else {
        final bareText = take(_yearBare);
        if (bareText.isNotEmpty) {
          yearFrom = int.tryParse(bareText);
          yearTo = yearFrom;
        }
      }
    }

    // 3) 评分（「9分以上」优先，其次「评分9」）。
    final scoreText = take(_score);
    if (scoreText.isNotEmpty) {
      final m = _score.firstMatch(scoreText)!;
      minScore = double.tryParse(m.group(1)!);
    } else {
      final prefixText = take(_scorePrefix);
      if (prefixText.isNotEmpty) {
        final m = _scorePrefix.firstMatch(prefixText)!;
        minScore = double.tryParse(m.group(1)!);
      }
    }

    // 4) 人物（只在显式标注时取，避免把普通词当人名）。
    final roleMatch = _rolePerson.firstMatch(rest);
    if (roleMatch != null) {
      final name = roleMatch.group(2)!;
      if (!_peopleStopWords.contains(name)) {
        role = roleMatch.group(1) == '导演'
            ? 'director'
            : (roleMatch.group(1) == '主演' || roleMatch.group(1) == '演员')
                ? 'actor'
                : '';
        people.add(name);
        rest = rest.replaceRange(roleMatch.start, roleMatch.end, ' ');
      }
    } else {
      // `X的Y`：X 不在停用词表、且后面跟的是题材/类型词时才当人名。
      for (final match in _possessive.allMatches(rest).toList()) {
        final name = match.group(1)!;
        if (_peopleStopWords.contains(name)) continue;
        if (!_surnames.contains(name[0])) continue;
        final tail = rest.substring(match.end);
        final isBeforeFilter = _kindWords.keys.any(tail.startsWith) ||
            _genreWords.any(tail.startsWith) ||
            _regionWords.keys.any(tail.startsWith);
        if (!isBeforeFilter) continue;
        people.add(name);
        rest = rest.replaceRange(match.start, match.end, ' ');
        break;
      }
    }

    // 5) 类型 / 地区 / 题材（长词优先，避免「悬疑剧」只吃到「悬疑」）。
    for (final entry in _regionWords.entries) {
      if (rest.contains(entry.key)) {
        regions.add(entry.value);
        // 「韩剧」同时是电视剧。
        if (entry.key.endsWith('剧')) kinds.add('电视剧');
        rest = rest.replaceAll(entry.key, ' ');
      }
    }
    for (final entry in _kindWords.entries) {
      if (rest.contains(entry.key)) {
        kinds.add(entry.value);
        rest = rest.replaceAll(entry.key, ' ');
      }
    }
    for (final genre in _genreWords) {
      if (rest.contains(genre)) {
        genres.add(genre);
        rest = rest.replaceAll(genre, ' ');
      }
    }

    // 「悬疑剧」这类「题材+剧」的组合，补一个电视剧类型。
    // 判据必须是「题材词后面跟着剧」，不能是整句含「剧」——
    // 否则「周星驰的喜剧」会被误判成电视剧。
    final hasGenreDrama =
        _genreWords.any((genre) => raw.contains('$genre剧'));
    if (kinds.isEmpty && genres.isNotEmpty && hasGenreDrama) {
      kinds.add('电视剧');
    }
    // 已推断出电视剧时，把孤立残留的「剧」字去掉。
    if (kinds.contains('电视剧')) rest = rest.replaceAll('剧', ' ');

    final keyword = rest
        .replaceAll(RegExp(r'[的了吗呢吧啊]'), ' ')
        .replaceAll(RegExp(r'[，,。.、；;：:!！?？]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return QueryIntent(
      raw: raw,
      keyword: keyword,
      yearFrom: yearFrom,
      yearTo: yearTo,
      minScore: minScore,
      kinds: kinds,
      genres: genres,
      regions: regions,
      people: people,
      role: role,
    );
  }
}
