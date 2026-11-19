import 'dart:convert';
import 'dart:io';

/// mpv 列表选项条目的跨平台安全编码。
///
/// 依据 mpv `m_option.c` 源码（v0.33 → master 逐一核对）得出的两条硬约束：
///
/// 1. `audio-files` 等 `OPT_PATHLIST`（= `m_option_type_string_list` +
///    平台分隔符 priv）由 `parse_str_list` 解析：按平台分隔符
///    （`_WIN32` → `;`，其余 → `:`）切分条目，**只支持「\ + 分隔符」转义，
///    不支持 `%n%` 长度前缀**（那是 `read_subparam` 的 keyvalue 列表语义）。
///    URL 里的 `://` 在 Android 上恰好撞上 `:` 分隔符，被切成
///    `https` + `//host/...` 两个坏条目（11-20 现场日志）——必须转义。
/// 2. `demuxer-lavf-o` 等 keyvalue 列表由 `parse_keyvalue_list` +
///    `read_subparam` 解析：值支持 `%n%` 长度前缀引用（v0.33+ 同时支持
///    `[...]` 方括号配平，但 `%n%` 语义不依赖配平、跨版本最稳）。
///    `protocol_whitelist` 值本身含逗号，不加引用会被当列表分隔符截断。
///
/// 本 helper 是这两个写入点的唯一出口，调用点不允许内联手拼（同形态字符串
/// 散落多处是 11-19 双端事故的直接原因）。

/// mpv 路径/字符串列表（`audio-files` 等）单条目的安全编码。
///
/// 把值里出现的平台分隔符转义成 `\` + 分隔符，保证 mpv 无论哪个平台都把
/// 整个值当作**一个**条目（mpv 解码时会原样去掉反斜杠还原）。原样返回
/// 原值的其余部分——mpv 对条目内容不再做任何百分号/长度前缀解释。
///
/// 注意：空串不能走这里直接 setProperty —— `parse_str_list` 对空 param
/// 也会先无条件放入一条空条目（`while (1)` 循环先 `list[0] = ""` 再退出），
/// mpv 会真的去打开空路径（11-17「Cannot open file ''」假失败事故）。
/// 清列表必须用 [mpvClearPathListCommand]（`change-list … clr`）。
String mpvListEntry(String value) {
  if (value.isEmpty) return '';
  final sep = Platform.isWindows ? ';' : ':';
  return value.replaceAll(sep, '\\$sep');
}

/// 清空 mpv 路径列表（如 `audio-files`）的 `change-list` 命令参数。
///
/// setProperty 传空串会产生空条目（见 [mpvListEntry] 注释），唯一的干净
/// 清法是 OP_CLR：mpv 的 `parse_str_list` 对名字带 `-clr` 后缀的请求在
/// 解析前直接释放整个列表、完全忽略 param（cmd_change_list 的
/// `m_option_parse(optname="audio-files-clr")` 路径，v0.34+ 行为一致）。
/// 经 [PlayerEngine.command] 下发为 `mpv_command`。
List<String> mpvClearPathListCommand(String property) =>
    <String>['change-list', property, 'clr', ''];

/// `demuxer-lavf-o` 里完整的 `protocol_whitelist=<值>` option 片段。
///
/// 值部分用 `%n%` 长度前缀引用：`n` 取 UTF-8 字节数（read_subparam 按字节
/// 取值，不是 Dart 的 code unit 数）——白名单值自身含逗号，没有引用会被
/// keyvalue 列表解析当成条目分隔符截断；`%n%` 让 mpv 恰好取 n 个字节，
/// 跨版本稳定（v0.33→master 的 read_subparam 均支持）。返回完整 key=value
/// 片段，调用点直接放进 demuxer-lavf-o 的条目列表，避免手拼漏掉键名。
String lavfProtocolWhitelist({required List<String> protocols}) {
  final joined = protocols.join(',');
  return 'protocol_whitelist=%${utf8.encode(joined).length}%$joined';
}

/// 网络流（webplay DASH / 音频轨 / TTS / 听书）通用协议白名单集合。
/// 与此前六处内联的 `[http,https,tcp,tls,crypto,data,file]` 完全一致，
/// 仅为消除字面量重复而收敛。
const List<String> kMpvLavfNetworkProtocols = <String>[
  'http', 'https', 'tcp', 'tls', 'crypto', 'data', 'file',
];

/// 本地缓存文件起播的白名单集合（file 优先，player_screen._playLocal）。
/// 与此前内联的 `[file,http,https,tcp,tls,crypto,data]` 完全一致。
const List<String> kMpvLavfLocalProtocols = <String>[
  'file', 'http', 'https', 'tcp', 'tls', 'crypto', 'data',
];
