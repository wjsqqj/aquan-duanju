/// 命令行启动参数。
///
/// 供 AI 助手 / 脚本调用，桌面端可用：
///   aquan_duanju.exe --search 持械入宋     # 只查列表，打印到 stdout 后退出
///   aquan_duanju.exe --series ID          # 打开并直接播放这一部（有历史就续播）
///   aquan_duanju.exe --watch 持械入宋       # 程序自己搜、挑最匹配的一部开播
///   aquan_duanju.exe 持械入宋               # 裸参数等价于 --watch
class LaunchCommand {
  const LaunchCommand._({
    required this.kind,
    this.value = '',
    this.limit = 10,
    this.json = false,
  });

  /// search / series / watch / none
  final String kind;
  final String value;
  final int limit;
  final bool json;

  static const none = LaunchCommand._(kind: 'none');

  bool get isEmpty => kind == 'none';

  static LaunchCommand parse(List<String> args) {
    var kind = '';
    var value = '';
    var limit = 10;
    var json = false;
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      String? next() => i + 1 < args.length ? args[++i] : null;
      switch (a) {
        case '--search':
          kind = 'search';
          value = next() ?? '';
        case '--series':
          kind = 'series';
          value = next() ?? '';
        case '--watch':
          kind = 'watch';
          value = next() ?? '';
        case '--limit':
          limit = int.tryParse(next() ?? '') ?? 10;
        case '--json':
          json = true;
        case '--help':
        case '-h':
          kind = 'help';
        case '--version':
        case '-v':
          kind = 'version';
        default:
          if (!a.startsWith('-') && kind.isEmpty) {
            kind = 'watch';
            value = a;
          }
      }
    }
    if (kind.isEmpty) return none;
    if ((kind == 'search' || kind == 'watch') && value.trim().isEmpty) {
      return none;
    }
    if (kind == 'series' && value.trim().isEmpty) return none;
    if (limit <= 0) limit = 10;
    if (limit > 50) limit = 50;
    return LaunchCommand._(kind: kind, value: value.trim(), limit: limit, json: json);
  }

  Map<String, dynamic> toJson() =>
      {'kind': kind, 'value': value, 'limit': limit, 'json': json};

  factory LaunchCommand.fromJson(Map<String, dynamic> json) => LaunchCommand._(
        kind: json['kind'] as String? ?? 'none',
        value: json['value'] as String? ?? '',
        limit: (json['limit'] as num?)?.toInt() ?? 10,
        json: json['json'] as bool? ?? false,
      );
}

const kCliHelp = '''
阿圈短剧命令行入口（供 AI 助手 / 脚本使用）：

  aquan_duanju --search <关键词> [--limit 10] [--json]
      只查一次搜索列表，打印到 stdout 后退出，不打开窗口。

  aquan_duanju --series <ID>
      打开并直接播放这一部；有观看历史时从上次那一集那一秒续播。

  aquan_duanju --watch <关键词>
      程序自己搜索并挑最匹配的一部开播（裸参数等价）。

窗口已经在运行时，--series / --watch 会转交给已运行的窗口并置顶，
不会重复开第二个窗口。
''';
